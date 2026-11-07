// Copyleft 2005 Chris Korda (original hls.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from hls.h: convert between RGB and HLS color space

namespace whorld {

class HLS {
public:
	static	void	hls2rgb(double H, double L, double S,
							double& R, double &G, double &B);
	static	void	rgb2hls(double R, double G, double B,
							double& H, double& L, double& S);
private:
	static	double	mkrgb(double H, double M1, double M2);
};

} // namespace whorld
