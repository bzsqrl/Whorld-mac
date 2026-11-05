// Copyleft 2025 Chris Korda (original SnapshotV1.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "SnapshotV1.h"
#include "ByteIO.h"

#include <algorithm>
#include <cstring>

namespace whorld {

using namespace bin;

namespace {

// Reads MFC CArchive primitives: little-endian integers and CStrings.
class ArchiveReader {
public:
	explicit ArchiveReader(const std::vector<uint8_t>& data) : m_in(data) {}
	bool	ReadInt(int32_t& v) { return m_in.ReadI32(v); }
	bool	ReadDword(uint32_t& v) { return m_in.ReadU32(v); }
	bool	Read(void* p, size_t n) { return m_in.Read(p, n); }
	// CArchive >> CString: skip the string, as the original discards it.
	// Length prefix per MFC AfxReadStringLength: BYTE, or 0xff + WORD, or
	// 0xff 0xffff + DWORD (+ QWORD); 0xff 0xfffe marks a wide string.
	bool	SkipString()
	{
		size_t	nCharSize = 1;
		uint8_t	bLen;
		if (!m_in.ReadU8(bLen))
			return false;
		uint64_t	nLen = bLen;
		if (bLen == 0xff) {
			uint16_t	wLen;
			if (!m_in.ReadU16(wLen))
				return false;
			if (wLen == 0xfffe) {	// Unicode marker; read length again
				nCharSize = 2;
				if (!m_in.ReadU8(bLen))
					return false;
				nLen = bLen;
				if (bLen == 0xff) {
					if (!m_in.ReadU16(wLen))
						return false;
				}
			}
			if (bLen == 0xff) {
				nLen = wLen;
				if (wLen == 0xffff) {
					uint32_t	dwLen;
					if (!m_in.ReadU32(dwLen))
						return false;
					nLen = dwLen;
					if (dwLen == 0xffffffff) {
						if (!m_in.ReadU64(nLen))
							return false;
					}
				}
			}
		}
		if (nLen > m_in.Remaining() / nCharSize)
			return false;
		return m_in.Skip(static_cast<size_t>(nLen * nCharSize));
	}

private:
	Reader	m_in;
};

DPOINT GetDPoint(const uint8_t* p)
{
	return DPOINT{GetF64(p), GetF64(p + 8)};
}

bool Fail(std::string* pError, const char* pszMsg)
{
	if (pError)
		*pError = pszMsg;
	return false;
}

const char* const kBadFormat = "Unexpected file format.";	// original throws badIndex
const char* const kEOF = "Unexpected end of file.";

} // namespace

// x86 MSVC offsets for RING_V1 (152 bytes)
void SnapshotV1::DecodeRing(const uint8_t* p, RING_V1& r)
{
	r.RotDelta = GetF64(p + 0);
	r.ShiftDelta = GetDPoint(p + 8);
	r.Hue = GetF64(p + 24);
	r.Lightness = GetF32(p + 32);
	r.Saturation = GetF32(p + 36);
	r.Rot = GetF64(p + 40);
	r.Steps = GetF64(p + 48);
	r.Scale = GetDPoint(p + 56);
	r.Shift = GetDPoint(p + 72);
	r.StarRatio = GetF64(p + 88);
	r.Sides = GetI16(p + 96);
	r.Delete = GetBool(p + 98);
	r.Reverse = GetBool(p + 99);
	r.Color = GetI32(p + 100);
	r.Pinwheel = GetF64(p + 104);
	r.LineWidth = GetI16(p + 112);
	r.DrawMode = GetI16(p + 114);
	r.Spacing = GetF32(p + 116);
	r.Origin = GetDPoint(p + 120);
	r.EvenCurve = GetF32(p + 136);
	r.OddCurve = GetF32(p + 140);
	r.EvenShear = GetF32(p + 144);
	r.OddShear = GetF32(p + 148);
}

// x86 MSVC offsets for GLOB_RING_V1 (80 bytes)
void SnapshotV1::DecodeGlobRing(const uint8_t* p, GLOB_RING_V1& g)
{
	g.Rot = GetF64(p + 0);
	g.StarRatio = GetF64(p + 8);
	g.Pinwheel = GetF64(p + 16);
	g.Scale = GetDPoint(p + 24);
	g.Shift = GetDPoint(p + 40);
	g.EvenCurve = GetF32(p + 56);
	g.OddCurve = GetF32(p + 60);
	g.EvenShear = GetF32(p + 64);
	g.OddShear = GetF32(p + 68);
	g.LineWidth = GetI32(p + 72);
	g.PolySides = GetI32(p + 76);
}

// x86 MSVC offsets for DRAW_STATE_V1 (128 bytes)
void SnapshotV1::DecodeState(const uint8_t* p, DRAW_STATE_V1& s)
{
	s.RingOffset = GetF64(p + 0);
	s.CanvasScale = GetF64(p + 8);
	s.Hue = GetF64(p + 16);
	s.Color = GetI32(p + 24);
	s.BkColor = GetI32(p + 28);
	s.DrawMode = GetI32(p + 32);
	s.Mirror = GetBool(p + 36);
	s.HueLoop = GetBool(p + 37);
	s.Convex = GetBool(p + 38);
	s.VideoROPIdx = p[39];
	s.NormOrg = GetDPoint(p + 40);
	s.MirrorOrg = GetDPoint(p + 56);
	s.HueLoopPos = GetF64(p + 72);
	s.HueLoopLength = GetF64(p + 80);
	s.HueLoopBase = GetF32(p + 88);
	s.InvertMask = GetI32(p + 92);
	s.Zoom = GetF64(p + 96);
	s.Trail = GetF64(p + 104);
	s.VideoOrg = GetDPoint(p + 112);
}

// ported from SnapshotV1.cpp CSnapshotV1::Read
std::unique_ptr<Snapshot> SnapshotV1::Read(const std::vector<uint8_t>& data, std::string* pError,
	IntSize szLegacy)
{
	ArchiveReader	ar(data);	// original seeks to the beginning first
	int32_t	nSig, nVersion;
	if (!ar.ReadInt(nSig) || !ar.ReadInt(nVersion))
		return Fail(pError, kEOF), nullptr;
	if (nSig != SNAPSHOT_SIG || nVersion > SNAPSHOT_VERSION)
		return Fail(pError, kBadFormat), nullptr;
	int32_t	nParmsSize;
	if (!ar.ReadInt(nParmsSize))
		return Fail(pError, kEOF), nullptr;
	// original compares int against size_t, so negative sizes are rejected too
	if (nParmsSize < 0 || nParmsSize > PARMS_V1_SIZE)
		return Fail(pError, kBadFormat), nullptr;
	uint8_t	parms[PARMS_V1_SIZE];	// read and unused, as in the original
	if (!ar.Read(parms, nParmsSize))
		return Fail(pError, kEOF), nullptr;
	int32_t	nRings, nRingSize;
	if (!ar.ReadInt(nRingSize) || !ar.ReadInt(nRings))
		return Fail(pError, kEOF), nullptr;
	if (nRings < 0)
		return Fail(pError, kBadFormat), nullptr;
	if (nRingSize < 0 || nRingSize > RING_V1_SIZE)
		return Fail(pError, kBadFormat), nullptr;
	std::unique_ptr<Snapshot>	pSnapshot(Snapshot::Alloc(nRings));	// rings zeroed
	uint8_t	ringBuf[RING_V1_SIZE];
	std::memset(ringBuf, 0, sizeof(ringBuf));	// ZeroMemory(&ring); persists across rings
	RING_V1	ring;
	for (int iRing = 0; iRing < nRings; iRing++) {	// for each ring
		if (!ar.Read(ringBuf, nRingSize))	// read ring into buffer
			return Fail(pError, kEOF), nullptr;
		DecodeRing(ringBuf, ring);
		CvtRing(ring, pSnapshot->m_aRing[iRing]);	// convert to V2
	}
	if (nVersion > 3) {	// if video overlay is supported
		uint32_t	nVideoFrame;
		if (!ar.SkipString() || !ar.ReadDword(nVideoFrame))
			return Fail(pError, kEOF), nullptr;
	}
	int32_t	nStateSize;
	if (!ar.ReadInt(nStateSize))
		return Fail(pError, kEOF), nullptr;
	if (nStateSize < 0 || nStateSize > DRAW_STATE_V1_SIZE)
		return Fail(pError, kBadFormat), nullptr;
	uint8_t	stateBuf[DRAW_STATE_V1_SIZE];
	std::memset(stateBuf, 0, sizeof(stateBuf));
	if (!ar.Read(stateBuf, nStateSize))
		return Fail(pError, kEOF), nullptr;
	DRAW_STATE_V1	drawState;
	DecodeState(stateBuf, drawState);
	std::memset(&pSnapshot->m_drawState, 0, sizeof(DRAW_STATE));
	CvtState(drawState, pSnapshot->m_drawState, szLegacy);
	pSnapshot->m_drawState.nRings = nRings;
	pSnapshot->m_globRing = m_globalRingDefault;
	if (nVersion > 4) {	// if global parameters are supported
		int32_t	nGlobRingSize;
		if (!ar.ReadInt(nGlobRingSize))
			return Fail(pError, kEOF), nullptr;
		if (nGlobRingSize < 0 || nGlobRingSize > GLOB_RING_V1_SIZE)
			return Fail(pError, kBadFormat), nullptr;
		uint8_t	globBuf[GLOB_RING_V1_SIZE];
		std::memset(globBuf, 0, sizeof(globBuf));
		if (!ar.Read(globBuf, nGlobRingSize))
			return Fail(pError, kEOF), nullptr;
		GLOB_RING_V1	globring;
		DecodeGlobRing(globBuf, globring);
		CvtGlobRing(globring, pSnapshot->m_globRing);
	}
	if (nVersion <= 1) {	// if snapshot version 1 or earlier
		// mirror origin coordinates are unzoomed and reversed
		drawState.MirrorOrg.x *= -drawState.Zoom;	// convert to zoomed and non-reversed
		drawState.MirrorOrg.y *= -drawState.Zoom;
		// per-ring origins didn't exist, so make them all the same
		for (int iRing = 0; iRing < nRings; iRing++) {	// for each ring
			pSnapshot->m_aRing[iRing].ptOrigin = drawState.MirrorOrg;	// set ring origin
		}
	}
	return pSnapshot;
}

// ported from SnapshotV1.cpp CSnapshotV1::CvtColor (D2D1::ColorF has alpha 1)
ColorF SnapshotV1::CvtColor(uint32_t clr)
{
	return ColorF{
		static_cast<float>(clr & 0xff) / 255.0f,	// GetRValue
		static_cast<float>((clr >> 8) & 0xff) / 255.0f,	// GetGValue
		static_cast<float>((clr >> 16) & 0xff) / 255.0f,	// GetBValue
		1.0f};
}

// ported from SnapshotV1.cpp CSnapshotV1::CvtRing
void SnapshotV1::CvtRing(const RING_V1& ringOld, RING& ringNew)
{
	// Upstream quirk: ptShiftDelta is copied from Shift, not ShiftDelta.
	ringNew.ptShiftDelta	= ringOld.Shift;
	ringNew.fRotDelta		= ringOld.RotDelta;
	ringNew.fHue			= ringOld.Hue;
	ringNew.fLightness		= ringOld.Lightness;
	ringNew.fSaturation		= ringOld.Saturation;
	ringNew.fRot			= ringOld.Rot;
	ringNew.fRadius			= ringOld.Steps;
	ringNew.ptScale			= ringOld.Scale;
	ringNew.ptShift			= ringOld.Shift;
	ringNew.fStarRatio		= ringOld.StarRatio;
	ringNew.nSides			= ringOld.Sides;
	ringNew.nDrawMode		= ringOld.DrawMode;
	ringNew.bDelete			= ringOld.Delete;
	ringNew.bSkipFill		= false;
	ringNew.clrCur			= CvtColor(static_cast<uint32_t>(ringOld.Color));
	ringNew.fPinwheel		= ringOld.Pinwheel;
	ringNew.fLineWidth		= std::max<int>(ringOld.LineWidth, 1);
	ringNew.ptOrigin		= ringOld.Origin;
	ringNew.fEvenCurve		= ringOld.EvenCurve;
	ringNew.fOddCurve		= ringOld.OddCurve;
	ringNew.fEvenShear		= ringOld.EvenShear;
	ringNew.fOddShear		= ringOld.OddShear;
}

// ported from SnapshotV1.cpp CSnapshotV1::CvtState
void SnapshotV1::CvtState(const DRAW_STATE_V1& stateOld, DRAW_STATE& stateNew, IntSize szLegacy)
{
	// V1 snapshot format didn't include a frame size, so user must specify it
	stateNew.szTarget		= SizeF{static_cast<float>(szLegacy.cx), static_cast<float>(szLegacy.cy)};
	stateNew.clrBkgnd		= CvtColor(static_cast<uint32_t>(stateOld.BkColor));
	stateNew.fZoom			= stateOld.Zoom;
	stateNew.bConvex		= stateOld.Convex;
	stateNew.nFlags			= Snapshot::SF_V1;
	stateNew.bMirror		= stateOld.Mirror;
}

// ported from SnapshotV1.cpp CSnapshotV1::CvtGlobRing
void SnapshotV1::CvtGlobRing(const GLOB_RING_V1& grOld, GLOB_RING& grNew)
{
	grNew.fRot				= grOld.Rot;
	grNew.fStarRatio		= grOld.StarRatio;
	grNew.fPinwheel			= grOld.Pinwheel;
	grNew.ptScale			= grOld.Scale;
	grNew.ptShift			= grOld.Shift;
	grNew.fEvenCurve		= grOld.EvenCurve;
	grNew.fOddCurve			= grOld.OddCurve;
	grNew.fEvenShear		= grOld.EvenShear;
	grNew.fOddShear			= grOld.OddShear;
	grNew.fLineWidth		= grOld.LineWidth;
	grNew.nPolySides		= grOld.PolySides;
}

} // namespace whorld
