// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#include "CGRenderer.h"

#include <ImageIO/ImageIO.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace whorld {

namespace {

// Direct2D's default stroke style: D2D1_LINE_JOIN_MITER with miterLimit 10.
// Direct2D measures the miter from the vertex against half the width, and
// Core Graphics (like PostScript) from the inner corner against the full
// width; both ratios are 1 / sin(angle / 2), so the limit is 10 in both.
// Past the limit Direct2D clips the miter (cuts it off at the limit) while
// Core Graphics bevels it; StrokePath adds the clipped part back.
const CGFloat kMiterLimit = 10;
const double kD2DMiterLimit = 10;	// times half the stroke width

struct Vec {
	double	x, y;
};
inline Vec operator-(Vec a, Vec b) { return Vec{a.x - b.x, a.y - b.y}; }
inline Vec operator+(Vec a, Vec b) { return Vec{a.x + b.x, a.y + b.y}; }
inline Vec operator*(Vec a, double s) { return Vec{a.x * s, a.y * s}; }
inline double Dot(Vec a, Vec b) { return a.x * b.x + a.y * b.y; }
inline double Cross(Vec a, Vec b) { return a.x * b.y - a.y * b.x; }
inline double Len(Vec a) { return std::sqrt(Dot(a, a)); }
inline Vec ToVec(const PointF& p) { return Vec{p.x, p.y}; }

// One segment of a figure, reduced to what joins need: end points and the
// tangent directions at both ends.
struct Seg {
	Vec		p0, p1;		// start and end points
	Vec		t0, t1;		// unit tangents at start and end
};

bool Normalize(Vec& v)
{
	double	l = Len(v);
	if (!(l > 1e-9))
		return false;
	v = v * (1 / l);
	return true;
}

// Tangent at a cubic's end: the first non-degenerate control vector.
bool BezierEndTangent(Vec p, Vec q1, Vec q2, Vec q3, Vec& t)
{
	// q1, q2, q3 are the other points in order of distance along the curve
	for (Vec q : {q1, q2, q3}) {
		t = q - p;
		if (Normalize(t))
			return true;
	}
	return false;
}

}	// namespace

namespace {

} // namespace

CGBitmapRenderer::CGBitmapRenderer(int nWidth, int nHeight, double fScale)
	: m_nWidth(std::max(nWidth, 0)), m_nHeight(std::max(nHeight, 0)), m_fScale(fScale)
{
	m_nStride = static_cast<size_t>(m_nWidth) * 4;
	m_aPixel.assign(m_nStride * static_cast<size_t>(std::max(m_nHeight, 1)), 0);
	m_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	if (m_nWidth > 0 && m_nHeight > 0) {
		// BGRA in memory, premultiplied: DXGI_FORMAT_B8G8R8A8_UNORM, PREMULTIPLIED
		m_ctx = CGBitmapContextCreate(m_aPixel.data(), m_nWidth, m_nHeight, 8, m_nStride, m_space,
			kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	}
	if (m_ctx) {
		CGContextSetInterpolationQuality(m_ctx, kCGInterpolationNone);
		CGContextSetShouldSmoothFonts(m_ctx, false);
	}
}

CGBitmapRenderer::~CGBitmapRenderer()
{
	ReleasePaths();
	if (m_ctx)
		CGContextRelease(m_ctx);
	if (m_space)
		CGColorSpaceRelease(m_space);
}

SizeF CGBitmapRenderer::GetSizeDIPs() const
{
	return SizeF{static_cast<float>(m_nWidth / m_fScale), static_cast<float>(m_nHeight / m_fScale)};
}

void CGBitmapRenderer::ApplyBaseState()
{
	// map DIPs (top-left origin, y down) to pixels (bottom-left origin, y up)
	CGContextTranslateCTM(m_ctx, 0, m_nHeight);
	CGContextScaleCTM(m_ctx, m_fScale, -m_fScale);
	CGContextSetLineJoin(m_ctx, kCGLineJoinMiter);
	CGContextSetMiterLimit(m_ctx, kMiterLimit);
	CGContextSetLineCap(m_ctx, kCGLineCapButt);
	CGContextSetBlendMode(m_ctx, kCGBlendModeNormal);	// source-over, premultiplied
}

void CGBitmapRenderer::BeginFrame()
{
	if (!m_ctx || m_bInFrame)
		return;
	CGContextSaveGState(m_ctx);
	ApplyBaseState();
	m_bInFrame = true;
}

void CGBitmapRenderer::EndFrame()
{
	if (!m_ctx || !m_bInFrame)
		return;
	if (m_bMirrorClip) {	// unbalanced mirror; drop the clip
		CGContextRestoreGState(m_ctx);
		m_bMirrorClip = false;
	}
	ReleasePaths();
	CGContextRestoreGState(m_ctx);
	CGContextFlush(m_ctx);
	m_bInFrame = false;
}

void CGBitmapRenderer::SetFillColor(const ColorF& clr)
{
	// same color space as the context: no conversion, as in Direct2D
	const CGFloat	comp[4] = {clr.r, clr.g, clr.b, clr.a};
	CGColorRef	c = CGColorCreate(m_space, comp);
	CGContextSetFillColorWithColor(m_ctx, c);
	CGColorRelease(c);
}

void CGBitmapRenderer::SetStrokeColor(const ColorF& clr)
{
	const CGFloat	comp[4] = {clr.r, clr.g, clr.b, clr.a};
	CGColorRef	c = CGColorCreate(m_space, comp);
	CGContextSetStrokeColorWithColor(m_ctx, c);
	CGColorRelease(c);
}

void CGBitmapRenderer::SetAntialiasing(bool bEnable)
{
	if (!m_ctx)
		return;
	CGContextSetShouldAntialias(m_ctx, bEnable);
	CGContextSetAllowsAntialiasing(m_ctx, bEnable);
}

void CGBitmapRenderer::Clear(const ColorF& clr)
{
	if (!m_ctx)
		return;
	// replace every pixel within the clip, including alpha, without blending
	CGContextSaveGState(m_ctx);
	CGContextSetBlendMode(m_ctx, kCGBlendModeCopy);
	CGContextSetShouldAntialias(m_ctx, false);
	SetFillColor(clr);
	SizeF	sz = GetSizeDIPs();
	CGContextFillRect(m_ctx, CGRectMake(0, 0, sz.width, sz.height));
	CGContextRestoreGState(m_ctx);
}

void CGBitmapRenderer::ReleasePaths()
{
	if (m_pathFilled) {
		CGPathRelease(m_pathFilled);
		m_pathFilled = nullptr;
	}
	if (m_pathAll) {
		CGPathRelease(m_pathAll);
		m_pathAll = nullptr;
	}
}

void CGBitmapRenderer::BeginPath()
{
	ReleasePaths();
	m_aFigure.clear();
	m_pathFilled = CGPathCreateMutable();
	m_pathAll = CGPathCreateMutable();
}

void CGBitmapRenderer::AddFigure(const PointF* pStart, int nSegments, bool bCurved, bool bFilled)
{
	if (!m_pathAll)
		BeginPath();
	int	nPts = 1 + (bCurved ? nSegments * 3 : nSegments);
	m_aFigure.push_back(Figure{std::vector<PointF>(pStart, pStart + nPts), nSegments, bCurved});
	CGMutablePathRef	paths[2] = {m_pathAll, bFilled ? m_pathFilled : nullptr};
	for (CGMutablePathRef path : paths) {
		if (!path)
			continue;
		CGPathMoveToPoint(path, nullptr, pStart[0].x, pStart[0].y);	// BeginFigure
		if (bCurved) {	// AddBeziers
			for (int i = 0; i < nSegments; i++) {
				const PointF*	p = &pStart[1 + i * 3];
				CGPathAddCurveToPoint(path, nullptr, p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y);
			}
		} else {	// AddLines
			for (int i = 1; i <= nSegments; i++)
				CGPathAddLineToPoint(path, nullptr, pStart[i].x, pStart[i].y);
		}
		CGPathCloseSubpath(path);	// D2D1_FIGURE_END_CLOSED
	}
}

void CGBitmapRenderer::EndPath()
{
	// nothing to do: paths are immutable once figures are added
}

void CGBitmapRenderer::FillPath(const ColorF& clr)
{
	if (!m_ctx || !m_pathFilled || CGPathIsEmpty(m_pathFilled))
		return;
	SetFillColor(clr);
	CGContextAddPath(m_ctx, m_pathFilled);
	CGContextEOFillPath(m_ctx);	// D2D1_FILL_MODE_ALTERNATE
}

void CGBitmapRenderer::StrokePath(const ColorF& clr, float fWidth)
{
	if (!m_ctx || !m_pathAll || CGPathIsEmpty(m_pathAll))
		return;
	// Direct2D strokes a negative width as its absolute value (oscillators
	// can drive line width below zero; confirmed against the "fish eye"
	// golden image). A zero width is skipped, because Core Graphics would
	// draw a one-pixel hairline; Direct2D's behavior at exactly zero is
	// unverified.
	fWidth = std::fabs(fWidth);
	if (!(fWidth > 0))
		return;
	CGMutablePathRef	pathMiters = CGPathCreateMutable();
	bool	bMiters = AddClippedMiters(pathMiters, fWidth);
	// With translucent color, the stroke and the miter fill overlap would
	// blend twice; draw both opaque into a layer and composite it once.
	bool	bLayer = bMiters && clr.a < 1;
	ColorF	clrDraw = clr;
	if (bLayer) {
		CGContextSaveGState(m_ctx);
		CGContextSetAlpha(m_ctx, clr.a);
		CGRect	rBounds = CGRectInset(CGPathGetBoundingBox(m_pathAll), -fWidth * kD2DMiterLimit, -fWidth * kD2DMiterLimit);
		CGContextBeginTransparencyLayerWithRect(m_ctx, rBounds, nullptr);
		clrDraw.a = 1;
	}
	SetStrokeColor(clrDraw);
	CGContextSetLineWidth(m_ctx, fWidth);
	CGContextAddPath(m_ctx, m_pathAll);
	CGContextStrokePath(m_ctx);
	if (bMiters) {
		SetFillColor(clrDraw);
		CGContextAddPath(m_ctx, pathMiters);
		CGContextFillPath(m_ctx);	// polygons are oriented alike, so nonzero is a union
	}
	if (bLayer) {
		CGContextEndTransparencyLayer(m_ctx);
		CGContextRestoreGState(m_ctx);
	}
	CGPathRelease(pathMiters);
}

bool CGBitmapRenderer::AddClippedMiters(CGMutablePathRef path, float fWidth) const
{
	const double	hw = fWidth / 2;
	const double	fLimit = kD2DMiterLimit * hw;	// clipped miter length from the vertex
	bool	bAny = false;
	std::vector<Seg>	segs;
	for (const Figure& fig : m_aFigure) {
		// collect non-degenerate segments, including the implicit closing line
		segs.clear();
		Vec	cur = ToVec(fig.pts[0]);
		for (int i = 0; i < fig.nSegments; i++) {
			Seg	sg;
			sg.p0 = cur;
			if (fig.bCurved) {
				Vec	c1 = ToVec(fig.pts[1 + i * 3]), c2 = ToVec(fig.pts[2 + i * 3]), p3 = ToVec(fig.pts[3 + i * 3]);
				sg.p1 = p3;
				if (!BezierEndTangent(cur, c1, c2, p3, sg.t0))
					continue;	// degenerate: a point
				Vec	tEnd;
				BezierEndTangent(p3, c2, c1, cur, tEnd);
				sg.t1 = tEnd * -1;	// direction of travel at the end
			} else {
				sg.p1 = ToVec(fig.pts[1 + i]);
				sg.t0 = sg.p1 - cur;
				if (!Normalize(sg.t0))
					continue;	// zero length
				sg.t1 = sg.t0;
			}
			segs.push_back(sg);
			cur = sg.p1;
		}
		Vec	start = ToVec(fig.pts[0]);
		Seg	close;
		close.p0 = cur;
		close.p1 = start;
		close.t0 = start - cur;
		if (Normalize(close.t0)) {	// D2D1_FIGURE_END_CLOSED adds a closing line
			close.t1 = close.t0;
			segs.push_back(close);
		}
		size_t	n = segs.size();
		if (n < 2)
			continue;
		for (size_t i = 0; i < n; i++) {	// join between segment i and the next
			Vec	a = segs[i].t1;				// incoming direction
			Vec	b = segs[(i + 1) % n].t0;	// outgoing direction
			Vec	p = segs[i].p1;				// the vertex
			Vec	m = a - b;					// miter direction, pointing out of the corner
			if (!Normalize(m))
				continue;	// straight through: no join
			// outer-side normals of both segments
			double	s = Cross(a, b) > 0 ? -1 : 1;
			Vec	na = Vec{-a.y, a.x} * s;
			Vec	nb = Vec{-b.y, b.x} * s;
			double	fDot = Dot(m, na);	// cos of half the exterior angle
			double	fMiter = fDot > 1e-12 ? hw / fDot : HUGE_VAL;	// full miter length
			if (fMiter <= fLimit)
				continue;	// within the limit: Core Graphics draws this miter itself
			Vec	o1 = p + na * hw, o2 = p + nb * hw;
			// cut the offset edges off at the clip line dot(X - p, m) = fLimit
			double	fA = Dot(a, m), fB = Dot(b, m);
			if (!(fA > 1e-12) || !(fB < -1e-12))
				continue;
			Vec	x1 = o1 + a * ((fLimit - Dot(o1 - p, m)) / fA);
			Vec	x2 = o2 + b * ((fLimit - Dot(o2 - p, m)) / fB);
			Vec	poly[5] = {p, o1, x1, x2, o2};
			double	fArea = 0;
			for (int k = 0; k < 5; k++)
				fArea += Cross(poly[k], poly[(k + 1) % 5]);
			if (fArea < 0)	// orient all polygons the same way
				std::reverse(poly, poly + 5);
			CGPathMoveToPoint(path, nullptr, poly[0].x, poly[0].y);
			for (int k = 1; k < 5; k++)
				CGPathAddLineToPoint(path, nullptr, poly[k].x, poly[k].y);
			CGPathCloseSubpath(path);
			bAny = true;
		}
	}
	return bAny;
}

void CGBitmapRenderer::FillRect(const RectF& rect, const ColorF& clr)
{
	if (!m_ctx)
		return;
	SetFillColor(clr);
	CGContextFillRect(m_ctx, CGRectMake(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top));
}

// ported from WhorldDraw.cpp CWhorldDraw::InitMirroring
bool CGBitmapRenderer::BeginQuadMirror()
{
	if (!m_ctx || m_bMirrorClip)
		return false;
	// quadrant size in pixels, rounded up so odd sizes share the center
	m_nQuadWidth = (m_nWidth + 1) / 2;
	m_nQuadHeight = (m_nHeight + 1) / 2;
	if (!m_nQuadWidth || !m_nQuadHeight)	// if either size is zero
		return false;	// fail silently, as the original does
	// clip in pixels: aliased, pixel-aligned
	CGContextSaveGState(m_ctx);
	CGContextClipToRect(m_ctx, CGRectMake(0, 0, m_nQuadWidth / m_fScale, m_nQuadHeight / m_fScale));
	m_bMirrorClip = true;
	return true;
}

// ported from WhorldDraw.cpp CWhorldDraw::FinishMirroring
bool CGBitmapRenderer::EndQuadMirror()
{
	if (!m_ctx || !m_bMirrorClip)	// no clip was pushed
		return false;
	CGContextRestoreGState(m_ctx);	// pop clip
	m_bMirrorClip = false;
	CGContextFlush(m_ctx);
	// copy the upper-left quadrant, then write it flipped into the other
	// three with copy semantics (no blending), reflecting across the full
	// frame: source pixel x lands at width - 1 - x, y at height - 1 - y
	const int	qw = m_nQuadWidth, qh = m_nQuadHeight;
	std::vector<uint32_t>	quad(static_cast<size_t>(qw) * qh);
	for (int y = 0; y < qh; y++)
		std::memcpy(&quad[static_cast<size_t>(y) * qw], &m_aPixel[y * m_nStride], qw * 4);
	auto	Put = [this](int x, int y, uint32_t px) {
		std::memcpy(&m_aPixel[y * m_nStride + static_cast<size_t>(x) * 4], &px, 4);
	};
	for (int y = 0; y < qh; y++) {	// upper right: horizontal flip
		for (int x = 0; x < qw; x++)
			Put(m_nWidth - 1 - x, y, quad[static_cast<size_t>(y) * qw + x]);
	}
	for (int y = 0; y < qh; y++) {	// lower left: vertical flip
		for (int x = 0; x < qw; x++)
			Put(x, m_nHeight - 1 - y, quad[static_cast<size_t>(y) * qw + x]);
	}
	for (int y = 0; y < qh; y++) {	// lower right: flip both axes
		for (int x = 0; x < qw; x++)
			Put(m_nWidth - 1 - x, m_nHeight - 1 - y, quad[static_cast<size_t>(y) * qw + x]);
	}
	return true;
}

CGImageRef CGBitmapRenderer::CopyImage() const
{
	return m_ctx ? CGBitmapContextCreateImage(m_ctx) : nullptr;
}

bool CGBitmapRenderer::WritePNG(const std::string& sPath, std::string* pError) const
{
	auto	Fail = [pError](const std::string& sMsg) {
		if (pError)
			*pError = sMsg;
		return false;
	};
	if (!m_ctx)
		return Fail("No bitmap.");
	// WIC is given GUID_WICPixelFormat32bppBGRA (straight alpha) but the
	// mapped bits are premultiplied; reproduce that by labeling the same
	// bytes as non-premultiplied
	CFDataRef	data = CFDataCreate(nullptr, m_aPixel.data(), m_nStride * m_nHeight);
	CGDataProviderRef	provider = CGDataProviderCreateWithCFData(data);
	CGImageRef	image = CGImageCreate(m_nWidth, m_nHeight, 8, 32, m_nStride, m_space,
		kCGImageAlphaFirst | kCGBitmapByteOrder32Little, provider, nullptr, false,
		kCGRenderingIntentDefault);
	CGDataProviderRelease(provider);
	CFRelease(data);
	if (!image)
		return Fail("Can't create image.");
	CFStringRef	path = CFStringCreateWithCString(nullptr, sPath.c_str(), kCFStringEncodingUTF8);
	CFURLRef	url = CFURLCreateWithFileSystemPath(nullptr, path, kCFURLPOSIXPathStyle, false);
	CFRelease(path);
	CGImageDestinationRef	dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr);
	CFRelease(url);
	if (!dest) {
		CGImageRelease(image);
		return Fail("Can't create file: " + sPath);
	}
	CGImageDestinationAddImage(dest, image, nullptr);
	bool	bOk = CGImageDestinationFinalize(dest);
	CFRelease(dest);
	CGImageRelease(image);
	return bOk ? true : Fail("Error writing file: " + sPath);
}

} // namespace whorld
