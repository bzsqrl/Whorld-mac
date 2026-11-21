// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Playlist auto-advance (Mac addition): AutoAdvance.

#include "TestHarness.h"
#include "whorld/AutoAdvance.h"
#include "whorld/Modulation.h"

#include <cmath>
#include <vector>

using namespace whorld;

namespace {

const double	kDt = 1.0 / 60;

// A steady beat at fBpm, from fPos at time 0
struct Music {
	double	fBpm = 120;
	double	fPos = 0;
	bool	bBeat = true;
	uint32_t	nMoves = 0;
	ModSources	Next(double dt) {
		fPos += dt * fBpm / 60;
		ModSources	s;
		s.bBeat = bBeat;
		s.fBeatPos = fPos;
		s.fTempo = bBeat ? fBpm : 0;
		s.nBeatMoves = nMoves;
		return s;
	}
};

// the beat positions (by the music) at which it advanced, over nFrames
std::vector<double> Run(AutoAdvance& aa, Music& m, int nFrames, bool bPaused = false)
{
	std::vector<double>	at;
	for (int i = 0; i < nFrames; i++) {
		ModSources	s = m.Next(kDt);
		if (aa.Step(kDt, bPaused, s))
			at.push_back(m.fPos);
	}
	return at;
}

}	// namespace

TEST(SecondsCountWhileRunning) {
	AutoAdvance	aa;
	aa.SetLength(2, AutoAdvance::UNIT_Seconds);
	Music	m;
	CHECK(Run(aa, m, 300).empty());	// not started
	aa.Start();
	auto	at = Run(aa, m, 60 * 7 + 1);	// 7 s: at 2, 4, 6
	CHECK_EQ(at.size(), size_t(3));
	// paused: no count
	CHECK(Run(aa, m, 600, true).empty());
	// a hand-played patch counts from then
	Run(aa, m, 60);	// 1 s since 6 s
	aa.Restart();
	CHECK(Run(aa, m, 60 + 30).empty());	// 1.5 s
	CHECK_EQ(Run(aa, m, 60).size(), size_t(1));	// then at 2
	aa.Stop();
	CHECK(Run(aa, m, 600).empty());
}

TEST(BeatsSwitchOnTheBeat) {
	AutoAdvance	aa;
	aa.SetLength(8, AutoAdvance::UNIT_Beats);
	Music	m;
	m.fPos = 3.4;	// Play pressed between beats
	Run(aa, m, 1);
	aa.Start();
	auto	at = Run(aa, m, 60 * 20);	// 40 beats at 120 BPM
	CHECK(at.size() >= 4);
	for (double p : at)	// each on a beat (within a frame's travel)
		CHECK(p - std::floor(p) < 2.0 / 60 + 1e-9);
	for (size_t i = 1; i < at.size(); i++)
		CHECK_NEAR(at[i] - at[i - 1], 8, 2.0 / 60);
	auto	st = aa.GetStatus();
	CHECK(st.bRunning && st.bFollowingBeat);
	CHECK_NEAR(st.fTempo, 120, 1e-9);
}

TEST(WholeBarsSwitchOnTheOne) {
	AutoAdvance	aa;
	aa.SetLength(2, AutoAdvance::UNIT_Bars);
	Music	m;
	m.fPos = 5.7;	// in bar 2
	Run(aa, m, 1);
	aa.Start();
	auto	at = Run(aa, m, 60 * 30);	// 60 beats
	CHECK(at.size() >= 6);
	for (double p : at)	// each on a bar's first beat
		CHECK(std::fmod(p, 4) < 2.0 / 60 + 1e-9);
	CHECK_NEAR(at[0], 12, 2.0 / 60);	// 5.7 + 8 = 13.7: nearest bar line 12
	// half a bar: beats, not bars
	aa.SetLength(1.5, AutoAdvance::UNIT_Bars);
	aa.Restart();
	at = Run(aa, m, 60 * 10);
	for (size_t i = 1; i < at.size(); i++)
		CHECK_NEAR(at[i] - at[i - 1], 6, 2.0 / 60);
}

TEST(WithoutABeatItKeepsTheLastTempo) {
	AutoAdvance	aa;
	aa.SetLength(4, AutoAdvance::UNIT_Beats);
	// never a beat: 120 BPM, 4 beats every 2 s
	Music	m;
	m.bBeat = false;
	aa.Start();
	int	n = 0;
	for (int i = 0; i < 60 * 10 + 1; i++)
		n += aa.Step(kDt, false, m.Next(kDt));
	CHECK_EQ(n, 5);
	CHECK(!aa.GetStatus().bFollowingBeat);
	CHECK_NEAR(aa.GetStatus().fTempo, AutoAdvance::kDefaultTempo, 1e-9);
	// a beat at 90 BPM, then lost: carries on at 90 (4 beats every 2.67 s)
	m.bBeat = true;
	m.fBpm = 90;
	Run(aa, m, 600);
	m.bBeat = false;
	aa.Restart();
	n = 0;
	for (int i = 0; i < 60 * 8 + 1; i++)
		n += aa.Step(kDt, false, m.Next(kDt));
	CHECK_EQ(n, 3);
	CHECK_NEAR(aa.GetStatus().fTempo, 90, 1e-9);
	// pause doesn't stop beats
	n = 0;
	for (int i = 0; i < 60 * 8; i++)
		n += aa.Step(kDt, true, m.Next(kDt));
	CHECK_EQ(n, 3);
}

TEST(TheBeatComingBackKeepsWhatWasLeft) {
	AutoAdvance	aa;
	aa.SetLength(2, AutoAdvance::UNIT_Bars);
	Music	m;
	m.bBeat = false;
	aa.Start();
	Run(aa, m, 60);	// 1 s free: 2 of 8 beats
	// the beat found, its position far from the free clock's
	m.bBeat = true;
	m.fPos = 101.0;
	auto	at = Run(aa, m, 60 * 4);	// 8 beats
	CHECK_EQ(at.size(), size_t(1));
	CHECK_NEAR(at[0], 108, 2.0 / 60);	// 6 left from 101 = 107: nearest bar line 108
	// a nudge of a beat moves the grid with it
	m.nMoves++;
	m.fPos += 1;
	at = Run(aa, m, 60 * 5);
	for (double p : at)
		CHECK(std::fmod(p, 4) < 2.0 / 60 + 1e-9);
}

TEST(LengthsAreKeptInRange) {
	CHECK_EQ(AutoAdvance::ClampLength(0, AutoAdvance::UNIT_Seconds), 1.0);
	CHECK_EQ(AutoAdvance::ClampLength(1e9, AutoAdvance::UNIT_Bars), 256.0);
	CHECK_EQ(AutoAdvance::ClampLength(NAN, AutoAdvance::UNIT_Beats), AutoAdvance::kDefaultLength);
	AutoAdvance	aa;
	aa.SetLength(16, 99);	// unknown unit: seconds
	CHECK_EQ(aa.GetUnit(), int(AutoAdvance::UNIT_Seconds));
}

int main() { return RunAllTests(); }
