// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// printf-style formatting that matches the C runtime Windows Whorld is
// built with (toolset v110, msvcr110). That runtime prints at least three
// exponent digits for %e and %g ("7.22068e-005"); C99 runtimes print two
// ("7.22068e-05"). Patch files from Windows contain the three-digit form,
// so the port writes it too. sscanf reads both forms.

#include <cctype>
#include <cstdio>
#include <string>

namespace whorld {
namespace detail {

// Pad every exponent in s to at least three digits. An exponent is
// recognized as a digit or '.', then 'e' or 'E', a sign, and digits.
inline void PadExponents(std::string& s)
{
	for (size_t i = 1; i + 2 < s.size(); i++) {
		char	c = s[i];
		char	prev = s[i - 1];
		if ((c != 'e' && c != 'E') || !(std::isdigit(static_cast<unsigned char>(prev)) || prev == '.'))
			continue;
		if (s[i + 1] != '+' && s[i + 1] != '-')
			continue;
		size_t	iDigits = i + 2;
		size_t	iEnd = iDigits;
		while (iEnd < s.size() && std::isdigit(static_cast<unsigned char>(s[iEnd])))
			iEnd++;
		size_t	nDigits = iEnd - iDigits;
		if (nDigits > 0 && nDigits < 3)
			s.insert(iDigits, 3 - nDigits, '0');
		i = iEnd;
	}
}

// snprintf into a std::string, then apply the msvcr110 exponent width.
// Replaces CString::Format for numeric output.
template <typename... Args>
std::string FormatMsvc(const char* fmt, Args... args)
{
	int	n = std::snprintf(nullptr, 0, fmt, args...);
	if (n < 0)
		return std::string();
	std::string	s(static_cast<size_t>(n) + 1, '\0');
	std::snprintf(&s[0], s.size(), fmt, args...);
	s.resize(static_cast<size_t>(n));
	PadExponents(s);
	return s;
}

} // namespace detail
} // namespace whorld
