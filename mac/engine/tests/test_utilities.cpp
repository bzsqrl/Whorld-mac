// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Tests for HLS, RandList and FormatIO.

#include "TestHarness.h"
#include "whorld/FormatIO.h"
#include "whorld/HLS.h"
#include "whorld/RandList.h"
#include "whorld/Random.h"
#include "whorld/Types.h"

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

using namespace whorld;

TEST(HlsPrimaries) {
	double	r, g, b;
	HLS::hls2rgb(0, 0.5, 1, r, g, b);
	CHECK_NEAR(r, 1, 1e-12); CHECK_NEAR(g, 0, 1e-12); CHECK_NEAR(b, 0, 1e-12);
	HLS::hls2rgb(120, 0.5, 1, r, g, b);
	CHECK_NEAR(r, 0, 1e-12); CHECK_NEAR(g, 1, 1e-12); CHECK_NEAR(b, 0, 1e-12);
	HLS::hls2rgb(240, 0.5, 1, r, g, b);
	CHECK_NEAR(r, 0, 1e-12); CHECK_NEAR(g, 0, 1e-12); CHECK_NEAR(b, 1, 1e-12);
	HLS::hls2rgb(60, 0.25, 0.5, r, g, b);	// dark desaturated yellow
	CHECK_NEAR(r, 0.375, 1e-12); CHECK_NEAR(g, 0.375, 1e-12); CHECK_NEAR(b, 0.125, 1e-12);
}

TEST(HlsGrayAndWhite) {
	double	r, g, b;
	HLS::hls2rgb(200, 0.3, 0, r, g, b);
	CHECK_NEAR(r, 0.3, 1e-12); CHECK_NEAR(g, 0.3, 1e-12); CHECK_NEAR(b, 0.3, 1e-12);
	HLS::hls2rgb(0, 1, 1, r, g, b);
	CHECK_NEAR(r, 1, 1e-12); CHECK_NEAR(g, 1, 1e-12); CHECK_NEAR(b, 1, 1e-12);
}

TEST(HlsHueOutsideRangeWrapsOnce) {
	// mkrgb only wraps by one turn: hue 400 behaves like 40
	double	r1, g1, b1, r2, g2, b2;
	HLS::hls2rgb(400, 0.5, 1, r1, g1, b1);
	HLS::hls2rgb(40, 0.5, 1, r2, g2, b2);
	CHECK_NEAR(r1, r2, 1e-12); CHECK_NEAR(g1, g2, 1e-12); CHECK_NEAR(b1, b2, 1e-12);
}

TEST(HlsRoundTrip) {
	for (double h = 0; h < 360; h += 17) {
		for (double l = 0.1; l < 1; l += 0.2) {
			for (double s = 0.1; s <= 1; s += 0.3) {
				double	r, g, b, h2, l2, s2;
				HLS::hls2rgb(h, l, s, r, g, b);
				HLS::rgb2hls(r, g, b, h2, l2, s2);
				CHECK_NEAR(h2, h, 1e-9);
				CHECK_NEAR(l2, l, 1e-9);
				CHECK_NEAR(s2, s, 1e-9);
			}
		}
	}
}

TEST(RandListIsPermutation) {
	whorld::srand(1);
	RandList	list(20);
	CHECK_EQ(list.GetSize(), 20);
	CHECK_EQ(list.GetAvail(), 0);
	for (int pass = 0; pass < 3; pass++) {
		std::vector<int>	seen;
		for (int i = 0; i < 20; i++)
			seen.push_back(list.GetNext());
		CHECK_EQ(list.GetAvail(), 0);
		std::sort(seen.begin(), seen.end());
		for (int i = 0; i < 20; i++)
			CHECK_EQ(seen[i], i);
	}
}

TEST(RandListRand) {
	CHECK_EQ(RandList::Rand(0), -1);
	CHECK_EQ(RandList::Rand(-3), -1);
	for (int i = 0; i < 500; i++) {
		int	r = RandList::Rand(7);
		CHECK(r >= 0 && r < 7);
	}
	whorld::srand(1);
	CHECK_EQ(RandList::Rand(1000), Trunc(41 / double(kRandMax) * 1000));
}

TEST(FormatValToStr) {
	std::string	s;
	int32_t	i = -42;
	CHECK(FormatIO::ValToStr(FIO_INT, &i, s));
	CHECK_EQ(s, std::string("-42"));
	uint32_t	u = 7;
	CHECK(FormatIO::ValToStr(FIO_UINT, &u, s));
	CHECK_EQ(s, std::string("7"));
	double	d = 0.186261;
	CHECK(FormatIO::ValToStr(FIO_DOUBLE, &d, s));
	CHECK_EQ(s, std::string("0.186261"));
	d = 1.0 / 3;
	CHECK(FormatIO::ValToStr(FIO_DOUBLE, &d, s));
	CHECK_EQ(s, std::string("0.333333"));	// %g keeps 6 significant digits
	d = 1e-7;
	CHECK(FormatIO::ValToStr(FIO_DOUBLE, &d, s));
	CHECK_EQ(s, std::string("1e-007"));	// msvcr110 prints three exponent digits
	d = 7.22068e-5;
	CHECK(FormatIO::ValToStr(FIO_DOUBLE, &d, s));
	CHECK_EQ(s, std::string("7.22068e-005"));
	d = -1.5e100;
	CHECK(FormatIO::ValToStr(FIO_DOUBLE, &d, s));
	CHECK_EQ(s, std::string("-1.5e+100"));
	d = 1234567;
	CHECK(FormatIO::ValToStr(FIO_DOUBLE, &d, s));
	CHECK_EQ(s, std::string("1.23457e+006"));
	DPOINT	pt = {0.5, -0.25};
	CHECK(FormatIO::ValToStr(FIO_DPOINT, &pt, s));
	CHECK_EQ(s, std::string("0.5 -0.25"));
	bool	b = true;
	CHECK(FormatIO::ValToStr(FIO_bool, &b, s));
	CHECK_EQ(s, std::string("1"));
	CHECK(!FormatIO::ValToStr(99, &i, s));
}

TEST(FormatValToStrPrecision) {
	std::string	s;
	double	d = 3.14159;
	CHECK(FormatIO::ValToStr(FIO_DOUBLE, &d, s, 2));
	CHECK_EQ(s, std::string("3.14"));
	int32_t	i = 5;
	CHECK(FormatIO::ValToStr(FIO_INT, &i, s, 2));	// falls back to default format
	CHECK_EQ(s, std::string("5"));
}

TEST(FormatStrToVal) {
	int32_t	i = 0;
	CHECK(FormatIO::StrToVal(FIO_INT, "-17", &i));
	CHECK_EQ(i, -17);
	double	d = 0;
	CHECK(FormatIO::StrToVal(FIO_DOUBLE, "2.5", &d));
	CHECK_EQ(d, 2.5);
	DPOINT	pt = {0, 0};
	CHECK(FormatIO::StrToVal(FIO_DPOINT, "0.25 0.75", &pt));
	CHECK_EQ(pt.x, 0.25);
	CHECK_EQ(pt.y, 0.75);
	float	f = 0;
	CHECK(FormatIO::StrToVal(FIO_FLOAT, "1.5", &f));
	CHECK_EQ(f, 1.5f);
}

TEST(FormatStrToValByteReturnsFalseButStores) {
	// Upstream quirk: the FIO_BYTE case falls through to default.
	bool	b = false;
	CHECK(!FormatIO::StrToVal(FIO_bool, "1", &b));
	CHECK_EQ(b, true);
	uint8_t	n = 0;
	CHECK(!FormatIO::StrToVal(FIO_BYTE, "200", &n));
	CHECK_EQ(int(n), 200);
}

int main() { return RunAllTests(); }
