// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Core Graphics implementation of whorld::IRenderer, drawing into a bitmap
// it owns. The bitmap matches Direct2D's swap chain format: 8-bit BGRA,
// premultiplied alpha, sRGB values written without color management.
//
// Coordinates: the engine draws in Direct2D DIPs with a top-left origin and
// y down. The renderer maps them to pixels with a flipped, scaled CTM, so
// one DIP is `scale` pixels (the Retina backing scale; 1 for exports).

#include "whorld/IRenderer.h"

#include <CoreGraphics/CoreGraphics.h>

#include <cstdint>
#include <string>
#include <vector>

namespace whorld {

class CGBitmapRenderer : public IRenderer {
public:
	// Bitmap of nWidth x nHeight pixels; DIP size is pixels / fScale.
	CGBitmapRenderer(int nWidth, int nHeight, double fScale = 1);
	~CGBitmapRenderer() override;
	CGBitmapRenderer(const CGBitmapRenderer&) = delete;
	CGBitmapRenderer& operator=(const CGBitmapRenderer&) = delete;

// Attributes
	bool	IsValid() const { return m_ctx != nullptr; }
	int		GetPixelWidth() const { return m_nWidth; }
	int		GetPixelHeight() const { return m_nHeight; }
	double	GetScale() const { return m_fScale; }
	SizeF	GetSizeDIPs() const;
	CGContextRef	GetContext() const { return m_ctx; }
	// Pixel access: BGRA, premultiplied; row 0 is the top of the image.
	const uint8_t*	GetPixels() const { return m_aPixel.data(); }
	size_t	GetStride() const { return m_nStride; }

// Frame (the host's BeginDraw / EndDraw)
	void	BeginFrame();
	void	EndFrame();

// Output
	CGImageRef	CopyImage() const;	// caller releases
	// Writes the bitmap as PNG the way WriteCapturedBitmap does on Windows:
	// the premultiplied bytes are written as straight (unpremultiplied)
	// BGRA. Identical for opaque images.
	bool	WritePNG(const std::string& sPath, std::string* pError = nullptr) const;

// IRenderer
	void	SetAntialiasing(bool bEnable) override;
	void	Clear(const ColorF& clr) override;
	void	BeginPath() override;
	void	AddFigure(const PointF* pStart, int nSegments, bool bCurved, bool bFilled) override;
	void	EndPath() override;
	void	FillPath(const ColorF& clr) override;
	void	StrokePath(const ColorF& clr, float fWidth) override;
	void	FillRect(const RectF& rect, const ColorF& clr) override;
	bool	BeginQuadMirror() override;
	bool	EndQuadMirror() override;

protected:
	int		m_nWidth;
	int		m_nHeight;
	double	m_fScale;
	size_t	m_nStride;
	std::vector<uint8_t>	m_aPixel;
	CGColorSpaceRef	m_space = nullptr;
	CGContextRef	m_ctx = nullptr;
	CGMutablePathRef	m_pathFilled = nullptr;	// figures begun FILLED
	CGMutablePathRef	m_pathAll = nullptr;	// all figures, for stroking
	struct Figure {	// copy of each figure's points, for computing joins
		std::vector<PointF>	pts;
		int		nSegments;
		bool	bCurved;
	};
	std::vector<Figure>	m_aFigure;
	bool	m_bInFrame = false;
	bool	m_bMirrorClip = false;	// true while the mirror clip is pushed
	int		m_nQuadWidth = 0;	// mirror quadrant size in pixels
	int		m_nQuadHeight = 0;

	void	SetFillColor(const ColorF& clr);
	void	SetStrokeColor(const ColorF& clr);
	void	ReleasePaths();
	void	ApplyBaseState();
	// Adds Direct2D's clipped miters for joins whose miter exceeds the limit.
	// Returns false if no join needs one.
	bool	AddClippedMiters(CGMutablePathRef path, float fWidth) const;
};

} // namespace whorld
