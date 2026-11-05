// Copyleft 2005 Chris Korda (original FormatIO.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from FormatIO.h: type-driven formatted I/O, used for main
// properties in patch files. Formatting uses the C locale's decimal point,
// as on Windows.

#include <string>

namespace whorld {

enum {
	FIO_INT,
	FIO_UINT,
	FIO_FLOAT,
	FIO_DOUBLE,
	FIO_DPOINT,
	FIO_SHORT,
	FIO_USHORT,
	FIO_BYTE
};

#define FIO_bool FIO_BYTE
#define FIO_DPoint FIO_DPOINT

class FormatIO {
public:
	static	bool	ValToStr(int Type, const void* Val, std::string& Str);
	static	bool	ValToStr(int Type, const void* Val, std::string& Str, int Precision);
	static	bool	StrToVal(int Type, const char* Str, void *Val);
};

} // namespace whorld
