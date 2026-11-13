// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Beat tracking (new in the Mac port; AUDIO_PLAN.md, Phase 9.5): finds the
// tempo and the beat from an onset strength signal (one value per analysis
// hop), and keeps a steady beat going through hits the onset detectors miss
// (a kick masked by the bassline) or that aren't there (a short break).
// Deterministic: the same onsets give the same beats.
//
//   Tempo: autocorrelation of the last 8 seconds of onsets, every third of
//     a second, over 70 to 180 BPM; echoes at twice the period count too,
//     and a gentle preference for the middle of the range settles half and
//     double tempo. A new tempo must be seen several times before it's taken.
//   Phase: a comb over the last 8 beats finds when the latest beat fell; a
//     running beat clock is nudged toward it, so one missed or extra hit
//     hardly moves it. A big error (half a beat, when a breakdown leaves only
//     the off-beat sounds) must persist 16 beats, and the sub-bass onsets (the
//     kick) must back it 3 to 1, before the clock jumps.
//   Beats: when the clock (shifted by the onset signal's own delay, so beats
//     land on the sound) crosses a whole beat, while locked; after the music
//     loses its beat (or goes quiet), for 8 beats more, then none until it
//     locks again.

#include <cstddef>
#include <cstdint>
#include <vector>

namespace whorld {

class BeatTracker {
public:
	void	Reset(double fHopRate);	// analyses a second
	// one hop's onset strengths (0 or more): all of them, for the tempo and
	// the phase, and the sub-bass's, which must back a jump in phase; and
	// whether the hop was silent
	void	Process(double fOnset, double fPhaseOnset, bool bSilent);
	bool	IsLocked() const { return m_bLocked; }
	double	GetTempo() const;		// BPM, 0 until a tempo is found
	double	GetPhase() const;		// 0 to 1 through the beat (shifted like the beats)
	uint32_t	GetBeatCount() const { return m_nBeats; }
	// Bars and phrases (Mac addition, user's request): beats are numbered
	// from the first after locking, which is "the one" until MarkDownbeat
	// says otherwise; it makes the beat nearest now the one (the last beat if
	// it's less than half a beat ago, and then every span fires at once; else
	// the next). 4 beats to a bar.
	void	MarkDownbeat();
	int		GetBeatInBar() const;	// 0 to 3, the beat just counted (-1 before any)
	int		GetBarInPhrase() const;	// 0 to 31, its bar in 32
	// beats that began a span of nBeats (4: bars, 16: 4 bars, ... 128: 32 bars)
	uint32_t	GetSpanCount(int iSpan) const { return m_aSpanCount[iSpan]; }
	static constexpr int	SPANS = 5;
	static const int	kSpanBeats[SPANS];	// 4, 16, 32, 64, 128
	double	GetConfidence() const { return m_fConfidence; }	// 0 to 1, how clear the beat is

private:
	double	m_fHopRate = 0;
	std::vector<double>	m_aOnset;	// circular
	std::vector<double>	m_aPhaseOnset;	// circular, alongside: the sub-bass's
	size_t	m_iWrite = 0;
	size_t	m_nFilled = 0;
	uint64_t	m_nHops = 0;
	std::vector<double>	m_aAcf;		// scratch for the autocorrelation
	double	m_fPeriod = 0;		// hops per beat; 0 until found
	double	m_fCandidate = 0;	// a different tempo seen lately
	int		m_nCandidate = 0;	// times in a row
	double	m_fClock = 0;		// beats, continuous
	double	m_fConfidence = 0;
	bool	m_bLocked = false;
	int		m_nUnsure = 0;		// beats since the beat was last clear
	double	m_fJumpHops = 0;	// hops a big phase error has persisted
	bool	m_bBeatSilent = true;	// every hop so far this beat was silent
	bool	m_bMayLock = true;	// false from losing the beat until the comb forgets it
	uint32_t	m_nBeats = 0;
	int64_t	m_iBeat = -1;		// the last beat counted, numbered from the one (-1: none yet)
	bool	m_bMarkNext = false;	// MarkDownbeat while unlocked: the next beat is the one
	uint32_t	m_aSpanCount[SPANS] = {};

	double	Onset(const std::vector<double>& a, double fAgo) const;	// fAgo hops ago, interpolated
	void	EstimateTempo();
	void	TrackPhase();
	double	SubBassComb(double fAgo) const;
};

} // namespace whorld
