// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#include "whorld/Osc.h"

#include <cstring>

namespace whorld {
namespace Osc {

namespace {

class Reader {
public:
	Reader(const uint8_t* p, size_t n) : m_p(p), m_n(n) {}
	bool	AtEnd() const { return m_pos >= m_n; }
	size_t	Left() const { return m_n - m_pos; }

	bool	String(std::string& s)	// null-terminated, padded to a multiple of 4
	{
		size_t	end = m_pos;
		while (end < m_n && m_p[end] != 0)
			end++;
		if (end >= m_n)
			return false;
		s.assign(reinterpret_cast<const char*>(m_p + m_pos), end - m_pos);
		m_pos = (end + 4) & ~size_t(3);
		return m_pos <= m_n;
	}
	bool	U32(uint32_t& v)
	{
		if (Left() < 4)
			return false;
		v = uint32_t(m_p[m_pos]) << 24 | uint32_t(m_p[m_pos + 1]) << 16
			| uint32_t(m_p[m_pos + 2]) << 8 | m_p[m_pos + 3];
		m_pos += 4;
		return true;
	}
	bool	U64(uint64_t& v)
	{
		uint32_t	hi, lo;
		if (!U32(hi) || !U32(lo))
			return false;
		v = uint64_t(hi) << 32 | lo;
		return true;
	}
	bool	Skip(size_t n)
	{
		if (Left() < n)
			return false;
		m_pos += n;
		return true;
	}
	const uint8_t*	Here() const { return m_p + m_pos; }

private:
	const uint8_t*	m_p;
	size_t	m_n;
	size_t	m_pos = 0;
};

bool DecodeMessage(const uint8_t* p, size_t n, OscMessage& msg)
{
	Reader	r(p, n);
	if (!r.String(msg.path) || msg.path.empty() || msg.path[0] != '/')
		return false;
	if (r.AtEnd())	// no type tag string: allowed by older senders, no arguments
		return true;
	std::string	tags;
	if (!r.String(tags) || tags.empty() || tags[0] != ',')
		return true;	// arguments we can't read: keep the address
	for (size_t i = 1; i < tags.size(); i++) {
		OscArg	a;
		switch (tags[i]) {
		case 'i':
			{
				uint32_t	v;
				if (!r.U32(v))
					return true;
				a = OscArg::Int(static_cast<int32_t>(v));
			}
			break;
		case 'h':
			{
				uint64_t	v;
				if (!r.U64(v))
					return true;
				a = OscArg::Int(static_cast<int64_t>(v));
			}
			break;
		case 'f':
			{
				uint32_t	v;
				if (!r.U32(v))
					return true;
				float	f;
				std::memcpy(&f, &v, 4);
				a = OscArg::Float(f);
			}
			break;
		case 'd':
			{
				uint64_t	v;
				if (!r.U64(v))
					return true;
				double	d;
				std::memcpy(&d, &v, 8);
				a = OscArg::Float(d);
			}
			break;
		case 's':
		case 'S':
			{
				std::string	s;
				if (!r.String(s))
					return true;
				a = OscArg::String(s);
			}
			break;
		case 'T':
		case 'F':
			a.type = OscArg::BOOL;
			a.i = tags[i] == 'T';
			break;
		case 'N':
		case 'I':
			a.type = OscArg::NIL;
			break;
		default:	// blobs, colors and the rest: stop here
			return true;
		}
		msg.args.push_back(a);
	}
	return true;
}

void DecodeInto(const uint8_t* p, size_t n, std::vector<OscMessage>& out, int nDepth)
{
	static const char	kBundle[] = "#bundle";
	if (n >= 16 && std::memcmp(p, kBundle, 8) == 0) {
		if (nDepth > 8)	// a bundle in a bundle in ...: enough
			return;
		Reader	r(p, n);
		r.Skip(16);	// "#bundle\0" and the time tag (we act at once)
		while (!r.AtEnd()) {
			uint32_t	nSize;
			if (!r.U32(nSize) || nSize > r.Left() || nSize % 4)
				return;
			DecodeInto(r.Here(), nSize, out, nDepth + 1);
			r.Skip(nSize);
		}
		return;
	}
	OscMessage	msg;
	if (DecodeMessage(p, n, msg))
		out.push_back(std::move(msg));
}

void PutString(std::vector<uint8_t>& v, const std::string& s)
{
	v.insert(v.end(), s.begin(), s.end());
	size_t	nPad = 4 - s.size() % 4;	// at least one null
	v.insert(v.end(), nPad, 0);
}

void PutU32(std::vector<uint8_t>& v, uint32_t x)
{
	v.push_back(uint8_t(x >> 24));
	v.push_back(uint8_t(x >> 16));
	v.push_back(uint8_t(x >> 8));
	v.push_back(uint8_t(x));
}

}	// namespace

std::vector<OscMessage> Decode(const uint8_t* pData, size_t nSize)
{
	std::vector<OscMessage>	out;
	if (pData && nSize >= 4 && nSize % 4 == 0)
		DecodeInto(pData, nSize, out, 0);
	return out;
}

std::vector<uint8_t> Encode(const OscMessage& msg)
{
	std::vector<uint8_t>	v;
	PutString(v, msg.path);
	std::string	tags = ",";
	for (const OscArg& a : msg.args) {
		switch (a.type) {
		case OscArg::INT: tags += 'i'; break;
		case OscArg::FLOAT: tags += 'f'; break;
		case OscArg::STRING: tags += 's'; break;
		case OscArg::BOOL: tags += a.i ? 'T' : 'F'; break;
		case OscArg::NIL: tags += 'N'; break;
		}
	}
	PutString(v, tags);
	for (const OscArg& a : msg.args) {
		switch (a.type) {
		case OscArg::INT:
			PutU32(v, static_cast<uint32_t>(static_cast<int32_t>(a.i)));
			break;
		case OscArg::FLOAT:
			{
				float	f = static_cast<float>(a.f);
				uint32_t	x;
				std::memcpy(&x, &f, 4);
				PutU32(v, x);
			}
			break;
		case OscArg::STRING:
			PutString(v, a.s);
			break;
		default:	// T, F and N carry no data
			break;
		}
	}
	return v;
}

}	// namespace Osc
}	// namespace whorld
