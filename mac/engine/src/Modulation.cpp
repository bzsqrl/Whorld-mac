// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Modulation routing (new in the Mac port); see Modulation.h and AUDIO_PLAN.md.

#include "whorld/Modulation.h"

#include <algorithm>
#include <cmath>

namespace whorld {

namespace {

struct SourceInfo {
	const char*	pszTag;
	const char*	pszName;
	bool		bTrigger;
};

const SourceInfo kSource[ModSources::SOURCES] = {
	#define MODSOURCEDEF(name, trigger, text) {#name, text, trigger},
	#include "whorld/ModulationDef.h"
};

struct ActionInfo {
	const char*	pszTag;
	const char*	pszName;
};

const ActionInfo kAction[ModActions::ACTIONS] = {
	#define MODACTIONDEF(name, text) {#name, text},
	#include "whorld/ModulationDef.h"
};

} // namespace

bool ModSources::IsTrigger(int iSource)
{
	return IsValid(iSource) && kSource[iSource].bTrigger;
}

int ModSources::SpanBeats(int iSource)
{
	switch (iSource) {
	case SRC_Beat: return 1;
	case SRC_Bar: return 4;
	case SRC_Bar4: return 16;
	case SRC_Bar8: return 32;
	case SRC_Bar16: return 64;
	case SRC_Bar32: return 128;
	default: return 0;
	}
}

const char* ModSources::GetTag(int iSource)
{
	return IsValid(iSource) ? kSource[iSource].pszTag : "";
}

const char* ModSources::GetName(int iSource)
{
	return IsValid(iSource) ? kSource[iSource].pszName : "";
}

int ModSources::FindTag(const std::string& sTag)
{
	for (int i = 0; i < SOURCES; i++) {
		if (sTag == kSource[i].pszTag)
			return i;
	}
	return -1;
}

const char* ModActions::GetTag(int iAction)
{
	return IsValid(iAction) ? kAction[iAction].pszTag : "";
}

const char* ModActions::GetName(int iAction)
{
	return IsValid(iAction) ? kAction[iAction].pszName : "";
}

int ModActions::FindTag(const std::string& sTag)
{
	for (int i = 0; i < ACTIONS; i++) {
		if (sTag == kAction[i].pszTag)
			return i;
	}
	return -1;
}

bool ModRow::IsModulatable(int iTarget, int iProp)
{
	if (iTarget >= 0 && iTarget < MappingBase::PARAM_COUNT) {	// a parameter
		if (iProp == MappingBase::PARAM_PROP_Val)
			return true;
		return iProp == MappingBase::PARAM_PROP_Global && MappingBase::MapParamToGlobal(iTarget) >= 0;
	}
	if (iTarget >= MappingBase::TARGET_Speed && iTarget < MappingBase::TARGET_Speed + MappingBase::MASTER_COUNT)
		return true;	// a master property
	return iTarget == MappingBase::TARGET_Hue || iTarget == MappingBase::TARGET_OriginX
		|| iTarget == MappingBase::TARGET_OriginY;
}

void Modulator::SetRows(const std::vector<ModRow>& aRow)
{
	m_aRow = aRow;
	m_aState.assign(aRow.size(), State());
	m_fTime = 0;
}

double Modulator::GetRowLevel(size_t iRow) const
{
	return iRow < m_aState.size() ? m_aState[iRow].fLevel : 0;
}

// One-pole smoothing toward fTarget with time constant fTime (seconds):
// after fTime, 63% of the way there. Time-based, so it's the same at any
// frame rate.
double Modulator::Smooth(double fEnv, double fTarget, double dt, double fTime)
{
	if (fTime <= 0 || dt <= 0)
		return dt > 0 || fTime <= 0 ? fTarget : fEnv;
	return fEnv + (fTarget - fEnv) * (1 - std::exp(-dt / fTime));
}

double Modulator::Shape(int nCurve, double x, double fThreshold)
{
	switch (nCurve) {
	case ModRow::CURVE_Soft:
		return std::sqrt(x);
	case ModRow::CURVE_Hard:
		return x * x;
	case ModRow::CURVE_Gate:
		return x >= fThreshold ? 1 : 0;
	default:
		return x;
	}
}

void Modulator::Step(const ModSources& src, double dt, ModOutput& out)
{
	out.Clear();
	if (dt > 0)
		m_fTime += dt;
	for (size_t iRow = 0; iRow < m_aRow.size(); iRow++) {
		const ModRow&	row = m_aRow[iRow];
		State&	st = m_aState[iRow];
		if (!row.bOn || !ModSources::IsValid(row.iSource)) {
			st = State();	// starts afresh when turned back on
			continue;
		}
		bool	bFired = false;	// a trigger source fired
		if (int nSpan = ModSources::SpanBeats(row.iSource)) {
			// beat-based: when the beat position, shifted by the offset, enters
			// a new span (a beat, a bar, a phrase). Also when a jump lands near a
			// span's start (Mark Downbeat a little late), not in its middle.
			if (src.bBeat && src.fTempo > 0) {
				double	fPos = src.fBeatPos - row.fOffset * src.fTempo / 60;
				int64_t	iSpan = static_cast<int64_t>(std::floor(fPos / nSpan));
				double	fInto = fPos - static_cast<double>(iSpan) * nSpan;	// beats into the span
				bFired = st.bSpanKnown && iSpan != st.iSpan && fInto < 0.5;
				st.iSpan = iSpan;
				st.bSpanKnown = true;
			} else {
				st.bSpanKnown = false;	// no beat: nothing until it's back
			}
		} else if (ModSources::IsTrigger(row.iSource)) {
			uint32_t	nCount = src.aCount[row.iSource];
			bool	bHit = st.bPrimed && nCount != st.nCount;	// several hits in a frame fire once
			st.nCount = nCount;
			st.bPrimed = true;
			if (bHit) {
				if (row.fOffset > 0) {	// late: fire after the offset (hits can't come early)
					if (st.nPending < MAX_PENDING)
						st.aPending[st.nPending++] = m_fTime + row.fOffset;
				} else {
					bFired = true;
				}
			}
			for (int i = 0; i < st.nPending; ) {	// delayed hits due
				if (st.aPending[i] <= m_fTime) {
					bFired = true;
					st.aPending[i] = st.aPending[--st.nPending];
				} else {
					i++;
				}
			}
		}
		if (ModSources::IsTrigger(row.iSource)) {
			// a pulse: jumps to 1 on a hit, then decays over the release
			st.fEnv = bFired ? 1 : Smooth(st.fEnv, 0, dt, row.fRelease);
		} else {
			double	x = std::clamp(static_cast<double>(src.aValue[row.iSource]), 0.0, 1.0);
			st.fEnv = Smooth(st.fEnv, x, dt, x > st.fEnv ? row.fAttack : row.fRelease);
		}
		st.fLevel = Shape(row.nCurve, std::clamp(st.fEnv, 0.0, 1.0), row.fThreshold);
		if (row.IsAction()) {
			bool	bFire;
			if (ModSources::IsTrigger(row.iSource)) {
				bFire = bFired;
			} else {	// rising through the threshold; re-arms below it
				bool	bAbove = st.fLevel >= row.fThreshold;
				bFire = bAbove && !st.bAbove;
				st.bAbove = bAbove;
			}
			if (bFire && !m_bBypass)
				out.nActions |= 1u << row.iAction;
			continue;
		}
		if (!ModRow::IsModulatable(row.iTarget, row.iProp) || m_bBypass)
			continue;
		out.bActive = true;
		double	fOffset = (row.bCentered ? st.fLevel - 0.5 : st.fLevel) * row.fAmount * m_fDepth;
		if (row.iTarget < MappingBase::PARAM_COUNT) {	// rows on one target add up
			if (row.iProp == MappingBase::PARAM_PROP_Global)
				out.aGlobal[row.iTarget] += fOffset;
			else
				out.aParam[row.iTarget] += fOffset;
		} else if (row.iTarget < MappingBase::TARGET_Speed + MappingBase::MASTER_COUNT) {
			out.aMaster[row.iTarget - MappingBase::TARGET_Speed] += fOffset;
		} else if (row.iTarget == MappingBase::TARGET_Hue) {
			out.fHue += fOffset;
		} else if (row.iTarget == MappingBase::TARGET_OriginX) {
			out.fOriginX += fOffset;
		} else if (row.iTarget == MappingBase::TARGET_OriginY) {
			out.fOriginY += fOffset;
		}
	}
}

} // namespace whorld
