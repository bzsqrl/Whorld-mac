// Copyleft 2005 Chris Korda (original hls.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "whorld/HLS.h"

#include <algorithm>

namespace whorld {

// ported from hls.cpp CHLS::mkrgb
double HLS::mkrgb(double H, double M1, double M2)
{
	if (H < 0)
		H += 360;
	else if (H > 360)
		H -= 360;
	if (H < 60)
		return M1 + (M2 - M1) * H / 60;
	else if (H >= 60 && H < 180)
		return M2;
	else if (H >= 180 && H < 240)
		return M1 + (M2 - M1) * (240 - H) / 60;
	else
		return M1;
}

// ported from hls.cpp CHLS::hls2rgb
void HLS::hls2rgb(double H, double L, double S,
				  double& R, double &G, double &B)
{
	double  M1, M2;
	if (L <= 0.5)
		M2 = L + L * S;
	else
		M2 = L + S - L * S;
	M1 = 2 * L - M2;
	R = mkrgb(H + 120, M1, M2);
	G = mkrgb(H, M1, M2);
	B = mkrgb(H - 120, M1, M2);
}

// ported from hls.cpp CHLS::rgb2hls
void HLS::rgb2hls(double R, double G, double B,
				  double& H, double& L, double& S)
{
	double	M1 = std::max(std::max(R, G), B);
	double	M2 = std::min(std::min(R, G), B);
	L = (M1 + M2) / 2;
	if (M1 == M2) {
		S = 0;
		H = 0;
	} else {
		double	delta = M1 - M2;
		if (L <= 0.5)
			S = delta / (M1 + M2);
		else
			S = delta / (2 - M1 - M2);
		if (M1 == R)
			H = (G - B) / delta;
		else if (M1 == G)
			H = 2 + (B - R) / delta;
		else
			H = 4 + (R - G) / delta;
		H *= 60;
		if (H < 0)
			H += 360;
	}
}

} // namespace whorld
