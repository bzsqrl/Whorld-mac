// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Tests for Oscillator and TriggerOscillator.

#include "TestHarness.h"
#include "whorld/Oscillator.h"
#include "whorld/Random.h"

#include <cmath>
#include <vector>

using namespace whorld;

namespace {
// timer 100 Hz, 1 Hz output: one cycle every 100 ticks
Oscillator MakeOsc(int wave)
{
	return Oscillator(100, wave, 1);
}

double ValAt(Oscillator& osc, double clock)
{
	osc.SetClock(clock);
	return osc.GetVal();
}
} // namespace

TEST(DefaultInit) {
	Oscillator	osc;
	CHECK_EQ(osc.GetTimerFreq(), 0.0);
	CHECK_EQ(osc.GetWaveform(), 0);
	CHECK_EQ(osc.GetFreq(), 0.0);
	CHECK_EQ(osc.GetPulseWidth(), 0.5);
	CHECK_EQ(osc.GetClock(), 0.0);
}

TEST(Triangle) {
	Oscillator	osc = MakeOsc(Oscillator::TRIANGLE);
	CHECK_NEAR(ValAt(osc, 0), 0, 1e-12);
	CHECK_NEAR(ValAt(osc, 25), 1, 1e-12);
	CHECK_NEAR(ValAt(osc, 50), 0, 1e-12);
	CHECK_NEAR(ValAt(osc, 75), -1, 1e-12);
	CHECK_NEAR(ValAt(osc, 12.5), 0.5, 1e-12);
	CHECK_NEAR(ValAt(osc, 100), 0, 1e-12);
}

TEST(Sine) {
	Oscillator	osc = MakeOsc(Oscillator::SINE);
	CHECK_NEAR(ValAt(osc, 0), 0, 1e-12);
	CHECK_NEAR(ValAt(osc, 25), 1, 1e-12);
	CHECK_NEAR(ValAt(osc, 75), -1, 1e-12);
	CHECK_NEAR(ValAt(osc, 10), std::sin(0.1 * 2 * kPi), 1e-12);
}

TEST(Ramps) {
	Oscillator	up = MakeOsc(Oscillator::RAMP_UP);
	CHECK_NEAR(ValAt(up, 0), -1, 1e-12);
	CHECK_NEAR(ValAt(up, 25), -0.5, 1e-12);
	CHECK_NEAR(ValAt(up, 75), 0.5, 1e-12);
	Oscillator	down = MakeOsc(Oscillator::RAMP_DOWN);
	CHECK_NEAR(ValAt(down, 0), 1, 1e-12);
	CHECK_NEAR(ValAt(down, 25), 0.5, 1e-12);
}

TEST(SquareAndPulse) {
	Oscillator	sq = MakeOsc(Oscillator::SQUARE);
	CHECK_EQ(ValAt(sq, 0), 1.0);
	CHECK_EQ(ValAt(sq, 49), 1.0);
	CHECK_EQ(ValAt(sq, 50), -1.0);
	CHECK_EQ(ValAt(sq, 99), -1.0);
	Oscillator	pulse = MakeOsc(Oscillator::PULSE);
	pulse.SetPulseWidth(0.2);
	CHECK_EQ(ValAt(pulse, 10), 1.0);
	CHECK_EQ(ValAt(pulse, 30), -1.0);
}

TEST(NegativeClockUsesFmodSign) {
	// fmod keeps the sign of the dividend; the original relies on this
	Oscillator	up = MakeOsc(Oscillator::RAMP_UP);
	CHECK_NEAR(ValAt(up, -25), std::fmod(-0.25, 1) * 2 - 1, 1e-12);
}

TEST(UnknownWaveformIsZero) {
	Oscillator	osc = MakeOsc(99);
	CHECK_EQ(ValAt(osc, 25), 0.0);
}

TEST(SetFreqKeepsPhase) {
	Oscillator	osc = MakeOsc(Oscillator::RAMP_UP);
	osc.SetClock(25);
	CHECK_NEAR(osc.GetPhase(), 0.25, 1e-12);
	osc.SetFreq(2);
	CHECK_NEAR(osc.GetClock(), 12.5, 1e-12);
	CHECK_NEAR(osc.GetPhase(), 0.25, 1e-12);
	osc.SetFreqSync(4);	// keeps clock, so phase jumps
	CHECK_NEAR(osc.GetClock(), 12.5, 1e-12);
	CHECK_NEAR(osc.GetPhase(), 0.5, 1e-12);
	osc.SetFreq(0);	// zero frequency resyncs clock to zero
	CHECK_EQ(osc.GetClock(), 0.0);
}

TEST(SetPhaseFromVal) {
	// Upstream quirk: for the triangle, the original formula lands on the
	// phase where the output is -fVal, not fVal. Preserved; it is unused.
	Oscillator	tri = MakeOsc(Oscillator::TRIANGLE);
	tri.SetPhaseFromVal(0.5);
	CHECK_NEAR(tri.GetVal(), -0.5, 1e-9);
	tri.SetPhaseFromVal(-0.8);
	CHECK_NEAR(tri.GetVal(), 0.8, 1e-9);
	Oscillator	sine = MakeOsc(Oscillator::SINE);
	sine.SetPhaseFromVal(0.5);
	CHECK_NEAR(sine.GetVal(), 0.5, 1e-9);
	Oscillator	up = MakeOsc(Oscillator::RAMP_UP);
	up.SetPhaseFromVal(0.25);
	CHECK_NEAR(up.GetVal(), 0.25, 1e-9);
	Oscillator	down = MakeOsc(Oscillator::RAMP_DOWN);
	down.SetPhaseFromVal(0.25);
	CHECK_NEAR(down.GetVal(), 0.25, 1e-9);
}

TEST(TimerHookAdvancesClock) {
	Oscillator	osc = MakeOsc(Oscillator::RAMP_UP);
	for (int i = 0; i < 10; i++)
		osc.TimerHook();
	CHECK_EQ(osc.GetClock(), 10.0);
}

TEST(RandomChangesOnlyOnWrap) {
	whorld::srand(1);
	Oscillator	osc = MakeOsc(Oscillator::RANDOM);
	double	first = osc.GetVal();
	CHECK_EQ(first, 0.0);	// no wrap yet, so the initial value
	osc.SetClock(60);
	CHECK_EQ(osc.GetVal(), 0.0);	// phase 0.6, still no wrap
	osc.SetClock(110);	// phase 0.1 after 0.6: wrap, new random value
	double	v = osc.GetVal();
	CHECK_NEAR(v, 41.0 / kRandMax * 2 - 1, 1e-15);	// first MSVC rand() is 41
	osc.SetClock(120);
	CHECK_EQ(osc.GetVal(), v);	// unchanged until the next wrap
}

TEST(RandomRampInterpolates) {
	whorld::srand(1);
	Oscillator	osc = MakeOsc(Oscillator::RANDOM_RAMP);
	osc.SetClock(60);
	osc.GetVal();	// prime previous phase
	osc.SetClock(125);	// wrap at phase 0.25
	double	cur = 41.0 / kRandMax * 2 - 1;
	CHECK_NEAR(osc.GetVal(), 0 + (cur - 0) * 0.25, 1e-12);
}

TEST(TriggerFiresOncePerCycle) {
	TriggerOscillator	trig(100, 1);
	// fires on the first tick, then each time the phase wraps to zero
	std::vector<int>	fired;
	for (int i = 1; i <= 1000; i++) {
		if (trig.IsTrigger())
			fired.push_back(i);
	}
	const std::vector<int>	expected = {1, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000};
	CHECK(fired == expected);
	trig.Reset();
	CHECK_EQ(trig.GetClock(), 0.0);
	CHECK(trig.IsTrigger());
}

int main() { return RunAllTests(); }
