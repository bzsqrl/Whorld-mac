// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Audio analysis (new in the Mac port); see AudioAnalyzer.h and AUDIO_PLAN.md.

#include "whorld/AudioAnalyzer.h"

#include <algorithm>
#include <cassert>
#include <cmath>

namespace whorld {

namespace {

const double kMinDb = -200;		// what silence reads
const double kCompress = 100;	// magnitude compression for hits: log(1 + 100 m), m = 1 at full scale
const double kSilentDb = -50;	// below this level (re a full-scale sine), the beat tracker hears silence
const double kMinFlux = 0.004;	// hits need at least this much flux (silence and hiss never hit)
const double kHistSeconds = 0.5;	// flux history for the median
const double kPeakFall = 3;		// auto-level: dB per second its peak falls
const double kAutoMinSpan = 12;	// auto-level: the peak stays this far above the floor
const double kHitPeakRatio = 0.4;	// a hit needs this share of the last hit's flux...
const double kHitPeakTime = 0.3;	// ...which decays with this time constant (seconds)
// the bass detector averages only a few bins, so its flux on noise has
// heavier tails: a stricter threshold
const double kOnsetStrictness[AudioAnalyzer::ONSETS] = {1, 1.5, 1};
// a kick's tail beats against a bassline a few notes away, swelling again
// 100 to 180 ms later as strongly as the kick began; heard as roughness,
// not a second kick, so kicks are at least this far apart (seconds;
// 8th-note kicks up to about 165 BPM)
const double kMinRefractory[AudioAnalyzer::ONSETS] = {0, 0.18, 0};

} // namespace

const double AudioAnalyzer::kBandEdge[BANDS + 1] = {20, 150, 600, 4000, 16000};

// Fft

void Fft::Init(size_t nSize)
{
	assert(nSize >= 2 && (nSize & (nSize - 1)) == 0);
	m_nSize = nSize;
	m_aTwiddle.resize(nSize / 2);
	for (size_t k = 0; k < nSize / 2; k++)
		m_aTwiddle[k] = std::polar(1.0, -2 * kPi * static_cast<double>(k) / static_cast<double>(nSize));
	int	nBits = 0;
	while ((size_t(1) << nBits) < nSize)
		nBits++;
	m_aReverse.resize(nSize);
	for (size_t i = 0; i < nSize; i++) {
		uint32_t	r = 0;
		for (int b = 0; b < nBits; b++)
			r |= ((i >> b) & 1) << (nBits - 1 - b);
		m_aReverse[i] = r;
	}
}

void Fft::Forward(std::complex<double>* p) const
{
	const size_t	n = m_nSize;
	for (size_t i = 0; i < n; i++) {	// bit-reversal permutation
		size_t	j = m_aReverse[i];
		if (j > i)
			std::swap(p[i], p[j]);
	}
	for (size_t nLen = 2; nLen <= n; nLen <<= 1) {	// butterflies
		size_t	nHalf = nLen / 2;
		size_t	nStep = n / nLen;
		for (size_t i = 0; i < n; i += nLen) {
			for (size_t k = 0; k < nHalf; k++) {
				std::complex<double>	t = m_aTwiddle[k * nStep] * p[i + k + nHalf];
				p[i + k + nHalf] = p[i + k] - t;
				p[i + k] += t;
			}
		}
	}
}

// AudioAnalyzer

void AudioAnalyzer::Reset(double fSampleRate)
{
	m_fSampleRate = fSampleRate > 0 ? fSampleRate : 48000;
	// about 43 ms at 48 kHz; doubled at 88.2 and 96 kHz, again above, so
	// the bass bands keep their resolution
	m_nWindow = m_fSampleRate > 128000 ? 8192 : m_fSampleRate > 64000 ? 4096 : 2048;
	m_nHop = m_nWindow / 4;
	m_fft.Init(m_nWindow);
	m_aRing.assign(m_nWindow, 0);
	m_iRing = 0;
	m_nPending = 0;
	m_aHann.resize(m_nWindow);
	double	fSumSq = 0;
	for (size_t i = 0; i < m_nWindow; i++) {
		double	w = 0.5 - 0.5 * std::cos(2 * kPi * static_cast<double>(i) / static_cast<double>(m_nWindow));
		m_aHann[i] = w;
		fSumSq += w * w;
	}
	// Parseval: a full-scale sine's windowed energy is about fSumSq / 2;
	// the spectrum has N times it, half on the positive frequencies
	m_fRefPower = static_cast<double>(m_nWindow) * fSumSq / 2 / 2;
	m_fHannSumSq = fSumSq;
	m_aSpectrum.assign(m_nWindow, 0);
	m_aMag.assign(m_nWindow / 2, 0);
	m_aPrevMag.assign(m_nWindow / 2, 0);
	for (int b = 0; b < BANDS; b++)
		m_aBand[b] = BinRange(kBandEdge[b], kBandEdge[b + 1]);
	m_rAudible = BinRange(kBandEdge[0], kBandEdge[BANDS]);
	m_rSubBass = BinRange(20, 60);
	m_aOnsetRange[ONSET_All] = m_rAudible;
	m_aOnsetRange[ONSET_Bass] = m_aBand[0];
	m_aOnsetRange[ONSET_Treble] = m_aBand[BANDS - 1];
	size_t	nHist = std::max<size_t>(8, static_cast<size_t>(std::lround(kHistSeconds * m_fSampleRate / static_cast<double>(m_nHop))));
	for (auto& hist : m_aFluxHist)
		hist.assign(nHist, 0);
	m_nHistSize = nHist;
	m_aScratch.assign(nHist, 0);
	m_iHist = 0;
	m_nHist = 0;
	std::fill(std::begin(m_aFlux), std::end(m_aFlux), 0.0);
	std::fill(std::begin(m_aRawFlux), std::end(m_aRawFlux), 0.0);
	std::fill(std::begin(m_aSinceHit), std::end(m_aSinceHit), 1e9);
	std::fill(std::begin(m_aHitPeak), std::end(m_aHitPeak), 0.0);
	m_fLevelDb = kMinDb;
	std::fill(std::begin(m_aBandDb), std::end(m_aBandDb), kMinDb);
	m_fPeakDb = kMinDb;
	m_bPrimed = false;
	m_nAnalyses = 0;
	m_src = ModSources();
	m_beat.Reset(m_fSampleRate / static_cast<double>(m_nHop));
	SetSettings(m_set);
}

void AudioAnalyzer::SetSettings(const Settings& settings)
{
	m_set = settings;
	m_fGain = std::pow(10, m_set.fGainDb / 20);
}

AudioAnalyzer::Range AudioAnalyzer::BinRange(double fLow, double fHigh) const
{
	double	fBin = m_fSampleRate / static_cast<double>(m_nWindow);	// Hz per bin
	size_t	nLast = m_nWindow / 2 - 1;
	Range	r;
	r.iFirst = std::clamp<size_t>(static_cast<size_t>(std::ceil(fLow / fBin)), 1, nLast);
	r.iLast = std::clamp<size_t>(static_cast<size_t>(std::ceil(fHigh / fBin)) - 1, r.iFirst, nLast);
	return r;
}

void AudioAnalyzer::Process(const float* pSample, size_t nSamples)
{
	if (!m_nWindow)
		Reset(m_fSampleRate);
	for (size_t i = 0; i < nSamples; i++) {
		m_aRing[m_iRing] = pSample[i];
		m_iRing = (m_iRing + 1) % m_nWindow;
		if (++m_nPending == m_nHop) {
			m_nPending = 0;
			Analyze();
		}
	}
}

double AudioAnalyzer::MapDb(double fDb) const
{
	double	fFloor = m_set.fFloorDb;
	double	fCeil = m_set.fCeilDb;
	if (m_set.bAutoLevel) {	// the recent peak reads 1, the same span below it 0
		double	fSpan = fCeil - fFloor;
		fCeil = std::max(m_fPeakDb, fFloor + kAutoMinSpan);
		fFloor = fCeil - fSpan;
	}
	if (fCeil <= fFloor)
		return fDb >= fCeil ? 1 : 0;
	return std::clamp((fDb - fFloor) / (fCeil - fFloor), 0.0, 1.0);
}

void AudioAnalyzer::Analyze()
{
	const size_t	n = m_nWindow;
	const double	fHopSeconds = static_cast<double>(m_nHop) / m_fSampleRate;
	// the window, oldest sample first, with gain; the level is its RMS,
	// Hann-weighted (steadier), relative to a full-scale sine's (AES17), so
	// a full-scale sine reads 0 dB, as it does in its band
	double	fSumSq = 0;
	for (size_t i = 0; i < n; i++) {
		double	x = m_aRing[(m_iRing + i) % n] * m_fGain;
		double	wx = x * m_aHann[i];
		fSumSq += wx * wx;
		m_aSpectrum[i] = std::complex<double>(wx, 0);
	}
	double	fRms = std::sqrt(fSumSq / m_fHannSumSq) * std::sqrt(2.0);
	m_fLevelDb = fRms > 0 ? std::max(20 * std::log10(fRms), kMinDb) : kMinDb;
	m_fft.Forward(m_aSpectrum.data());
	// bands: power relative to a full-scale sine's
	const double	fMagScale = 2 / (static_cast<double>(n) / 2);	// |X| of a full-scale sine is about N/4
	double	fCentroidNum = 0, fCentroidDen = 0;
	double	fBinHz = m_fSampleRate / static_cast<double>(n);
	for (size_t k = 1; k < n / 2; k++) {
		double	fMag = std::abs(m_aSpectrum[k]);
		m_aMag[k] = std::log1p(kCompress * fMag * fMagScale);
		if (k >= m_rAudible.iFirst && k <= m_rAudible.iLast) {
			fCentroidNum += fMag * static_cast<double>(k) * fBinHz;
			fCentroidDen += fMag;
		}
	}
	for (int b = 0; b < BANDS; b++) {
		double	fPower = 0;
		for (size_t k = m_aBand[b].iFirst; k <= m_aBand[b].iLast; k++)
			fPower += std::norm(m_aSpectrum[k]);
		double	fDb = fPower > 0 ? 10 * std::log10(fPower / m_fRefPower) : kMinDb;
		m_aBandDb[b] = std::max(fDb, kMinDb);
	}
	// auto-level follows the loudest of the level and bands
	double	fLoudest = std::max(m_fLevelDb, *std::max_element(std::begin(m_aBandDb), std::end(m_aBandDb)));
	m_fPeakDb = fLoudest > m_fPeakDb ? fLoudest : std::max(m_fPeakDb - kPeakFall * fHopSeconds, kMinDb);
	m_src.aValue[ModSources::SRC_Level] = static_cast<float>(MapDb(m_fLevelDb));
	for (int b = 0; b < BANDS; b++)
		m_src.aValue[ModSources::SRC_Bass + b] = static_cast<float>(MapDb(m_aBandDb[b]));
	// brightness: the centroid on a log scale, 100 Hz to 10 kHz; 0 in silence
	double	fBright = 0;
	if (fCentroidDen > 0 && MapDb(m_fLevelDb) > 0) {
		double	fCentroid = fCentroidNum / fCentroidDen;
		fBright = std::clamp(std::log2(fCentroid / 100) / std::log2(100.0), 0.0, 1.0);
	}
	m_src.aValue[ModSources::SRC_Brightness] = static_cast<float>(fBright);
	// hits: spectral flux (the rise in compressed magnitude, per bin),
	// averaged over two hops, above an adaptive threshold: the recent
	// median plus some median absolute deviations. Robust statistics, so
	// steady sound, however noisy, doesn't hit (the bass detector sees only
	// a few bins, so its flux on hiss jumps around), and a hit doesn't raise
	// the bar for the next one (fast patterns still hit every time).
	auto	median = [this](size_t n) {
		auto	mid = m_aScratch.begin() + static_cast<std::ptrdiff_t>(n / 2);
		std::nth_element(m_aScratch.begin(), mid, m_aScratch.begin() + static_cast<std::ptrdiff_t>(n));
		return *mid;
	};
	static const int	kOnsetSource[ONSETS] = {ModSources::SRC_Hit, ModSources::SRC_Kick, ModSources::SRC_Hats};
	for (int o = 0; o < ONSETS; o++) {
		const Range&	r = m_aOnsetRange[o];
		double	fFlux = 0;
		if (m_bPrimed) {
			for (size_t k = r.iFirst; k <= r.iLast; k++)
				fFlux += std::max(m_aMag[k] - m_aPrevMag[k], 0.0);
			fFlux /= static_cast<double>(r.iLast - r.iFirst + 1);
		}
		double	fSmooth = (fFlux + m_aRawFlux[o]) / 2;
		m_aRawFlux[o] = fFlux;
		fFlux = fSmooth;
		m_aFlux[o] = fFlux;
		std::vector<double>&	hist = m_aFluxHist[o];
		double	fMedian = 0, fDev = 0;
		if (m_nHist) {
			std::copy(hist.begin(), hist.begin() + static_cast<std::ptrdiff_t>(m_nHist), m_aScratch.begin());
			fMedian = median(m_nHist);
			for (size_t i = 0; i < m_nHist; i++)
				m_aScratch[i] = std::fabs(hist[i] - fMedian);
			fDev = median(m_nHist) * 1.4826;	// as a standard deviation, for normal noise
		}
		// also a share of the last hit's strength, decaying, so a hit's own
		// aftermath (a kick's tail beating against the bass) isn't a hit,
		// while an equal hit soon after is
		m_aHitPeak[o] *= std::exp(-fHopSeconds / kHitPeakTime);
		double	fThreshold = std::max(fMedian + m_set.fHitThreshold * kOnsetStrictness[o] * fDev + kMinFlux,
			m_aHitPeak[o] * kHitPeakRatio);
		m_aThreshold[o] = fThreshold;
		m_aSinceHit[o] += fHopSeconds;
		double	fRefractory = std::max(m_set.fRefractory, kMinRefractory[o]);
		if (fFlux > fThreshold && m_aSinceHit[o] >= fRefractory) {
			m_src.aCount[kOnsetSource[o]]++;
			m_aSinceHit[o] = 0;
			m_aHitPeak[o] = fFlux;
		} else if (m_aSinceHit[o] < fRefractory) {	// a hit's peak can come a hop or two late
			m_aHitPeak[o] = std::max(m_aHitPeak[o], fFlux);
		}
		hist[m_iHist] = fFlux;
	}
	// the beat, from this hop's raw bass and overall onsets, with the
	// sub-bass's to back phase jumps (computed before m_aMag becomes the
	// last hop's). The sub-bass tells beat from off-beat better on a house
	// track, but peaks later and less sharply, so it doesn't set the timing.
	double	fSubFlux = 0;
	if (m_bPrimed) {
		for (size_t k = m_rSubBass.iFirst; k <= m_rSubBass.iLast; k++)
			fSubFlux += std::max(m_aMag[k] - m_aPrevMag[k], 0.0);
	}
	m_beat.Process(m_aRawFlux[ONSET_Bass] + m_aRawFlux[ONSET_All], fSubFlux, m_fLevelDb < kSilentDb);
	m_src.aCount[ModSources::SRC_Beat] = m_beat.GetBeatCount();
	for (int i = 0; i < BeatTracker::SPANS; i++)	// Bar, 4-Bar ... 32-Bar
		m_src.aCount[ModSources::SRC_Bar + i] = m_beat.GetSpanCount(i);
	m_src.bBeat = m_beat.IsLocked();	// the position, for beat-based rows
	m_src.fBeatPos = m_beat.GetBeatPosition();
	m_src.fTempo = m_beat.GetTempo();
	m_iHist = (m_iHist + 1) % m_nHistSize;
	m_nHist = std::min(m_nHist + 1, m_nHistSize);
	std::swap(m_aMag, m_aPrevMag);
	m_bPrimed = true;
	m_nAnalyses++;
}

} // namespace whorld
