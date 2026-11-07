// Copyleft 2025 Chris Korda (original SnapshotV1.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from SnapshotV1.h CSnapshotV1: reads Whorld V1 snapshots.
//
// V1 snapshots were written by 32-bit MSVC through an MFC CArchive: ints
// are 4 bytes little-endian, CStrings use MFC's length-prefix encoding, and
// structs are raw dumps with x86 MSVC layout (doubles 8-byte aligned).
// Field offsets are listed in SnapshotV1.cpp.

#include "whorld/Snapshot.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace whorld {

class SnapshotV1 : public WhorldBase {
public:
// Operations
	static std::unique_ptr<Snapshot> Read(const std::vector<uint8_t>& data, std::string* pError,
		IntSize szLegacy);

// Constants
	enum {
		SNAPSHOT_SIG = 0x4e534857,	// snapshot signature: WHSN (WHorld SNapshot)
		SNAPSHOT_VERSION = 5,		// snapshot version number
	};
	enum {	// struct sizes as laid out by 32-bit MSVC
		PARMS_V1_SIZE = 160,
		RING_V1_SIZE = 152,
		GLOB_RING_V1_SIZE = 80,
		DRAW_STATE_V1_SIZE = 128,
	};

protected:
// Types
	struct PARMS_V1 {
		double	Parm[20];		// geometry parameters
	};
	struct RING_V1 {
		double	RotDelta;		// additional rotation per tick
		DPOINT	ShiftDelta;		// additional shear per tick
		double	Hue;			// ring's current hue
		float	Lightness;		// ring's current lightness
		float	Saturation;		// ring's current saturation
		// mini-ring begins here
		double	Rot;			// rotation for all vertices, in radians
		double	Steps;			// radius of even vertices, in pixels
		DPOINT	Scale;			// anisotropic scaling
		DPOINT	Shift;			// shear, in pixels
		double	StarRatio;		// ratio of odd radii to even radii
		int16_t	Sides;			// polygon's number of sides
		bool	Delete;			// true if this ring should be deleted
		bool	Reverse;		// true if ring was born growing inward
		int32_t	Color;			// ring's current color, in RGB
		double	Pinwheel;		// additional rotation for odd vertices
		int16_t	LineWidth;		// pen width, in pixels, or 0 to use DC pen
		int16_t	DrawMode;		// see draw mode enum
		float	Spacing;		// distance between rings, in pixels
		DPOINT	Origin;			// origin in client coords relative to window center
		float	EvenCurve;		// even vertex curvature, as multiple of radius
		float	OddCurve;		// odd vertex curvature, as multiple of radius
		float	EvenShear;		// even vertex curve point asymmetry ratio
		float	OddShear;		// odd vertex curve point asymmetry ratio
	};
	struct GLOB_RING_V1 {
		double	Rot;			// rotation for all vertices, in radians
		double	StarRatio;		// ratio of odd radii to even radii
		double	Pinwheel;		// additional rotation for odd vertices
		DPOINT	Scale;			// anisotropic scaling
		DPOINT	Shift;			// shear, in pixels
		float	EvenCurve;		// even vertex curvature, as multiple of radius
		float	OddCurve;		// odd vertex curvature, as multiple of radius
		float	EvenShear;		// even vertex curve point asymmetry ratio
		float	OddShear;		// odd vertex curve point asymmetry ratio
		int32_t	LineWidth;		// line width, in pixels
		int32_t	PolySides;		// number of sides
	};
	struct DRAW_STATE_V1 {
		double	RingOffset;		// size of gap since last ring, in pixels
		double	CanvasScale;	// canvas size, as a fraction of client window
		double	Hue;			// hue of new rings, in degrees
		int32_t	Color;			// color of new rings, in RGB
		int32_t	BkColor;		// background color, in RGB
		int32_t	DrawMode;		// see draw mode enum
		bool	Mirror;			// true if we're mirroring
		bool	HueLoop;		// true if hue is being looped
		bool	Convex;			// true if rings are drawn in descending size order
		uint8_t	VideoROPIdx;	// index of video raster operation
		DPOINT	NormOrg;		// normalized origin: 0,0 = upper left, 1,1 = lower right
		DPOINT	MirrorOrg;		// distance from origin to window center, in client coords
		double	HueLoopPos;		// hue loop position, in degrees
		double	HueLoopLength;	// length of hue loop, in degrees
		float	HueLoopBase;	// hue loop's base hue, in degrees
		int32_t	InvertMask;		// 0xffffff if inverting color, else zero
		double	Zoom;			// magnification factor, 1 = normal
		double	Trail;			// origin propagation: 0 = no trail, 1 = permanent origin
		DPOINT	VideoOrg;		// video origin in mirror mode
	};

// Helpers
	static void	DecodeRing(const uint8_t* p, RING_V1& ring);
	static void	DecodeGlobRing(const uint8_t* p, GLOB_RING_V1& gr);
	static void	DecodeState(const uint8_t* p, DRAW_STATE_V1& ds);
	static void	CvtRing(const RING_V1& ringOld, RING& ringNew);
	static void	CvtState(const DRAW_STATE_V1& stateOld, DRAW_STATE& stateNew, IntSize szLegacy);
	static void CvtGlobRing(const GLOB_RING_V1& grOld, GLOB_RING& grNew);
	static ColorF CvtColor(uint32_t clr);
};

} // namespace whorld
