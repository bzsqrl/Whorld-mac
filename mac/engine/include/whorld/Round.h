// Copyleft 2012 Chris Korda (original Round.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from Round.h
//
// The Windows x64 build implements these with SSE2 cvtsd2si / cvttsd2si.
// Behavior that must be preserved:
//   - Round uses the current rounding mode (default: round half to even),
//     so Round(0.5) == 0 and Round(2.5) == 2.
//   - NaN or out-of-range input yields the "integer indefinite" value,
//     INT_MIN (or INT64_MIN for the 64-bit versions).

#include <cfenv>
#include <cmath>
#include <cstdint>
#include <limits>

namespace whorld {

namespace detail {
template <typename I> inline I ConvertIndefinite(double x)
{
	// valid range for a conversion that doesn't overflow
	constexpr double lo = static_cast<double>(std::numeric_limits<I>::min());
	constexpr double hi = -lo;	// 2^31 or 2^63, exactly representable
	if (!(x >= lo && x < hi))	// also catches NaN
		return std::numeric_limits<I>::min();
	return static_cast<I>(x);
}
} // namespace detail

inline int Round(double x)	// round to 32-bit integer
{
	return detail::ConvertIndefinite<int32_t>(std::nearbyint(x));
}

inline int Trunc(double x)	// truncate to 32-bit integer
{
	return detail::ConvertIndefinite<int32_t>(std::trunc(x));
}

inline int64_t Round64(double x)	// round to 64-bit integer
{
	return detail::ConvertIndefinite<int64_t>(std::nearbyint(x));
}

inline int64_t Trunc64(double x)	// truncate to 64-bit integer
{
	return detail::ConvertIndefinite<int64_t>(std::trunc(x));
}

} // namespace whorld
