// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Audio analysis (new in the Mac port; design in AUDIO_PLAN.md): turns
// audio samples into modulation sources (ModSources): level, four bands,
// brightness, and hits (onsets) overall, in the bass ("kick") and in the
// treble ("hats"). Portable and deterministic: the results depend only on
// the samples, not on how they're split into calls, so live input, an
// audio file and tests all give the same answers. Process allocates
// nothing after Reset, so it can run on an audio thread, though the app
// runs it on its own analysis thread.

#include "whorld/BeatTracker.h"
#include "whorld/Modulation.h"

#include <complex>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace whorld {

// In-place radix-2 complex FFT (forward, unscaled).
class Fft {
public:
	void	Init(size_t nSize);	// a power of two
	size_t	GetSize() const { return m_nSize; }
	void	Forward(std::complex<double>* pData) const;

private:
	size_t	m_nSize = 0;
	std::vector<std::complex<double>>	m_aTwiddle;	// e^(-2πik/N), k < N/2
	std::vector<uint32_t>	m_aReverse;	// bit-reversed index
};

class AudioAnalyzer {
public:
	struct Settings {
		double	fGainDb = 0;		// input gain
		double	fFloorDb = -60;		// level and bands read 0 here...
		double	fCeilDb = 0;		// ...and 1 here (dB relative to a full-scale sine)
		bool	bAutoLevel = false;	// follow the music's recent peak instead of fixed dB
		double	fHitThreshold = 4;	// a hit is flux this many (robust) deviations above its recent median
		double	fRefractory = 0.08;	// seconds after a hit before the same kind can hit again (kicks: 0.18 at least)
	};
	enum {	// hit detectors
		ONSET_All,
		ONSET_Bass,
		ONSET_Treble,
		ONSETS
	};

	void	Reset(double fSampleRate);	// allocates; clears all state and counts
	void	SetSettings(const Settings& settings);
	const Settings&	GetSettings() const { return m_set; }
	// Mono samples, any number at a time; analyses run every hop.
	void	Process(const float* pSample, size_t nSamples);
	// The latest results: values 0 to 1, and hit counts.
	const ModSources&	GetSources() const { return m_src; }
	// for meters and tests
	double	GetLevelDb() const { return m_fLevelDb; }	// RMS, after gain; a full-scale sine is 0 dB
	double	GetBandDb(int iBand) const { return m_aBandDb[iBand]; }	// 0..3: Bass..Treble
	double	GetFlux(int iOnset) const { return m_aFlux[iOnset]; }
	double	GetThreshold(int iOnset) const { return m_aThreshold[iOnset]; }	// the last analysis's
	double	GetHitPeak(int iOnset) const { return m_aHitPeak[iOnset]; }	// the last hit's flux, decaying
	uint64_t	GetAnalysisCount() const { return m_nAnalyses; }
	const BeatTracker&	GetBeatTracker() const { return m_beat; }
	void	MarkDownbeat() { m_beat.MarkDownbeat(); }
	size_t	GetWindowSize() const { return m_nWindow; }
	size_t	GetHopSize() const { return m_nHop; }
	double	GetSampleRate() const { return m_fSampleRate; }

	static constexpr int	BANDS = 4;
	static const double	kBandEdge[BANDS + 1];	// Hz: 20, 150, 600, 4000, 16000

private:
	struct Range {	// FFT bins, first to last inclusive
		size_t	iFirst = 1;
		size_t	iLast = 1;
	};
	Settings	m_set;
	double	m_fGain = 1;
	double	m_fSampleRate = 0;
	size_t	m_nWindow = 0;	// FFT size
	size_t	m_nHop = 0;
	Fft		m_fft;
	std::vector<float>	m_aRing;	// the last m_nWindow samples, circular
	size_t	m_iRing = 0;		// next write position
	size_t	m_nPending = 0;		// samples since the last analysis
	std::vector<double>	m_aHann;
	std::vector<std::complex<double>>	m_aSpectrum;
	std::vector<double>	m_aMag;		// compressed magnitudes, this analysis
	std::vector<double>	m_aPrevMag;	// and the last
	Range	m_aBand[BANDS];
	Range	m_aOnsetRange[ONSETS];
	Range	m_rAudible;		// 20 Hz to 16 kHz, for brightness
	Range	m_rSubBass;		// 20 to 60 Hz, which must back the beat tracker's phase jumps
	std::vector<double>	m_aFluxHist[ONSETS];	// recent flux, circular, for the median and spread
	std::vector<double>	m_aScratch;	// for the medians
	size_t	m_nHistSize = 0;
	size_t	m_iHist = 0;
	size_t	m_nHist = 0;		// entries filled
	double	m_aFlux[ONSETS] = {};	// smoothed: this hop's and the last's, averaged
	double	m_aRawFlux[ONSETS] = {};
	double	m_aThreshold[ONSETS] = {};
	double	m_aSinceHit[ONSETS] = {};	// seconds
	double	m_aHitPeak[ONSETS] = {};	// the last hit's flux, decaying
	double	m_fLevelDb = -200;
	double	m_aBandDb[BANDS] = {};
	double	m_fPeakDb = -200;	// auto-level's recent peak
	double	m_fRefPower = 1;	// one-sided spectrum power of a full-scale sine
	double	m_fHannSumSq = 1;	// sum of the window's squares
	bool	m_bPrimed = false;	// m_aPrevMag is valid
	uint64_t	m_nAnalyses = 0;
	ModSources	m_src;
	BeatTracker	m_beat;	// fed by the bass and overall onsets

	void	Analyze();
	double	MapDb(double fDb) const;
	Range	BinRange(double fLow, double fHigh) const;
};

} // namespace whorld
