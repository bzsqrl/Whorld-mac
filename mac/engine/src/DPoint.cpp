// Copyleft 2005 Chris Korda (original DPoint.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "whorld/Types.h"

#include <cmath>

namespace whorld {

// ported from DPoint.cpp DPoint::Equal
bool DPoint::Equal(double a, double b)
{
	return std::fabs(a - b) < m_fEpsilon;	// less than this and they're equal
}

} // namespace whorld
