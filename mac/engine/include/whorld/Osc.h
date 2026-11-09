// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Open Sound Control 1.0 messages (new in the Mac port; Windows Whorld has
// no OSC): decoding packets (messages and bundles) and encoding messages.
// Arguments of types i, f, d, h, s, S, T, F, N and I are understood; others
// end the argument list. Big-endian, 4-byte aligned, as the spec says.

#include <cstdint>
#include <string>
#include <vector>

namespace whorld {

struct OscArg {
	enum Type { INT, FLOAT, STRING, BOOL, NIL };
	Type	type = NIL;
	int64_t	i = 0;		// INT, BOOL (0 or 1)
	double	f = 0;		// FLOAT
	std::string	s;		// STRING

	static OscArg	Int(int64_t v) { OscArg a; a.type = INT; a.i = v; return a; }
	static OscArg	Float(double v) { OscArg a; a.type = FLOAT; a.f = v; return a; }
	static OscArg	String(const std::string& v) { OscArg a; a.type = STRING; a.s = v; return a; }
	bool	IsNumber() const { return type == INT || type == FLOAT || type == BOOL; }
	double	Number() const { return type == FLOAT ? f : static_cast<double>(i); }
};

struct OscMessage {
	std::string	path;
	std::vector<OscArg>	args;
};

namespace Osc {

// Messages in a packet (a bundle's, recursively); empty if it isn't valid OSC.
std::vector<OscMessage>	Decode(const uint8_t* pData, size_t nSize);

// One message as a packet. Arguments: INT as i, FLOAT as f, STRING as s,
// BOOL as T or F, NIL as N.
std::vector<uint8_t>	Encode(const OscMessage& msg);

}	// namespace Osc

}	// namespace whorld
