// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Beat tracking (new in the Mac port); see BeatTracker.h and AUDIO_PLAN.md.

#include "whorld/BeatTracker.h"

#include <algorithm>
#include <iterator>
#include <cmath>

namespace whorld {

namespace {

const double kWindowSeconds = 8;	// onsets kept, for tempo and phase
const double kMinBpm = 70;
const double kMaxBpm = 180;
const double kTempoEvery = 0.33;	// seconds between tempo estimates
const double kPriorBpm = 120;		// the gentle preference: centered here...
const double kPriorOctaves = 0.9;	// ...this wide (a standard deviation, in octaves)
const double kTempoTolerance = 0.04;	// within this, a new estimate refines the tempo
const int	kTempoConfirm = 3;		// a different tempo must be seen this many times in a row
const int	kCombBeats = 8;			// beats the phase comb looks back
const double kCombDecay = 0.85;		// each older beat counts this much less
const double kPhaseGain = 0.08;		// share of the phase error corrected each hop
const double kConfidenceSmoothing = 0.05;	// per hop
const double kLockConfidence = 0.3;	// locks above this...
const double kUnsureConfidence = 0.15;	// ...and is unsure below it
const int	kFlywheelBeats = 8;		// beats kept going after the beat is lost
// The onset signal peaks about this many hops after a sound starts (the
// sound must reach the window's heavier middle); beats are shifted earlier
// by it, so they land on the sound. Measured with synthetic kicks.
const double kOnsetDelayHops = 1.5;
// A phase error up to this (beats) is corrected smoothly. A bigger one, as
// when a breakdown leaves only the off-beat sounds, must persist this many
// beats, and the sub-bass (the kick: on a house track 3 to 6 times stronger
// on the beat than off it) must back the new phase over the current one by
// this much, before the clock jumps to it (two songs crossfaded out of
// phase); so the beat rides through breakdowns. Tuned on a 124 BPM house
// track: with 8 beats or a smaller margin, its kickless breakdown (with an
// off-beat sub bassline) pulled the beat half a beat over.
const double kSmallPhaseError = 0.15;
const double kJumpConfirmBeats = 16;
const double kSubBassMargin = 3.0;

} // namespace

const int BeatTracker::kSpanBeats[BeatTracker::SPANS] = {4, 16, 32, 64, 128};

void BeatTracker::Reset(double fHopRate)
{
	m_fHopRate = fHopRate > 0 ? fHopRate : 93.75;
	m_aOnset.assign(static_cast<size_t>(std::ceil(kWindowSeconds * m_fHopRate)), 0.0);
	m_aPhaseOnset.assign(m_aOnset.size(), 0.0);
	m_iWrite = 0;
	m_nFilled = 0;
	m_nHops = 0;
	m_aAcf.clear();
	m_fPeriod = 0;
	m_fCandidate = 0;
	m_nCandidate = 0;
	m_fClock = 0;
	m_fConfidence = 0;
	m_bLocked = false;
	m_nUnsure = 0;
	m_nBeats = 0;
	m_iBeat = -1;
	m_bMarkNext = false;
	std::fill(std::begin(m_aSpanCount), std::end(m_aSpanCount), 0u);
	m_fJumpHops = 0;
	m_bBeatSilent = true;
	m_bMayLock = true;
	m_aAcf.reserve(static_cast<size_t>(2 * m_fHopRate * 60 / kMinBpm) + 4);
}

double BeatTracker::GetTempo() const
{
	return m_fPeriod > 0 ? 60 * m_fHopRate / m_fPeriod : 0;
}

double BeatTracker::GetPhase() const
{
	if (m_fPeriod <= 0)
		return 0;
	double	f = m_fClock + kOnsetDelayHops / m_fPeriod;
	return f - std::floor(f);
}

void BeatTracker::MarkDownbeat()
{
	if (!m_bLocked || m_iBeat < 0) {	// the next beat counted is the one
		m_bMarkNext = true;
		return;
	}
	if (GetPhase() < 0.5) {	// the last beat was the one (pressed a little late):
		m_iBeat = 0;		// it begins every span, so they fire now
		for (uint32_t& n : m_aSpanCount)
			n++;
	} else {				// the next is (pressed a little early)
		m_iBeat = -1;
	}
}

int BeatTracker::GetBeatInBar() const
{
	return m_iBeat < 0 ? -1 : static_cast<int>(m_iBeat % 4);
}

int BeatTracker::GetBarInPhrase() const
{
	return m_iBeat < 0 ? -1 : static_cast<int>((m_iBeat / 4) % 32);
}

double BeatTracker::Onset(const std::vector<double>& aOnset, double fAgo) const
{
	const size_t	n = aOnset.size();
	if (fAgo < 0 || fAgo > static_cast<double>(m_nFilled) - 2)
		return 0;
	size_t	i0 = static_cast<size_t>(fAgo);
	double	fFrac = fAgo - static_cast<double>(i0);
	double	a = aOnset[(m_iWrite + n - 1 - i0) % n];
	double	b = aOnset[(m_iWrite + n - 2 - i0) % n];
	return a + (b - a) * fFrac;
}

void BeatTracker::Process(double fOnset, double fPhaseOnset, bool bSilent)
{
	if (m_aOnset.empty())
		Reset(m_fHopRate);
	m_aOnset[m_iWrite] = std::max(fOnset, 0.0);
	m_aPhaseOnset[m_iWrite] = std::max(fPhaseOnset, 0.0);
	m_iWrite = (m_iWrite + 1) % m_aOnset.size();
	m_nFilled = std::min(m_nFilled + 1, m_aOnset.size());
	m_nHops++;
	size_t	nEvery = std::max<size_t>(1, static_cast<size_t>(std::lround(kTempoEvery * m_fHopRate)));
	if (m_nHops % nEvery == 0 && m_nFilled >= m_aOnset.size() / 2)
		EstimateTempo();
	if (m_fPeriod <= 0)
		return;
	double	fShift = kOnsetDelayHops / m_fPeriod;
	double	fBefore = m_fClock + fShift;
	m_fClock += 1 / m_fPeriod;
	TrackPhase();
	m_bBeatSilent = m_bBeatSilent && bSilent;
	double	fAfter = m_fClock + fShift;
	if (std::floor(fAfter) > std::floor(fBefore)) {	// a beat
		// unsure when the comb is unclear, or this whole beat was silent
		// (the comb still remembers the music for a few beats)
		if (m_fConfidence < kUnsureConfidence || m_bBeatSilent)
			m_nUnsure++;
		else
			m_nUnsure = 0;
		m_bBeatSilent = true;
		if (m_bLocked && m_nUnsure > kFlywheelBeats) {
			m_bLocked = false;	// the beat's gone: stop until it's found again
			m_bMayLock = false;	// (after the comb has forgotten it)
			m_iBeat = -1;		// and count bars afresh from the next lock
		}
		if (m_bLocked) {
			m_nBeats++;
			m_iBeat++;	// the first after locking is 0, the one
			if (m_bMarkNext) {
				m_iBeat = 0;
				m_bMarkNext = false;
			}
			for (int i = 0; i < SPANS; i++) {
				if (m_iBeat % kSpanBeats[i] == 0)
					m_aSpanCount[i]++;
			}
		}
	}
}

// Autocorrelation of the onsets over the tempo range; an echo at twice the
// period adds to a lag's score, and the prior settles half or double tempo.
void BeatTracker::EstimateTempo()
{
	const size_t	n = m_nFilled;
	const size_t	nMinLag = static_cast<size_t>(std::floor(m_fHopRate * 60 / kMaxBpm));
	const size_t	nMaxLag = static_cast<size_t>(std::ceil(m_fHopRate * 60 / kMinBpm));
	if (n <= 2 * nMaxLag + 2)
		return;
	double	fMean = 0;
	for (size_t i = 0; i < n; i++)
		fMean += Onset(m_aOnset, static_cast<double>(i));
	fMean /= static_cast<double>(n);
	auto	x = [&](size_t i) { return Onset(m_aOnset, static_cast<double>(i)) - fMean; };
	double	fEnergy = 0;
	for (size_t i = 0; i < n; i++)
		fEnergy += x(i) * x(i);
	if (fEnergy <= 1e-9)
		return;	// silence: keep what we have
	m_aAcf.assign(2 * nMaxLag + 2, 0.0);
	for (size_t lag = nMinLag; lag < m_aAcf.size(); lag++) {
		double	s = 0;
		for (size_t i = 0; i + lag < n; i++)
			s += x(i) * x(i + lag);
		m_aAcf[lag] = s / static_cast<double>(n - lag);
	}
	auto	score = [&](size_t lag) {
		double	fBpm = 60 * m_fHopRate / static_cast<double>(lag);
		double	fOct = std::log2(fBpm / kPriorBpm) / kPriorOctaves;
		return (m_aAcf[lag] + 0.5 * m_aAcf[2 * lag]) * std::exp(-0.5 * fOct * fOct);
	};
	size_t	iBest = nMinLag;
	double	fBest = -1e300;
	for (size_t lag = nMinLag; lag <= nMaxLag; lag++) {
		double	s = score(lag);
		if (s > fBest) {
			fBest = s;
			iBest = lag;
		}
	}
	if (fBest <= 0)
		return;	// nothing periodic
	double	fLag = static_cast<double>(iBest);
	if (iBest > nMinLag && iBest < nMaxLag) {	// parabolic refinement
		double	a = score(iBest - 1), b = fBest, c = score(iBest + 1);
		double	fDen = a - 2 * b + c;
		if (fDen < 0)
			fLag += std::clamp(0.5 * (a - c) / fDen, -0.5, 0.5);
	}
	if (m_fPeriod <= 0) {
		m_fPeriod = fLag;
		m_fClock = 0;
	} else if (std::fabs(fLag / m_fPeriod - 1) < kTempoTolerance) {
		m_fPeriod += 0.25 * (fLag - m_fPeriod);	// refine
		m_nCandidate = 0;
	} else {	// a different tempo: take it once it's been seen a few times
		if (m_nCandidate && std::fabs(fLag / m_fCandidate - 1) < kTempoTolerance) {
			m_fCandidate += 0.5 * (fLag - m_fCandidate);
			m_nCandidate++;
		} else {
			m_fCandidate = fLag;
			m_nCandidate = 1;
		}
		if (m_nCandidate >= kTempoConfirm) {
			m_fPeriod = m_fCandidate;
			m_nCandidate = 0;
		}
	}
}

double BeatTracker::SubBassComb(double fAgo) const
{
	double	s = 0, w = 1;
	for (int k = 0; k < kCombBeats; k++) {
		s += w * Onset(m_aPhaseOnset, fAgo + k * m_fPeriod);
		w *= kCombDecay;
	}
	return s;
}

// The comb: for each place the latest beat might have been, the onsets at
// that place and the beats before it; the best one, and how clearly it beats
// the rest, steer the clock.
void BeatTracker::TrackPhase()
{
	const double	P = m_fPeriod;
	if (static_cast<double>(m_nFilled) < (kCombBeats + 1) * P)
		return;
	double	fBest = -1, fSum = 0, fBestAgo = 0;
	int		nCandidates = 0;
	for (double d = 0; d < P; d += 0.5) {
		double	s = 0, w = 1;
		for (int k = 0; k < kCombBeats; k++) {
			s += w * Onset(m_aOnset, d + k * P);
			w *= kCombDecay;
		}
		fSum += s;
		nCandidates++;
		if (s > fBest) {
			fBest = s;
			fBestAgo = d;
		}
	}
	double	fMean = fSum / nCandidates;
	double	c = fBest > 1e-12 ? (fBest - fMean) / fBest : 0;
	m_fConfidence += (c - m_fConfidence) * kConfidenceSmoothing;
	double	fFrac = m_fClock - std::floor(m_fClock);	// beats since the last beat
	double	fError = fBestAgo / P - fFrac;			// the comb says the last beat was this much longer ago
	fError -= std::round(fError);					// -0.5 to 0.5
	if (!m_bLocked) {
		if (m_fConfidence < kUnsureConfidence)
			m_bMayLock = true;
		if (m_bMayLock && m_fConfidence > kLockConfidence) {	// lock: straight onto the comb's beat
			m_fClock = std::floor(m_fClock) + fBestAgo / P;
			m_bLocked = true;
			m_nUnsure = 0;
		}
		return;
	}
	if (std::fabs(fError) <= kSmallPhaseError) {
		double	fWeight = std::min(1.0, m_fConfidence / kLockConfidence);	// an unclear comb steers less
		m_fClock += kPhaseGain * fWeight * fError;
		m_fJumpHops = 0;
	} else if (m_fConfidence > kLockConfidence
	&& SubBassComb(fBestAgo) > kSubBassMargin * SubBassComb(fFrac * P)) {	// a clear beat elsewhere, with the kick: is it staying?
		m_fJumpHops += 1;
		if (m_fJumpHops >= kJumpConfirmBeats * P) {
			m_fClock = std::floor(m_fClock) + fBestAgo / P;
			m_fJumpHops = 0;
		}
	} else {
		m_fJumpHops = std::max(0.0, m_fJumpHops - 1);
	}
}

} // namespace whorld
