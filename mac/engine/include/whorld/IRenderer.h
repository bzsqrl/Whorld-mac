// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Abstract drawing backend for the engine. It covers exactly the Direct2D
// calls CWhorldDraw makes, with the same semantics, so a backend can match
// Windows output. Coordinates are Direct2D's: device-independent pixels,
// origin at the top left, y pointing down. A backend converts to its own
// coordinate system and pixel scale.
//
// The host brackets each frame with its own begin/end (Direct2D's
// BeginDraw/EndDraw happen in the render thread, not in CWhorldDraw).

#include "whorld/Types.h"

namespace whorld {

struct RectF {	// replaces D2D1_RECT_F
	float	left;
	float	top;
	float	right;
	float	bottom;
};

class IRenderer {
public:
	virtual ~IRenderer() {}

	// Antialiasing: true = D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
	// false = D2D1_ANTIALIAS_MODE_ALIASED. Applies to fills and strokes.
	virtual void	SetAntialiasing(bool bEnable) = 0;

	// ID2D1RenderTarget::Clear: replace every pixel inside the current clip
	// (including alpha) with the color, without blending.
	virtual void	Clear(const ColorF& clr) = 0;

	// Path building, replacing ID2D1PathGeometry and ID2D1GeometrySink.
	// BeginPath starts a new, empty path; AddFigure appends a closed figure
	// (D2D1_FIGURE_END_CLOSED); EndPath finishes it. The finished path stays
	// current for FillPath and StrokePath until the next BeginPath.
	//
	// A figure starts at pStart[0] and has nSegments segments:
	//   straight: lines to pStart[1] .. pStart[nSegments] (AddLines)
	//   curved:   cubic Beziers using pStart[1] .. pStart[3 * nSegments],
	//             three points per segment (AddBeziers)
	// bFilled is D2D1_FIGURE_BEGIN_FILLED; false is D2D1_FIGURE_BEGIN_HOLLOW,
	// which FillPath ignores and StrokePath still draws.
	virtual void	BeginPath() = 0;
	virtual void	AddFigure(const PointF* pStart, int nSegments, bool bCurved, bool bFilled) = 0;
	virtual void	EndPath() = 0;

	// ID2D1RenderTarget::FillGeometry with a solid color brush. The fill
	// rule is D2D1_FILL_MODE_ALTERNATE (even-odd), Direct2D's default for
	// path geometries; Whorld relies on it to fill between two rings.
	virtual void	FillPath(const ColorF& clr) = 0;

	// ID2D1RenderTarget::DrawGeometry with a solid color brush and the
	// default stroke style: miter joins with miter limit 10, flat caps, the
	// stroke centered on the path.
	virtual void	StrokePath(const ColorF& clr, float fWidth) = 0;

	// ID2D1RenderTarget::FillRectangle with a solid color brush.
	virtual void	FillRect(const RectF& rect, const ColorF& clr) = 0;

	// Quad mirroring (CWhorldDraw::InitMirroring / FinishMirroring).
	// BeginQuadMirror clips drawing to the upper-left quadrant, whose size
	// in physical pixels is ((width + 1) / 2, (height + 1) / 2) rounded
	// down by integer division, using an aliased pixel-aligned clip. It
	// returns false, with no clip, if it can't mirror (for example a zero
	// size). EndQuadMirror removes the clip and copies the quadrant into the
	// other three, flipped horizontally, vertically and both, reflecting
	// across the full frame size so odd sizes overlap by one pixel at the
	// center. The copy replaces pixels exactly (no blending, nearest
	// neighbor). The engine calls EndQuadMirror after every BeginQuadMirror,
	// as the original does; if BeginQuadMirror failed, EndQuadMirror must do
	// nothing and return false.
	virtual bool	BeginQuadMirror() = 0;
	virtual bool	EndQuadMirror() = 0;
};

} // namespace whorld
