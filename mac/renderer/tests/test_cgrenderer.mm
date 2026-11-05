// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Unit tests for the Core Graphics renderer.

#include "CGRenderer.h"
#include "TestHarness.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>

using namespace whorld;

namespace {

struct Px {
	int	r, g, b, a;
};

Px GetPx(const CGBitmapRenderer& rr, int x, int y)
{
	const uint8_t*	p = rr.GetPixels() + y * rr.GetStride() + x * 4;	// BGRA
	return Px{p[2], p[1], p[0], p[3]};
}

const ColorF kRed = {1, 0, 0, 1};
const ColorF kBlack = {0, 0, 0, 1};
const ColorF kWhite = {1, 1, 1, 1};

void FillSquare(CGBitmapRenderer& rr, float x0, float y0, float x1, float y1, const ColorF& clr)
{
	PointF	pts[5] = {{x0, y0}, {x1, y0}, {x1, y1}, {x0, y1}, {x0, y0}};
	rr.BeginPath();
	rr.AddFigure(pts, 4, false, true);
	rr.EndPath();
	rr.FillPath(clr);
}

} // namespace

TEST(TopLeftOriginYDown) {
	CGBitmapRenderer	rr(20, 10);
	rr.BeginFrame();
	rr.SetAntialiasing(false);
	rr.Clear(kBlack);
	rr.FillRect(RectF{0, 0, 2, 1}, kRed);	// top-left corner, one row
	rr.EndFrame();
	CHECK_EQ(GetPx(rr, 0, 0).r, 255);	// memory row 0 is the top
	CHECK_EQ(GetPx(rr, 1, 0).r, 255);
	CHECK_EQ(GetPx(rr, 2, 0).r, 0);
	CHECK_EQ(GetPx(rr, 0, 1).r, 0);
	CHECK_EQ(GetPx(rr, 0, 9).a, 255);
}

TEST(BackingScale) {
	CGBitmapRenderer	rr(40, 20, 2);	// 20 x 10 DIPs
	CHECK_EQ(rr.GetSizeDIPs().width, 20.0f);
	rr.BeginFrame();
	rr.SetAntialiasing(false);
	rr.Clear(kBlack);
	rr.FillRect(RectF{10, 5, 11, 6}, kRed);	// one DIP = 2 x 2 pixels
	rr.EndFrame();
	CHECK_EQ(GetPx(rr, 20, 10).r, 255);
	CHECK_EQ(GetPx(rr, 21, 11).r, 255);
	CHECK_EQ(GetPx(rr, 22, 10).r, 0);
	CHECK_EQ(GetPx(rr, 19, 10).r, 0);
}

TEST(ClearReplacesAlpha) {
	CGBitmapRenderer	rr(4, 4);
	rr.BeginFrame();
	rr.Clear(kRed);
	rr.Clear(ColorF{0, 0, 0, 0});	// transparent clear replaces, doesn't blend
	rr.EndFrame();
	Px	p = GetPx(rr, 2, 2);
	CHECK_EQ(p.a, 0);
	CHECK_EQ(p.r, 0);
}

TEST(EvenOddFillMakesAnnulus) {
	CGBitmapRenderer	rr(20, 20);
	rr.BeginFrame();
	rr.SetAntialiasing(false);
	rr.Clear(kBlack);
	PointF	outer[5] = {{2, 2}, {18, 2}, {18, 18}, {2, 18}, {2, 2}};
	PointF	inner[5] = {{6, 6}, {14, 6}, {14, 14}, {6, 14}, {6, 6}};	// same winding
	rr.BeginPath();
	rr.AddFigure(outer, 4, false, true);
	rr.AddFigure(inner, 4, false, true);
	rr.EndPath();
	rr.FillPath(kRed);
	rr.EndFrame();
	CHECK_EQ(GetPx(rr, 3, 10).r, 255);		// in the band
	CHECK_EQ(GetPx(rr, 10, 10).r, 0);		// hole, despite matching winding
}

TEST(HollowFiguresAreNotFilled) {
	CGBitmapRenderer	rr(20, 20);
	rr.BeginFrame();
	rr.SetAntialiasing(false);
	rr.Clear(kBlack);
	PointF	sq[5] = {{2, 2}, {18, 2}, {18, 18}, {2, 18}, {2, 2}};
	rr.BeginPath();
	rr.AddFigure(sq, 4, false, false);	// D2D1_FIGURE_BEGIN_HOLLOW
	rr.EndPath();
	rr.FillPath(kRed);
	CHECK_EQ(GetPx(rr, 10, 10).r, 0);
	rr.StrokePath(kRed, 2);	// still stroked
	rr.EndFrame();
	CHECK_EQ(GetPx(rr, 2, 10).r, 255);
	CHECK_EQ(GetPx(rr, 10, 10).r, 0);
}

TEST(NegativeWidthStrokesAbsoluteValue) {
	CGBitmapRenderer	a(20, 20), b(20, 20);
	PointF	sq[5] = {{4, 4}, {16, 4}, {16, 16}, {4, 16}, {4, 4}};
	for (auto* rr : {&a, &b}) {
		rr->BeginFrame();
		rr->Clear(kBlack);
		rr->BeginPath();
		rr->AddFigure(sq, 4, false, false);
		rr->EndPath();
		rr->StrokePath(kWhite, rr == &a ? 3.0f : -3.0f);
		rr->EndFrame();
	}
	CHECK(std::memcmp(a.GetPixels(), b.GetPixels(), a.GetStride() * 20) == 0);
	CHECK_EQ(GetPx(a, 4, 10).r, 255);
}

TEST(ZeroWidthStrokeDrawsNothing) {
	CGBitmapRenderer	rr(20, 20);
	PointF	sq[5] = {{4, 4}, {16, 4}, {16, 16}, {4, 16}, {4, 4}};
	rr.BeginFrame();
	rr.Clear(kBlack);
	rr.BeginPath();
	rr.AddFigure(sq, 4, false, false);
	rr.EndPath();
	rr.StrokePath(kWhite, 0);
	rr.EndFrame();
	for (int y = 0; y < 20; y++)
		for (int x = 0; x < 20; x++)
			CHECK_EQ(GetPx(rr, x, y).r, 0);
}

TEST(SharpJoinGetsClippedMiter) {
	// A spike turning back on itself: Direct2D draws a miter clipped at
	// 10 x half the width beyond the vertex; Core Graphics alone would bevel.
	CGBitmapRenderer	rr(100, 40);
	rr.BeginFrame();
	rr.SetAntialiasing(false);
	rr.Clear(kBlack);
	PointF	pts[3] = {{10, 20}, {50, 20}, {10, 20.5f}};	// nearly 180 degrees at (50, 20)
	rr.BeginPath();
	rr.AddFigure(pts, 2, false, false);
	rr.EndPath();
	rr.StrokePath(kWhite, 2);	// half width 1: miter clipped at 10 px past the vertex
	rr.EndFrame();
	CHECK_EQ(GetPx(rr, 55, 20).r, 255);	// inside the clipped miter
	CHECK_EQ(GetPx(rr, 59, 20).r, 255);
	CHECK_EQ(GetPx(rr, 62, 20).r, 0);	// beyond the clip
}

TEST(QuadMirrorEvenSize) {
	CGBitmapRenderer	rr(8, 6);
	rr.BeginFrame();
	rr.SetAntialiasing(false);
	CHECK(rr.BeginQuadMirror());
	rr.Clear(kBlack);
	rr.FillRect(RectF{0, 0, 8, 6}, kRed);	// clipped to the 4 x 3 quadrant
	rr.FillRect(RectF{0, 0, 1, 1}, kWhite);	// mark the corner pixel
	CHECK(rr.EndQuadMirror());
	rr.EndFrame();
	CHECK_EQ(GetPx(rr, 0, 0).g, 255);
	CHECK_EQ(GetPx(rr, 7, 0).g, 255);	// upper right
	CHECK_EQ(GetPx(rr, 0, 5).g, 255);	// lower left
	CHECK_EQ(GetPx(rr, 7, 5).g, 255);	// lower right
	CHECK_EQ(GetPx(rr, 3, 2).r, 255);
	CHECK_EQ(GetPx(rr, 4, 3).r, 255);	// mirrored red
	CHECK_EQ(GetPx(rr, 4, 3).g, 0);
}

TEST(QuadMirrorOddSizeSharesCenter) {
	CGBitmapRenderer	rr(5, 3);	// quadrant 3 x 2; center column and row overlap
	rr.BeginFrame();
	rr.SetAntialiasing(false);
	CHECK(rr.BeginQuadMirror());
	rr.Clear(kBlack);
	rr.FillRect(RectF{2, 0, 3, 1}, kWhite);	// center column, top row
	rr.FillRect(RectF{4, 0, 5, 3}, kRed);	// outside the quadrant: clipped away
	rr.EndQuadMirror();
	rr.EndFrame();
	CHECK_EQ(GetPx(rr, 2, 0).g, 255);
	CHECK_EQ(GetPx(rr, 2, 2).g, 255);	// mirrored vertically onto the bottom row
	CHECK_EQ(GetPx(rr, 4, 0).r, 0);		// overwritten by the mirror (black)
	CHECK_EQ(GetPx(rr, 1, 0).g, 0);
}

TEST(MirrorFailsOnEmptyAndEndIsSafe) {
	CGBitmapRenderer	rr(0, 0);
	CHECK(!rr.IsValid());
	CHECK(!rr.BeginQuadMirror());
	CHECK(!rr.EndQuadMirror());
	CGBitmapRenderer	ok(4, 4);
	ok.BeginFrame();
	CHECK(!ok.EndQuadMirror());	// no clip pushed
	ok.EndFrame();
}

TEST(AntialiasingToggle) {
	CGBitmapRenderer	rr(20, 20);
	rr.BeginFrame();
	rr.Clear(kBlack);
	rr.SetAntialiasing(false);
	FillSquare(rr, 2.5f, 2.5f, 10.5f, 10.5f, kWhite);
	rr.SetAntialiasing(true);
	FillSquare(rr, 12.5f, 2.5f, 18.5f, 10.5f, kWhite);
	rr.EndFrame();
	int	r = GetPx(rr, 2, 5).r;	// aliased edge pixel: all or nothing
	CHECK(r == 0 || r == 255);
	int	ra = GetPx(rr, 12, 5).r;	// antialiased edge pixel: half covered
	CHECK(ra > 100 && ra < 160);
}

namespace {
// Draws a scene that exercises every operation, optionally mirrored.
void DrawScene(CGBitmapRenderer& rr, bool bMirror)
{
	rr.BeginFrame();
	rr.SetAntialiasing(true);
	if (bMirror)
		rr.BeginQuadMirror();
	rr.Clear(ColorF{0.1f, 0.1f, 0.2f, 1});
	PointF	outer[5] = {{5, 5}, {60, 8}, {55, 50}, {8, 45}, {5, 5}};
	PointF	inner[5] = {{20, 20}, {40, 20}, {40, 35}, {20, 35}, {20, 20}};
	rr.BeginPath();
	rr.AddFigure(outer, 4, false, true);
	rr.AddFigure(inner, 4, false, true);
	rr.EndPath();
	rr.FillPath(ColorF{1, 0.5f, 0, 1});
	rr.StrokePath(ColorF{0, 0, 0, 1}, 3);
	PointF	curve[7] = {{70, 10}, {90, 0}, {100, 40}, {80, 50}, {60, 60}, {50, 20}, {70, 10}};
	rr.BeginPath();
	rr.AddFigure(curve, 2, true, false);
	rr.EndPath();
	rr.StrokePath(ColorF{0, 1, 1, 0.5f}, 4);
	rr.StrokePath(ColorF{1, 1, 1, 1}, 0.5f);	// thin: stroked directly
	if (bMirror)
		rr.EndQuadMirror();
	rr.FillRect(RectF{0, 0, 4, 61}, ColorF{0, 0, 0, 1});	// after mirroring, like the letterbox
	rr.EndFrame();
}
} // namespace

TEST(DeferredMatchesImmediate) {
	for (bool bMirror : {false, true}) {
		CGBitmapRenderer	a(121, 61), b(121, 61);	// odd sizes: shared center row and column
		b.SetDeferred(true);
		DrawScene(a, bMirror);
		DrawScene(b, bMirror);
		int	nMax = 0;
		for (int y = 0; y < 61; y++) {
			for (int x = 0; x < 121; x++) {
				Px	pa = GetPx(a, x, y), pb = GetPx(b, x, y);
				nMax = std::max({nMax, std::abs(pa.r - pb.r), std::abs(pa.g - pb.g), std::abs(pa.b - pb.b)});
			}
		}
		// prebuilt stroke outlines rasterize within a few levels of direct strokes
		if (nMax > 24)
			std::fprintf(stderr, "  mirror %d: max difference %d\n", bMirror, nMax);
		CHECK(nMax <= 24);
		if (bMirror) {	// (x, y) lands at (width - 1 - x, height - 1 - y)
			CHECK_EQ(GetPx(b, 110, 50).r, GetPx(b, 10, 10).r);
			CHECK_EQ(GetPx(b, 110, 50).g, GetPx(b, 10, 10).g);
			CHECK_EQ(GetPx(b, 90, 15).b, GetPx(b, 30, 15).b);
		}
	}
}

int main() { return RunAllTests(); }
