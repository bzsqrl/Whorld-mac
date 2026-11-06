// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Metal implementation of whorld::IRenderer (Phase 8 spike). It records a
// frame's calls, tessellates the paths on the CPU in parallel at EndFrame
// (gpu/Tessellator.h), and draws them on the GPU:
// - antialiasing by multisampling, resolved into a BGRA8 texture that holds
//   sRGB values without color management, as the CG renderer does;
// - even-odd fills by stencil, then cover;
// - strokes with a per-stroke stencil reference, so a translucent stroke
//   covers each sample once even where its triangles overlap;
// - quad mirroring by a pass that copies the upper-left quadrant flipped.
//
// Coordinates are the engine's DIPs, top-left origin, y down; one DIP is
// `scale` pixels.

#include "whorld/IRenderer.h"
#include "gpu/Tessellator.h"

#include <cstdint>
#include <memory>
#include <vector>

#ifdef __OBJC__
@protocol MTLDevice;
@protocol MTLTexture;
#endif

namespace whorld {

class MetalRenderer : public IRenderer {
public:
	// nSamples: multisample count for antialiased frames (1, 2, 4 or 8), or
	// 0 for coverage mode: per-path 64-sample coverage, blended per shape as
	// Direct2D does (Apple GPUs only).
	MetalRenderer(int nWidth, int nHeight, double fScale, int nSamples = 4);
	~MetalRenderer() override;
	MetalRenderer(const MetalRenderer&) = delete;
	MetalRenderer& operator=(const MetalRenderer&) = delete;

	bool	IsValid() const;
	int		GetPixelWidth() const { return m_nWidth; }
	int		GetPixelHeight() const { return m_nHeight; }
	double	GetScale() const { return m_fScale; }
	SizeF	GetSizeDIPs() const;
	void	SetTolerance(float fPixels) { m_fTolerance = fPixels; }	// curve flattening

	// Frame. EndFrame tessellates, encodes and commits; WaitUntilDone blocks
	// until the GPU has finished the last committed frame.
	void	BeginFrame();
	void	EndFrame();
	void	WaitUntilDone();

	// Pixels of the last finished frame: BGRA, premultiplied, row 0 at top.
	bool	ReadPixels(std::vector<uint8_t>& aPixel, size_t& nStride);

	struct Stats {
		double	fTessMs = 0;	// CPU: flattening and tessellation (parallel)
		double	fEncodeMs = 0;	// CPU: buffer fill and command encoding
		double	fGpuMs = 0;		// GPU time of the last finished frame
		size_t	nVertices = 0;
		size_t	nDraws = 0;
		struct Profile {	// coverage mode, with WHORLD_MTL_PROFILE: [fill, stroke, rect]
			size_t	nOps[3] = {};
			size_t	nTris[3] = {};
			double	fPx[3] = {};	// pixels rasterized by one draw (mask; the cover draw repeats it)
			double	fArea[3] = {};	// triangle area before growth
			size_t	nBoxTris = 0;	// thin triangles drawn as their bounding box
		} prof;
	};
	const Stats&	GetStats() const { return m_stats; }
	// coverage mode with WHORLD_MTL_PROFILE: the last frame's mask-draw
	// fragments by path through TriangleMask (see the shader), then [7] the
	// hybrid fills' fan-flip fragments
	bool	GetFragmentCounts(uint32_t aCount[8]) const;

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

private:
	struct Impl;	// Metal objects
	std::unique_ptr<Impl>	m_pImpl;
	int		m_nWidth;
	int		m_nHeight;
	double	m_fScale;
	int		m_nSamples;
	float	m_fTolerance = 0.1f;
	Stats	m_stats;

	struct Figure {
		size_t	iPt;		// first point in m_aPt
		int		nSegments;
		bool	bCurved;
		bool	bFilled;
	};
	struct Op {
		enum Type { CLEAR, FILL, STROKE, RECT, MIRROR_BEGIN, MIRROR_END };
		Type	type;
		ColorF	clr{0, 0, 0, 0};
		float	fWidth = 0;
		RectF	rect{0, 0, 0, 0};
		size_t	iFig = 0;	// figures [iFig, iFig + nFig)
		size_t	nFig = 0;
		std::vector<gpu::Vec2>	tris;	// built at EndFrame
		size_t	iVert = 0;	// first vertex in the frame's buffer
		float	box[4] = {};	// fills: bounding box in pixels (left, top, right, bottom)
	};
	std::vector<PointF>	m_aPt;
	std::vector<Figure>	m_aFig;
	std::vector<gpu::Contour>	m_aContour;	// one per figure, built at EndFrame
	std::vector<Op>	m_aOp;
	size_t	m_iPathFig = 0;	// first figure of the current path
	bool	m_bInFrame = false;
	bool	m_bAntialias = true;
	bool	m_bAntialiasSet = false;	// first SetAntialiasing of the frame seen
	bool	m_bMirrorPending = false;
	int		m_nAblate = 0;		// WHORLD_MTL_ABLATE (profiling)
	bool	m_bProfile = false;	// WHORLD_MTL_PROFILE
	void	ProfileOp(const Op& op);

	void	Tessellate();
	void	Encode();
	void	EncodeCoverage();
};

} // namespace whorld
