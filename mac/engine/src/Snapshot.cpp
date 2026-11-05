// Copyleft 2025 Chris Korda (original Snapshot.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "whorld/Snapshot.h"
#include "whorld/Patch.h"	// for string conversion operators
#include "ByteIO.h"
#include "SnapshotV1.h"

#include <algorithm>
#include <cstring>
#include <fstream>
#include <sstream>

namespace whorld {

using namespace bin;

const uint32_t Snapshot::m_nFileID = MakeFourCC('W', 'H', 'S', '2');
const uint16_t Snapshot::m_nFileVersion = 1;
const IntSize Snapshot::DEFAULT_LEGACY_SIZE = {800, 600};

// MSVC x64 field offsets. These are fixed by the files Windows writes;
// the header sizes in mac/testdata/snapshots confirm the struct sizes.
namespace {

namespace ds {	// DRAW_STATE, 40 bytes
enum {
	szTarget = 0,	// SizeF: 2 x f32
	clrBkgnd = 8,	// ColorF: 4 x f32
	fZoom = 24,		// f64
	nRings = 32,	// i32
	bConvex = 36,	// bool
	nFlags = 37,	// u8
	bMirror = 38,	// bool
	nReserved = 39,	// u8
};
}

namespace gr {	// GLOB_RING, 104 bytes
enum {
	fRot = 0,
	fStarRatio = 8,
	fPinwheel = 16,
	ptScale = 24,	// DPOINT: 2 x f64
	ptShift = 40,
	fEvenCurve = 56,
	fOddCurve = 64,
	fEvenShear = 72,
	fOddShear = 80,
	fLineWidth = 88,
	nPolySides = 96,	// i32
	nReserved = 100,	// i32
};
}

namespace rg {	// RING, 192 bytes
enum {
	ptShiftDelta = 0,	// DPOINT
	fRotDelta = 16,
	fHue = 24,
	fLightness = 32,
	fSaturation = 40,
	fRot = 48,
	fRadius = 56,
	ptScale = 64,		// DPOINT
	ptShift = 80,		// DPOINT
	fStarRatio = 96,
	nSides = 104,		// i16
	nDrawMode = 106,	// i16
	bDelete = 108,		// bool
	bSkipFill = 109,	// bool
	nReserved = 110,	// i16
	clrCur = 112,		// ColorF
	fPinwheel = 128,
	fLineWidth = 136,
	ptOrigin = 144,		// DPOINT
	fEvenCurve = 160,
	fOddCurve = 168,
	fEvenShear = 176,
	fOddShear = 184,
};
}

DPOINT GetDPoint(const uint8_t* p)
{
	return DPOINT{GetF64(p), GetF64(p + 8)};
}

void PutDPoint(uint8_t* p, const DPOINT& pt)
{
	PutF64(p, pt.x);
	PutF64(p + 8, pt.y);
}

ColorF GetColor(const uint8_t* p)
{
	return ColorF{GetF32(p), GetF32(p + 4), GetF32(p + 8), GetF32(p + 12)};
}

void PutColor(uint8_t* p, const ColorF& c)
{
	PutF32(p, c.r);
	PutF32(p + 4, c.g);
	PutF32(p + 8, c.b);
	PutF32(p + 12, c.a);
}

// Copy at most nSize bytes into a zeroed image of nFull bytes, mirroring
// the original's ZeroMemory then Read(min(size, sizeof)).
template <size_t nFull>
void MakeImage(const uint8_t* p, size_t nSize, uint8_t (&img)[nFull])
{
	std::memset(img, 0, nFull);
	std::memcpy(img, p, std::min(nSize, nFull));
}

} // namespace

void Snapshot::DecodeDrawState(const uint8_t* p, size_t nSize, DRAW_STATE& s)
{
	uint8_t	b[DRAW_STATE_SIZE];
	MakeImage(p, nSize, b);
	s.szTarget = SizeF{GetF32(b + ds::szTarget), GetF32(b + ds::szTarget + 4)};
	s.clrBkgnd = GetColor(b + ds::clrBkgnd);
	s.fZoom = GetF64(b + ds::fZoom);
	s.nRings = GetI32(b + ds::nRings);
	s.bConvex = GetBool(b + ds::bConvex);
	s.nFlags = b[ds::nFlags];
	s.bMirror = GetBool(b + ds::bMirror);
	s.nReserved = b[ds::nReserved];
}

void Snapshot::EncodeDrawState(const DRAW_STATE& s, uint8_t* b)
{
	std::memset(b, 0, DRAW_STATE_SIZE);
	PutF32(b + ds::szTarget, s.szTarget.width);
	PutF32(b + ds::szTarget + 4, s.szTarget.height);
	PutColor(b + ds::clrBkgnd, s.clrBkgnd);
	PutF64(b + ds::fZoom, s.fZoom);
	PutI32(b + ds::nRings, s.nRings);
	PutBool(b + ds::bConvex, s.bConvex);
	b[ds::nFlags] = s.nFlags;
	PutBool(b + ds::bMirror, s.bMirror);
	b[ds::nReserved] = s.nReserved;
}

void Snapshot::DecodeGlobRing(const uint8_t* p, size_t nSize, GLOB_RING& g)
{
	uint8_t	b[GLOB_RING_SIZE];
	MakeImage(p, nSize, b);
	g.fRot = GetF64(b + gr::fRot);
	g.fStarRatio = GetF64(b + gr::fStarRatio);
	g.fPinwheel = GetF64(b + gr::fPinwheel);
	g.ptScale = GetDPoint(b + gr::ptScale);
	g.ptShift = GetDPoint(b + gr::ptShift);
	g.fEvenCurve = GetF64(b + gr::fEvenCurve);
	g.fOddCurve = GetF64(b + gr::fOddCurve);
	g.fEvenShear = GetF64(b + gr::fEvenShear);
	g.fOddShear = GetF64(b + gr::fOddShear);
	g.fLineWidth = GetF64(b + gr::fLineWidth);
	g.nPolySides = GetI32(b + gr::nPolySides);
	g.nReserved = GetI32(b + gr::nReserved);
}

void Snapshot::EncodeGlobRing(const GLOB_RING& g, uint8_t* b)
{
	std::memset(b, 0, GLOB_RING_SIZE);
	PutF64(b + gr::fRot, g.fRot);
	PutF64(b + gr::fStarRatio, g.fStarRatio);
	PutF64(b + gr::fPinwheel, g.fPinwheel);
	PutDPoint(b + gr::ptScale, g.ptScale);
	PutDPoint(b + gr::ptShift, g.ptShift);
	PutF64(b + gr::fEvenCurve, g.fEvenCurve);
	PutF64(b + gr::fOddCurve, g.fOddCurve);
	PutF64(b + gr::fEvenShear, g.fEvenShear);
	PutF64(b + gr::fOddShear, g.fOddShear);
	PutF64(b + gr::fLineWidth, g.fLineWidth);
	PutI32(b + gr::nPolySides, g.nPolySides);
	PutI32(b + gr::nReserved, g.nReserved);
}

void Snapshot::DecodeRing(const uint8_t* p, size_t nSize, RING& r)
{
	uint8_t	b[RING_SIZE];
	MakeImage(p, nSize, b);
	r.ptShiftDelta = GetDPoint(b + rg::ptShiftDelta);
	r.fRotDelta = GetF64(b + rg::fRotDelta);
	r.fHue = GetF64(b + rg::fHue);
	r.fLightness = GetF64(b + rg::fLightness);
	r.fSaturation = GetF64(b + rg::fSaturation);
	r.fRot = GetF64(b + rg::fRot);
	r.fRadius = GetF64(b + rg::fRadius);
	r.ptScale = GetDPoint(b + rg::ptScale);
	r.ptShift = GetDPoint(b + rg::ptShift);
	r.fStarRatio = GetF64(b + rg::fStarRatio);
	r.nSides = GetI16(b + rg::nSides);
	r.nDrawMode = GetI16(b + rg::nDrawMode);
	r.bDelete = GetBool(b + rg::bDelete);
	r.bSkipFill = GetBool(b + rg::bSkipFill);
	r.nReserved = GetI16(b + rg::nReserved);
	r.clrCur = GetColor(b + rg::clrCur);
	r.fPinwheel = GetF64(b + rg::fPinwheel);
	r.fLineWidth = GetF64(b + rg::fLineWidth);
	r.ptOrigin = GetDPoint(b + rg::ptOrigin);
	r.fEvenCurve = GetF64(b + rg::fEvenCurve);
	r.fOddCurve = GetF64(b + rg::fOddCurve);
	r.fEvenShear = GetF64(b + rg::fEvenShear);
	r.fOddShear = GetF64(b + rg::fOddShear);
}

void Snapshot::EncodeRing(const RING& r, uint8_t* b)
{
	std::memset(b, 0, RING_SIZE);
	PutDPoint(b + rg::ptShiftDelta, r.ptShiftDelta);
	PutF64(b + rg::fRotDelta, r.fRotDelta);
	PutF64(b + rg::fHue, r.fHue);
	PutF64(b + rg::fLightness, r.fLightness);
	PutF64(b + rg::fSaturation, r.fSaturation);
	PutF64(b + rg::fRot, r.fRot);
	PutF64(b + rg::fRadius, r.fRadius);
	PutDPoint(b + rg::ptScale, r.ptScale);
	PutDPoint(b + rg::ptShift, r.ptShift);
	PutF64(b + rg::fStarRatio, r.fStarRatio);
	PutI16(b + rg::nSides, r.nSides);
	PutI16(b + rg::nDrawMode, r.nDrawMode);
	PutBool(b + rg::bDelete, r.bDelete);
	PutBool(b + rg::bSkipFill, r.bSkipFill);
	PutI16(b + rg::nReserved, r.nReserved);
	PutColor(b + rg::clrCur, r.clrCur);
	PutF64(b + rg::fPinwheel, r.fPinwheel);
	PutF64(b + rg::fLineWidth, r.fLineWidth);
	PutDPoint(b + rg::ptOrigin, r.ptOrigin);
	PutF64(b + rg::fEvenCurve, r.fEvenCurve);
	PutF64(b + rg::fOddCurve, r.fOddCurve);
	PutF64(b + rg::fEvenShear, r.fEvenShear);
	PutF64(b + rg::fOddShear, r.fOddShear);
}

// ported from Snapshot.cpp CSnapshot::GetSize
uint32_t Snapshot::GetSize(int nRings)
{
	return DRAW_STATE_SIZE + GLOB_RING_SIZE + nRings * RING_SIZE;
}

// ported from Snapshot.cpp CSnapshot::Alloc
std::unique_ptr<Snapshot> Snapshot::Alloc(int nRings)
{
	std::unique_ptr<Snapshot>	pSnapshot(new Snapshot);
	std::memset(&pSnapshot->m_drawState, 0, sizeof(DRAW_STATE));
	std::memset(&pSnapshot->m_globRing, 0, sizeof(GLOB_RING));
	pSnapshot->m_aRing.resize(nRings > 0 ? nRings : 0);	// value-initialized (zeroed)
	return pSnapshot;
}

// ported from Snapshot.cpp CSnapshot::Write (the header and body encoding)
std::vector<uint8_t> Snapshot::Encode(const Snapshot& snapshot)
{
	// set all members of snapshot before calling this method
	int	nRings = snapshot.m_drawState.nRings;
	std::vector<uint8_t>	data(HEADER_SIZE + GetSize(nRings));
	uint8_t*	p = data.data();
	PutU32(p, m_nFileID);
	PutU16(p + 4, m_nFileVersion);
	PutU16(p + 6, DRAW_STATE_SIZE);
	PutU16(p + 8, GLOB_RING_SIZE);
	PutU16(p + 10, RING_SIZE);
	p += HEADER_SIZE;
	EncodeDrawState(snapshot.m_drawState, p);
	p += DRAW_STATE_SIZE;
	EncodeGlobRing(snapshot.m_globRing, p);
	p += GLOB_RING_SIZE;
	for (int iRing = 0; iRing < nRings; iRing++) {
		EncodeRing(snapshot.m_aRing[iRing], p);
		p += RING_SIZE;
	}
	return data;
}

bool Snapshot::Write(const Snapshot* pSnapshot, const std::string& sPath, std::string* pError)
{
	if (pSnapshot->m_aRing.size() != static_cast<size_t>(pSnapshot->m_drawState.nRings)) {
		if (pError)
			*pError = "Snapshot ring count doesn't match its ring array.";
		return false;
	}
	if (!WriteFile(sPath, Encode(*pSnapshot))) {	// original throws CFileException
		if (pError)
			*pError = "Can't write file: " + sPath;
		return false;
	}
	return true;
}

// ported from Snapshot.cpp CSnapshot::Read
std::unique_ptr<Snapshot> Snapshot::Read(const std::vector<uint8_t>& data, std::string* pError,
	IntSize szLegacy)
{
	const char*	pszEOF = "Unexpected end of file.";	// original throws endOfFile
	Reader	fIn(data);
	uint8_t	hb[HEADER_SIZE];
	if (!fIn.Read(hb, HEADER_SIZE)) {
		if (pError)
			*pError = pszEOF;
		return nullptr;
	}
	HEADER	hdr;
	hdr.nFileID = GetU32(hb);
	hdr.nVersion = GetU16(hb + 4);
	hdr.nDrawStateSize = GetU16(hb + 6);
	hdr.nGlobRingSize = GetU16(hb + 8);
	hdr.nRingSize = GetU16(hb + 10);
	if (hdr.nFileID != m_nFileID) {	// if invalid file ID
		return SnapshotV1::Read(data, pError, szLegacy);
	}
	std::vector<uint8_t>	buf(std::max<size_t>({hdr.nDrawStateSize, hdr.nGlobRingSize, hdr.nRingSize}));
	DRAW_STATE	drawState;
	size_t	nStateSize = std::min<size_t>(hdr.nDrawStateSize, DRAW_STATE_SIZE);
	if (!fIn.Read(buf.data(), nStateSize)) {
		if (pError)
			*pError = pszEOF;
		return nullptr;
	}
	DecodeDrawState(buf.data(), nStateSize, drawState);
	// The original doesn't skip a larger (future) draw state or glob ring;
	// it reads only min(size, sizeof) bytes and carries on. Same here.
	if (drawState.nRings < 0
	|| static_cast<uint64_t>(drawState.nRings) * hdr.nRingSize > fIn.Remaining()) {
		// The original would fail allocating or hit end of file here.
		if (pError)
			*pError = drawState.nRings < 0 ? "Invalid ring count." : pszEOF;
		return nullptr;
	}
	std::unique_ptr<Snapshot>	pSnapshot(Alloc(drawState.nRings));
	pSnapshot->m_drawState = drawState;
	size_t	nGlobSize = std::min<size_t>(hdr.nGlobRingSize, GLOB_RING_SIZE);
	if (!fIn.Read(buf.data(), nGlobSize)) {
		if (pError)
			*pError = pszEOF;
		return nullptr;
	}
	DecodeGlobRing(buf.data(), nGlobSize, pSnapshot->m_globRing);
	// Original: if the ring size is current, read all rings in one block;
	// else read min(size, sizeof) bytes per ring. Either way each ring
	// occupies min(nRingSize, sizeof(RING)) bytes in the file.
	size_t	nRingSize = std::min<size_t>(hdr.nRingSize, RING_SIZE);
	for (int iRing = 0; iRing < drawState.nRings; iRing++) {
		if (!fIn.Read(buf.data(), nRingSize)) {
			if (pError)
				*pError = pszEOF;
			return nullptr;
		}
		DecodeRing(buf.data(), nRingSize, pSnapshot->m_aRing[iRing]);
	}
	return pSnapshot;
}

std::unique_ptr<Snapshot> Snapshot::Read(const std::string& sPath, std::string* pError,
	IntSize szLegacy)
{
	std::vector<uint8_t>	data;
	if (!ReadFile(sPath, data)) {	// original throws CFileException
		if (pError)
			*pError = "Can't open file: " + sPath;
		return nullptr;
	}
	return Read(data, pError, szLegacy);
}

namespace {
// ported from Snapshot.h CSnapshot::FormatItem
template <class T>
void FormatItem(const char* pszCaption, const T& val, std::string& sLine)
{
	std::ostringstream	oss;
	oss << val;
	sLine += std::string(pszCaption) + ": " + oss.str() + '\n';
}
void FormatItem(const char* pszCaption, const DPOINT& val, std::string& sLine)
{
	FormatItem(pszCaption, DPoint(val), sLine);
}
} // namespace

// ported from Snapshot.cpp CSnapshot::FormatState
std::string Snapshot::FormatState(const DRAW_STATE& drawState)
{
	std::string	sLine;
	#define STATEDEF(type, name) \
		FormatItem(#name, drawState.name, sLine);
	#include "whorld/WhorldDef.h"
	return sLine;
}

// ported from Snapshot.cpp CSnapshot::FormatRing
std::string Snapshot::FormatRing(int iRing, const RING& ring)
{
	std::string	sLine = "[" + std::to_string(iRing) + "]\n";
	#define RINGDEF(type, name) \
		FormatItem(#name, ring.name, sLine);
	#include "whorld/WhorldDef.h"
	return sLine;
}

// ported from Snapshot.cpp CSnapshot::FormatGlobRing
std::string Snapshot::FormatGlobRing(const GLOB_RING& globRing)
{
	std::string	sLine("[GlobRing]\n");
	#define GLOBRINGDEF(type, name) \
		FormatItem(#name, globRing.name, sLine);
	#include "whorld/WhorldDef.h"
	return sLine;
}

// ported from Snapshot.cpp CSnapshot::DumpToFile
bool Snapshot::DumpToFile(const std::string& sPath) const
{
	std::ofstream	fOut(sPath);
	if (!fOut)
		return false;
	fOut << FormatState(m_drawState);
	for (int iRing = 0; iRing < m_drawState.nRings; iRing++) {	// for each ring
		fOut << FormatRing(iRing, m_aRing[iRing]);
	}
	fOut << FormatGlobRing(m_globRing);
	return static_cast<bool>(fOut);
}

} // namespace whorld
