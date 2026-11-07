// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// The tessellator's strokes against the golden-tested Core Graphics
// renderer, which strokes with Core Graphics and adds Direct2D's clipped
// miters (CGRenderer.mm AddClippedMiters). Each shape is stroked opaque
// white on black by both; the tessellator's output is rasterized with 4 x 4
// samples per pixel (RasterTest.h) and compared as coverage per pixel.

#include "CGRenderer.h"
#include "RasterTest.h"
#include "TestHarness.h"

#include <cstdio>
#include <string>

using namespace whorld;
using namespace whorld::gpu;
using namespace raster_test;

namespace {

const int	kW = 200, kH = 200;
const float	kTol = 0.1f;

struct Shape {
	const char	*name;
	std::vector<PointF>	pts;	// as IRenderer::AddFigure takes them, closed
	bool	bCurved;
	float	fWidth;
	// Loops tighter than half the stroke width: the tessellator strokes the
	// flattened path's swept perpendiculars plus round joins, Core Graphics
	// fills an offset outline that folds over there; which one Direct2D
	// matches is open (no Windows reference yet), so these only bound the
	// current difference, to catch regressions.
	double	fMaxFracOver = 0.01;
};

struct Result {
	double	fMeanDiff;	// mean |coverage difference| over pixels either covers
	double	fFracOver;	// fraction of those pixels differing by more than 0.25
	int		nPixels;
};

std::vector<PointF> Polygon(std::vector<Vec2> v)
{
	std::vector<PointF>	p;
	for (Vec2 q : v)
		p.push_back(PointF{q.x, q.y});
	p.push_back(p[0]);
	return p;
}

Result Compare(const Shape& sh)
{
	int	nSeg = sh.bCurved ? int(sh.pts.size() - 1) / 3 : int(sh.pts.size() - 1);
	// Core Graphics
	CGBitmapRenderer	cg(kW, kH, 1);
	cg.BeginFrame();
	cg.SetAntialiasing(true);
	cg.Clear(ColorF{0, 0, 0, 1});
	cg.BeginPath();
	cg.AddFigure(sh.pts.data(), nSeg, sh.bCurved, false);
	cg.EndPath();
	cg.StrokePath(ColorF{1, 1, 1, 1}, sh.fWidth);
	cg.EndFrame();
	// tessellator
	Contour	ct;
	FlattenFigure(sh.pts.data(), nSeg, sh.bCurved, 1, kTol, ct);
	std::vector<Vec2>	tris;
	StrokeContours(&ct, 1, sh.fWidth, kTol, tris);
	Coverage	cv(kW, kH);
	cv.AddTriangles(tris);
	Result	r{0, 0, 0};
	int	nOver = 0;
	for (int y = 0; y < kH; y++) {
		for (int x = 0; x < kW; x++) {
			float	a = cg.GetPixels()[y * cg.GetStride() + x * 4 + 2] / 255.f;	// red
			float	b = cv.PixelCoverage(x, y);
			if (a == 0 && b == 0)
				continue;
			r.nPixels++;
			r.fMeanDiff += std::fabs(a - b);
			nOver += std::fabs(a - b) > 0.25f;
		}
	}
	if (r.nPixels) {
		r.fMeanDiff /= r.nPixels;
		r.fFracOver = double(nOver) / r.nPixels;
	}
	std::printf("  %-28s %6d px  mean |diff| %.4f  over 0.25: %.3f%%\n", sh.name, r.nPixels, r.fMeanDiff,
		100 * r.fFracOver);
	return r;
}

std::vector<Shape> Shapes()
{
	std::vector<Shape>	v;
	v.push_back({"square", Polygon({{40, 40}, {160, 40}, {160, 160}, {40, 160}}), false, 6});
	v.push_back({"equilateral triangle", Polygon({{100, 30}, {160.6f, 135}, {39.4f, 135}}), false, 6});
	v.push_back({"star 5/2 (36 deg)", Polygon(Star(100, 100, 70, 5, 2)), false, 4});
	v.push_back({"star 11/5 (16 deg)", Polygon(Star(100, 100, 70, 11, 5)), false, 3});
	v.push_back({"thin wedge (6 deg, clipped)", Polygon({{30, 100}, {170, 92.6f}, {170, 107.4f}}), false, 4});
	v.push_back({"thin stroke square", Polygon({{40, 40}, {160, 40}, {160, 160}, {40, 160}}), false, 1});
	const float	c = 0.5522847f * 60;
	v.push_back({"circle", {{160, 100}, {160, 100 + c}, {100 + c, 160}, {100, 160}, {100 - c, 160}, {40, 100 + c},
		{40, 100}, {40, 100 - c}, {100 - c, 40}, {100, 40}, {100 + c, 40}, {160, 100 - c}, {160, 100}}, true, 8});
	// two cubics meeting at sharp corners, as Whorld's curved rings can
	v.push_back({"curved petals", {{100, 30}, {180, 60}, {140, 140}, {100, 170}, {60, 140}, {20, 60}, {100, 30}},
		true, 6});
	// a cubic whose end tangent and last chord differ a lot (near-cusp end)
	v.push_back({"near-cusp end", {{40, 100}, {120, 20}, {161, 101}, {160, 100}, {150, 160}, {60, 160}, {40, 100}},
		true, 10});
	// a curl 4 px across under a 30 px stroke: miters at its segment ends
	// follow the curve's end tangents, far from the flattened chords (new
	// Whorld rings start this small, often with thick outlines); from the
	// spike's stroke scene, shape 125, moved
	std::vector<PointF>	curl = {{266.87f, 403.17f}, {263.68f, 401.76f}, {267.11f, 402.56f}, {266.07f, 404.56f},
		{266.38f, 404.40f}, {265.10f, 405.11f}, {264.46f, 404.56f}, {267.38f, 402.67f}, {266.88f, 403.95f},
		{263.66f, 403.17f}, {264.84f, 403.05f}, {267.31f, 404.38f}, {264.46f, 401.78f}, {265.52f, 400.79f},
		{265.90f, 402.90f}, {266.07f, 401.78f}, {265.16f, 402.96f}, {263.58f, 401.29f}, {266.87f, 403.17f}};
	for (PointF& q : curl) {
		q.x -= 165;
		q.y -= 303;
	}
	v.push_back({"tiny curl, thick stroke", curl, true, 30});
	// a looping figure of four cubics (stroke scene shape 5, moved)
	std::vector<PointF>	loops = {{286.30f, 702.97f}, {259.88f, 656.38f}, {227.70f, 669.58f}, {254.82f, 734.45f},
		{280.34f, 676.67f}, {208.82f, 686.99f}, {223.34f, 702.97f}, {263.39f, 691.61f}, {271.78f, 724.30f},
		{254.82f, 671.49f}, {218.78f, 664.94f}, {265.10f, 667.73f}, {286.30f, 702.97f}};
	for (PointF& q : loops) {
		q.x -= 150;
		q.y -= 600;
	}
	v.push_back({"loops, width 4", loops, true, 4, 0.006});
	v.push_back({"loops, width 12 (open)", loops, true, 12, 0.02});
	v.push_back({"loops, width 30 (open)", loops, true, 30, 0.035});
	return v;
}

} // namespace

TEST(TessellatorStrokesMatchCoreGraphics)
{
	std::printf("Tessellator strokes vs Core Graphics + clipped miters (%dx%d):\n", kW, kH);
	for (const Shape& sh : Shapes()) {
		Result	r = Compare(sh);
		CHECK(r.nPixels > 100);
		CHECK(r.fMeanDiff < 0.05);
		CHECK(r.fFracOver < sh.fMaxFracOver);
	}
}

int main()
{
	return RunAllTests();
}
