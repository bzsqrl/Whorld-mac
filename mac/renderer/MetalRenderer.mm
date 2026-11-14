// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
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

// Only the triangle's index is passed to the fragments: on Apple GPUs each
// flat input is fetched again per fragment, and passing the edges' setup
// (21 values) cost more than all of the coverage math. The fragment shader
// reads the triangle's vertices from the vertex buffer instead.
struct TOut {
	float4 pos [[position]];
	uint tri [[flat]];
};

constant int kLutAngles = 512, kLutDists = 257;	// odd: column 128 is distance 0
constant float kLutR = 0.7072;	// just over half the pixel diagonal

// One instance per triangle (three float2 at buffer 0), 12 vertices: a fan
// of four triangles. The rasterized shape is the triangle grown by 0.75 px,
// so that every pixel the triangle touches gets a fragment. Triangles with
// a corner sharper than about 33 degrees, whose mitered corners would reach
// far out, use a hexagon instead: each edge pushed out by 0.75 px and
// extended 0.75 px past both ends, the corners cut flat. (A bounding box was
// used before; for long thin stroke triangles its area grows with the square
// of their length.) Mitered triangles use vertices 0..2 only.
vertex TOut vsTri(uint vid [[vertex_id]], uint iid [[instance_id]],
	const device float2 *v [[buffer(0)]], constant float2 &size [[buffer(1)]])
{
	float2 a = v[iid * 3], b = v[iid * 3 + 1], c = v[iid * 3 + 2];
	TOut o;
	o.tri = iid;
#if ABLATE_NOGROW || CENTER_ONLY
	const float d = 0.0;	// CENTER_ONLY: the rasterizer's own pixel-center rule
#else
	const float d = 0.75;
#endif
	float area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
	float2 p = a;	// degenerate: nothing to draw
	if (area != 0) {
		// edge directions and outward unit normals of ab, bc, ca
		float s = area > 0 ? 1 : -1;
		float2 eab = normalize(b - a), ebc = normalize(c - b), eca = normalize(a - c);
		float2 nab = s * float2(eab.y, -eab.x), nbc = s * float2(ebc.y, -ebc.x), nca = s * float2(eca.y, -eca.x);
		float ka = 1 + dot(nca, nab), kb = 1 + dot(nab, nbc), kc = 1 + dot(nbc, nca);
		// fan triangle t = vid / 3 has hexagon corners 0, t + 1, t + 2
		uint t = vid / 3, j = vid % 3;
		uint h = j == 0 ? 0 : t + j;
		if (min(ka, min(kb, kc)) > 0.08) {	// mitered triangle: fan triangle 0 only
			if (t == 0) {
				float2 q = j == 0 ? a : j == 1 ? b : c;
				float2 n1 = j == 0 ? nca : j == 1 ? nab : nbc;
				float2 n2 = j == 0 ? nab : j == 1 ? nbc : nca;
				p = q + (n1 + n2) * (d / (1 + dot(n1, n2)));
			}
		} else {	// hexagon: two corners per vertex, the incoming edge's then the outgoing's
			uint k = h / 2;
			float2 q = k == 0 ? a : k == 1 ? b : c;
			float2 eIn = k == 0 ? eca : k == 1 ? eab : ebc, nIn = k == 0 ? nca : k == 1 ? nab : nbc;
			float2 eOut = k == 0 ? eab : k == 1 ? ebc : eca, nOut = k == 0 ? nab : k == 1 ? nbc : nca;
			p = (h & 1) ? q + d * (nOut - eOut) : q + d * (nIn + eIn);
		}
	}
	o.pos = float4(p.x / size.x * 2 - 1, 1 - p.y / size.y * 2, 0, 1);
	return o;
}

// 64 sample positions in a pixel, n-rooks: x = (k + 0.5) / 64, y = ((37k mod 64) + 0.5) / 64
//
// Edge p -> q of a triangle with orientation sign, at the pixel's corner o.
// The edge's canonical form takes its endpoints in a fixed order (u, w):
// e0(x) = A (x.x - u.x) + B (x.y - u.y), A = -(w.y - u.y), B = w.x - u.x,
// and the triangle's inside is g e0 > 0. Per pixel, base = e0(o) and
// e0(o + s) = base + A s.x + B s.y. Both triangles sharing the edge compute
// the same A, B and base, and opposite g, so a sample goes to exactly one of
// them; one on the edge (value 0) by the sign of the gradient g (A, B).
struct Edge {
	float A, B, base;	// canonical
	float g;
};

inline Edge PixelEdge(float2 p, float2 q, float sign, float2 o)
{
	bool swap = p.x > q.x || (p.x == q.x && p.y > q.y);
	float2 u = swap ? q : p, w = swap ? p : q;
	Edge x;
	x.A = -(w.y - u.y);
	x.B = w.x - u.x;
	x.base = fma(x.A, o.x - u.x, x.B * (o.y - u.y));
	x.g = swap ? -sign : sign;
	return x;
}

// Sample mask of one edge from the lookup table (see BuildMaskTable): rows
// are the canonical normal's direction as a "diamond angle" in [0, 4) (no
// atan2), columns its signed distance from the pixel center. Both triangles
// sharing an edge read the same entry, and the one on the other side takes
// its complement, so they split the samples exactly.
// Mask of the samples s with A s'.x + B s'.y + c > 0, s' = s - center.
inline uint2 LutMask(float A, float B, float c, texture2d<uint> lut)
{
	float p = B / (abs(A) + abs(B));
	float da = A >= 0 ? (B >= 0 ? p : 4 + p) : 2 - p;
	uint row = uint(int(rint(da * (kLutAngles / 4)))) & (kLutAngles - 1);
	// distance of the center from the line, in table columns: -c / len
	float k = ((kLutDists - 1) / (2 * kLutR)) * rsqrt(A * A + B * B);
	int j = clamp(int(rint(fma(-c, k, (kLutDists - 1) * 0.5))), 0, kLutDists - 1);
	return lut.read(uint2(j, row)).xy;
}

inline uint2 EdgeMask(Edge e, texture2d<uint> lut)
{
	uint2 m = LutMask(e.A, e.B, e.base + 0.5 * (e.A + e.B), lut);	// e0 at the center
	return e.g > 0 ? m : ~m;
}

inline bool Inside(Edge e, float2 s)
{
	float v = fma(e.A, s.x, fma(e.B, s.y, e.base)) * e.g;	// exact: g is +1 or -1
	float A = e.A * e.g, B = e.B * e.g;
	return v > 0 || (v == 0 && (A > 0 || (A == 0 && B > 0)));
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
// One edge of a convex shape at a pixel: false if the pixel is outside it
// (no sample covered); otherwise ANDs in its sample mask if it crosses the
// pixel, counting crossing edges in n.
inline bool EdgeStep(Edge e, thread uint2& m, thread int& n, texture2d<uint> lut)
{

	float v00 = e.base, v10 = e.A + e.base, v01 = e.B + e.base, v11 = e.A + e.B + e.base;
	float lo = min(min(v00, v10), min(v01, v11)), hi = max(max(v00, v10), max(v01, v11));
	if (e.g < 0) {
		float t = lo;
		lo = -hi;
		hi = -t;
	}
	if (hi < 0)
		return false;
	if (lo > 0)
		return true;
	n++;
	m &= EdgeMask(e, lut);
	return true;
}

// Stroke strips: a convex quad (four points at buffer 1, in order)
inline uint2 QuadMask(TOut in, const device float2 *q, texture2d<uint> lut CNT_ARG)
{
#if CENTER_ONLY	// ungrown: the rasterizer gave only pixels whose centers are inside
	return uint2(0xFFFFFFFF);
#endif
	float2 a = q[in.tri * 4], b = q[in.tri * 4 + 1], c = q[in.tri * 4 + 2], d = q[in.tri * 4 + 3];
	float area = (a.x * b.y - b.x * a.y) + (b.x * c.y - c.x * b.y) + (c.x * d.y - d.x * c.y) + (d.x * a.y - a.x * d.y);
	if (area == 0)
		return uint2(0);
	float sg = area > 0 ? 1 : -1;
	float2 o = floor(in.pos.xy);
	uint2 m = uint2(0xFFFFFFFF);
	int n = 0;
	if (!EdgeStep(PixelEdge(a, b, sg, o), m, n, lut) || !EdgeStep(PixelEdge(b, c, sg, o), m, n, lut)
		|| !EdgeStep(PixelEdge(c, d, sg, o), m, n, lut) || !EdgeStep(PixelEdge(d, a, sg, o), m, n, lut)) {
		COUNT(1);
		return uint2(0);
	}
	COUNT(n == 0 ? 2 : min(2 + n, 5));
	return m;
}

inline uint2 TriangleMask(TOut in, const device float2 *v, texture2d<uint> lut CNT_ARG)
{
#if CENTER_ONLY	// ungrown: the rasterizer gave only pixels whose centers are inside
	return uint2(0xFFFFFFFF);
#endif
#if ABLATE_ALL
	return uint2(0xFFFFFFFF);	// timing only: raster and framebuffer cost
#endif
	float2 a = v[in.tri * 3], b = v[in.tri * 3 + 1], c = v[in.tri * 3 + 2];
	float area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
	if (area == 0) {
		COUNT(0);
		return uint2(0);
	}
	float sg = area > 0 ? 1 : -1;
	float2 o = floor(in.pos.xy);
	Edge e3[3] = {PixelEdge(a, b, sg, o), PixelEdge(b, c, sg, o), PixelEdge(c, a, sg, o)};

	// Classify each edge by the pixel's corners (e is linear, so the samples
	// lie between the corner values): all outside, the pixel is empty; all
	// inside, the edge can't exclude a sample. Only crossing edges are tested,
	// each ANDing its mask in as it's found: no array indexed at run time,
	// which would move to stack memory.
	uint2 m = uint2(0xFFFFFFFF);
	int n = 0;
#if EXACT_LOOP
	Edge x[3];
#endif
	for (int i = 0; i < 3; i++) {
		Edge e = e3[i];
		float v00 = e.base, v10 = e.A + e.base, v01 = e.B + e.base, v11 = e.A + e.B + e.base;
		float lo = min(min(v00, v10), min(v01, v11)), hi = max(max(v00, v10), max(v01, v11));
		if (e.g < 0) {
			float t = lo;
			lo = -hi;
			hi = -t;
		}
		if (hi < 0) {
			COUNT(1);
			return uint2(0);
		}
		if (lo > 0)
			continue;
		n++;
#if ABLATE_LOOP
		m = uint2(0x55555555);	// half coverage, no per-sample tests
#elif EXACT_LOOP
		x[n - 1] = e;
#else
		m &= EdgeMask(e, lut);
#endif
	}
	if (n == 0) {
		COUNT(2);
		return m;
	}
	COUNT(2 + n);
#if EXACT_LOOP
	m = uint2(0);
	if (n == 1) {
		Edge e = x[0];
		for (uint k = 0; k < 32; k++) {
			m.x |= uint(Inside(e, Sample(k))) << k;
			m.y |= uint(Inside(e, Sample(k + 32))) << k;
		}
	} else {
		Edge e0 = x[0], e1 = x[1];
		Edge e2 = n == 3 ? x[2] : Edge{0, 0, 1, 1};	// always inside
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
	const device float2 *v [[buffer(1)]], texture2d<uint> lut [[texture(0)]] CNT_PARAM)
{
	uint2 t = TriangleMask(in, v, lut CNT_PASS);
#if !NO_DISCARD
	if (!any(t != 0))
		discard_fragment();
#endif
	FBOut o;
	o.color = float4(0);	// not written (write mask)
#if ABLATE_FETCH
	o.mask = t;	// timing only: wrong output
#else
	o.mask = m | t;
#endif
	return o;
}

fragment FBOut fsMaskXor(TOut in [[stage_in]], uint2 m [[color(1)]],
	const device float2 *v [[buffer(1)]], texture2d<uint> lut [[texture(0)]] CNT_PARAM)
{
	uint2 t = TriangleMask(in, v, lut CNT_PASS);
#if !NO_DISCARD
	if (!any(t != 0))
		discard_fragment();
#endif
	FBOut o;
	o.color = float4(0);
#if ABLATE_FETCH
	o.mask = t;	// timing only: wrong output
#else
	o.mask = m ^ t;
#endif
	return o;
}

// ---- hybrid even-odd fills ----
//
// 1. The fan's triangles, not grown, flip all 64 bits where the pixel's
//    center is inside: each pixel's mask holds the fill's parity at its
//    center (the rasterizer's own watertight rule; no coverage math).
// 2. Each contour edge, drawn as a band around it, XORs in the samples s
//    for which the segment from the center c to s crosses the edge: those
//    are exactly the samples whose parity differs from c's by that edge.
//    The set is the edge's shadow seen from c: beyond the edge's line, and
//    inside the wedge between the rays from c through its endpoints. Three
//    table lookups. Consecutive edges compute the ray through their shared
//    vertex identically, so a sample near it is counted consistently.
// 3. A quad over the path's bounding box blends by coverage and clears.
// Cost grows with the fan's area only in step 1, which is nearly free; the
// coverage math runs on a band about 2.5 pixels wide along the outline.
// A contour passing within the rasterizer's precision of a pixel center
// can flip that pixel's parity; with an edge through the center the
// coverage is near 1/2 either way, so the error stays small.

fragment FBOut fsFanFlip(VOut in [[stage_in]], uint2 m [[color(1)]] CNT_PARAM)
{
	COUNT(7);
	FBOut o;
	o.color = float4(0);	// not written
	o.mask = ~m;
	return o;
}

// Spans (see gpu::SpanContours), one instance each: two points (x0, row),
// (x1, row) at buffer 0; the pixels x0 <= x < x1 of that row. Used in place
// of the fan for step 1: each pixel inside is flipped once, so the cost is
// the fill's area, not the fan's overdraw (a ring pair is the band between
// them, not both disks; self-overlapping rings don't multiply it).
vertex VOut vsSpan(uint vid [[vertex_id]], uint iid [[instance_id]],
	const device float2 *v [[buffer(0)]], constant float2 &size [[buffer(1)]])
{
	float2 a = v[iid * 2], b = v[iid * 2 + 1];
	const uint2 k[6] = {uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1)};
	float2 p = float2(k[vid].x ? b.x : a.x, a.y + k[vid].y);
	VOut o;
	o.pos = float4(p.x / size.x * 2 - 1, 1 - p.y / size.y * 2, 0, 1);
	return o;
}

// one instance per fan triangle; its edge is vertices 1 and 2
vertex TOut vsBand(uint vid [[vertex_id]], uint iid [[instance_id]],
	const device float2 *v [[buffer(0)]], constant float2 &size [[buffer(1)]])
{
	float2 P = v[iid * 3 + 1], Q = v[iid * 3 + 2];
	TOut o;
	o.tri = iid;
	const float d = 0.75;
	float2 p = P;
	float len = length(Q - P);
	if (len > 0) {
		float2 t = (Q - P) / len, n = float2(-t.y, t.x);
		const float2 k[6] = {float2(0, -1), float2(1, -1), float2(0, 1), float2(1, -1), float2(1, 1), float2(0, 1)};
		float2 e = k[vid].x > 0 ? Q + t * d : P - t * d;
		p = e + n * (d * k[vid].y);
	}
	o.pos = float4(p.x / size.x * 2 - 1, 1 - p.y / size.y * 2, 0, 1);
	return o;
}

fragment FBOut fsBand(TOut in [[stage_in]], uint2 m [[color(1)]],
	const device float2 *v [[buffer(1)]], texture2d<uint> lut [[texture(0)]])
{
	float2 c = floor(in.pos.xy) + 0.5;
	float2 P = v[in.tri * 3 + 1] - c, Q = v[in.tri * 3 + 2] - c;	// relative to the center
	// beyond the edge's line: e(s') = A s'.x + B s'.y + ec, on the side away from c
	float A = -(Q.y - P.y), B = Q.x - P.x;
	float ec = -(A * P.x + B * P.y);
	uint2 x = LutMask(A, B, ec, lut);
	if (ec > 0)
		x = ~x;
	// the wedge: Q's side of the ray through P, P's side of the ray through Q
	float cr = P.x * Q.y - P.y * Q.x;	// Q's side of line c-P is the sign of cr
	uint2 wp = LutMask(-P.y, P.x, 0, lut), wq = LutMask(-Q.y, Q.x, 0, lut);
	x &= (cr > 0 ? wp : ~wp) & (cr > 0 ? ~wq : wq);
	if (!any(x != 0))
		discard_fragment();
	FBOut o;
	o.color = float4(0);	// not written
	o.mask = m ^ x;
	return o;
}

// the cover quad: a rectangle in pixels (left, top, right, bottom)
vertex TOut vsRect(uint vid [[vertex_id]], constant float2 &size [[buffer(1)]],
	constant float4 &r [[buffer(2)]])
{
	const uint2 k[6] = {uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1)};
	float2 p = float2(k[vid].x ? r.z : r.x, k[vid].y ? r.w : r.y);
	TOut o;
	o.tri = 0;
	o.pos = float4(p.x / size.x * 2 - 1, 1 - p.y / size.y * 2, 0, 1);
	return o;
}

// One instance per quad (four float2 at buffer 0), 6 vertices: the quad
// grown by 0.75 px with mitered corners (its corners are near right angles),
// or its grown bounding box if a corner is sharp or an edge has no length.
vertex TOut vsQuad(uint vid [[vertex_id]], uint iid [[instance_id]],
	const device float2 *v [[buffer(0)]], constant float2 &size [[buffer(1)]])
{
	float2 q[4] = {v[iid * 4], v[iid * 4 + 1], v[iid * 4 + 2], v[iid * 4 + 3]};
	TOut o;
	o.tri = iid;
#if CENTER_ONLY
	const float d = 0.0;
#else
	const float d = 0.75;
#endif
	const uint fan[6] = {0, 1, 2, 0, 2, 3};
	uint k = fan[vid];
	float area = (q[0].x * q[1].y - q[1].x * q[0].y) + (q[1].x * q[2].y - q[2].x * q[1].y)
		+ (q[2].x * q[3].y - q[3].x * q[2].y) + (q[3].x * q[0].y - q[0].x * q[3].y);
	float s = area > 0 ? 1 : -1;
	float2 eIn = q[k] - q[(k + 3) & 3], eOut = q[(k + 1) & 3] - q[k];
	float2 p = q[0];
	bool bBox = true;
#if CENTER_ONLY
	if (area != 0) {	// exact corners (d is 0): the rasterizer's pixel-center rule decides
		p = q[k];
		bBox = false;
	}
#endif
	if (area != 0 && length(eIn) > 0 && length(eOut) > 0) {
		float2 n1 = s * float2(normalize(eIn).y, -normalize(eIn).x);
		float2 n2 = s * float2(normalize(eOut).y, -normalize(eOut).x);
		float kk = 1 + dot(n1, n2);
		if (kk > 0.08) {
			p = q[k] + (n1 + n2) * (d / kk);
			bBox = false;
		}
	}
	if (bBox && area != 0) {	// grown bounding box (rare)
		float2 lo = min(min(q[0], q[1]), min(q[2], q[3])) - d, hi = max(max(q[0], q[1]), max(q[2], q[3])) + d;
		const uint2 c[4] = {uint2(0, 0), uint2(1, 0), uint2(1, 1), uint2(0, 1)};
		p = float2(c[k].x ? hi.x : lo.x, c[k].y ? hi.y : lo.y);
	}
	o.pos = float4(p.x / size.x * 2 - 1, 1 - p.y / size.y * 2, 0, 1);
	return o;
}

fragment FBOut fsMaskOrQuad(TOut in [[stage_in]], uint2 m [[color(1)]],
	const device float2 *v [[buffer(1)]], texture2d<uint> lut [[texture(0)]] CNT_PARAM)
{
	uint2 t = QuadMask(in, v, lut CNT_PASS);
	if (!any(t != 0))
		discard_fragment();
	FBOut o;
	o.color = float4(0);	// not written
	o.mask = m | t;
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

// Coverage mode edge lookup table; must match kLut* and EdgeMask in the
// shader. Entry (row i, column j) holds the mask of the 64 samples s with
// dot(n, s - center) > r, for n the unit direction at diamond angle
// 4 i / kLutAngles and r = -kLutR + 2 kLutR j / (kLutDists - 1). Samples as
// Sample() in the shader.
const int	kLutAngles = 512, kLutDists = 257;
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
		// diamond angle da in [0, 4) -> a point on |x| + |y| = 1, normalized
		double	da = 4.0 * i / kLutAngles, x, y;
		if (da < 1) { x = 1 - da; y = da; }
		else if (da < 2) { x = 1 - da; y = 2 - da; }
		else if (da < 3) { x = da - 3; y = 2 - da; }
		else { x = da - 3; y = da - 4; }
		double	len = std::sqrt(x * x + y * y);
		float	nx = float(x / len), ny = float(y / len);
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
		id<MTLRenderPipelineState>	fanFlip, spanFlip, band, coverRect;	// hybrid fills
		id<MTLRenderPipelineState>	maskOrQuad, coverQuad;	// stroke strips
	} cov, covAliased;	// covAliased: the shaders built with CENTER_ONLY, for aliased frames
	id<MTLLibrary>	libraryAliased;
	id<MTLTexture>	mask;	// coverage mode: RG32Uint, tile memory only
	id<MTLBuffer>	counts;	// coverage mode fragment counts (profiling)
	id<MTLTexture>	maskLut;	// coverage mode: edge sample masks, RG32Uint
	id<MTLDepthStencilState>	dssNone;
	id<MTLDepthStencilState>	dssFillMark;	// invert the fill bit
	id<MTLDepthStencilState>	dssFillCover;	// draw where set, clearing it
	id<MTLDepthStencilState>	dssStroke;		// draw where ref > stored, store ref
	id<MTLDepthStencilState>	dssStrokeReset;	// zero the stroke bits
	id<MTLBuffer>	vertices;
	// Command buffers are referenced weakly: a strong reference would keep
	// a finished frame's resources, its IOSurface among them, alive, and the
	// app reuses a surface only once nothing holds it. The queue keeps a
	// command buffer until it completes; after that these read nil.
	__weak id<MTLCommandBuffer>	lastCmd;
	// vertex buffers: a ring, so the CPU can fill one while the GPU reads others
	static const int	kRing = 3;
	id<MTLBuffer>	ring[kRing];
	__weak id<MTLCommandBuffer>	ringCmd[kRing];	// last frame that read ring[i]
	int		iRing = 0;
	id<MTLTexture>	ownTarget;	// the renderer's texture, when no surface is set
	IOSurfaceRef	targetSurface = nullptr;	// not retained; wrapped per frame
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

	id<MTLRenderPipelineState> MakeCovPipe(NSString *vs, NSString *fs, bool bColor, id<MTLLibrary> lib = nil)
	{
		if (!lib)
			lib = library;
		MTLRenderPipelineDescriptor	*d = [MTLRenderPipelineDescriptor new];
		d.vertexFunction = [lib newFunctionWithName:vs];
		d.fragmentFunction = [lib newFunctionWithName:fs];
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
	// 64 exact per-sample loop instead of the lookup table, 128 mask draws
	// don't read the mask, 256 no mask computation at all, 512 no discard,
	// 2048 fills as grown fan triangles instead of hybrid, 4096 hybrid fills
	// without edge bands, 8192 strokes as triangles instead of strips, 16384
	// hybrid fills flip with the fan instead of spans);
	// WHORLD_MTL_PROFILE counts pixels and fragments (and slows the GPU)
	m_nAblate = getenv("WHORLD_MTL_ABLATE") ? atoi(getenv("WHORLD_MTL_ABLATE")) : 0;
	m_bProfile = getenv("WHORLD_MTL_PROFILE") != nullptr;
	MTLCompileOptions	*co = [MTLCompileOptions new];
	co.preprocessorMacros = @{@"ABLATE_LOOP": @((m_nAblate & 1) ? 1 : 0),
		@"ABLATE_NOGROW": @((m_nAblate & 16) ? 1 : 0), @"PROF_COUNT": @(m_bProfile ? 1 : 0),
		@"EXACT_LOOP": @((m_nAblate & 64) ? 1 : 0), @"ABLATE_FETCH": @((m_nAblate & 128) ? 1 : 0),
		@"ABLATE_ALL": @((m_nAblate & 256) ? 1 : 0),
		@"NO_DISCARD": @((m_nAblate & 512) ? 1 : 0)};
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
	im.ownTarget = im.target;
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
		im.cov.fanFlip = im.MakeCovPipe(@"vsPath", @"fsFanFlip", false);
		im.cov.spanFlip = im.MakeCovPipe(@"vsSpan", @"fsFanFlip", false);
		im.cov.band = im.MakeCovPipe(@"vsBand", @"fsBand", false);
		im.cov.coverRect = im.MakeCovPipe(@"vsRect", @"fsCover", true);
		im.cov.maskOrQuad = im.MakeCovPipe(@"vsQuad", @"fsMaskOrQuad", false);
		im.cov.coverQuad = im.MakeCovPipe(@"vsQuad", @"fsCover", true);
		// Aliased frames use the same machinery with one sample, the pixel
		// center (Direct2D's aliased rule): a pixel is all in or all out.
		// Fills need no edge bands then; spans are exact.
		{
			MTLCompileOptions	*ca = [MTLCompileOptions new];
			NSMutableDictionary	*macros = [co.preprocessorMacros mutableCopy];
			macros[@"CENTER_ONLY"] = @1;
			ca.preprocessorMacros = macros;
			NSError	*errA = nil;
			im.libraryAliased = [im.device newLibraryWithSource:@(kShaderSource) options:ca error:&errA];
			if (!im.libraryAliased) {
				NSLog(@"MetalRenderer: aliased shaders: %@", errA);
				im.device = nil;
				return;
			}
			id<MTLLibrary>	la = im.libraryAliased;
			Impl::CovPipelines&	a = im.covAliased;
			a.maskOr = im.MakeCovPipe(@"vsTri", @"fsMaskOr", false, la);
			a.maskXor = im.MakeCovPipe(@"vsTri", @"fsMaskXor", false, la);
			a.cover = im.MakeCovPipe(@"vsTri", @"fsCover", true, la);
			a.clear = im.MakeCovPipe(@"vsFull", @"fsClearCov", true, la);
			a.fanFlip = im.MakeCovPipe(@"vsPath", @"fsFanFlip", false, la);
			a.spanFlip = im.MakeCovPipe(@"vsSpan", @"fsFanFlip", false, la);
			a.band = nil;	// not needed
			a.coverRect = im.MakeCovPipe(@"vsRect", @"fsCover", true, la);
			a.maskOrQuad = im.MakeCovPipe(@"vsQuad", @"fsMaskOrQuad", false, la);
			a.coverQuad = im.MakeCovPipe(@"vsQuad", @"fsCover", true, la);
		}
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
	// stroke strips only in coverage mode; the stencil path draws triangles
	const bool	bStrips = !m_nSamples && !(m_nAblate & 8192);
	const bool	bSpans = !m_nSamples && !(m_nAblate & (2048 | 16384));
	const int	nWidth = m_nWidth, nHeight = m_nHeight;
	dispatch_apply(m_aOp.size(), DISPATCH_APPLY_AUTO, ^(size_t i) {
		Op&	op = pOps[i];
		op.tris.clear();
		op.quads.clear();
		op.spans.clear();
		switch (op.type) {
		case Op::FILL: {
			// only figures begun FILLED take part in the fill
			std::vector<gpu::Contour>	filled;
			bool	bAll = true;
			for (size_t f = op.iFig; f < op.iFig + op.nFig; f++)
				bAll = bAll && pFig[f].bFilled;
			if (bAll) {
				gpu::FanContours(&pCt[op.iFig], op.nFig, op.tris);
				if (bSpans)
					gpu::SpanContours(&pCt[op.iFig], op.nFig, nWidth, nHeight, op.spans);
			} else {
				for (size_t f = op.iFig; f < op.iFig + op.nFig; f++) {
					if (pFig[f].bFilled)
						filled.push_back(pCt[f]);
				}
				gpu::FanContours(filled.data(), filled.size(), op.tris);
				if (bSpans)
					gpu::SpanContours(filled.data(), filled.size(), nWidth, nHeight, op.spans);
			}
			float	x0 = HUGE_VALF, y0 = HUGE_VALF, x1 = -HUGE_VALF, y1 = -HUGE_VALF;
			for (gpu::Vec2 p : op.tris) {
				x0 = std::min(x0, p.x); y0 = std::min(y0, p.y);
				x1 = std::max(x1, p.x); y1 = std::max(y1, p.y);
			}
			op.box[0] = x0; op.box[1] = y0; op.box[2] = x1; op.box[3] = y1;
			break;
		}
		case Op::STROKE:
			gpu::StrokeContours(&pCt[op.iFig], op.nFig, op.fWidth * fScale, fTol, op.tris,
				bStrips ? &op.quads : nullptr);
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
			op.iQuad = nVert;
			nVert += op.quads.size();
			op.iSpan = nVert;
			nVert += op.spans.size();
		}
		m_stats.nVertices = nVert;
		size_t	nBytes = std::max<size_t>(nVert, 1) * sizeof(gpu::Vec2);
		im.iRing = (im.iRing + 1) % Impl::kRing;
		if (id<MTLCommandBuffer> pending = im.ringCmd[im.iRing]) {	// the GPU may still read this buffer
			[pending waitUntilCompleted];
			im.ringCmd[im.iRing] = nil;
		}
		id<MTLBuffer>	__strong &buf = im.ring[im.iRing];
		if (!buf || buf.length < nBytes)
			buf = [im.device newBufferWithLength:nBytes * 3 / 2 options:MTLResourceStorageModeShared];
		im.vertices = buf;
		// a surface target: wrap it for this frame only
		if (im.targetSurface) {
			MTLTextureDescriptor	*td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
				width:m_nWidth height:m_nHeight mipmapped:NO];
			td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
			td.storageMode = im.bShared ? MTLStorageModeShared : MTLStorageModeManaged;
			im.target = [im.device newTextureWithDescriptor:td iosurface:im.targetSurface plane:0];
			if (!im.target)
				im.target = im.ownTarget;
		} else {
			im.target = im.ownTarget;
		}
		auto	*pDst = static_cast<gpu::Vec2 *>(im.vertices.contents);
		for (const Op& op : m_aOp) {
			if (!op.tris.empty())
				std::memcpy(&pDst[op.iVert], op.tris.data(), op.tris.size() * sizeof(gpu::Vec2));
			if (!op.quads.empty())
				std::memcpy(&pDst[op.iQuad], op.quads.data(), op.quads.size() * sizeof(gpu::Vec2));
			if (!op.spans.empty())
				std::memcpy(&pDst[op.iSpan], op.spans.data(), op.spans.size() * sizeof(gpu::Vec2));
		}

		if (!m_nSamples) {	// coverage mode: 64 samples, or the pixel center when aliased
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
		Commit((__bridge void *)cmd, nDraws);
	}
}

bool MetalRenderer::GetFragmentCounts(uint32_t aCount[8]) const
{
	if (!m_pImpl->counts)
		return false;
	std::memcpy(aCount, m_pImpl->counts.contents, sizeof(uint32_t) * 8);
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
		} else {	// hexagon, as vsTri
			gpu::Vec2	q[3] = {a, b, c}, e[3] = {eca, eab, ebc}, n[3] = {nca, nab, nbc};
			gpu::Vec2	hx[6];
			for (int k = 0; k < 3; k++) {
				int	o = (k + 1) % 3;
				hx[2 * k] = {q[k].x + d * (n[k].x + e[k].x), q[k].y + d * (n[k].y + e[k].y)};
				hx[2 * k + 1] = {q[k].x + d * (n[o].x - e[o].x), q[k].y + d * (n[o].y - e[o].y)};
			}
			double	f = 0;
			for (int k = 0; k < 6; k++)
				f += double(hx[k].x) * hx[(k + 1) % 6].y - double(hx[(k + 1) % 6].x) * hx[k].y;
			fPx += std::fabs(f) / 2;
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
	const bool	bAliased = !m_bAntialias;	// pixel centers only: see covAliased
	const Impl::CovPipelines&	cv = bAliased ? im.covAliased : im.cov;
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
		[enc setFragmentBuffer:im.vertices offset:0 atIndex:1];
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
				[enc setRenderPipelineState:cv.clear];
				[enc setFragmentBytes:clr length:sizeof(clr) atIndex:0];
				[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
				nDraws++;
				break;
			case Op::FILL:
			case Op::STROKE:
			case Op::RECT: {
				if (op.tris.empty() && op.quads.empty())
					break;
				if (((m_nAblate & 4) && op.type == Op::FILL) || ((m_nAblate & 8) && op.type == Op::STROKE))
					break;
				if (!op.quads.empty()) {	// stroke strips: quads and the remaining join triangles, one mask
					NSUInteger	nQuad = op.quads.size() / 4, nTri = op.tris.size() / 3;
					[enc setVertexBufferOffset:op.iQuad * sizeof(gpu::Vec2) atIndex:0];
					[enc setFragmentBufferOffset:op.iQuad * sizeof(gpu::Vec2) atIndex:1];
					[enc setRenderPipelineState:cv.maskOrQuad];
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:nQuad];
					if (nTri) {
						[enc setVertexBufferOffset:op.iVert * sizeof(gpu::Vec2) atIndex:0];
						[enc setFragmentBufferOffset:op.iVert * sizeof(gpu::Vec2) atIndex:1];
						[enc setRenderPipelineState:cv.maskOr];
						[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12 instanceCount:nTri];
					}
					if (!(m_nAblate & 2)) {
						[enc setFragmentBytes:clr length:sizeof(clr) atIndex:0];
						[enc setVertexBufferOffset:op.iQuad * sizeof(gpu::Vec2) atIndex:0];
						[enc setRenderPipelineState:cv.coverQuad];
						[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:nQuad];
						if (nTri) {
							[enc setVertexBufferOffset:op.iVert * sizeof(gpu::Vec2) atIndex:0];
							[enc setRenderPipelineState:cv.cover];
							[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12 instanceCount:nTri];
						}
					}
					nDraws += 4;
					break;
				}
				if (op.tris.empty())
					break;
				NSUInteger	nTri = op.tris.size() / 3;
				if (m_bProfile)
					ProfileOp(op);
				if (op.type == Op::FILL && !(m_nAblate & 2048)) {	// hybrid fill
					[enc setVertexBufferOffset:op.iVert * sizeof(gpu::Vec2) atIndex:0];
					[enc setFragmentBufferOffset:op.iVert * sizeof(gpu::Vec2) atIndex:1];
					if (!(m_nAblate & 16384)) {	// spans: the fill's area once
						if (!op.spans.empty()) {
							[enc setVertexBufferOffset:op.iSpan * sizeof(gpu::Vec2) atIndex:0];
							[enc setRenderPipelineState:cv.spanFlip];
							[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6
								instanceCount:op.spans.size() / 2];
							[enc setVertexBufferOffset:op.iVert * sizeof(gpu::Vec2) atIndex:0];
						}
					} else {
						[enc setRenderPipelineState:cv.fanFlip];
						[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:op.tris.size()];
					}
					if (!bAliased && !(m_nAblate & 4096)) {	// aliased: spans are exact
						[enc setRenderPipelineState:cv.band];
						[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:nTri];
					}
					// cover the bounding box (from Tessellate), grown a pixel, clipped to the target
					const float	x0 = op.box[0], y0 = op.box[1], x1 = op.box[2], y1 = op.box[3];
					const float	r[4] = {std::max(x0 - 1, 0.f), std::max(y0 - 1, 0.f),
						std::min(x1 + 1, float(m_nWidth)), std::min(y1 + 1, float(m_nHeight))};
					if (r[2] > r[0] && r[3] > r[1]) {
						[enc setRenderPipelineState:cv.coverRect];
						[enc setVertexBytes:r length:sizeof(r) atIndex:2];
						[enc setFragmentBytes:clr length:sizeof(clr) atIndex:0];
						[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
					}
					nDraws += 3;
					break;
				}
				[enc setVertexBufferOffset:op.iVert * sizeof(gpu::Vec2) atIndex:0];
				[enc setFragmentBufferOffset:op.iVert * sizeof(gpu::Vec2) atIndex:1];
				[enc setRenderPipelineState:op.type == Op::FILL ? cv.maskXor : cv.maskOr];
				[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12 instanceCount:nTri];
				nDraws++;
				if (!(m_nAblate & 2)) {
					[enc setRenderPipelineState:cv.cover];
					[enc setFragmentBytes:clr length:sizeof(clr) atIndex:0];
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12 instanceCount:nTri];
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
	Commit((__bridge void *)cmd, nDraws);
}

void MetalRenderer::Commit(void *pCmd, size_t nDraws)
{
	Impl&	im = *m_pImpl;
	id<MTLCommandBuffer>	cmd = (__bridge id<MTLCommandBuffer>)pCmd;
	Stats	*pStats = &m_stats;
	std::function<void(bool, double)>	fnDone = std::move(m_fnDone);
	m_fnDone = nullptr;
	[cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
		double	fMs = (cb.GPUEndTime - cb.GPUStartTime) * 1000;
		pStats->fGpuMs = fMs;
		if (fnDone) {
			bool	bOk = cb.status == MTLCommandBufferStatusCompleted;
			if (!bOk)
				NSLog(@"MetalRenderer: frame failed: %@", cb.error);
			fnDone(bOk, fMs);
		}
	}];
	[cmd commit];
	im.lastCmd = cmd;
	im.ringCmd[im.iRing] = cmd;
	im.target = im.ownTarget;	// don't hold the frame's surface texture
	m_stats.nDraws = nDraws;
}

void MetalRenderer::EndFrame(std::function<void(bool bOk, double fGpuMs)> fnDone)
{
	m_fnDone = std::move(fnDone);
	EndFrame();
	if (m_fnDone) {	// nothing was committed
		auto	fn = std::move(m_fnDone);
		m_fnDone = nullptr;
		fn(false, 0);
	}
}

bool MetalRenderer::SetTargetSurface(IOSurfaceRef surface)
{
	if (surface && (int(IOSurfaceGetWidth(surface)) != m_nWidth || int(IOSurfaceGetHeight(surface)) != m_nHeight
		|| IOSurfaceGetPixelFormat(surface) != 'BGRA')) {
		m_pImpl->targetSurface = nullptr;
		return false;
	}
	m_pImpl->targetSurface = surface;
	return true;
}

bool MetalRenderer::IsCoverageModeSupported()
{
	id<MTLDevice>	device = MTLCreateSystemDefaultDevice();
	return device && [device supportsFamily:MTLGPUFamilyApple1];
}

bool MetalRenderer::CanDrawCoverage(int nWidth, int nHeight)
{
	static const bool	bSupported = IsCoverageModeSupported();
	const int	kMaxSize = 16384;	// Metal's 2D texture limit on Apple GPUs (Apple3 and later)
	return bSupported && nWidth > 0 && nHeight > 0 && nWidth <= kMaxSize && nHeight <= kMaxSize;
}

void MetalRenderer::WaitUntilDone()
{
	if (!m_pImpl)
		return;
	if (id<MTLCommandBuffer> cmd = m_pImpl->lastCmd)
		[cmd waitUntilCompleted];
	m_pImpl->lastCmd = nil;
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
