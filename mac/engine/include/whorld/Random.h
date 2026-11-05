// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Replacement for the C runtime rand()/srand() used by the original.
//
// Windows Whorld is built with MSVC, whose rand() is a per-thread linear
// congruential generator with RAND_MAX = 0x7fff, seeded with 1 on each
// thread. Whorld never calls srand, so its random sequence is the same on
// every run. Reproducing that generator here keeps random waveforms and
// random origins identical to Windows (and the same on macOS and Linux).
//
// Ported code replaces `rand()` with `whorld::rand()` and `RAND_MAX` with
// `whorld::kRandMax`; the arithmetic around them is unchanged.

#include <cstdint>

namespace whorld {

constexpr int kRandMax = 0x7fff;	// MSVC RAND_MAX

namespace detail {
inline uint32_t& RandState()
{
	thread_local uint32_t state = 1;	// MSVC initial seed, per thread
	return state;
}
} // namespace detail

inline void srand(unsigned int seed)
{
	detail::RandState() = seed;
}

inline int rand()
{
	uint32_t&	s = detail::RandState();
	s = s * 214013u + 2531011u;
	return static_cast<int>((s >> 16) & 0x7fff);
}

} // namespace whorld
