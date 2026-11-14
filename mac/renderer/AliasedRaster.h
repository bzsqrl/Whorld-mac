// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Aliased drawing on the CPU, for CGBitmapRenderer. Direct2D's aliased mode
// lights a pixel when its center is inside the shape, as MetalRenderer's
// aliased frames do; screenshots of Windows Whorld with antialiasing off
// match that rule (0.002% of pixels differ) and not Core Graphics' aliased
// rasterizer (8 to 10%), which draws thin lines and slivers too heavily
// (PORT_PLAN Phase 8, "Settled: Metal's aliased output matches Windows").
//
// Shapes become spans of pixels whose centers are inside, using the GPU
// renderer's geometry (gpu::FlattenFigure, SpanContours, StrokeContours),
// then are blended source-over into premultiplied BGRA memory. Each pixel
// of a fill or stroke is blended once, however often the shape overlaps
// itself, as Direct2D blends a translucent stroke once.

#include "gpu/Tessellator.h"
#include "whorld/IRenderer.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace whorld {

namespace aliased {

// Pixels [x0, x1) of row y (row 0 at the top)
struct Span {
	int	y, x0, x1;
};

// A figure as IRenderer::AddFigure gives it, in DIPs
struct Figure {
	std::vector<PointF>	pts;
	int		nSegments = 0;
	bool	bCurved = false;
	bool	bFilled = false;
};

// Spans are sorted by row, then x, and don't overlap. Coordinates are DIPs,
// scaled to pixels by fScale; the target is nWidth x nHeight pixels.
void	FillSpans(const Figure* pFig, size_t nFigs, double fScale, int nWidth, int nHeight,
	std::vector<Span>& spans);	// the even-odd fill of the figures begun filled
void	StrokeSpans(const Figure* pFig, size_t nFigs, float fWidth, double fScale, int nWidth, int nHeight,
	std::vector<Span>& spans);	// fWidth in DIPs, positive
void	RectSpans(const RectF& rect, double fScale, int nWidth, int nHeight, std::vector<Span>& spans);

// Blends the spans in rows [y0, y1), clipped to x < xMax and y < yMax,
// source-over with the straight-alpha color, into premultiplied BGRA pixels
void	Blend(const std::vector<Span>& spans, const ColorF& clr, uint8_t* pPixels, size_t nStride,
	int y0, int y1, int xMax, int yMax);

} // namespace aliased

} // namespace whorld
