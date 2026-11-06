// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#include "Tessellator.h"

#include <algorithm>
#include <cmath>

namespace whorld {
namespace gpu {

namespace {

// Direct2D's default miter limit, in multiples of half the stroke width
// (see CGRenderer.mm for how it relates to Core Graphics' limit).
const float kMiterLimit = 10;
const int kMaxCurveSteps = 512;

inline Vec2 operator+(Vec2 a, Vec2 b) { return Vec2{a.x + b.x, a.y + b.y}; }
inline Vec2 operator-(Vec2 a, Vec2 b) { return Vec2{a.x - b.x, a.y - b.y}; }
inline Vec2 operator*(Vec2 a, float s) { return Vec2{a.x * s, a.y * s}; }
inline float Dot(Vec2 a, Vec2 b) { return a.x * b.x + a.y * b.y; }
inline float Cross(Vec2 a, Vec2 b) { return a.x * b.y - a.y * b.x; }
inline float Len(Vec2 a) { return std::sqrt(Dot(a, a)); }
inline Vec2 Perp(Vec2 a) { return Vec2{-a.y, a.x}; }

inline bool Normalize(Vec2& v)
{
	float	l = Len(v);
	if (!(l > 1e-6f))
		return false;
	v = v * (1 / l);
	return true;
}

inline void Tri(std::vector<Vec2>& t, Vec2 a, Vec2 b, Vec2 c)
{
	t.push_back(a);
	t.push_back(b);
	t.push_back(c);
}

void AddPoint(Contour& out, Vec2 p, bool bCorner)
{
	if (!out.pts.empty()) {
		Vec2	q = out.pts.back();
		if (std::fabs(p.x - q.x) < 1e-4f && std::fabs(p.y - q.y) < 1e-4f) {
			if (bCorner)
				out.corner.back() = 1;
			return;
		}
	}
	out.pts.push_back(p);
	out.corner.push_back(bCorner ? 1 : 0);
}

// Join at vertex p between incoming direction a and outgoing direction b
// (unit vectors).
void Join(std::vector<Vec2>& tris, Vec2 p, Vec2 a, Vec2 b, float hw, bool bCorner, float fTolerance)
{
	float	cr = Cross(a, b), dt = Dot(a, b);
	if (std::fabs(cr) < 1e-6f && dt > 0)
		return;	// straight through
	// outer-side normals, as in CGRenderer.mm AddClippedMiters
	float	s = cr > 0 ? -1.0f : 1.0f;
	Vec2	na = Perp(a) * s, nb = Perp(b) * s;
	Vec2	o1 = p + na * hw, o2 = p + nb * hw;
	if (bCorner) {	// Direct2D miter, clipped at the limit
		Tri(tris, p, o1, o2);	// bevel
		Vec2	m = a - b;	// miter direction, out of the corner
		if (!Normalize(m))
			return;
		float	fDot = Dot(m, na);	// cos of half the exterior angle
		float	fLimit = kMiterLimit * hw;
		float	fMiter = fDot > 1e-6f ? hw / fDot : HUGE_VALF;
		if (fMiter <= fLimit) {
			Tri(tris, o1, p + m * fMiter, o2);
		} else {
			float	fA = Dot(a, m), fB = Dot(b, m);
			if (!(fA > 1e-6f) || !(fB < -1e-6f))
				return;
			Vec2	x1 = o1 + a * ((fLimit - Dot(o1 - p, m)) / fA);
			Vec2	x2 = o2 + b * ((fLimit - Dot(o2 - p, m)) / fB);
			Tri(tris, o1, x1, x2);
			Tri(tris, o1, x2, o2);
		}
	} else {	// inside a flattened curve: round join
		float	fAngle = std::atan2(std::fabs(cr), dt);	// turn angle, 0..pi
		// step angle keeping the arc within the tolerance
		float	fStep = hw > fTolerance ? 2 * std::acos(1 - fTolerance / hw) : 3.14159265f;
		int		n = std::max(1, int(std::ceil(fAngle / std::max(fStep, 1e-3f))));
		n = std::min(n, 64);
		float	fDir = Cross(na, nb) > 0 ? 1.0f : -1.0f;
		Vec2	prev = o1;
		for (int i = 1; i <= n; i++) {
			Vec2	cur;
			if (i == n) {
				cur = o2;
			} else {
				float	th = fDir * fAngle * i / n;
				float	c = std::cos(th), sn = std::sin(th);
				cur = p + Vec2{na.x * c - na.y * sn, na.x * sn + na.y * c} * hw;
			}
			Tri(tris, p, prev, cur);
			prev = cur;
		}
	}
}

} // namespace

void FlattenFigure(const PointF* pStart, int nSegments, bool bCurved, float fScale,
	float fTolerance, Contour& out)
{
	out.pts.clear();
	out.corner.clear();
	auto	P = [fScale](const PointF& p) { return Vec2{p.x * fScale, p.y * fScale}; };
	Vec2	cur = P(pStart[0]);
	AddPoint(out, cur, true);
	if (bCurved) {
		for (int i = 0; i < nSegments; i++) {
			Vec2	p1 = P(pStart[1 + i * 3]), p2 = P(pStart[2 + i * 3]), p3 = P(pStart[3 + i * 3]);
			// Wang's formula: n >= sqrt(3/4 * max|second difference| / tol)
			float	d = std::max(Len(cur - p1 * 2 + p2), Len(p1 - p2 * 2 + p3));
			int		n = int(std::ceil(std::sqrt(0.75f * d / fTolerance)));
			n = std::clamp(n, 1, kMaxCurveSteps);
			for (int j = 1; j <= n; j++) {
				if (j == n) {
					AddPoint(out, p3, true);
					break;
				}
				float	t = float(j) / n, u = 1 - t;
				float	b0 = u * u * u, b1 = 3 * u * u * t, b2 = 3 * u * t * t, b3 = t * t * t;
				AddPoint(out, Vec2{b0 * cur.x + b1 * p1.x + b2 * p2.x + b3 * p3.x,
					b0 * cur.y + b1 * p1.y + b2 * p2.y + b3 * p3.y}, false);
			}
			cur = p3;
		}
	} else {
		for (int i = 1; i <= nSegments; i++)
			AddPoint(out, P(pStart[i]), true);
	}
	// the closing edge is implied: drop a last point equal to the first
	if (out.pts.size() > 1) {
		Vec2	a = out.pts.front(), b = out.pts.back();
		if (std::fabs(a.x - b.x) < 1e-4f && std::fabs(a.y - b.y) < 1e-4f) {
			if (out.corner.back())
				out.corner.front() = 1;
			out.pts.pop_back();
			out.corner.pop_back();
		}
	}
}

void StrokeContours(const Contour* pContour, size_t nContours, float fWidth, float fTolerance,
	std::vector<Vec2>& tris)
{
	float	hw = std::fabs(fWidth) / 2;
	if (!(hw > 0))
		return;
	std::vector<Vec2>	dir;
	for (size_t c = 0; c < nContours; c++) {
		const Contour&	ct = pContour[c];
		size_t	n = ct.pts.size();
		if (n < 2)
			continue;
		dir.resize(n);
		for (size_t i = 0; i < n; i++) {	// segment i: point i to point i + 1
			Vec2	d = ct.pts[(i + 1) % n] - ct.pts[i];
			if (!Normalize(d))
				d = Vec2{1, 0};	// can't happen after merging duplicates
			dir[i] = d;
			Vec2	nrm = Perp(d) * hw;
			Vec2	p0 = ct.pts[i], p1 = ct.pts[(i + 1) % n];
			Tri(tris, p0 + nrm, p0 - nrm, p1 + nrm);
			Tri(tris, p1 + nrm, p0 - nrm, p1 - nrm);
		}
		for (size_t i = 0; i < n; i++)	// join at point i
			Join(tris, ct.pts[i], dir[(i + n - 1) % n], dir[i], hw, ct.corner[i] != 0, fTolerance);
	}
}

void FanContours(const Contour* pContour, size_t nContours, std::vector<Vec2>& tris)
{
	// pivot at the center of the bounding box keeps the fan's overdraw small
	float	x0 = HUGE_VALF, y0 = HUGE_VALF, x1 = -HUGE_VALF, y1 = -HUGE_VALF;
	for (size_t c = 0; c < nContours; c++) {
		for (Vec2 p : pContour[c].pts) {
			x0 = std::min(x0, p.x);
			y0 = std::min(y0, p.y);
			x1 = std::max(x1, p.x);
			y1 = std::max(y1, p.y);
		}
	}
	if (!(x1 >= x0))
		return;
	Vec2	pivot{(x0 + x1) / 2, (y0 + y1) / 2};
	for (size_t c = 0; c < nContours; c++) {
		const std::vector<Vec2>&	pts = pContour[c].pts;
		size_t	n = pts.size();
		if (n < 3)
			continue;
		for (size_t i = 0; i < n; i++)
			Tri(tris, pivot, pts[i], pts[(i + 1) % n]);
	}
}

void RectTriangles(float left, float top, float right, float bottom, std::vector<Vec2>& tris)
{
	Tri(tris, Vec2{left, top}, Vec2{right, top}, Vec2{left, bottom});
	Tri(tris, Vec2{right, top}, Vec2{right, bottom}, Vec2{left, bottom});
}

} // namespace gpu
} // namespace whorld
