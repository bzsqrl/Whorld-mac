// Copyleft 2005 Chris Korda (original FormatIO.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "whorld/FormatIO.h"
#include "whorld/Types.h"

#include <cstdint>
#include <cstdio>

namespace whorld {

namespace {
template <typename... Args>
std::string Format(const char* fmt, Args... args)
{
	char	buf[128];
	int	n = std::snprintf(buf, sizeof(buf), fmt, args...);
	if (n < 0)
		return std::string();
	if (static_cast<size_t>(n) < sizeof(buf))
		return std::string(buf, static_cast<size_t>(n));
	std::string	s(static_cast<size_t>(n) + 1, '\0');
	std::snprintf(&s[0], s.size(), fmt, args...);
	s.resize(static_cast<size_t>(n));
	return s;
}
} // namespace

#define VALTOSTR(id, type, fmt) case FIO_##id: Str = Format(fmt, *((const type *)Val)); break;
#define VALTOSTR_PREC(id, type, fmt, prec) case FIO_##id: Str = Format(fmt, prec, *((const type *)Val)); break;
#define STRTOVAL(id, type, fmt) case FIO_##id: std::sscanf(Str, fmt, (type *)Val); break;

// ported from FormatIO.cpp CFormatIO::ValToStr
bool FormatIO::ValToStr(int Type, const void* Val, std::string& Str)
{
	switch (Type) {
	VALTOSTR(INT,		int32_t,	"%d");
	VALTOSTR(UINT,		uint32_t,	"%u");
	case FIO_FLOAT:
		Str = Format("%g", static_cast<double>(*((const float *)Val)));
		break;
	VALTOSTR(DOUBLE,	double,		"%g");
	case FIO_DPOINT:
		Str = Format("%g %g", ((const DPOINT *)Val)->x, ((const DPOINT *)Val)->y);
		break;
	case FIO_SHORT:
		Str = Format("%hd", static_cast<int>(*((const int16_t *)Val)));
		break;
	case FIO_USHORT:
		Str = Format("%hu", static_cast<unsigned>(*((const uint16_t *)Val)));
		break;
	case FIO_BYTE:
		Str = Format("%u", static_cast<unsigned>(*((const uint8_t *)Val)));
		break;
	default:
		return false;
	}
	return true;
}

// ported from FormatIO.cpp CFormatIO::ValToStr (with precision)
bool FormatIO::ValToStr(int Type, const void* Val, std::string& Str, int Precision)
{
	switch (Type) {
	case FIO_FLOAT:
		Str = Format("%.*f", Precision, static_cast<double>(*((const float *)Val)));
		break;
	VALTOSTR_PREC(DOUBLE,	double,	"%.*f", Precision);
	default:
		return ValToStr(Type, Val, Str);
	}
	return true;
}

// ported from FormatIO.cpp CFormatIO::StrToVal
bool FormatIO::StrToVal(int Type, const char* Str, void *Val)
{
	switch (Type) {
	STRTOVAL(INT,		int32_t,	"%d");
	STRTOVAL(UINT,		uint32_t,	"%u");
	STRTOVAL(FLOAT,		float,		"%f");
	STRTOVAL(DOUBLE,	double,		"%lf");
	case FIO_DPOINT:
		std::sscanf(Str, "%lf %lf", &((DPOINT *)Val)->x, &((DPOINT *)Val)->y);
		break;
	STRTOVAL(SHORT,		int16_t,	"%hd");
	STRTOVAL(USHORT,	uint16_t,	"%hu");
	case FIO_BYTE:
		{
			int	i = 0;	// original leaves this uninitialized if the scan fails
			std::sscanf(Str, "%d", &i);
			*((uint8_t *)Val) = static_cast<uint8_t>(i);
		}
		// The original has no break here, so FIO_BYTE (and FIO_bool) falls
		// through to default and returns false even though the value was
		// stored. Preserved; see PORT_PLAN.md "Upstream notes".
		[[fallthrough]];
	default:
		return false;
	}
	return true;
}

} // namespace whorld
