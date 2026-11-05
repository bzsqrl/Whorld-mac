// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyleft 2025 Chris Korda (original Whorld); port Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#include "TestHarness.h"
#include "whorld/Version.h"

#include <string>

TEST(EngineVersionIsSet) {
	CHECK(std::string(whorld::EngineVersion()).size() > 0);
}

TEST(UpstreamBaselineMatchesPlan) {
	CHECK_EQ(std::string(whorld::UpstreamBaseline()), std::string("2.0.20 (5b5de69)"));
}

int main() { return RunAllTests(); }
