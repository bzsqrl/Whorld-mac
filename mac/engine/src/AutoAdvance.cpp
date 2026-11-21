// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Playlist auto-advance (new in the Mac port); see AutoAdvance.h.

#include "whorld/AutoAdvance.h"
#include "whorld/Modulation.h"

#include <algorithm>
#include <cmath>

namespace whorld {

double AutoAdvance::MinLength(int nUnit)
{
	switch (nUnit) {
	case UNIT_Beats: return 1;
	case UNIT_Bars: return 0.25;
	default: return 1;	// seconds
	}
}

double AutoAdvance::MaxLength(int nUnit)
{
	switch (nUnit) {
	case UNIT_Beats: return 1024;
	case UNIT_Bars: return 256;
	default: return 3600;
	}
}

double AutoAdvance::ClampLength(double fLength, int nUnit)
{
	if (!std::isfinite(fLength))
		fLength = kDefaultLength;
	return std::clamp(fLength, MinLength(nUnit), MaxLength(nUnit));
}

void AutoAdvance::SetLength(double fLength, int nUnit)
{
	if (!IsValidUnit(nUnit))
		nUnit = UNIT_Seconds;
	fLength = ClampLength(fLength, nUnit);
	if (fLength == m_fLength && nUnit == m_nUnit)
		return;
	bool	bUnitChanged = nUnit != m_nUnit;
	m_fLength = fLength;
	m_nUnit = nUnit;
	if (!m_bRunning)
		return;
	if (bUnitChanged) {	// seconds and beats don't convert: count afresh
		m_bPending = true;
	} else if (m_nUnit != UNIT_Seconds && !m_bPending) {	// the same start, a new end
		m_fTarget = OnGrid(m_fStart + SpanBeats());
		if (m_fTarget <= m_fPos)	// already past it: the next grid point
			m_fTarget = OnGrid(m_fPos + std::max(GridBeats(), 1e-9));
	}
}

void AutoAdvance::Start()
{
	m_bRunning = true;
	m_bPending = true;
}

void AutoAdvance::Stop()
{
	m_bRunning = false;
	m_bPending = false;
	m_fElapsed = 0;
}

void AutoAdvance::Restart()
{
	if (m_bRunning)
		m_bPending = true;
}

double AutoAdvance::SpanBeats() const
{
	return m_nUnit == UNIT_Bars ? m_fLength * kBeatsPerBar : m_fLength;
}

// Whole bars land on bars' first beats; whole beats (or bars of whole
// beats) on beats; any other length runs free
double AutoAdvance::GridBeats() const
{
	double	fSpan = SpanBeats();
	if (m_nUnit == UNIT_Bars && m_fLength == std::floor(m_fLength))
		return kBeatsPerBar;
	if (fSpan == std::floor(fSpan))
		return 1;
	return 0;
}

double AutoAdvance::OnGrid(double fPos) const
{
	double	g = GridBeats();
	return g > 0 ? std::round(fPos / g) * g : fPos;
}

// The count from fFrom: the grid point nearest the length, and never at or
// before the start
void AutoAdvance::Plan(double fFrom)
{
	m_fStart = fFrom;
	m_fTarget = OnGrid(fFrom + SpanBeats());
	double	g = GridBeats();
	while (m_fTarget <= fFrom)
		m_fTarget += g > 0 ? g : SpanBeats();
}

bool AutoAdvance::Step(double dt, bool bPaused, const ModSources& src)
{
	dt = std::max(dt, 0.0);
	// the beat clock runs whatever the unit, so a switch to beats finds it
	bool	bKnown = src.bBeat;
	if (bKnown && src.fTempo > 0)
		m_fLastTempo = src.fTempo;
	double	fTempo = m_fLastTempo > 0 ? m_fLastTempo : kDefaultTempo;
	double	fFree = m_fPos + dt * fTempo / 60;	// where the clock would be by itself
	double	fPos = bKnown ? src.fBeatPos : fFree;
	// a jump: the beat found (again), moved by hand, or the tracker's own
	// correction of more than half a beat
	bool	bJump = m_bHaveClock && bKnown && (!m_bBeatKnown || src.nBeatMoves != m_nBeatMoves
		|| std::fabs(fPos - fFree) > 0.5);
	m_bBeatKnown = bKnown;
	m_nBeatMoves = src.nBeatMoves;
	double	fPrev = m_fPos;
	m_fPos = fPos;
	bool	bHadClock = m_bHaveClock;
	m_bHaveClock = true;
	if (!m_bRunning)
		return false;
	if (m_bPending) {
		m_bPending = false;
		m_fElapsed = 0;
		Plan(fPos);
		return false;
	}
	if (m_nUnit == UNIT_Seconds) {
		if (!bPaused)
			m_fElapsed += dt;
		if (m_fElapsed < m_fLength)
			return false;
		m_fElapsed = std::fmod(m_fElapsed - m_fLength, m_fLength);	// at most one patch a frame
		return true;
	}
	if (bJump && bHadClock) {	// keep what was left, from the beat's new place
		double	fLeft = m_fTarget - fPrev;
		double	fDone = fPrev - m_fStart;
		m_fStart = fPos - fDone;
		m_fTarget = OnGrid(fPos + fLeft);
		if (m_fTarget <= fPos)	// it rounded back to now: the next grid point
			m_fTarget = OnGrid(fPos + std::max(GridBeats(), fLeft));
		if (m_fTarget <= fPos)
			m_fTarget = fPos + std::max(GridBeats(), 1e-9);
		return false;
	}
	if (fPos < m_fTarget)
		return false;
	// time for the next patch; its count starts where this one ended
	double	fEnd = m_fTarget;
	Plan(fEnd);
	while (m_fTarget <= fPos)	// a long stall: at most one patch a frame
		Plan(m_fTarget);
	return true;
}

AutoAdvance::Status AutoAdvance::GetStatus() const
{
	Status	st;
	st.bRunning = m_bRunning;
	if (!m_bRunning)
		return st;
	if (m_nUnit == UNIT_Seconds) {
		st.fProgress = m_bPending ? 0 : std::clamp(m_fElapsed / m_fLength, 0.0, 1.0);
	} else {
		double	fSpan = m_fTarget - m_fStart;
		st.fProgress = m_bPending || fSpan <= 0 ? 0 : std::clamp((m_fPos - m_fStart) / fSpan, 0.0, 1.0);
		st.bFollowingBeat = m_bBeatKnown;
		st.fTempo = m_fLastTempo > 0 ? m_fLastTempo : kDefaultTempo;
	}
	return st;
}

}	// namespace whorld
