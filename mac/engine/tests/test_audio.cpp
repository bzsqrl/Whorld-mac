// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Tests for AudioAnalyzer (Mac addition, AUDIO_PLAN.md) with synthetic
// signals: tones for level, bands and brightness; drum-like bursts for hits.

#include "TestHarness.h"
#include "whorld/AudioAnalyzer.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>
#include <algorithm>

using namespace whorld;
using Src = ModSources;

namespace {

std::vector<float> Sine(double fHz, double fAmp, double fSeconds, double fRate = 48000)
{
	std::vector<float>	a(static_cast<size_t>(fSeconds * fRate));
	for (size_t i = 0; i < a.size(); i++)
		a[i] = static_cast<float>(fAmp * std::sin(2 * kPi * fHz * static_cast<double>(i) / fRate));
	return a;
}

// deterministic white noise, -1 to 1
struct Noise {
	uint32_t	n = 12345;
	double	Next() { n = n * 1664525u + 1013904223u; return static_cast<double>(n >> 8) / 8388608.0 - 1; }
};

// a kick: a 60 Hz sine dying away over about 0.1 s (to silence: no
// abrupt end, which would be a click of its own)
void AddKick(std::vector<float>& a, size_t iAt, double fAmp, double fRate = 48000)
{
	for (size_t i = 0; i < static_cast<size_t>(1.0 * fRate) && iAt + i < a.size(); i++) {
		double	t = static_cast<double>(i) / fRate;
		a[iAt + i] += static_cast<float>(fAmp * std::exp(-t / 0.08) * std::sin(2 * kPi * 60 * t));
	}
}

// a hat: 20 ms of noise, differenced twice so it's mostly treble
void AddHat(std::vector<float>& a, size_t iAt, double fAmp, Noise& noise, double fRate = 48000)
{
	double	x1 = 0, x2 = 0;
	for (size_t i = 0; i < static_cast<size_t>(0.02 * fRate) && iAt + i < a.size(); i++) {
		double	x = noise.Next();
		double	y = (x - 2 * x1 + x2) / 4;
		x2 = x1;
		x1 = x;
		double	t = static_cast<double>(i) / fRate;
		a[iAt + i] += static_cast<float>(fAmp * y * std::exp(-t / 0.008));
	}
}

AudioAnalyzer Run(const std::vector<float>& a, double fRate = 48000,
	const AudioAnalyzer::Settings& set = AudioAnalyzer::Settings())
{
	AudioAnalyzer	an;
	an.SetSettings(set);
	an.Reset(fRate);
	an.Process(a.data(), a.size());
	return an;
}

// hits counted after a lead-in (a tone starting from silence is a hit)
ModSources HitsAfter(const std::vector<float>& a, double fLeadIn)
{
	AudioAnalyzer	an;
	an.Reset(48000);
	size_t	nLead = static_cast<size_t>(fLeadIn * 48000);
	an.Process(a.data(), nLead);
	ModSources	before = an.GetSources();
	an.Process(a.data() + nLead, a.size() - nLead);
	ModSources	s = an.GetSources();
	for (int i = 0; i < Src::SOURCES; i++)
		s.aCount[i] -= before.aCount[i];
	return s;
}

} // namespace

TEST(FftMatchesDft) {
	const size_t	n = 64;
	Fft	fft;
	fft.Init(n);
	Noise	noise;
	std::vector<std::complex<double>>	x(n), y;
	for (auto& v : x)
		v = std::complex<double>(noise.Next(), noise.Next());
	y = x;
	fft.Forward(y.data());
	double	fMaxErr = 0;
	for (size_t k = 0; k < n; k++) {
		std::complex<double>	s = 0;
		for (size_t j = 0; j < n; j++)
			s += x[j] * std::polar(1.0, -2 * kPi * static_cast<double>(j * k) / static_cast<double>(n));
		fMaxErr = std::max(fMaxErr, std::abs(s - y[k]));
	}
	CHECK(fMaxErr < 1e-9);
}

TEST(SilenceIsZero) {
	AudioAnalyzer	an = Run(std::vector<float>(48000));
	const Src&	s = an.GetSources();
	for (int i = 0; i < Src::SOURCES; i++) {
		CHECK_EQ(s.aValue[i], 0.0f);
		CHECK_EQ(s.aCount[i], 0u);
	}
	CHECK(an.GetAnalysisCount() > 80);	// a hop every 512 samples
}

TEST(SineLevelAndBand) {
	// a full-scale sine is -3 dBFS RMS and 0 dB in its band
	AudioAnalyzer	an = Run(Sine(1000, 1, 0.5));
	CHECK_NEAR(an.GetLevelDb(), 0, 0.05);
	CHECK_NEAR(an.GetBandDb(2), 0, 0.2);	// High Mid
	CHECK(an.GetBandDb(0) < -40);
	CHECK(an.GetBandDb(3) < -40);
	const Src&	s = an.GetSources();
	CHECK_NEAR(s.aValue[Src::SRC_Level], 1, 0.002);
	CHECK_NEAR(s.aValue[Src::SRC_HighMid], 1, 0.005);
	// a half-scale bass tone: -6 dB in Bass, little elsewhere
	an = Run(Sine(80, 0.5, 0.5));
	CHECK_NEAR(an.GetBandDb(0), -6.0206, 0.3);
	CHECK(an.GetBandDb(2) < -40);
	CHECK_NEAR(an.GetSources().aValue[Src::SRC_Bass], (60 - 6.0206) / 60, 0.01);
}

TEST(GainAddsDecibels) {
	AudioAnalyzer::Settings	set;
	set.fGainDb = 6.0206;	// doubles the samples
	AudioAnalyzer	a = Run(Sine(440, 0.25, 0.5), 48000, set);
	AudioAnalyzer	b = Run(Sine(440, 0.5, 0.5));
	CHECK_NEAR(a.GetLevelDb(), b.GetLevelDb(), 0.01);
	CHECK_NEAR(a.GetSources().aValue[Src::SRC_LowMid], b.GetSources().aValue[Src::SRC_LowMid], 0.001);
}

TEST(BrightnessFollowsPitch) {
	double	fLow = Run(Sine(200, 0.5, 0.5)).GetSources().aValue[Src::SRC_Brightness];
	double	fHigh = Run(Sine(6000, 0.5, 0.5)).GetSources().aValue[Src::SRC_Brightness];
	CHECK_NEAR(fLow, std::log2(2.0) / std::log2(100.0), 0.05);	// 200 Hz: 1 octave of 6.64 above 100
	CHECK_NEAR(fHigh, std::log2(60.0) / std::log2(100.0), 0.05);
	CHECK(fHigh > fLow + 0.5);
}

TEST(SampleRatesAgree) {
	AudioAnalyzer	a = Run(Sine(100, 0.5, 0.5, 44100), 44100);
	AudioAnalyzer	b = Run(Sine(100, 0.5, 0.5, 96000), 96000);
	CHECK_EQ(b.GetWindowSize(), size_t(4096));	// bass resolution kept
	CHECK_NEAR(a.GetBandDb(0), b.GetBandDb(0), 0.5);
	CHECK_NEAR(a.GetLevelDb(), b.GetLevelDb(), 0.1);
}

TEST(ChunkingDoesNotMatter) {
	// the same samples in odd-sized calls give the same results
	std::vector<float>	a = Sine(300, 0.3, 1);
	for (size_t i = 0; i < a.size(); i += 12000)
		AddKick(a, i, 0.6);
	AudioAnalyzer	whole = Run(a);
	AudioAnalyzer	parts;
	parts.Reset(48000);
	size_t	iAt = 0, nChunk = 1;
	while (iAt < a.size()) {
		size_t	n = std::min(nChunk, a.size() - iAt);
		parts.Process(a.data() + iAt, n);
		iAt += n;
		nChunk = nChunk * 7 % 997 + 1;
	}
	CHECK_EQ(whole.GetAnalysisCount(), parts.GetAnalysisCount());
	for (int i = 0; i < Src::SOURCES; i++) {
		CHECK_EQ(whole.GetSources().aValue[i], parts.GetSources().aValue[i]);
		CHECK_EQ(whole.GetSources().aCount[i], parts.GetSources().aCount[i]);
	}
}

TEST(KicksAreHitsAndKicks) {
	// eight kicks, half a second apart, over a quiet tone
	std::vector<float>	a = Sine(440, 0.02, 4.6);
	for (int i = 0; i < 8; i++)
		AddKick(a, static_cast<size_t>((0.5 + 0.5 * i) * 48000), 0.7);
	Src	s = HitsAfter(a, 0.3);
	CHECK_EQ(s.aCount[Src::SRC_Kick], 8u);
	CHECK_EQ(s.aCount[Src::SRC_Hit], 8u);
	CHECK(s.aCount[Src::SRC_Hats] <= 1u);
	std::printf("  hats on kicks: %u\n", s.aCount[Src::SRC_Hats]);
}

TEST(HatsAreHitsAndHats) {
	Noise	noise;
	std::vector<float>	a = Sine(440, 0.02, 4.6);
	for (int i = 0; i < 16; i++)
		AddHat(a, static_cast<size_t>((0.5 + 0.25 * i) * 48000), 0.6, noise);
	Src	s = HitsAfter(a, 0.3);
	CHECK_EQ(s.aCount[Src::SRC_Hats], 16u);
	CHECK_EQ(s.aCount[Src::SRC_Hit], 16u);
	CHECK_EQ(s.aCount[Src::SRC_Kick], 0u);
}

TEST(SteadySoundsDoNotHit) {
	// once a tone has started, holding it doesn't hit, nor does steady
	// hiss, loud or quiet
	for (double fHiss : {0.003, 0.03, 0.2}) {
		Noise	noise;
		std::vector<float>	a = Sine(220, 0.5, 6);
		for (auto& x : a)
			x += static_cast<float>(fHiss * noise.Next());
		Src	s = HitsAfter(a, 0.5);
		std::printf("  hiss %g: hits %u kicks %u hats %u\n", fHiss,
			s.aCount[Src::SRC_Hit], s.aCount[Src::SRC_Kick], s.aCount[Src::SRC_Hats]);
		CHECK(s.aCount[Src::SRC_Hit] <= 1u);
		CHECK(s.aCount[Src::SRC_Kick] <= 1u);
		CHECK(s.aCount[Src::SRC_Hats] <= 1u);
	}
}

TEST(KicksOverABassline) {
	// a sustained 55 Hz bass under the kicks doesn't hide them
	std::vector<float>	a = Sine(55, 0.3, 4.6);
	for (int i = 0; i < 8; i++)
		AddKick(a, static_cast<size_t>((0.5 + 0.5 * i) * 48000), 0.6);
	Src	s = HitsAfter(a, 0.3);
	CHECK_EQ(s.aCount[Src::SRC_Kick], 8u);
}

TEST(KicksOverHiss) {
	Noise	noise;
	std::vector<float>	a = Sine(440, 0.02, 4.6);
	for (auto& x : a)
		x += static_cast<float>(0.05 * noise.Next());
	for (int i = 0; i < 8; i++)
		AddKick(a, static_cast<size_t>((0.5 + 0.5 * i) * 48000), 0.6);
	Src	s = HitsAfter(a, 0.3);
	CHECK_EQ(s.aCount[Src::SRC_Kick], 8u);
	CHECK_EQ(s.aCount[Src::SRC_Hit], 8u);
}

TEST(FastPatternsHitEveryTime) {
	// 16ths at 120 BPM: every hat counts
	Noise	noise;
	std::vector<float>	a = Sine(440, 0.02, 3.6);
	for (int i = 0; i < 24; i++)
		AddHat(a, static_cast<size_t>((0.5 + 0.125 * i) * 48000), 0.5, noise);
	Src	s = HitsAfter(a, 0.3);
	CHECK_EQ(s.aCount[Src::SRC_Hats], 24u);
}

TEST(GrooveCountsEachInstrument) {
	// 4 s at 120 BPM: kicks on the beats, hats on the 8ths, a bassline and
	// some hiss; each detector counts its own instrument, and Hit counts
	// each 8th once (kick and hat together are one hit)
	Noise	noise;
	std::vector<float>	a(static_cast<size_t>(4.8 * 48000));
	for (size_t i = 0; i < a.size(); i++) {
		double	t = static_cast<double>(i) / 48000;
		a[i] = static_cast<float>(0.2 * std::sin(2 * kPi * 49 * t) + 0.01 * noise.Next());
	}
	for (int i = 0; i < 8; i++)
		AddKick(a, static_cast<size_t>((0.5 + 0.5 * i) * 48000), 0.6);
	for (int i = 0; i < 16; i++)
		AddHat(a, static_cast<size_t>((0.5 + 0.25 * i) * 48000), 0.4, noise);
	Src	s = HitsAfter(a, 0.4);
	std::printf("  kicks %u hats %u hits %u\n", s.aCount[Src::SRC_Kick], s.aCount[Src::SRC_Hats], s.aCount[Src::SRC_Hit]);
	CHECK_EQ(s.aCount[Src::SRC_Kick], 8u);
	CHECK_EQ(s.aCount[Src::SRC_Hats], 16u);
	CHECK_EQ(s.aCount[Src::SRC_Hit], 16u);
}

TEST(FalseHitsAreRare) {
	// loud steady hiss for 30 s: a false hit now and then at most
	Noise	noise;
	std::vector<float>	a = Sine(220, 0.3, 30.5);
	for (auto& x : a)
		x += static_cast<float>(0.2 * noise.Next());
	Src	s = HitsAfter(a, 0.5);
	std::printf("  in 30 s: hits %u kicks %u hats %u\n",
		s.aCount[Src::SRC_Hit], s.aCount[Src::SRC_Kick], s.aCount[Src::SRC_Hats]);
	CHECK(s.aCount[Src::SRC_Hit] <= 3u);
	CHECK(s.aCount[Src::SRC_Kick] <= 3u);
	CHECK(s.aCount[Src::SRC_Hats] <= 3u);
}

TEST(RefractoryMergesCloseHits) {
	// two kicks 30 ms apart are one hit; 250 ms apart, two (kicks are at
	// least 180 ms apart, so a kick's tail beating against the bass isn't one)
	std::vector<float>	a(static_cast<size_t>(1.5 * 48000));
	AddKick(a, 24000, 0.7);
	AddKick(a, 24000 + 1440, 0.7);
	CHECK_EQ(Run(a).GetSources().aCount[Src::SRC_Kick], 1u);
	std::vector<float>	b(static_cast<size_t>(1.5 * 48000));
	AddKick(b, 24000, 0.7);
	AddKick(b, 24000 + 12000, 0.7);
	CHECK_EQ(Run(b).GetSources().aCount[Src::SRC_Kick], 2u);
}

TEST(HitsAreDetectedPromptly) {
	// the hit is counted within two hops (about 21 ms) of the kick
	std::vector<float>	a(48000);
	const size_t	iKick = 24000;
	AddKick(a, iKick, 0.7);
	AudioAnalyzer	an;
	an.Reset(48000);
	size_t	iHit = 0;
	for (size_t i = 0; i < a.size() && !iHit; i++) {
		an.Process(&a[i], 1);
		if (an.GetSources().aCount[Src::SRC_Kick])
			iHit = i + 1;
	}
	CHECK(iHit > iKick);
	double	fMs = static_cast<double>(iHit - iKick) / 48;
	std::printf("  kick detected after %.1f ms\n", fMs);
	CHECK(fMs <= 2 * 512 / 48.0 + 0.01);
}

TEST(AutoLevelFollowsTheMusic) {
	// a quiet tone (-30 dBFS) reads low at fixed levels, near the top with
	// auto-level once it has settled
	AudioAnalyzer::Settings	set;
	std::vector<float>	a = Sine(1000, 0.0447, 2);	// -30 dBFS RMS, -27 dB re a full-scale sine
	double	fFixed = Run(a, 48000, set).GetSources().aValue[Src::SRC_Level];
	set.bAutoLevel = true;
	double	fAuto = Run(a, 48000, set).GetSources().aValue[Src::SRC_Level];
	CHECK_NEAR(fFixed, 0.5 + 3.0103 / 60, 0.01);	// -30 dB RMS is -27 re a full-scale sine
	CHECK(fAuto > 0.95);
}

// Beat tracking

namespace {

// beat times (seconds), with the tracker's tempo at the end
struct BeatRun {
	std::vector<double>	beats;
	double	fTempo = 0;
	bool	bLocked = false;
};

BeatRun RunBeats(const std::vector<float>& a)
{
	AudioAnalyzer	an;
	an.Reset(48000);
	BeatRun	r;
	uint32_t	n0 = 0;
	for (size_t i = 0; i + 512 <= a.size(); i += 512) {
		an.Process(&a[i], 512);
		uint32_t	n = an.GetSources().aCount[Src::SRC_Beat];
		if (n != n0)
			r.beats.push_back(static_cast<double>(i + 512) / 48000);
		n0 = n;
	}
	r.fTempo = an.GetBeatTracker().GetTempo();
	r.bLocked = an.GetBeatTracker().IsLocked();
	return r;
}

// how many of the expected times (from fFrom to fTo) have a beat within
// fTol, how many beats in that span aren't near any, and the median offset
struct BeatScore {
	int		nHit = 0, nMissed = 0, nExtra = 0;
	double	fMedianMs = 0;
};

BeatScore Score(const BeatRun& r, const std::vector<double>& expected, double fFrom, double fTo, double fTol = 0.035)
{
	BeatScore	sc;
	std::vector<double>	off;
	for (double t : expected) {
		if (t < fFrom || t > fTo)
			continue;
		double	fBest = 1e9;
		for (double b : r.beats)
			if (std::fabs(b - t) < std::fabs(fBest))
				fBest = b - t;
		if (std::fabs(fBest) <= fTol) {
			sc.nHit++;
			off.push_back(fBest);
		} else {
			sc.nMissed++;
		}
	}
	for (double b : r.beats) {
		if (b < fFrom || b > fTo)
			continue;
		bool	bNear = false;
		for (double t : expected)
			bNear = bNear || std::fabs(b - t) <= fTol;
		sc.nExtra += !bNear;
	}
	if (!off.empty()) {
		std::sort(off.begin(), off.end());
		sc.fMedianMs = off[off.size() / 2] * 1000;
	}
	return sc;
}

std::vector<double> Grid(double fBpm, double fStart, double fEnd)
{
	std::vector<double>	g;
	for (double t = fStart; t < fEnd; t += 60 / fBpm)
		g.push_back(t);
	return g;
}

} // namespace

TEST(BeatLocksToSteadyKicks) {
	std::vector<float>	a = Sine(440, 0.02, 20);
	std::vector<double>	kicks = Grid(124, 0.5, 19.5);
	for (double t : kicks)
		AddKick(a, static_cast<size_t>(t * 48000), 0.7);
	BeatRun	r = RunBeats(a);
	CHECK(!r.beats.empty() && r.beats.front() < 6);	// locked within a few seconds
	BeatScore	sc = Score(r, kicks, 6, 19.5);
	std::printf("  tempo %.2f, first beat %.2f s, hit %d missed %d extra %d, median %+.0f ms\n",
		r.fTempo, r.beats.empty() ? 0 : r.beats.front(), sc.nHit, sc.nMissed, sc.nExtra, sc.fMedianMs);
	CHECK_NEAR(r.fTempo, 124, 0.5);
	CHECK_EQ(sc.nMissed, 0);
	CHECK_EQ(sc.nExtra, 0);
	CHECK(std::fabs(sc.fMedianMs) <= 20);	// on the kick, give or take
}

TEST(BeatFillsMissingKicks) {
	// a third of the kicks are gone after 8 s; the beat isn't
	std::vector<float>	a = Sine(440, 0.02, 24);
	std::vector<double>	grid = Grid(124, 0.5, 23.5);
	for (size_t i = 0; i < grid.size(); i++)
		if (grid[i] < 8 || i % 3 != 1)
			AddKick(a, static_cast<size_t>(grid[i] * 48000), 0.7);
	BeatScore	sc = Score(RunBeats(a), grid, 8, 23.5);
	std::printf("  hit %d missed %d extra %d\n", sc.nHit, sc.nMissed, sc.nExtra);
	CHECK_EQ(sc.nMissed, 0);
	CHECK_EQ(sc.nExtra, 0);
}

TEST(BeatPrefersTheKickInAGroove) {
	// 120 BPM: kicks on the beats, louder hats on the off-beats, a bassline;
	// the beat is on the kicks, at 120 (not 240 or 60)
	Noise	noise;
	std::vector<float>	a = Sine(55, 0.2, 24);
	std::vector<double>	kicks = Grid(120, 0.5, 23.5);
	for (double t : kicks) {
		AddKick(a, static_cast<size_t>(t * 48000), 0.6);
		AddHat(a, static_cast<size_t>((t + 0.25) * 48000), 0.9, noise);
	}
	BeatRun	r = RunBeats(a);
	BeatScore	sc = Score(r, kicks, 8, 23.5);
	std::printf("  tempo %.2f, hit %d missed %d extra %d, median %+.0f ms\n", r.fTempo, sc.nHit, sc.nMissed, sc.nExtra, sc.fMedianMs);
	CHECK_NEAR(r.fTempo, 120, 1);
	CHECK_EQ(sc.nMissed, 0);
	CHECK_EQ(sc.nExtra, 0);
}

TEST(BeatFollowsATempoChange) {
	// 120 BPM for 16 s, then 130; within 10 s it's on the new beat
	std::vector<float>	a = Sine(440, 0.02, 40);
	std::vector<double>	kicks = Grid(120, 0.5, 16);
	double	t = kicks.back() + 60 / 130.0;
	while (t < 39.5) {
		kicks.push_back(t);
		t += 60 / 130.0;
	}
	for (double k : kicks)
		AddKick(a, static_cast<size_t>(k * 48000), 0.7);
	BeatRun	r = RunBeats(a);
	BeatScore	sc = Score(r, kicks, 26, 39.5);
	std::printf("  tempo %.2f, hit %d missed %d extra %d\n", r.fTempo, sc.nHit, sc.nMissed, sc.nExtra);
	CHECK_NEAR(r.fTempo, 130, 1);
	CHECK_EQ(sc.nMissed, 0);
	CHECK_EQ(sc.nExtra, 0);
}

TEST(BeatRidesThroughABreakdown) {
	// 16 s of kicks with off-beat hats, 12 s of the hats alone, then the
	// kicks again: the beat stays on the kicks' beat throughout
	Noise	noise;
	std::vector<float>	a = Sine(440, 0.02, 40);
	std::vector<double>	grid = Grid(124, 0.5, 39.5);
	for (double t : grid) {
		if (t < 16 || t >= 28)
			AddKick(a, static_cast<size_t>(t * 48000), 0.7);
		AddHat(a, static_cast<size_t>((t + 30 / 124.0) * 48000), 0.6, noise);
	}
	BeatRun	r = RunBeats(a);
	BeatScore	sc = Score(r, grid, 8, 39.5);
	std::printf("  hit %d missed %d extra %d\n", sc.nHit, sc.nMissed, sc.nExtra);
	CHECK_EQ(sc.nExtra, 0);		// never on the off-beat
	CHECK_EQ(sc.nMissed, 0);	// and on through the breakdown
}

TEST(BeatStopsInSilence) {
	// 16 s of kicks, then silence: beats go on for 8 more, then stop
	std::vector<float>	a = Sine(440, 0.02, 16);
	a.resize(48000 * 40, 0.0f);
	for (double t : Grid(124, 0.5, 15.5))
		AddKick(a, static_cast<size_t>(t * 48000), 0.7);
	BeatRun	r = RunBeats(a);
	int		nAfter = 0;
	for (double b : r.beats)
		nAfter += b > 16;
	std::printf("  beats after the music: %d, last at %.1f s\n", nAfter, r.beats.empty() ? 0 : r.beats.back());
	CHECK(nAfter <= 9);
	CHECK(!r.beats.empty() && r.beats.back() < 21);
	CHECK(!r.bLocked);
}

TEST(BarsAndPhrasesCountFromTheLock) {
	// 70 s of kicks at 124 BPM: the first beat after locking is the one,
	// and Bar ... 32-Bar fire on beats 0, 4, 8 ... / 0, 16 ... / 0, 128 ...
	std::vector<float>	a = Sine(440, 0.02, 70);
	for (double t : Grid(124, 0.5, 69.5))
		AddKick(a, static_cast<size_t>(t * 48000), 0.7);
	AudioAnalyzer	an;
	an.Reset(48000);
	an.Process(a.data(), a.size());
	const Src&	s = an.GetSources();
	uint32_t	nBeats = s.aCount[Src::SRC_Beat];
	std::printf("  beats %u: bars %u, 4-bars %u, 8-bars %u, 16-bars %u, 32-bars %u\n", nBeats,
		s.aCount[Src::SRC_Bar], s.aCount[Src::SRC_Bar4], s.aCount[Src::SRC_Bar8], s.aCount[Src::SRC_Bar16], s.aCount[Src::SRC_Bar32]);
	CHECK(nBeats > 128);
	CHECK_EQ(s.aCount[Src::SRC_Bar], (nBeats + 3) / 4);
	CHECK_EQ(s.aCount[Src::SRC_Bar4], (nBeats + 15) / 16);
	CHECK_EQ(s.aCount[Src::SRC_Bar8], (nBeats + 31) / 32);
	CHECK_EQ(s.aCount[Src::SRC_Bar16], (nBeats + 63) / 64);
	CHECK_EQ(s.aCount[Src::SRC_Bar32], (nBeats + 127) / 128);
	CHECK_EQ(an.GetBeatTracker().GetBeatInBar(), static_cast<int>((nBeats - 1) % 4));
}

TEST(MarkDownbeatMovesTheOne) {
	// mark a quarter beat after a beat: that beat becomes the one (the bars
	// fire at once, then every 4 beats from it); a three-quarter-beat mark
	// makes the next beat the one
	std::vector<float>	a = Sine(440, 0.02, 30);
	for (double t : Grid(124, 0.5, 29.5))
		AddKick(a, static_cast<size_t>(t * 48000), 0.7);
	AudioAnalyzer	an;
	an.Reset(48000);
	const BeatTracker&	bt = an.GetBeatTracker();
	size_t	i = 0;
	auto	until = [&](auto done) {
		for (; i + 512 <= a.size() && !done(); i += 512)
			an.Process(&a[i], 512);
	};
	until([&] { return bt.GetBeatCount() >= 9 && bt.GetBeatInBar() == 1 && bt.GetPhase() > 0.2; });
	uint32_t	nBars = an.GetSources().aCount[Src::SRC_Bar];
	an.MarkDownbeat();	// late: beat 1 of the bar becomes the one
	an.Process(&a[i], 512);	// (sources update with the next analysis)
	i += 512;
	CHECK_EQ(bt.GetBeatInBar(), 0);
	CHECK_EQ(an.GetSources().aCount[Src::SRC_Bar], nBars + 1);
	uint32_t	nBeats = bt.GetBeatCount();
	until([&] { return bt.GetBeatCount() == nBeats + 4; });
	CHECK_EQ(bt.GetBeatInBar(), 0);	// 4 beats on: the next bar
	CHECK_EQ(an.GetSources().aCount[Src::SRC_Bar], nBars + 2);
	until([&] { return bt.GetBeatCount() == nBeats + 6 && bt.GetPhase() > 0.7; });
	an.MarkDownbeat();	// early: the next beat is the one
	nBars = an.GetSources().aCount[Src::SRC_Bar];
	until([&] { return bt.GetBeatCount() == nBeats + 7; });
	CHECK_EQ(bt.GetBeatInBar(), 0);
	CHECK_EQ(an.GetSources().aCount[Src::SRC_Bar], nBars + 1);
}

int main() { return RunAllTests(); }
