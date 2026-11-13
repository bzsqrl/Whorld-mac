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

int main() { return RunAllTests(); }
