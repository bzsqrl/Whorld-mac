// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Turns the engine's path figures into triangles for a GPU renderer. Plain
// C++ with no platform headers, so it builds and tests anywhere.
//
// Strokes follow Direct2D's default stroke style (see IRenderer.h): miter
// joins with limit 10, clipped (not beveled) past the limit, figures closed.
// Points that come from flattening a curve get round joins instead, which is
// what the stroke of a smooth curve sweeps out.
//
// Output triangles overlap (segment quads overlap at joins), so a renderer
// must draw each stroke so that a sample is covered at most once, for
// example with a stencil test. Fill fans are meant for an even-odd stencil
// (invert, then cover).

#include "whorld/Types.h"

#include <cstdint>
#include <vector>

namespace whorld {
namespace gpu {

struct Vec2 {
	float	x;
	float	y;
};

// A closed figure flattened to a polygon in device pixels. The closing edge
// from the last point back to the first is implied. corner[i] is nonzero
// where point i is a vertex of the original figure (a segment end).
struct Contour {
	std::vector<Vec2>	pts;
	std::vector<uint8_t>	corner;
};

// Flattens one figure (as passed to IRenderer::AddFigure), scaling DIPs to
// pixels by fScale. Curves are split into equal steps in t, enough that the
// chords stay within fTolerance pixels of the curve (Wang's formula).
// Consecutive duplicate points are merged.
void	FlattenFigure(const PointF* pStart, int nSegments, bool bCurved, float fScale,
	float fTolerance, Contour& out);

// Appends triangles covering the stroke of the contours with the given
// width in pixels (absolute value; zero draws nothing).
//
// With pQuads, smooth stretches become a strip of convex quads (four points
// each, in order around the quad) instead: at a point inside a flattened
// curve whose turn is small enough that a miter there stays within
// fTolerance of the round join, the two segments share one edge across the
// stroke, along the bisector, and no join is drawn. Quads that meet share
// that edge exactly. Other points (corners, sharper turns, short segments)
// end their segments square and get the usual join triangles.
void	StrokeContours(const Contour* pContour, size_t nContours, float fWidth, float fTolerance,
	std::vector<Vec2>& tris, std::vector<Vec2>* pQuads = nullptr);

// Appends a triangle fan per contour edge from a common pivot. Inverting a
// stencil bit for every triangle leaves it set exactly where the even-odd
// rule fills.
void	FanContours(const Contour* pContour, size_t nContours, std::vector<Vec2>& tris);

// Appends the even-odd fill of the contours as horizontal spans of pixels
// whose centers are inside, clipped to a target of nWidth x nHeight pixels.
// Each span is two points, (x0, row) and (x1, row): pixels x0 <= x < x1
// (integers) in that row. A pixel center exactly on an edge counts as
// inside to the right of the crossing and below it (half-open), as the
// edges' crossings are taken at y in [ymin, ymax). Spans never overlap, so
// each pixel inside is touched once, however often the contours wind.
void	SpanContours(const Contour* pContour, size_t nContours, int nWidth, int nHeight,
	std::vector<Vec2>& spans);

// Appends the two triangles of a rectangle, in pixels.
void	RectTriangles(float left, float top, float right, float bottom, std::vector<Vec2>& tris);

} // namespace gpu
} // namespace whorld
