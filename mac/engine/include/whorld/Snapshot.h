// Copyleft 2025 Chris Korda (original Snapshot.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from Snapshot.h CSnapshot: a captured drawing state (.whs).
//
// The original is a variable-size struct (header data followed by a ring
// array) written to disk with a raw memory dump. Here the rings live in a
// std::vector, and the disk format is encoded and decoded field by field
// at the MSVC x64 offsets (see the k*Size constants and Snapshot.cpp).
//
// File layout (little-endian):
//   HEADER      12 bytes: u32 file ID 'WHS2', u16 version (1),
//               u16 sizeof(DRAW_STATE), u16 sizeof(GLOB_RING), u16 sizeof(RING)
//   DRAW_STATE  nDrawStateSize bytes (40 in V2.0.20)
//   GLOB_RING   nGlobRingSize bytes (104)
//   RING[n]     nRings * nRingSize bytes (192 each)
// Smaller sizes come from older versions: missing trailing members read as
// zero. Files without the 'WHS2' ID are V1 snapshots (see SnapshotV1.h).

#include "whorld/WhorldBase.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace whorld {

class Snapshot : public WhorldBase {
public:
// Constants
	enum {	// flags
		SF_V1	= 0x01,			// true if V1 legacy snapshot
	};
	static const uint32_t m_nFileID;
	static const uint16_t m_nFileVersion;
	enum {	// sizes of the structs as laid out by MSVC for x64
		HEADER_SIZE = 12,
		DRAW_STATE_SIZE = 40,
		GLOB_RING_SIZE = 104,
		RING_SIZE = 192,
	};
	static const IntSize DEFAULT_LEGACY_SIZE;	// 800 x 600; COptions default

// Types (public here so the binary codecs can name them)
	using WhorldBase::DRAW_STATE;
	using WhorldBase::GLOB_RING;
	using WhorldBase::RING;

// Public data
	DRAW_STATE	m_drawState;	// drawing state
	GLOB_RING	m_globRing;		// global ring offsets
	std::vector<RING>	m_aRing;	// rings; size must equal m_drawState.nRings

// Attributes
	int		GetSize() const;	// size on disk, excluding header

// Operations
	static uint32_t	MakeFourCC(char ch0, char ch1, char ch2, char ch3);
	static std::unique_ptr<Snapshot>	Alloc(int nRings);
	static bool	Write(const Snapshot* pSnapshot, const std::string& sPath, std::string* pError = nullptr);
	static std::unique_ptr<Snapshot>	Read(const std::string& sPath, std::string* pError = nullptr,
		IntSize szLegacy = DEFAULT_LEGACY_SIZE);
	static std::unique_ptr<Snapshot>	Read(const std::vector<uint8_t>& data, std::string* pError = nullptr,
		IntSize szLegacy = DEFAULT_LEGACY_SIZE);
	static std::vector<uint8_t>	Encode(const Snapshot& snapshot);	// header and body
	static uint32_t	GetSize(int nRings);

// Binary codecs, shared with movie files. Decode reads the first nSize
// bytes (at most the full struct size) into a zeroed struct.
	static void	DecodeDrawState(const uint8_t* p, size_t nSize, DRAW_STATE& ds);
	static void	DecodeGlobRing(const uint8_t* p, size_t nSize, GLOB_RING& gr);
	static void	DecodeRing(const uint8_t* p, size_t nSize, RING& ring);
	static void	EncodeDrawState(const DRAW_STATE& ds, uint8_t* p);	// DRAW_STATE_SIZE bytes
	static void	EncodeGlobRing(const GLOB_RING& gr, uint8_t* p);	// GLOB_RING_SIZE bytes
	static void	EncodeRing(const RING& ring, uint8_t* p);			// RING_SIZE bytes

// Formatting
	static std::string	FormatState(const DRAW_STATE& drawState);
	static std::string	FormatRing(int iRing, const RING& ring);
	static std::string	FormatGlobRing(const GLOB_RING& globRing);
	bool	DumpToFile(const std::string& sPath) const;

protected:
// Types
	struct HEADER {
		uint32_t	nFileID;		// file identifier
		uint16_t	nVersion;		// version number
		uint16_t	nDrawStateSize;	// size of DRAW_STATE in bytes
		uint16_t	nGlobRingSize;	// size of GLOB_RING in bytes
		uint16_t	nRingSize;		// size of RING in bytes
	};
};

inline uint32_t Snapshot::MakeFourCC(char ch0, char ch1, char ch2, char ch3)
{
	return static_cast<uint32_t>(static_cast<uint8_t>(ch0))
		| (static_cast<uint32_t>(static_cast<uint8_t>(ch1)) << 8)
		| (static_cast<uint32_t>(static_cast<uint8_t>(ch2)) << 16)
		| (static_cast<uint32_t>(static_cast<uint8_t>(ch3)) << 24);
}

inline int Snapshot::GetSize() const
{
	return static_cast<int>(GetSize(m_drawState.nRings));
}

} // namespace whorld
