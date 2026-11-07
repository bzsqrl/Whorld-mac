// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Tests for Round.h, Types.h (DPoint) and Random.h.

#include "TestHarness.h"
#include "whorld/Random.h"
#include "whorld/Round.h"
#include "whorld/Types.h"

#include <climits>
#include <cmath>
#include <limits>

using namespace whorld;

TEST(RoundHalfToEvenLikeSSE) {
	CHECK_EQ(Round(0.5), 0);
	CHECK_EQ(Round(1.5), 2);
	CHECK_EQ(Round(2.5), 2);
	CHECK_EQ(Round(-0.5), 0);
	CHECK_EQ(Round(-1.5), -2);
	CHECK_EQ(Round(2.4999), 2);
	CHECK_EQ(Round(-2.6), -3);
	CHECK_EQ(Round64(4503599627370497.0), 4503599627370497LL);
}

TEST(TruncTowardZero) {
	CHECK_EQ(Trunc(1.9), 1);
	CHECK_EQ(Trunc(-1.9), -1);
	CHECK_EQ(Trunc64(-7.99), -7LL);
}

TEST(OutOfRangeGivesIntegerIndefinite) {
	CHECK_EQ(Round(3e9), INT_MIN);
	CHECK_EQ(Round(-3e9), INT_MIN);
	CHECK_EQ(Trunc(std::numeric_limits<double>::quiet_NaN()), INT_MIN);
	CHECK_EQ(Trunc(2147483647.9), INT_MAX);
	CHECK_EQ(Trunc(-2147483648.9), INT_MIN);
	CHECK_EQ(Round64(1e19), std::numeric_limits<int64_t>::min());
}

TEST(DPointArithmetic) {
	DPoint	a(1, 2), b(3, 5);
	CHECK(a + b == DPoint(4, 7));
	CHECK(b - a == DPoint(2, 3));
	CHECK(a * b == DPoint(3, 10));
	CHECK(b / DPoint(3, 5) == DPoint(1, 1));
	CHECK(a * 2.0 == DPoint(2, 4));
	DPoint	c = a;
	c += 1.0;
	CHECK(c == DPoint(2, 3));
	CHECK_EQ(c[0], 2.0);
	CHECK_EQ(c[1], 3.0);
	c[1] = 9;
	CHECK_EQ(c.y, 9.0);
}

TEST(DPointEqualityUsesEpsilon) {
	CHECK(DPoint(1, 1) == DPoint(1 + 1e-11, 1 - 1e-11));
	CHECK(DPoint(1, 1) != DPoint(1 + 1e-9, 1));
}

TEST(DPointConversions) {
	IntPoint	ip = DPoint(2.5, -3.5);	// half to even
	CHECK_EQ(ip.x, 2);
	CHECK_EQ(ip.y, -4);
	PointF	pf = DPoint(0.1, 0.2);
	CHECK_EQ(pf.x, 0.1f);
	CHECK_EQ(pf.y, 0.2f);
	DPoint	fromSize(SizeF{640, 480});
	CHECK(fromSize == DPoint(640, 480));
}

TEST(RandMatchesMsvcSequence) {
	// MSVC rand() with the default seed of 1
	whorld::srand(1);
	const int expected[] = {41, 18467, 6334, 26500, 19169, 15724, 11478, 29358, 26962, 24464};
	for (int v : expected)
		CHECK_EQ(whorld::rand(), v);
}

TEST(RandRestartsWithSeed) {
	whorld::srand(12345);
	int	a = whorld::rand(), b = whorld::rand();
	whorld::srand(12345);
	CHECK_EQ(whorld::rand(), a);
	CHECK_EQ(whorld::rand(), b);
	for (int i = 0; i < 1000; i++) {
		int	r = whorld::rand();
		CHECK(r >= 0 && r <= kRandMax);
	}
}

int main() { return RunAllTests(); }
