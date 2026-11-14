// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#include "AliasedRaster.h"

#include <algorithm>
#include <cmath>

namespace whorld {

namespace aliased {

namespace {

const float	kTolerance = 0.1f;	// curve flattening, pixels (as MetalRenderer)

void Flatten(const Figure* pFig, size_t nFigs, double fScale, bool bFilledOnly,
	std::vector<gpu::Contour>& aContour)
{
	aContour.clear();
	for (size_t i = 0; i < nFigs; i++) {
		const Figure&	f = pFig[i];
		if (bFilledOnly && !f.bFilled)
			continue;
		aContour.emplace_back();
		gpu::FlattenFigure(f.pts.data(), f.nSegments, f.bCurved, float(fScale), kTolerance, aContour.back());
	}
}

// The pixels whose centers are inside a convex polygon, appended as spans:
// x in [xl, xr) at y = row + 0.5, the half-open rule gpu::SpanContours uses
void ConvexSpans(const gpu::Vec2* p, int n, int nWidth, int nHeight, std::vector<Span>& out)
{
	float	y0 = p[0].y, y1 = p[0].y;
	for (int i = 1; i < n; i++) {
		y0 = std::min(y0, p[i].y);
		y1 = std::max(y1, p[i].y);
	}
	int	r0 = std::max(0, int(std::ceil(y0 - 0.5f))), r1 = std::min(nHeight, int(std::ceil(y1 - 0.5f)));
	if (r1 <= r0)
		return;
	int	nRows = r1 - r0;
	float	xl[64], xr[64];	// a stroke piece is a few rows high, almost always
	std::vector<float>	bigL, bigR;
	float	*pl = xl, *pr = xr;
	if (nRows > 64) {
		bigL.resize(size_t(nRows));
		bigR.resize(size_t(nRows));
		pl = bigL.data();
		pr = bigR.data();
	}
	std::fill(pl, pl + nRows, HUGE_VALF);
	std::fill(pr, pr + nRows, -HUGE_VALF);
	for (int i = 0; i < n; i++) {	// each edge over its rows: a convex polygon's
		gpu::Vec2	a = p[i], b = p[(i + 1) % n];	// crossings are its left and right sides
		if (a.y == b.y)
			continue;
		if (a.y > b.y)
			std::swap(a, b);
		int	ra = std::max(r0, int(std::ceil(a.y - 0.5f))), rb = std::min(r1, int(std::ceil(b.y - 0.5f)));
		float	k = (b.x - a.x) / (b.y - a.y);
		for (int r = ra; r < rb; r++) {
			float	x = a.x + (r + 0.5f - a.y) * k;
			pl[r - r0] = std::min(pl[r - r0], x);
			pr[r - r0] = std::max(pr[r - r0], x);
		}
	}
	for (int r = 0; r < nRows; r++) {
		if (!(pr[r] > pl[r]))
			continue;
		int	x0 = std::max(0, int(std::ceil(pl[r] - 0.5f))), x1 = std::min(nWidth, int(std::ceil(pr[r] - 0.5f)));
		if (x1 > x0)
			out.push_back(Span{r + r0, x0, x1});
	}
}

inline uint32_t MulDiv255(uint32_t x, uint32_t n)	// x * n / 255, rounded, for bytes
{
	uint32_t	t = x * n + 128;
	return (t + (t >> 8)) >> 8;
}

} // namespace

void FillSpans(const Figure* pFig, size_t nFigs, double fScale, int nWidth, int nHeight,
	std::vector<Span>& spans)
{
	spans.clear();
	thread_local std::vector<gpu::Contour>	aContour;
	thread_local std::vector<gpu::Vec2>	v;
	Flatten(pFig, nFigs, fScale, true, aContour);
	v.clear();
	gpu::SpanContours(aContour.data(), aContour.size(), nWidth, nHeight, v);
	spans.reserve(v.size() / 2);
	for (size_t i = 0; i + 1 < v.size(); i += 2)	// in row order, rows don't overlap
		spans.push_back(Span{int(v[i].y), int(v[i].x), int(v[i + 1].x)});
}

void StrokeSpans(const Figure* pFig, size_t nFigs, float fWidth, double fScale, int nWidth, int nHeight,
	std::vector<Span>& spans)
{
	spans.clear();
	thread_local std::vector<gpu::Contour>	aContour;
	thread_local std::vector<gpu::Vec2>	tris, quads;
	thread_local std::vector<Span>	raw, sorted;
	thread_local std::vector<uint32_t>	aStart, aFill;
	Flatten(pFig, nFigs, fScale, false, aContour);
	tris.clear();
	quads.clear();
	gpu::StrokeContours(aContour.data(), aContour.size(), fWidth * float(fScale), kTolerance, tris, &quads);
	raw.clear();
	for (size_t i = 0; i + 2 < tris.size(); i += 3)
		ConvexSpans(&tris[i], 3, nWidth, nHeight, raw);
	for (size_t i = 0; i + 3 < quads.size(); i += 4)
		ConvexSpans(&quads[i], 4, nWidth, nHeight, raw);
	if (raw.empty())
		return;
	// counting sort by row, then by x within each (short) row
	int	yMin = nHeight, yMax = -1;
	for (const Span& s : raw) {
		yMin = std::min(yMin, s.y);
		yMax = std::max(yMax, s.y);
	}
	aStart.assign(size_t(yMax - yMin) + 2, 0);
	for (const Span& s : raw)
		aStart[size_t(s.y - yMin) + 1]++;
	for (size_t r = 1; r < aStart.size(); r++)
		aStart[r] += aStart[r - 1];
	aFill.assign(aStart.begin(), aStart.end() - 1);
	sorted.resize(raw.size());
	for (const Span& s : raw)
		sorted[aFill[size_t(s.y - yMin)]++] = s;
	for (size_t r = 0; r + 1 < aStart.size(); r++) {
		std::sort(sorted.begin() + aStart[r], sorted.begin() + aStart[r + 1],
			[](const Span& a, const Span& b) { return a.x0 < b.x0; });
	}
	for (const Span& s : sorted) {	// the union of the pieces, row by row
		if (!spans.empty() && spans.back().y == s.y && s.x0 <= spans.back().x1)
			spans.back().x1 = std::max(spans.back().x1, s.x1);
		else
			spans.push_back(s);
	}
}

void RectSpans(const RectF& rect, double fScale, int nWidth, int nHeight, std::vector<Span>& spans)
{
	spans.clear();
	float	s = float(fScale);
	gpu::Vec2	q[4] = {
		{rect.left * s, rect.top * s}, {rect.right * s, rect.top * s},
		{rect.right * s, rect.bottom * s}, {rect.left * s, rect.bottom * s},
	};
	ConvexSpans(q, 4, nWidth, nHeight, spans);
}

void Blend(const std::vector<Span>& spans, const ColorF& clr, uint8_t* pPixels, size_t nStride,
	int y0, int y1, int xMax, int yMax)
{
	y1 = std::min(y1, yMax);
	if (y1 <= y0 || spans.empty())
		return;
	// premultiplied source, as Core Graphics draws a straight-alpha color
	float	a = std::clamp(clr.a, 0.0f, 1.0f);
	uint32_t	sb = uint32_t(std::lround(std::clamp(clr.b, 0.0f, 1.0f) * a * 255));
	uint32_t	sg = uint32_t(std::lround(std::clamp(clr.g, 0.0f, 1.0f) * a * 255));
	uint32_t	sr = uint32_t(std::lround(std::clamp(clr.r, 0.0f, 1.0f) * a * 255));
	uint32_t	sa = uint32_t(std::lround(a * 255));
	if (!sa)
		return;
	uint32_t	src = sb | (sg << 8) | (sr << 16) | (sa << 24);
	uint32_t	nInv = 255 - sa;
	auto	it = std::lower_bound(spans.begin(), spans.end(), y0,
		[](const Span& s, int y) { return s.y < y; });
	for (; it != spans.end() && it->y < y1; ++it) {
		int	x0 = it->x0, x1 = std::min(it->x1, xMax);
		if (x1 <= x0)
			continue;
		uint32_t	*p = reinterpret_cast<uint32_t*>(pPixels + size_t(it->y) * nStride);
		if (!nInv) {
			std::fill(p + x0, p + x1, src);
			continue;
		}
		for (int x = x0; x < x1; x++) {
			uint32_t	d = p[x];
			p[x] = (sb + MulDiv255(d & 255, nInv))
				| ((sg + MulDiv255((d >> 8) & 255, nInv)) << 8)
				| ((sr + MulDiv255((d >> 16) & 255, nInv)) << 16)
				| ((sa + MulDiv255(d >> 24, nInv)) << 24);
		}
	}
}

} // namespace aliased

} // namespace whorld
