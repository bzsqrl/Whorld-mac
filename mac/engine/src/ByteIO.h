// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Explicit little-endian encoding and decoding for the binary file formats
// (.whs, .whm), which are raw MSVC struct dumps. Never memcpy a whole
// struct: field sizes and padding differ between MSVC and clang.

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace whorld {
namespace bin {

inline uint16_t GetU16(const uint8_t* p)
{
	return static_cast<uint16_t>(p[0] | (p[1] << 8));
}

inline uint32_t GetU32(const uint8_t* p)
{
	return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8)
		| (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

inline uint64_t GetU64(const uint8_t* p)
{
	return static_cast<uint64_t>(GetU32(p)) | (static_cast<uint64_t>(GetU32(p + 4)) << 32);
}

inline int16_t GetI16(const uint8_t* p) { return static_cast<int16_t>(GetU16(p)); }
inline int32_t GetI32(const uint8_t* p) { return static_cast<int32_t>(GetU32(p)); }
inline int64_t GetI64(const uint8_t* p) { return static_cast<int64_t>(GetU64(p)); }

inline float GetF32(const uint8_t* p)
{
	uint32_t	u = GetU32(p);
	float	f;
	std::memcpy(&f, &u, sizeof(f));
	return f;
}

inline double GetF64(const uint8_t* p)
{
	uint64_t	u = GetU64(p);
	double	d;
	std::memcpy(&d, &u, sizeof(d));
	return d;
}

inline bool GetBool(const uint8_t* p)	// MSVC bool is one byte
{
	return p[0] != 0;
}

inline void PutU16(uint8_t* p, uint16_t v)
{
	p[0] = static_cast<uint8_t>(v);
	p[1] = static_cast<uint8_t>(v >> 8);
}

inline void PutU32(uint8_t* p, uint32_t v)
{
	for (int i = 0; i < 4; i++)
		p[i] = static_cast<uint8_t>(v >> (8 * i));
}

inline void PutU64(uint8_t* p, uint64_t v)
{
	for (int i = 0; i < 8; i++)
		p[i] = static_cast<uint8_t>(v >> (8 * i));
}

inline void PutI16(uint8_t* p, int16_t v) { PutU16(p, static_cast<uint16_t>(v)); }
inline void PutI32(uint8_t* p, int32_t v) { PutU32(p, static_cast<uint32_t>(v)); }

inline void PutF32(uint8_t* p, float f)
{
	uint32_t	u;
	std::memcpy(&u, &f, sizeof(u));
	PutU32(p, u);
}

inline void PutF64(uint8_t* p, double d)
{
	uint64_t	u;
	std::memcpy(&u, &d, sizeof(u));
	PutU64(p, u);
}

inline void PutBool(uint8_t* p, bool b)
{
	p[0] = b ? 1 : 0;
}

// Sequential reader over a byte buffer. Every read checks bounds.
class Reader {
public:
	Reader(const uint8_t* pData, size_t nSize) : m_pData(pData), m_nSize(nSize) {}
	explicit Reader(const std::vector<uint8_t>& data) : Reader(data.data(), data.size()) {}
	size_t	Pos() const { return m_nPos; }
	size_t	Remaining() const { return m_nSize - m_nPos; }
	void	Seek(size_t nPos) { m_nPos = nPos <= m_nSize ? nPos : m_nSize; }
	bool	Read(void* pBuf, size_t nCount)
	{
		if (nCount > Remaining())
			return false;
		std::memcpy(pBuf, m_pData + m_nPos, nCount);
		m_nPos += nCount;
		return true;
	}
	bool	Skip(size_t nCount)
	{
		if (nCount > Remaining())
			return false;
		m_nPos += nCount;
		return true;
	}
	bool	ReadU8(uint8_t& v) { return Read(&v, 1); }
	bool	ReadU16(uint16_t& v) { uint8_t b[2]; if (!Read(b, 2)) return false; v = GetU16(b); return true; }
	bool	ReadU32(uint32_t& v) { uint8_t b[4]; if (!Read(b, 4)) return false; v = GetU32(b); return true; }
	bool	ReadU64(uint64_t& v) { uint8_t b[8]; if (!Read(b, 8)) return false; v = GetU64(b); return true; }
	bool	ReadI32(int32_t& v) { uint32_t u; if (!ReadU32(u)) return false; v = static_cast<int32_t>(u); return true; }

private:
	const uint8_t*	m_pData;
	size_t	m_nSize;
	size_t	m_nPos = 0;
};

// Read a whole file into memory. Returns false if it can't be opened or read.
bool ReadFile(const std::string& sPath, std::vector<uint8_t>& data);

// Write a buffer to a file, replacing it. Returns false on any error.
bool WriteFile(const std::string& sPath, const std::vector<uint8_t>& data);

} // namespace bin
} // namespace whorld
