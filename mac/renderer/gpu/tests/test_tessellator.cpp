// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Unit tests for the portable tessellator (gpu/Tessellator.h): flattening,
// strokes (joins, clipped miters, strips), fans and spans. Output is checked
// by rasterizing it with a brute-force supersampler (RasterTest.h) against
// exact areas and an even-odd point-in-polygon reference.

#include "RasterTest.h"
#include "TestHarness.h"

#include <cstring>

using namespace whorld;
using namespace whorld::gpu;
using namespace raster_test;

namespace {

const float	kTol = 0.1f;	// flattening tolerance, as the renderer uses

Coverage StrokeCoverage(const std::vector<Contour>& ct, float fWidth, int w, int h, bool bStrips = false,
	std::vector<Vec2>* pTris = nullptr, std::vector<Vec2>* pQuads = nullptr)
{
	std::vector<Vec2>	tris, quads;
	StrokeContours(ct.data(), ct.size(), fWidth, kTol, tris, bStrips ? &quads : nullptr);
	Coverage	cv(w, h);
	cv.AddTriangles(tris);
	cv.AddQuads(quads);
	if (pTris)
		*pTris = tris;
	if (pQuads)
		*pQuads = quads;
	return cv;
}

std::vector<Contour> Square(float x0, float y0, float s)
{
	return {MakeContour({{x0, y0}, {x0 + s, y0}, {x0 + s, y0 + s}, {x0, y0 + s}})};
}

// A circle as four cubic arcs (as IRenderer::AddFigure takes them), flattened.
Contour Circle(float cx, float cy, float r)
{
	const float	c = 0.5522847f * r;
	PointF	p[13] = {
		{cx + r, cy}, {cx + r, cy + c}, {cx + c, cy + r}, {cx, cy + r},
		{cx - c, cy + r}, {cx - r, cy + c}, {cx - r, cy},
		{cx - r, cy - c}, {cx - c, cy - r}, {cx, cy - r},
		{cx + c, cy - r}, {cx + r, cy - c}, {cx + r, cy}};
	Contour	ct;
	FlattenFigure(p, 4, true, 1, kTol, ct);
	return ct;
}

// farthest covered sample from p along direction m
double Extent(const Coverage& cv, Vec2 p, Vec2 m)
{
	double	f = -1e9;
	for (int sy = 0; sy < cv.SH(); sy++)
		for (int sx = 0; sx < cv.SW(); sx++)
			if (cv.At(sx, sy)) {
				Vec2	q = cv.SamplePos(sx, sy);
				f = std::max(f, double(q.x - p.x) * m.x + double(q.y - p.y) * m.y);
			}
	return f;
}

} // namespace

// ---- flattening

TEST(FlattenPolygonScalesAndDropsClosingPoint)
{
	PointF	p[5] = {{1, 1}, {5, 1}, {5, 4}, {1, 4}, {1, 1}};
	Contour	ct;
	FlattenFigure(p, 4, false, 2, kTol, ct);
	CHECK_EQ(ct.pts.size(), size_t(4));
	CHECK_NEAR(ct.pts[1].x, 10, 0);
	CHECK_NEAR(ct.pts[2].y, 8, 0);
	for (uint8_t c : ct.corner)
		CHECK_EQ(int(c), 1);
}

TEST(FlattenMergesDuplicatePoints)
{
	PointF	p[7] = {{1, 1}, {5, 1}, {5, 1}, {5, 4}, {1, 4}, {1, 4}, {1, 1}};
	Contour	ct;
	FlattenFigure(p, 6, false, 1, kTol, ct);
	CHECK_EQ(ct.pts.size(), size_t(4));
}

TEST(FlattenCurveStaysWithinTolerance)
{
	// a wide S-shaped cubic and back: every point of the curve within the
	// tolerance of the polyline
	PointF	p[7] = {{10, 50}, {40, -30}, {60, 130}, {90, 50}, {60, 90}, {40, 10}, {10, 50}};
	Contour	ct;
	FlattenFigure(p, 2, true, 1, kTol, ct);
	CHECK(ct.pts.size() > 8);
	double	fWorst = 0;
	for (int s = 0; s < 2; s++) {
		const PointF	*q = &p[s * 3];
		for (int i = 0; i <= 2000; i++) {
			double	t = i / 2000.0, u = 1 - t;
			double	x = u * u * u * q[0].x + 3 * u * u * t * q[1].x + 3 * u * t * t * q[2].x + t * t * t * q[3].x;
			double	y = u * u * u * q[0].y + 3 * u * u * t * q[1].y + 3 * u * t * t * q[2].y + t * t * t * q[3].y;
			double	d = 1e9;
			size_t	n = ct.pts.size();
			for (size_t j = 0; j < n; j++) {	// distance to segment j
				Vec2	a = ct.pts[j], b = ct.pts[(j + 1) % n];
				double	dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy;
				double	tt = l2 > 0 ? std::clamp(((x - a.x) * dx + (y - a.y) * dy) / l2, 0.0, 1.0) : 0;
				d = std::min(d, std::hypot(x - (a.x + tt * dx), y - (a.y + tt * dy)));
			}
			fWorst = std::max(fWorst, d);
		}
	}
	CHECK(fWorst <= kTol * 1.01);
}

TEST(FlattenMarksOnlySegmentEndsAsCorners)
{
	Contour	ct = Circle(50, 50, 30);
	int	n = 0;
	for (uint8_t c : ct.corner)
		n += c;
	CHECK_EQ(n, 4);
}

// ---- strokes

TEST(StrokeSquareAreaWithMiters)
{
	// 90 degree miters are within the limit: the outline is a square ring
	Coverage	cv = StrokeCoverage(Square(20, 20, 40), 4, 100, 100);
	CHECK_NEAR(cv.Area(), 44.0 * 44 - 36.0 * 36, 640 * 0.01);
	CHECK_NEAR(cv.PixelCoverage(18, 18), 1, 0);	// outer corner filled by the miter
	CHECK_NEAR(cv.PixelCoverage(40, 40), 0, 0);	// inside empty
}

TEST(StrokeNegativeWidthIsAbsoluteZeroIsNothing)
{
	Coverage	a = StrokeCoverage(Square(20, 20, 40), 4, 100, 100);
	Coverage	b = StrokeCoverage(Square(20, 20, 40), -4, 100, 100);
	CHECK_EQ(a.CountDiff(b), size_t(0));
	std::vector<Vec2>	tris;
	std::vector<Contour>	sq = Square(20, 20, 40);
	StrokeContours(sq.data(), sq.size(), 0, kTol, tris);
	CHECK(tris.empty());
}

TEST(StrokeCollinearPointsChangeNothing)
{
	std::vector<Contour>	a = Square(20, 20, 40);
	std::vector<Contour>	b = {MakeContour({{20, 20}, {33, 20}, {60, 20}, {60, 47}, {60, 60}, {20, 60}, {20, 31}})};
	CHECK_EQ(StrokeCoverage(a, 5, 100, 100).CountDiff(StrokeCoverage(b, 5, 100, 100)), size_t(0));
}

TEST(StrokeZeroLengthSegmentsChangeNothing)
{
	// duplicates are merged by flattening, so the stroke is the same
	PointF	p[7] = {{20, 20}, {60, 20}, {60, 20}, {60, 60}, {20, 60}, {20, 60}, {20, 20}};
	Contour	ct;
	FlattenFigure(p, 6, false, 1, kTol, ct);
	CHECK_EQ(StrokeCoverage({ct}, 4, 100, 100).CountDiff(StrokeCoverage(Square(20, 20, 40), 4, 100, 100)),
		size_t(0));
}

TEST(StrokeMiterWithinLimitIsFull)
{
	// equilateral triangle: 60 degree corners, miter hw / sin(30) = 2 hw
	const float	hw = 3;
	std::vector<Contour>	ct = {MakeContour({{50, 20}, {50 + 34.641f, 80}, {50 - 34.641f, 80}})};
	Coverage	cv = StrokeCoverage(ct, 2 * hw, 100, 100);
	// the tip is a sharp point: the last covered samples fall short of it by
	// up to half a pixel at 4 x 4 samples; a bevel would reach hw / 2
	double	f = Extent(cv, Vec2{50, 20}, Vec2{0, -1});
	CHECK(f > 2 * hw - 0.5 && f <= 2 * hw + 0.01);
}

TEST(StrokeMiterPastLimitIsClippedNotBeveled)
{
	// a 6 degree corner: the full miter, hw / sin(3), is 19 hw; Direct2D
	// clips it at 10 hw from the vertex (a bevel would reach about hw)
	const float	hw = 2;
	const double	half = 3 * M_PI / 180;
	const float	L = 100;
	Vec2	apex{20, 50};
	std::vector<Contour>	ct = {MakeContour({apex, {float(apex.x + L * std::cos(half)), float(apex.y - L * std::sin(half))},
		{float(apex.x + L * std::cos(half)), float(apex.y + L * std::sin(half))}})};
	Coverage	cv = StrokeCoverage(ct, 2 * hw, 140, 100);
	CHECK_NEAR(Extent(cv, apex, Vec2{-1, 0}), 10 * hw, 0.3);
}

TEST(StrokeStripsMatchTriangles)
{
	for (float w : {0.7f, 3.f, 12.f}) {
		std::vector<Contour>	ct = {Circle(60, 60, 40)};
		std::vector<Vec2>	tris, quads;
		Coverage	a = StrokeCoverage(ct, w, 120, 120);
		Coverage	b = StrokeCoverage(ct, w, 120, 120, true, &tris, &quads);
		CHECK_EQ(quads.size(), ct[0].pts.size() * 4);	// one quad per segment
		// differences only where a miter replaces a round join: within the
		// tolerance along the outline
		CHECK(double(a.CountDiff(b)) / (a.k * a.k) <= 2 * M_PI * 40 * kTol);
		// quads are convex and consistently oriented, and neighbours share
		// their edge exactly
		size_t	nq = quads.size() / 4;
		int	nSign = 0;
		for (size_t i = 0; i < nq; i++) {
			const Vec2	*q = &quads[i * 4];
			for (int k = 0; k < 4; k++) {	// every turn the same way, in every quad
				Vec2	a0 = q[k], a1 = q[(k + 1) % 4], a2 = q[(k + 2) % 4];
				double	cr = (double(a1.x) - a0.x) * (double(a2.y) - a1.y) - (double(a1.y) - a0.y) * (double(a2.x) - a1.x);
				int	sg = cr > 0 ? 1 : cr < 0 ? -1 : 0;
				if (!nSign)
					nSign = sg;
				CHECK(sg != 0 && sg == nSign);
			}
			const Vec2	*n = &quads[((i + 1) % nq) * 4];
			bool	bShared = !std::memcmp(&q[1], &n[0], sizeof(Vec2)) && !std::memcmp(&q[2], &n[3], sizeof(Vec2));
			bool	bSquare = std::fabs((q[1].x - q[2].x) * (n[0].x - n[3].x) + (q[1].y - q[2].y) * (n[0].y - n[3].y)) > 0;
			CHECK(bShared || bSquare);	// shared edge, or square ends with a join
		}
	}
}

TEST(StrokeStripsFallBackOnTightCurves)
{
	// radius smaller than the stroke: the inner side would fold over
	std::vector<Contour>	ct = {Circle(30, 30, 3)};
	std::vector<Vec2>	tris, quads;
	Coverage	a = StrokeCoverage(ct, 10, 60, 60);
	Coverage	b = StrokeCoverage(ct, 10, 60, 60, true, &tris, &quads);
	CHECK(!tris.empty());
	CHECK(double(a.CountDiff(b)) / (a.k * a.k) <= 2 * M_PI * 8 * kTol);
	CHECK_NEAR(b.Area(), M_PI * 8 * 8, M_PI * 64 * 0.02);	// a disk of radius 3 + 5
}

// ---- fills

TEST(FanParityIsEvenOdd)
{
	std::vector<Contour>	ct = {MakeContour(Star(50, 50, 40, 7, 3)), MakeContour(Star(50, 50, 12, 5, 1, 0.3f))};
	std::vector<Vec2>	tris;
	FanContours(ct.data(), ct.size(), tris);
	Coverage	ref(100, 100);
	int	nBad = 0;
	for (int sy = 0; sy < ref.SH(); sy += 3) {
		for (int sx = 0; sx < ref.SW(); sx += 3) {
			Vec2	q = ref.SamplePos(sx, sy);
			int	n = 0;
			for (size_t i = 0; i + 2 < tris.size(); i += 3) {
				const Vec2	*t = &tris[i];
				double	e0 = (double(t[1].x) - t[0].x) * (q.y - t[0].y) - (double(t[1].y) - t[0].y) * (q.x - t[0].x);
				double	e1 = (double(t[2].x) - t[1].x) * (q.y - t[1].y) - (double(t[2].y) - t[1].y) * (q.x - t[1].x);
				double	e2 = (double(t[0].x) - t[2].x) * (q.y - t[2].y) - (double(t[0].y) - t[2].y) * (q.x - t[2].x);
				n += (e0 > 0 && e1 > 0 && e2 > 0) || (e0 < 0 && e1 < 0 && e2 < 0);
			}
			nBad += bool(n & 1) != InsideEvenOdd(ct.data(), ct.size(), q);
		}
	}
	CHECK_EQ(nBad, 0);
}

TEST(SpansAreThePixelCentersInside)
{
	// a self-crossing star with a hole, partly off the target on all sides
	std::vector<Contour>	ct = {MakeContour(Star(40, 35, 60, 9, 4)), MakeContour(Star(40, 35, 15, 6, 1, 0.2f)),
		MakeContour({{60, 50}, {75, 52}, {66, 70}})};
	const int	w = 80, h = 64;
	std::vector<Vec2>	spans;
	SpanContours(ct.data(), ct.size(), w, h, spans);
	std::vector<int>	hits(size_t(w) * h, 0);
	for (size_t i = 0; i + 1 < spans.size(); i += 2) {
		CHECK_EQ(spans[i].y, spans[i + 1].y);
		int	y = int(spans[i].y);
		CHECK(y >= 0 && y < h);
		for (int x = int(spans[i].x); x < int(spans[i + 1].x); x++) {
			CHECK(x >= 0 && x < w);
			hits[size_t(y) * w + x]++;
		}
	}
	int	nBad = 0, nOverlap = 0, nIn = 0;
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			bool	bRef = InsideEvenOdd(ct.data(), ct.size(), Vec2{x + 0.5f, y + 0.5f});
			int	n = hits[size_t(y) * w + x];
			nOverlap += n > 1;
			nBad += (n > 0) != bRef;
			nIn += bRef;
		}
	}
	CHECK_EQ(nOverlap, 0);
	CHECK_EQ(nBad, 0);
	CHECK(nIn > 500);
}

TEST(SpansOfAShapeOffTargetAreEmpty)
{
	std::vector<Contour>	ct = {MakeContour(Star(-50, 30, 20, 5, 2))};
	std::vector<Vec2>	spans;
	SpanContours(ct.data(), ct.size(), 40, 40, spans);
	CHECK(spans.empty());
}

int main()
{
	return RunAllTests();
}
