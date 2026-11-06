// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#include "MetalRenderer.h"

#import <Metal/Metal.h>
#include <dispatch/dispatch.h>

#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstring>
#include <map>

namespace whorld {

namespace {

// Shaders, compiled at run time so the build needs no Metal toolchain.
const char *const kShaderSource = R"(
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; };

// pixel coordinates (top-left origin, y down) to clip space
vertex VOut vsPath(uint vid [[vertex_id]], const device float2 *v [[buffer(0)]],
	constant float2 &size [[buffer(1)]])
{
	float2 p = v[vid];
	VOut o;
	o.pos = float4(p.x / size.x * 2 - 1, 1 - p.y / size.y * 2, 0, 1);
	return o;
}

// one triangle covering the whole target
vertex VOut vsFull(uint vid [[vertex_id]])
{
	float2 p = float2((vid << 1) & 2, vid & 2);
	VOut o;
	o.pos = float4(p * 2 - 1, 0, 1);
	return o;
}

fragment float4 fsColor(constant float4 &clr [[buffer(0)]])
{
	return clr;	// premultiplied
}

fragment float4 fsCopy(VOut in [[stage_in]], texture2d<float> src [[texture(0)]])
{
	return src.read(uint2(in.pos.xy));
}

// ---- coverage mode: per-path 64-sample masks in tile memory ----
//
// Each path's triangles set bits in a 64-sample mask per pixel (attachment
// 1), ORed for strokes and rects, XORed for even-odd fill fans; a second
// draw of the same triangles blends the path's color once per pixel with
// coverage = set bits / 64 and clears the mask. That is how Direct2D blends
// a shape: by its own coverage, independently of other shapes.

struct TOut {
	float4 pos [[position]];
	float2 a [[flat]];
	float2 b [[flat]];
	float2 c [[flat]];
};

// One instance per triangle (three float2 at buffer 0). The rasterized
// shape is the triangle grown by 0.75 px, so that every pixel the triangle
// touches gets a fragment; very thin triangles use their grown bounding box
// instead. Vertices 3..5 are only used for the box.
vertex TOut vsTri(uint vid [[vertex_id]], uint iid [[instance_id]],
	const device float2 *v [[buffer(0)]], constant float2 &size [[buffer(1)]])
{
	float2 a = v[iid * 3], b = v[iid * 3 + 1], c = v[iid * 3 + 2];
	TOut o;
	o.a = a; o.b = b; o.c = c;
#if ABLATE_NOGROW
	const float d = 0.0;
#else
	const float d = 0.75;
#endif
	float area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
	float2 p;
	bool bBox = true;
	if (area != 0) {
		// outward unit normals of the edges ab, bc, ca
		float s = area > 0 ? 1 : -1;
		float2 eab = normalize(b - a), ebc = normalize(c - b), eca = normalize(a - c);
		float2 nab = s * float2(eab.y, -eab.x), nbc = s * float2(ebc.y, -ebc.x), nca = s * float2(eca.y, -eca.x);
		float ka = 1 + dot(nca, nab), kb = 1 + dot(nab, nbc), kc = 1 + dot(nbc, nca);
		if (min(ka, min(kb, kc)) > 0.08) {	// no corner sharper than about 33 degrees
			bBox = false;
			if (vid >= 3) {
				p = a;	// degenerate: unused
			} else {
				float2 q = vid == 0 ? a : vid == 1 ? b : c;
				float2 n1 = vid == 0 ? nca : vid == 1 ? nab : nbc;
				float2 n2 = vid == 0 ? nab : vid == 1 ? nbc : nca;
				p = q + (n1 + n2) * (d / (1 + dot(n1, n2)));
			}
		}
	}
	if (bBox) {
		float2 lo = min(a, min(b, c)) - d, hi = max(a, max(b, c)) + d;
		const uint2 k[6] = {uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1)};
		p = float2(k[vid].x ? hi.x : lo.x, k[vid].y ? hi.y : lo.y);
		if (area == 0)
			p = lo;	// nothing to draw
	}
	o.pos = float4(p.x / size.x * 2 - 1, 1 - p.y / size.y * 2, 0, 1);
	return o;
}

// 64 sample positions in a pixel, n-rooks: x = (k + 0.5) / 64, y = ((37k mod 64) + 0.5) / 64
//
// Each edge p -> q becomes a linear form e(s) = A s.x + B s.y + C, built from
// the endpoints in a canonical order, so the two triangles sharing an edge
// get exactly opposite forms, and a sample on the edge (e = 0) is given to
// exactly one of them, by the sign of the gradient (A, B).
struct Edge {
	float A, B, C;
	bool tie;	// inside when e = 0
	float g;	// +1 or -1: (A, B, C) * g is the canonical form, shared by both sides
};

inline Edge MakeEdge(float2 p, float2 q, float sign)
{
	bool swap = p.x > q.x || (p.x == q.x && p.y > q.y);
	float2 u = swap ? q : p, w = swap ? p : q;
	float g = swap ? -sign : sign;
	float dx = w.x - u.x, dy = w.y - u.y;
	Edge e;
	e.A = -dy * g;
	e.B = dx * g;
	e.C = (dy * u.x - dx * u.y) * g;
	e.tie = e.A > 0 || (e.A == 0 && e.B > 0);
	e.g = g;
	return e;
}

// Sample mask of one edge from the lookup table (see BuildMaskTable): rows
// are the canonical normal's angle, columns its signed distance from the
// pixel center. Both triangles sharing an edge compute the same canonical
// form, hence the same entry, and the one on the other side takes its
// complement, so they split the samples exactly.
constant int kLutAngles = 512, kLutDists = 256;
constant float kLutR = 0.7072;	// just over half the pixel diagonal

inline uint2 EdgeMask(Edge e, texture2d<uint> lut)
{
	float A0 = e.A * e.g, B0 = e.B * e.g, C0 = e.C * e.g;
	float len = sqrt(A0 * A0 + B0 * B0);
	float r = -(C0 + 0.5 * (A0 + B0)) / len;
	int i = int(rint(atan2(B0, A0) * (kLutAngles / (2 * M_PI_F)))) & (kLutAngles - 1);
	int j = clamp(int(rint((r + kLutR) * ((kLutDists - 1) / (2 * kLutR)))), 0, kLutDists - 1);
	uint2 m = lut.read(uint2(j, i)).xy;
	return e.g > 0 ? m : ~m;
}

inline bool Inside(Edge e, float2 s)
{
	float v = fma(e.A, s.x, fma(e.B, s.y, e.C));
	return v > 0 || (v == 0 && e.tie);
}

inline float2 Sample(uint k)
{
	return float2((k + 0.5) / 64, (((k * 37) & 63) + 0.5) / 64);
}

#if PROF_COUNT
#define COUNT(i) atomic_fetch_add_explicit(&cnt[i], 1, memory_order_relaxed)
#define CNT_ARG , device atomic_uint *cnt
#define CNT_PASS , cnt
#define CNT_PARAM , device atomic_uint *cnt [[buffer(2)]]
#else
#define COUNT(i)
#define CNT_ARG
#define CNT_PASS
#define CNT_PARAM
#endif

// fragment counts (PROF_COUNT): 0 degenerate, 1 outside an edge, 2 full,
// 3..5 one..three crossing edges, 6 no sample covered after the loop
inline uint2 TriangleMask(TOut in, texture2d<uint> lut CNT_ARG)
{
	float2 o = floor(in.pos.xy);
	float2 a = in.a - o, b = in.b - o, c = in.c - o;
	float area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
	if (area == 0) {
		COUNT(0);
		return uint2(0);
	}
	float sg = area > 0 ? 1 : -1;
	Edge e3[3] = {MakeEdge(a, b, sg), MakeEdge(b, c, sg), MakeEdge(c, a, sg)};
	// Classify each edge by the pixel's corners (e is linear, so the samples
	// lie between the corner values): all outside, the pixel is empty; all
	// inside, the edge can't exclude a sample. Only crossing edges are tested.
	Edge x[3];
	int n = 0;
	for (int i = 0; i < 3; i++) {
		Edge e = e3[i];
		float v00 = e.C, v10 = e.A + e.C, v01 = e.B + e.C, v11 = e.A + e.B + e.C;
		float lo = min(min(v00, v10), min(v01, v11)), hi = max(max(v00, v10), max(v01, v11));
		if (hi < 0) {
			COUNT(1);
			return uint2(0);
		}
		if (lo > 0)
			continue;
		x[n++] = e;
	}
	if (n == 0) {
		COUNT(2);
		return uint2(0xFFFFFFFF);
	}
	COUNT(2 + n);
#if ABLATE_LOOP
	return uint2(0x55555555);	// half coverage, no per-sample tests
#endif
#if !EXACT_LOOP
	uint2 m = EdgeMask(x[0], lut);
	if (n > 1) m &= EdgeMask(x[1], lut);
	if (n > 2) m &= EdgeMask(x[2], lut);
#else
	uint2 m = uint2(0);
	if (n == 1) {
		Edge e = x[0];
		for (uint k = 0; k < 32; k++) {
			m.x |= uint(Inside(e, Sample(k))) << k;
			m.y |= uint(Inside(e, Sample(k + 32))) << k;
		}
	} else {
		Edge e0 = x[0], e1 = x[1];
		Edge e2 = n == 3 ? x[2] : Edge{0, 0, 1, false};	// always inside
		for (uint k = 0; k < 32; k++) {
			float2 s = Sample(k), t = Sample(k + 32);
			m.x |= uint(Inside(e0, s) && Inside(e1, s) && Inside(e2, s)) << k;
			m.y |= uint(Inside(e0, t) && Inside(e1, t) && Inside(e2, t)) << k;
		}
	}
#endif
	if (!any(m != 0))
		COUNT(6);
	return m;
}

struct FBOut {
	float4 color [[color(0)]];
	uint2 mask [[color(1)]];
};

// The triangle's mask is computed before the framebuffer is read, and a
// fragment that covers no sample is discarded: overlapping fragments on a
// pixel wait for each other only where they touch the framebuffer.
fragment FBOut fsMaskOr(TOut in [[stage_in]], uint2 m [[color(1)]],
	texture2d<uint> lut [[texture(0)]] CNT_PARAM)
{
	uint2 t = TriangleMask(in, lut CNT_PASS);
	if (!any(t != 0))
		discard_fragment();
	FBOut o;
	o.color = float4(0);	// not written (write mask)
	o.mask = m | t;
	return o;
}

fragment FBOut fsMaskXor(TOut in [[stage_in]], uint2 m [[color(1)]],
	texture2d<uint> lut [[texture(0)]] CNT_PARAM)
{
	uint2 t = TriangleMask(in, lut CNT_PASS);
	if (!any(t != 0))
		discard_fragment();
	FBOut o;
	o.color = float4(0);
	o.mask = m ^ t;
	return o;
}

fragment FBOut fsCover(TOut in [[stage_in]], float4 dst [[color(0)]], uint2 m [[color(1)]],
	constant float4 &clr [[buffer(0)]])
{
	float cov = float(popcount(m.x) + popcount(m.y)) / 64;
	FBOut o;
	o.color = clr * cov + dst * (1 - clr.a * cov);	// premultiplied source-over
	o.mask = uint2(0);
	return o;
}

fragment FBOut fsClearCov(constant float4 &clr [[buffer(0)]])
{
	FBOut o;
	o.color = clr;
	o.mask = uint2(0);
	return o;
}

// CWhorldDraw::FinishMirroring: the upper-left quadrant copied flipped
// into the other three, reflecting across the full frame
fragment float4 fsMirror(VOut in [[stage_in]], texture2d<float> src [[texture(0)]],
	constant uint4 &sz [[buffer(0)]])	// width, height, quadrant width, quadrant height
{
	uint x = uint(in.pos.x), y = uint(in.pos.y);
	uint sx = x < sz.z ? x : sz.x - 1 - x;
	uint sy = y < sz.w ? y : sz.y - 1 - y;
	return src.read(uint2(sx, sy));
}
)";

// Coverage mode edge lookup table; must match kLut* in the shader. Entry
// (angle i, distance j) holds the mask of the 64 samples s with
// dot(n, s - center) > r, for n = (cos, sin)(2 pi i / kLutAngles) and
// r = -kLutR + 2 kLutR j / (kLutDists - 1). Samples as Sample() in the shader.
const int	kLutAngles = 512, kLutDists = 256;
const float	kLutR = 0.7072f;

void BuildMaskTable(std::vector<uint32_t>& aLut)
{
	aLut.assign(size_t(kLutAngles) * kLutDists * 2, 0);
	float	sx[64], sy[64];
	for (int k = 0; k < 64; k++) {
		sx[k] = (k + 0.5f) / 64 - 0.5f;
		sy[k] = (((k * 37) & 63) + 0.5f) / 64 - 0.5f;
	}
	for (int i = 0; i < kLutAngles; i++) {
		double	a = 2 * M_PI * i / kLutAngles;
		float	nx = float(std::cos(a)), ny = float(std::sin(a));
		for (int j = 0; j < kLutDists; j++) {
			float	r = -kLutR + 2 * kLutR * j / (kLutDists - 1);
			uint32_t	*p = &aLut[(size_t(i) * kLutDists + j) * 2];
			for (int k = 0; k < 64; k++) {
				if (nx * sx[k] + ny * sy[k] > r)
					p[k >> 5] |= 1u << (k & 31);
			}
		}
	}
}

// stencil bits: the top bit for even-odd fills, the low 7 for the
// per-stroke reference
const uint32_t kFillBit = 0x80;
const uint32_t kStrokeMask = 0x7F;

double MsSince(std::chrono::steady_clock::time_point t0)
{
	return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

} // namespace

struct MetalRenderer::Impl {
	id<MTLDevice>	device;
	id<MTLCommandQueue>	queue;
	id<MTLLibrary>	library;
	id<MTLTexture>	target;		// the frame, 1 sample
	id<MTLTexture>	scratch;	// before mirroring, and for reloading after it
	std::map<int, id<MTLTexture>>	msaa;		// by sample count
	std::map<int, id<MTLTexture>>	stencil;
	struct Pipelines {
		id<MTLRenderPipelineState>	blend;		// source-over, premultiplied
		id<MTLRenderPipelineState>	replace;	// Clear: no blending
		id<MTLRenderPipelineState>	stencilOnly;	// no color writes
		id<MTLRenderPipelineState>	stencilOnlyFull;	// full-target triangle
		id<MTLRenderPipelineState>	clearFull;	// Clear: full-target triangle
		id<MTLRenderPipelineState>	copyFull;	// reload the frame
		id<MTLRenderPipelineState>	mirror;
	};
	std::map<int, Pipelines>	pipes;
	struct CovPipelines {
		id<MTLRenderPipelineState>	maskOr, maskXor, cover, clear;
	} cov;
	id<MTLTexture>	mask;	// coverage mode: RG32Uint, tile memory only
	id<MTLBuffer>	counts;	// coverage mode fragment counts (profiling)
	id<MTLTexture>	maskLut;	// coverage mode: edge sample masks, RG32Uint
	id<MTLDepthStencilState>	dssNone;
	id<MTLDepthStencilState>	dssFillMark;	// invert the fill bit
	id<MTLDepthStencilState>	dssFillCover;	// draw where set, clearing it
	id<MTLDepthStencilState>	dssStroke;		// draw where ref > stored, store ref
	id<MTLDepthStencilState>	dssStrokeReset;	// zero the stroke bits
	id<MTLBuffer>	vertices;
	id<MTLCommandBuffer>	lastCmd;
	bool	bMemoryless = false;
	bool	bShared = true;

	id<MTLTexture> MakeTexture(MTLPixelFormat fmt, int w, int h, int nSamples, bool bRead)
	{
		MTLTextureDescriptor	*d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
			width:w height:h mipmapped:NO];
		d.usage = MTLTextureUsageRenderTarget | (bRead ? MTLTextureUsageShaderRead : 0);
		if (nSamples > 1) {
			d.textureType = MTLTextureType2DMultisample;
			d.sampleCount = nSamples;
			d.storageMode = bMemoryless ? MTLStorageModeMemoryless : MTLStorageModePrivate;
		} else if (fmt == MTLPixelFormatStencil8) {
			d.storageMode = bMemoryless ? MTLStorageModeMemoryless : MTLStorageModePrivate;
		} else {
			d.storageMode = MTLStorageModePrivate;
		}
		return [device newTextureWithDescriptor:d];
	}

	id<MTLRenderPipelineState> MakeCovPipe(NSString *vs, NSString *fs, bool bColor)
	{
		MTLRenderPipelineDescriptor	*d = [MTLRenderPipelineDescriptor new];
		d.vertexFunction = [library newFunctionWithName:vs];
		d.fragmentFunction = [library newFunctionWithName:fs];
		d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		d.colorAttachments[1].pixelFormat = MTLPixelFormatRG32Uint;
		if (!bColor)
			d.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
		NSError	*err = nil;
		id<MTLRenderPipelineState>	p = [device newRenderPipelineStateWithDescriptor:d error:&err];
		if (!p)
			NSLog(@"MetalRenderer: pipeline %@/%@: %@", vs, fs, err);
		return p;
	}

	id<MTLRenderPipelineState> MakePipe(NSString *vs, NSString *fs, int nSamples, bool bBlend, bool bColor,
		bool bStencil = true)
	{
		MTLRenderPipelineDescriptor	*d = [MTLRenderPipelineDescriptor new];
		d.vertexFunction = [library newFunctionWithName:vs];
		d.fragmentFunction = [library newFunctionWithName:fs];
		d.rasterSampleCount = nSamples;
		d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		if (bStencil)
			d.stencilAttachmentPixelFormat = MTLPixelFormatStencil8;
		if (!bColor)
			d.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
		if (bBlend) {
			auto	*c = d.colorAttachments[0];
			c.blendingEnabled = YES;
			c.sourceRGBBlendFactor = MTLBlendFactorOne;
			c.sourceAlphaBlendFactor = MTLBlendFactorOne;
			c.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
			c.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		}
		NSError	*err = nil;
		id<MTLRenderPipelineState>	p = [device newRenderPipelineStateWithDescriptor:d error:&err];
		if (!p)
			NSLog(@"MetalRenderer: pipeline %@/%@: %@", vs, fs, err);
		return p;
	}

	const Pipelines& GetPipes(int nSamples)
	{
		auto	it = pipes.find(nSamples);
		if (it != pipes.end())
			return it->second;
		Pipelines	p;
		p.blend = MakePipe(@"vsPath", @"fsColor", nSamples, true, true);
		p.replace = MakePipe(@"vsPath", @"fsColor", nSamples, false, true);
		p.stencilOnly = MakePipe(@"vsPath", @"fsColor", nSamples, false, false);
		p.stencilOnlyFull = MakePipe(@"vsFull", @"fsColor", nSamples, false, false);
		p.clearFull = MakePipe(@"vsFull", @"fsColor", nSamples, false, true);
		p.copyFull = MakePipe(@"vsFull", @"fsCopy", nSamples, false, true);
		p.mirror = MakePipe(@"vsFull", @"fsMirror", 1, false, true, false);	// pass without stencil
		return pipes[nSamples] = p;
	}

	id<MTLDepthStencilState> MakeDSS(MTLCompareFunction cmp, MTLStencilOperation pass,
		uint32_t readMask, uint32_t writeMask)
	{
		MTLStencilDescriptor	*s = [MTLStencilDescriptor new];
		s.stencilCompareFunction = cmp;
		s.stencilFailureOperation = MTLStencilOperationKeep;
		s.depthFailureOperation = MTLStencilOperationKeep;
		s.depthStencilPassOperation = pass;
		s.readMask = readMask;
		s.writeMask = writeMask;
		MTLDepthStencilDescriptor	*d = [MTLDepthStencilDescriptor new];
		d.frontFaceStencil = s;
		d.backFaceStencil = s;
		return [device newDepthStencilStateWithDescriptor:d];
	}
};

MetalRenderer::MetalRenderer(int nWidth, int nHeight, double fScale, int nSamples)
	: m_pImpl(std::make_unique<Impl>()), m_nWidth(std::max(nWidth, 0)), m_nHeight(std::max(nHeight, 0)),
	m_fScale(fScale), m_nSamples(nSamples)
{
	Impl&	im = *m_pImpl;
	im.device = MTLCreateSystemDefaultDevice();
	if (!im.device || !m_nWidth || !m_nHeight)
		return;
	if (m_nSamples && ![im.device supportsTextureSampleCount:m_nSamples])
		m_nSamples = 4;
	im.bMemoryless = [im.device supportsFamily:MTLGPUFamilyApple1];
	im.bShared = im.device.hasUnifiedMemory;
	im.queue = [im.device newCommandQueue];
	NSError	*err = nil;
	// profiling: WHORLD_MTL_ABLATE bits turn parts of coverage mode off
	// (1 per-sample loop, 2 cover draw, 4 fills, 8 strokes, 16 triangle growth,
	// 64 exact per-sample loop instead of the lookup table);
	// WHORLD_MTL_PROFILE counts pixels and fragments (and slows the GPU)
	m_nAblate = getenv("WHORLD_MTL_ABLATE") ? atoi(getenv("WHORLD_MTL_ABLATE")) : 0;
	m_bProfile = getenv("WHORLD_MTL_PROFILE") != nullptr;
	MTLCompileOptions	*co = [MTLCompileOptions new];
	co.preprocessorMacros = @{@"ABLATE_LOOP": @((m_nAblate & 1) ? 1 : 0),
		@"ABLATE_NOGROW": @((m_nAblate & 16) ? 1 : 0), @"PROF_COUNT": @(m_bProfile ? 1 : 0),
		@"EXACT_LOOP": @((m_nAblate & 64) ? 1 : 0)};
	im.library = [im.device newLibraryWithSource:@(kShaderSource) options:co error:&err];
	if (!im.library) {
		NSLog(@"MetalRenderer: shaders: %@", err);
		im.device = nil;
		return;
	}
	// the frame: readable by the copy and mirror passes and by ReadPixels
	MTLTextureDescriptor	*d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		width:m_nWidth height:m_nHeight mipmapped:NO];
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	d.storageMode = im.bShared ? MTLStorageModeShared : MTLStorageModeManaged;
	im.target = [im.device newTextureWithDescriptor:d];
	im.scratch = im.MakeTexture(MTLPixelFormatBGRA8Unorm, m_nWidth, m_nHeight, 1, true);
	im.dssNone = im.MakeDSS(MTLCompareFunctionAlways, MTLStencilOperationKeep, 0, 0);
	im.dssFillMark = im.MakeDSS(MTLCompareFunctionAlways, MTLStencilOperationInvert, 0, kFillBit);
	im.dssFillCover = im.MakeDSS(MTLCompareFunctionEqual, MTLStencilOperationZero, kFillBit, kFillBit);
	im.dssStroke = im.MakeDSS(MTLCompareFunctionGreater, MTLStencilOperationReplace, kStrokeMask, kStrokeMask);
	im.dssStrokeReset = im.MakeDSS(MTLCompareFunctionAlways, MTLStencilOperationZero, 0, kStrokeMask);
	if (!m_nSamples) {	// coverage mode needs framebuffer reads (Apple GPUs)
		if (!im.bMemoryless) {
			NSLog(@"MetalRenderer: coverage mode needs an Apple GPU");
			im.device = nil;
			return;
		}
		{
			std::vector<uint32_t>	aLut;
			BuildMaskTable(aLut);
			MTLTextureDescriptor	*ld = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Uint
				width:kLutDists height:kLutAngles mipmapped:NO];
			ld.usage = MTLTextureUsageShaderRead;
			ld.storageMode = MTLStorageModeShared;
			im.maskLut = [im.device newTextureWithDescriptor:ld];
			[im.maskLut replaceRegion:MTLRegionMake2D(0, 0, kLutDists, kLutAngles) mipmapLevel:0
				withBytes:aLut.data() bytesPerRow:kLutDists * 8];
		}
		im.cov.maskOr = im.MakeCovPipe(@"vsTri", @"fsMaskOr", false);
		im.cov.maskXor = im.MakeCovPipe(@"vsTri", @"fsMaskXor", false);
		im.cov.cover = im.MakeCovPipe(@"vsTri", @"fsCover", true);
		im.cov.clear = im.MakeCovPipe(@"vsFull", @"fsClearCov", true);
		MTLTextureDescriptor	*md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Uint
			width:m_nWidth height:m_nHeight mipmapped:NO];
		md.usage = MTLTextureUsageRenderTarget;
		md.storageMode = MTLStorageModeMemoryless;
		im.mask = [im.device newTextureWithDescriptor:md];
	}
}

MetalRenderer::~MetalRenderer()
{
	WaitUntilDone();
}

bool MetalRenderer::IsValid() const
{
	return m_pImpl->device && m_pImpl->target;
}

SizeF MetalRenderer::GetSizeDIPs() const
{
	return SizeF{float(m_nWidth / m_fScale), float(m_nHeight / m_fScale)};
}

void MetalRenderer::BeginFrame()
{
	m_aPt.clear();
	m_aFig.clear();
	m_aOp.clear();
	m_iPathFig = 0;
	m_bAntialiasSet = false;
	m_bMirrorPending = false;
	m_bInFrame = true;
}

void MetalRenderer::SetAntialiasing(bool bEnable)
{
	// The multisample count is a property of the frame's render pass. The
	// engine sets the mode once, at the start of Draw; the spike takes the
	// first setting of the frame.
	if (!m_bAntialiasSet) {
		m_bAntialias = bEnable;
		m_bAntialiasSet = true;
	}
}

void MetalRenderer::Clear(const ColorF& clr)
{
	Op	op;
	op.type = Op::CLEAR;
	op.clr = clr;
	m_aOp.push_back(std::move(op));
}

void MetalRenderer::BeginPath()
{
	m_iPathFig = m_aFig.size();
}

void MetalRenderer::AddFigure(const PointF* pStart, int nSegments, bool bCurved, bool bFilled)
{
	int	nPts = 1 + (bCurved ? nSegments * 3 : nSegments);
	m_aFig.push_back(Figure{m_aPt.size(), nSegments, bCurved, bFilled});
	m_aPt.insert(m_aPt.end(), pStart, pStart + nPts);
}

void MetalRenderer::EndPath()
{
}

void MetalRenderer::FillPath(const ColorF& clr)
{
	if (m_aFig.size() == m_iPathFig)
		return;
	Op	op;
	op.type = Op::FILL;
	op.clr = clr;
	op.iFig = m_iPathFig;
	op.nFig = m_aFig.size() - m_iPathFig;
	m_aOp.push_back(std::move(op));
}

void MetalRenderer::StrokePath(const ColorF& clr, float fWidth)
{
	// as CGBitmapRenderer: negative widths are drawn as their absolute
	// value, zero is skipped
	fWidth = std::fabs(fWidth);
	if (m_aFig.size() == m_iPathFig || !(fWidth > 0))
		return;
	Op	op;
	op.type = Op::STROKE;
	op.clr = clr;
	// Antialiased strokes thinner than a pixel are drawn one pixel wide,
	// fainter in proportion: what Direct2D does, judging by the "fish eye"
	// golden image (mean difference 1.8 without this rule, 0.75 with it).
	if (!m_nSamples && m_bAntialias && fWidth * m_fScale < 1) {
		op.clr.a *= float(fWidth * m_fScale);
		fWidth = float(1 / m_fScale);
	}
	op.fWidth = fWidth;
	op.iFig = m_iPathFig;
	op.nFig = m_aFig.size() - m_iPathFig;
	m_aOp.push_back(std::move(op));
}

void MetalRenderer::FillRect(const RectF& rect, const ColorF& clr)
{
	Op	op;
	op.type = Op::RECT;
	op.clr = clr;
	op.rect = rect;
	m_aOp.push_back(std::move(op));
}

bool MetalRenderer::BeginQuadMirror()
{
	if (m_bMirrorPending || !((m_nWidth + 1) / 2) || !((m_nHeight + 1) / 2))
		return false;
	Op	op;
	op.type = Op::MIRROR_BEGIN;
	m_aOp.push_back(std::move(op));
	m_bMirrorPending = true;
	return true;
}

bool MetalRenderer::EndQuadMirror()
{
	if (!m_bMirrorPending)
		return false;
	Op	op;
	op.type = Op::MIRROR_END;
	m_aOp.push_back(std::move(op));
	m_bMirrorPending = false;
	return true;
}

void MetalRenderer::EndFrame()
{
	if (!m_bInFrame)
		return;
	m_bInFrame = false;
	if (!IsValid())
		return;
	auto	t0 = std::chrono::steady_clock::now();
	Tessellate();
	m_stats.fTessMs = MsSince(t0);
	t0 = std::chrono::steady_clock::now();
	Encode();
	m_stats.fEncodeMs = MsSince(t0);
}

void MetalRenderer::Tessellate()
{
	// 1) flatten every figure, in parallel
	const float	fScale = float(m_fScale), fTol = m_fTolerance;
	m_aContour.resize(m_aFig.size());
	{
		const Figure	*pFig = m_aFig.data();
		const PointF	*pPt = m_aPt.data();
		gpu::Contour	*pCt = m_aContour.data();
		dispatch_apply(m_aFig.size(), DISPATCH_APPLY_AUTO, ^(size_t i) {
			const Figure&	f = pFig[i];
			gpu::FlattenFigure(&pPt[f.iPt], f.nSegments, f.bCurved, fScale, fTol, pCt[i]);
		});
	}
	// 2) triangles per op, in parallel
	Op	*pOps = m_aOp.data();
	const gpu::Contour	*pCt = m_aContour.data();
	const Figure	*pFig = m_aFig.data();
	dispatch_apply(m_aOp.size(), DISPATCH_APPLY_AUTO, ^(size_t i) {
		Op&	op = pOps[i];
		op.tris.clear();
		switch (op.type) {
		case Op::FILL: {
			// only figures begun FILLED take part in the fill
			std::vector<gpu::Contour>	filled;
			bool	bAll = true;
			for (size_t f = op.iFig; f < op.iFig + op.nFig; f++)
				bAll = bAll && pFig[f].bFilled;
			if (bAll) {
				gpu::FanContours(&pCt[op.iFig], op.nFig, op.tris);
			} else {
				for (size_t f = op.iFig; f < op.iFig + op.nFig; f++) {
					if (pFig[f].bFilled)
						filled.push_back(pCt[f]);
				}
				gpu::FanContours(filled.data(), filled.size(), op.tris);
			}
			break;
		}
		case Op::STROKE:
			gpu::StrokeContours(&pCt[op.iFig], op.nFig, op.fWidth * fScale, fTol, op.tris);
			break;
		case Op::RECT:
			gpu::RectTriangles(op.rect.left * fScale, op.rect.top * fScale,
				op.rect.right * fScale, op.rect.bottom * fScale, op.tris);
			break;
		default:
			break;
		}
	});
}

void MetalRenderer::Encode()
{
	Impl&	im = *m_pImpl;
	@autoreleasepool {
		// one vertex buffer for the frame
		size_t	nVert = 0;
		for (Op& op : m_aOp) {
			op.iVert = nVert;
			nVert += op.tris.size();
		}
		m_stats.nVertices = nVert;
		size_t	nBytes = std::max<size_t>(nVert, 1) * sizeof(gpu::Vec2);
		if (im.lastCmd)	// the spike reuses one buffer, so wait for the previous frame
			[im.lastCmd waitUntilCompleted];
		if (!im.vertices || im.vertices.length < nBytes)
			im.vertices = [im.device newBufferWithLength:nBytes * 3 / 2 options:MTLResourceStorageModeShared];
		auto	*pDst = static_cast<gpu::Vec2 *>(im.vertices.contents);
		for (const Op& op : m_aOp) {
			if (!op.tris.empty())
				std::memcpy(&pDst[op.iVert], op.tris.data(), op.tris.size() * sizeof(gpu::Vec2));
		}

		if (!m_nSamples && m_bAntialias) {
			EncodeCoverage();
			return;
		}
		const int	nSamples = m_bAntialias ? std::max(m_nSamples, 1) : 1;
		const Impl::Pipelines&	pp = im.GetPipes(nSamples);
		if (nSamples > 1 && !im.msaa[nSamples])
			im.msaa[nSamples] = im.MakeTexture(MTLPixelFormatBGRA8Unorm, m_nWidth, m_nHeight, nSamples, false);
		if (!im.stencil[nSamples])
			im.stencil[nSamples] = im.MakeTexture(MTLPixelFormatStencil8, m_nWidth, m_nHeight, nSamples, false);
		id<MTLCommandBuffer>	cmd = [im.queue commandBuffer];
		const float	size[2] = {float(m_nWidth), float(m_nHeight)};
		const MTLScissorRect	rFull = {0, 0, NSUInteger(m_nWidth), NSUInteger(m_nHeight)};
		const MTLScissorRect	rQuad = {0, 0, NSUInteger((m_nWidth + 1) / 2), NSUInteger((m_nHeight + 1) / 2)};
		size_t	nDraws = 0;
		size_t	iOp = 0;
		bool	bFirstPass = true;
		while (iOp < m_aOp.size() || bFirstPass) {
			// a pass runs up to and including the next MIRROR_END
			size_t	iEnd = iOp;
			while (iEnd < m_aOp.size() && m_aOp[iEnd].type != Op::MIRROR_END)
				iEnd++;
			bool	bMirror = iEnd < m_aOp.size();
			// a pass after the first continues the frame drawn so far
			bool	bReload = !bFirstPass;
			if (bReload) {
				id<MTLBlitCommandEncoder>	blit = [cmd blitCommandEncoder];
				[blit copyFromTexture:im.target toTexture:im.scratch];
				[blit endEncoding];
			}
			id<MTLTexture>	dest = bMirror ? im.scratch : im.target;
			MTLRenderPassDescriptor	*rp = [MTLRenderPassDescriptor renderPassDescriptor];
			auto	*ca = rp.colorAttachments[0];
			if (nSamples > 1) {
				ca.texture = im.msaa[nSamples];
				ca.resolveTexture = dest;
				ca.storeAction = MTLStoreActionMultisampleResolve;
			} else {
				ca.texture = dest;
				ca.storeAction = MTLStoreActionStore;
			}
			ca.loadAction = MTLLoadActionClear;
			ca.clearColor = MTLClearColorMake(0, 0, 0, 0);
			rp.stencilAttachment.texture = im.stencil[nSamples];
			rp.stencilAttachment.loadAction = MTLLoadActionClear;
			rp.stencilAttachment.clearStencil = 0;
			rp.stencilAttachment.storeAction = MTLStoreActionDontCare;
			id<MTLRenderCommandEncoder>	enc = [cmd renderCommandEncoderWithDescriptor:rp];
			[enc setVertexBuffer:im.vertices offset:0 atIndex:0];
			[enc setVertexBytes:size length:sizeof(size) atIndex:1];
			if (bReload) {
				[enc setRenderPipelineState:pp.copyFull];
				[enc setDepthStencilState:im.dssNone];
				[enc setFragmentTexture:im.scratch atIndex:0];
				[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
				nDraws++;
			}
			uint32_t	nRef = 1;
			for (size_t i = iOp; i < iEnd; i++) {
				const Op&	op = m_aOp[i];
				const float	clr[4] = {op.clr.r * op.clr.a, op.clr.g * op.clr.a, op.clr.b * op.clr.a, op.clr.a};
				switch (op.type) {
				case Op::MIRROR_BEGIN:
					[enc setScissorRect:rQuad];
					break;
				case Op::CLEAR:
					[enc setRenderPipelineState:pp.clearFull];
					[enc setDepthStencilState:im.dssNone];
					[enc setFragmentBytes:clr length:sizeof(clr) atIndex:0];
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
					nDraws++;
					break;
				case Op::RECT:
					if (op.tris.empty())
						break;
					[enc setRenderPipelineState:pp.blend];
					[enc setDepthStencilState:im.dssNone];
					[enc setFragmentBytes:clr length:sizeof(clr) atIndex:0];
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:op.iVert vertexCount:op.tris.size()];
					nDraws++;
					break;
				case Op::FILL:
					if (op.tris.empty())
						break;
					[enc setRenderPipelineState:pp.stencilOnly];
					[enc setDepthStencilState:im.dssFillMark];
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:op.iVert vertexCount:op.tris.size()];
					[enc setRenderPipelineState:pp.blend];
					[enc setDepthStencilState:im.dssFillCover];
					[enc setStencilReferenceValue:kFillBit];
					[enc setFragmentBytes:clr length:sizeof(clr) atIndex:0];
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:op.iVert vertexCount:op.tris.size()];
					nDraws += 2;
					break;
				case Op::STROKE:
					if (op.tris.empty())
						break;
					if (nRef > kStrokeMask) {	// references used up: zero the stroke bits
						[enc setRenderPipelineState:pp.stencilOnlyFull];
						[enc setDepthStencilState:im.dssStrokeReset];
						[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
						nRef = 1;
						nDraws++;
					}
					[enc setRenderPipelineState:pp.blend];
					[enc setDepthStencilState:im.dssStroke];
					[enc setStencilReferenceValue:nRef++];
					[enc setFragmentBytes:clr length:sizeof(clr) atIndex:0];
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:op.iVert vertexCount:op.tris.size()];
					nDraws++;
					break;
				default:
					break;
				}
			}
			[enc endEncoding];
			if (bMirror) {	// copy the quadrant into all four, into the frame
				MTLRenderPassDescriptor	*mp = [MTLRenderPassDescriptor renderPassDescriptor];
				mp.colorAttachments[0].texture = im.target;
				mp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
				mp.colorAttachments[0].storeAction = MTLStoreActionStore;
				id<MTLRenderCommandEncoder>	me = [cmd renderCommandEncoderWithDescriptor:mp];
				const uint32_t	sz[4] = {uint32_t(m_nWidth), uint32_t(m_nHeight),
					uint32_t(rQuad.width), uint32_t(rQuad.height)};
				[me setRenderPipelineState:pp.mirror];
				[me setFragmentTexture:im.scratch atIndex:0];
				[me setFragmentBytes:sz length:sizeof(sz) atIndex:0];
				[me drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
				[me endEncoding];
				nDraws++;
			}
			(void)rFull;
			bFirstPass = false;
			iOp = bMirror ? iEnd + 1 : iEnd;
			if (iOp >= m_aOp.size())
				break;
		}
		if (!im.bShared) {
			id<MTLBlitCommandEncoder>	blit = [cmd blitCommandEncoder];
			[blit synchronizeResource:im.target];
			[blit endEncoding];
		}
		Stats	*pStats = &m_stats;
		[cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
			pStats->fGpuMs = (cb.GPUEndTime - cb.GPUStartTime) * 1000;
		}];
		[cmd commit];
		im.lastCmd = cmd;
		m_stats.nDraws = nDraws;
	}
}

bool MetalRenderer::GetFragmentCounts(uint32_t aCount[7]) const
{
	if (!m_pImpl->counts)
		return false;
	std::memcpy(aCount, m_pImpl->counts.contents, sizeof(uint32_t) * 7);
	return true;
}

// Profiling: pixels one coverage-mode draw of this op rasterizes, using the
// same grown triangle or box as vsTri (an estimate: area, not pixel centers).
void MetalRenderer::ProfileOp(const Op& op)
{
	const float	d = (m_nAblate & 16) ? 0 : 0.75f;
	double	fPx = 0, fArea = 0;
	for (size_t i = 0; i + 2 < op.tris.size(); i += 3) {
		gpu::Vec2	a = op.tris[i], b = op.tris[i + 1], c = op.tris[i + 2];
		float	area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
		if (area == 0)
			continue;
		fArea += std::fabs(area) / 2;
		auto	unit = [](gpu::Vec2 v) { float l = std::sqrt(v.x * v.x + v.y * v.y); return gpu::Vec2{v.x / l, v.y / l}; };
		float	s = area > 0 ? 1 : -1;
		gpu::Vec2	eab = unit({b.x - a.x, b.y - a.y}), ebc = unit({c.x - b.x, c.y - b.y}), eca = unit({a.x - c.x, a.y - c.y});
		gpu::Vec2	nab{s * eab.y, -s * eab.x}, nbc{s * ebc.y, -s * ebc.x}, nca{s * eca.y, -s * eca.x};
		auto	dot = [](gpu::Vec2 u, gpu::Vec2 v) { return u.x * v.x + u.y * v.y; };
		float	ka = 1 + dot(nca, nab), kb = 1 + dot(nab, nbc), kc = 1 + dot(nbc, nca);
		if (std::min(ka, std::min(kb, kc)) > 0.08f) {
			auto	grow = [&](gpu::Vec2 q, gpu::Vec2 n1, gpu::Vec2 n2) {
				float	k = d / (1 + dot(n1, n2));
				return gpu::Vec2{q.x + (n1.x + n2.x) * k, q.y + (n1.y + n2.y) * k};
			};
			gpu::Vec2	A = grow(a, nca, nab), B = grow(b, nab, nbc), C = grow(c, nbc, nca);
			fPx += std::fabs((B.x - A.x) * (C.y - A.y) - (B.y - A.y) * (C.x - A.x)) / 2;
		} else {
			float	w = std::max(a.x, std::max(b.x, c.x)) - std::min(a.x, std::min(b.x, c.x)) + 2 * d;
			float	h = std::max(a.y, std::max(b.y, c.y)) - std::min(a.y, std::min(b.y, c.y)) + 2 * d;
			fPx += double(w) * h;
			m_stats.prof.nBoxTris++;
		}
	}
	Stats::Profile&	p = m_stats.prof;
	int	t = op.type == Op::FILL ? 0 : op.type == Op::STROKE ? 1 : 2;
	p.nOps[t]++;
	p.nTris[t] += op.tris.size() / 3;
	p.fPx[t] += fPx;
	p.fArea[t] += fArea;
}

// Coverage mode (antialiased frames): one pass with a color attachment and
// a 64-sample mask attachment in tile memory; see the shaders.
void MetalRenderer::EncodeCoverage()
{
	Impl&	im = *m_pImpl;
	id<MTLCommandBuffer>	cmd = [im.queue commandBuffer];
	const float	size[2] = {float(m_nWidth), float(m_nHeight)};
	const MTLScissorRect	rQuad = {0, 0, NSUInteger((m_nWidth + 1) / 2), NSUInteger((m_nHeight + 1) / 2)};
	const Impl::Pipelines&	pp = im.GetPipes(1);
	size_t	nDraws = 0;
	m_stats.prof = Stats::Profile{};
	if (m_bProfile) {
		if (!im.counts)
			im.counts = [im.device newBufferWithLength:sizeof(uint32_t) * 8 options:MTLResourceStorageModeShared];
		std::memset(im.counts.contents, 0, sizeof(uint32_t) * 8);
	}
	size_t	iOp = 0;
	bool	bFirstPass = true;
	for (;;) {
		size_t	iEnd = iOp;
		while (iEnd < m_aOp.size() && m_aOp[iEnd].type != Op::MIRROR_END)
			iEnd++;
		bool	bMirror = iEnd < m_aOp.size();
		MTLRenderPassDescriptor	*rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = bMirror ? im.scratch : im.target;
		rp.colorAttachments[0].loadAction = (bFirstPass || bMirror) ? MTLLoadActionClear : MTLLoadActionLoad;
		if (!bFirstPass && bMirror) {	// a mirror after the first pass: continue from the frame
			id<MTLBlitCommandEncoder>	blit = [cmd blitCommandEncoder];
			[blit copyFromTexture:im.target toTexture:im.scratch];
			[blit endEncoding];
			rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
		}
		rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		rp.colorAttachments[1].texture = im.mask;
		rp.colorAttachments[1].loadAction = MTLLoadActionClear;
		rp.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0);
		rp.colorAttachments[1].storeAction = MTLStoreActionDontCare;
		id<MTLRenderCommandEncoder>	enc = [cmd renderCommandEncoderWithDescriptor:rp];
		[enc setVertexBuffer:im.vertices offset:0 atIndex:0];
		[enc setVertexBytes:size length:sizeof(size) atIndex:1];
		[enc setFragmentTexture:im.maskLut atIndex:0];
		if (m_bProfile)
			[enc setFragmentBuffer:im.counts offset:0 atIndex:2];
		for (size_t i = iOp; i < iEnd; i++) {
			const Op&	op = m_aOp[i];
			const float	clr[4] = {op.clr.r * op.clr.a, op.clr.g * op.clr.a, op.clr.b * op.clr.a, op.clr.a};
			switch (op.type) {
			case Op::MIRROR_BEGIN:
				[enc setScissorRect:rQuad];
				break;
			case Op::CLEAR:
				[enc setRenderPipelineState:im.cov.clear];
				[enc setFragmentBytes:clr length:sizeof(clr) atIndex:0];
				[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
				nDraws++;
				break;
			case Op::FILL:
			case Op::STROKE:
			case Op::RECT: {
				if (op.tris.empty())
					break;
				if (((m_nAblate & 4) && op.type == Op::FILL) || ((m_nAblate & 8) && op.type == Op::STROKE))
					break;
				NSUInteger	nTri = op.tris.size() / 3;
				if (m_bProfile)
					ProfileOp(op);
				[enc setVertexBufferOffset:op.iVert * sizeof(gpu::Vec2) atIndex:0];
				[enc setRenderPipelineState:op.type == Op::FILL ? im.cov.maskXor : im.cov.maskOr];
				[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:nTri];
				nDraws++;
				if (!(m_nAblate & 2)) {
					[enc setRenderPipelineState:im.cov.cover];
					[enc setFragmentBytes:clr length:sizeof(clr) atIndex:0];
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:nTri];
					nDraws++;
				}
				break;
			}
			default:
				break;
			}
		}
		[enc endEncoding];
		if (bMirror) {
			MTLRenderPassDescriptor	*mp = [MTLRenderPassDescriptor renderPassDescriptor];
			mp.colorAttachments[0].texture = im.target;
			mp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
			mp.colorAttachments[0].storeAction = MTLStoreActionStore;
			id<MTLRenderCommandEncoder>	me = [cmd renderCommandEncoderWithDescriptor:mp];
			const uint32_t	sz[4] = {uint32_t(m_nWidth), uint32_t(m_nHeight),
				uint32_t(rQuad.width), uint32_t(rQuad.height)};
			[me setRenderPipelineState:pp.mirror];
			[me setFragmentTexture:im.scratch atIndex:0];
			[me setFragmentBytes:sz length:sizeof(sz) atIndex:0];
			[me drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
			[me endEncoding];
			nDraws++;
		}
		bFirstPass = false;
		iOp = bMirror ? iEnd + 1 : iEnd;
		if (iOp >= m_aOp.size())
			break;
	}
	if (!im.bShared) {
		id<MTLBlitCommandEncoder>	blit = [cmd blitCommandEncoder];
		[blit synchronizeResource:im.target];
		[blit endEncoding];
	}
	Stats	*pStats = &m_stats;
	[cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
		pStats->fGpuMs = (cb.GPUEndTime - cb.GPUStartTime) * 1000;
	}];
	[cmd commit];
	im.lastCmd = cmd;
	m_stats.nDraws = nDraws;
}

void MetalRenderer::WaitUntilDone()
{
	if (m_pImpl && m_pImpl->lastCmd) {
		[m_pImpl->lastCmd waitUntilCompleted];
		m_pImpl->lastCmd = nil;
	}
}

bool MetalRenderer::ReadPixels(std::vector<uint8_t>& aPixel, size_t& nStride)
{
	if (!IsValid())
		return false;
	WaitUntilDone();
	nStride = size_t(m_nWidth) * 4;
	aPixel.resize(nStride * m_nHeight);
	[m_pImpl->target getBytes:aPixel.data() bytesPerRow:nStride
		fromRegion:MTLRegionMake2D(0, 0, m_nWidth, m_nHeight) mipmapLevel:0];
	return true;
}

} // namespace whorld
