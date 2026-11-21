// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Playlist auto-advance (new in the Mac port, the user's request,
// 2026-11-20): when to play the playlist's next patch, every so many
// seconds, beats or bars. The host steps it once a frame and plays the next
// patch when Step says so.
//
// Seconds count only while the picture runs (not paused). Beats and bars
// follow the beat (the tracker's or Ableton Link's, ModSources) and switch
// on a beat, or on a bar's first beat for whole bars; the first switch after
// Play is the grid point nearest the length, so the rest fall on the grid.
// Without a beat (no input, not found yet, or lost) the count goes on at the
// last tempo heard, or 120 BPM, and picks the beat up again when it's back,
// keeping what was left. Pause doesn't stop beats: the music goes on.

#ifndef WHORLD_AUTO_ADVANCE_H
#define WHORLD_AUTO_ADVANCE_H

#include <cstdint>

namespace whorld {

struct ModSources;

class AutoAdvance {
public:
	enum {
		UNIT_Seconds,
		UNIT_Beats,
		UNIT_Bars,
		UNITS
	};
	static constexpr double kDefaultTempo = 120;	// BPM, before any beat
	static constexpr double kDefaultLength = 30;	// seconds
	static constexpr int	kBeatsPerBar = 4;		// as the beat tracker counts
	// the lengths allowed, in the unit's own terms
	static double	MinLength(int nUnit);
	static double	MaxLength(int nUnit);
	static double	ClampLength(double fLength, int nUnit);
	static bool		IsValidUnit(int nUnit) { return nUnit >= 0 && nUnit < UNITS; }

	struct Status {
		bool	bRunning = false;
		double	fProgress = 0;		// 0 to 1, toward the next patch
		bool	bFollowingBeat = false;	// beats or bars, on the beat (else at fTempo)
		double	fTempo = 0;			// BPM counted at (beats or bars)
	};

	// Changes the length; a running count keeps its start and aims anew
	void	SetLength(double fLength, int nUnit);
	double	GetLength() const { return m_fLength; }
	int		GetUnit() const { return m_nUnit; }
	void	Start();	// counts from the next Step
	void	Stop();
	bool	IsRunning() const { return m_bRunning; }
	void	Restart();	// a patch played otherwise: counts from the next Step
	// One frame, dt seconds since the last: true when it's time for the next patch
	bool	Step(double dt, bool bPaused, const ModSources& src);
	Status	GetStatus() const;

protected:
	double	m_fLength = kDefaultLength;
	int		m_nUnit = UNIT_Seconds;
	bool	m_bRunning = false;
	bool	m_bPending = false;		// plan the count at the next Step
	double	m_fElapsed = 0;			// seconds
	// beats and bars: a clock in beats (the beat's position while it's known)
	double	m_fPos = 0;
	double	m_fStart = 0;			// where this patch's count began
	double	m_fTarget = 0;			// where it ends
	double	m_fLastTempo = 0;		// the last tempo heard, BPM
	bool	m_bBeatKnown = false;	// the beat was known at the last Step
	uint32_t	m_nBeatMoves = 0;
	bool	m_bHaveClock = false;	// m_fPos has been set

	double	SpanBeats() const;	// the length in beats
	double	GridBeats() const;	// what switches land on, in beats; 0: none
	double	OnGrid(double fPos) const;
	void	Plan(double fFrom);
};

}	// namespace whorld

#endif
