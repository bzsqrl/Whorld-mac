// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Modulation (new in the Mac port; design in AUDIO_PLAN.md): sources such
// as the music's level or a hit, routed by rows to controls (as render-only
// offsets the engine adds beside each control's oscillator) or to actions.
// The Modulator is pure: the same sources and time steps give the same
// output, so it works live, offline and in tests. It doesn't touch the
// engine; the host passes its output to WhorldEngine::SetModulation.

#include "whorld/Mapping.h"

#include <cstdint>
#include <string>
#include <vector>

namespace whorld {

// What the sources are this frame. The analyzer (and later Ableton Link)
// fills it; continuous sources are 0 to 1, and trigger sources count their
// hits, so a hit between two frames isn't missed.
struct ModSources {
	enum {
		#define MODSOURCEDEF(name, trigger, text) SRC_##name,
		#include "whorld/ModulationDef.h"
		SOURCES
	};
	float		aValue[SOURCES] = {};	// continuous sources, 0 to 1
	uint32_t	aCount[SOURCES] = {};	// trigger sources: hits so far
	// The beat, when known (the beat tracker, later Ableton Link): beats
	// since the one, continuous (just below 0 before the first), and the
	// tempo. Beat-based rows fire from this, so they can fire early or late
	// (ModRow::fOffset); the counts above are for meters.
	bool		bBeat = false;
	double		fBeatPos = 0;
	double		fTempo = 0;	// BPM

	static bool			IsValid(int iSource) { return iSource >= 0 && iSource < SOURCES; }
	static bool			IsTrigger(int iSource);
	static const char*	GetTag(int iSource);	// stable name, for settings files
	static const char*	GetName(int iSource);	// shown in the UI
	static int			FindTag(const std::string& sTag);	// -1 if unknown
	// beats in the span a beat-based source marks (Beat 1, Bar 4, 4-Bar 16
	// ... 32-Bar 128), or 0 for the rest
	static int			SpanBeats(int iSource);
};

// One-shot actions a row can fire (a trigger, or a continuous source
// crossing the row's threshold upward). The host carries them out.
struct ModActions {
	enum {
		#define MODACTIONDEF(name, text) ACT_##name,
		#include "whorld/ModulationDef.h"
		ACTIONS
	};
	static bool			IsValid(int iAction) { return iAction >= 0 && iAction < ACTIONS; }
	static const char*	GetTag(int iAction);
	static const char*	GetName(int iAction);
	static int			FindTag(const std::string& sTag);
};

// A routing row. Amount is a fraction of the target's slider travel
// (-1 to 1): for Hue, of the hue wheel; for Origin X and Y, of the view.
struct ModRow {
	enum {	// response curve, applied after smoothing
		CURVE_Linear,	// as is
		CURVE_Soft,		// square root: quiet passages count for more
		CURVE_Hard,		// square: only loud passages count
		CURVE_Gate,		// 1 at or above the threshold, else 0
		CURVES
	};
	bool	bOn = true;
	int		iSource = ModSources::SRC_Level;
	int		iAction = -1;	// if a valid action, the row fires it instead of moving a control
	int		iTarget = MappingBase::TARGET_RingGrowth;	// a mapping target (a control)
	int		iProp = MappingBase::PARAM_PROP_Val;	// parameters: Val or Global
	double	fAmount = 0;	// -1 to 1, of the target's travel
	int		nCurve = CURVE_Linear;
	bool	bCentered = false;	// -amount/2 to +amount/2, instead of 0 to amount
	double	fAttack = 0.01;		// seconds to rise (time constant)
	double	fRelease = 0.2;		// seconds to fall; a trigger's pulse decays over it
	double	fThreshold = 0.5;	// for the gate curve and for actions
	double	fOffset = 0;		// seconds (-0.3 to 0.3): beat-based sources fire this much early (negative) or late; hits only late

	bool	IsAction() const { return ModActions::IsValid(iAction); }
	// whether the row's target is one a modulation can move
	static bool	IsModulatable(int iTarget, int iProp);
};

// What the engine adds this frame, in slider travel (see ModRow), and
// which actions fired. All zero when nothing modulates.
struct ModOutput {
	bool	bActive = false;	// some row moves a control (offsets may still be 0)
	double	aParam[MappingBase::PARAM_COUNT] = {};	// Val column
	double	aGlobal[MappingBase::PARAM_COUNT] = {};	// Global column
	double	aMaster[MappingBase::MASTER_COUNT] = {};
	double	fHue = 0;		// of the hue wheel
	double	fOriginX = 0;	// of the view
	double	fOriginY = 0;
	double	fTempo = 0;		// BPM: the Tempo master property follows this (render-only); 0: the patch's
	uint32_t	nActions = 0;	// bit (1 << ModActions::ACT_*) per action fired

	void	Clear() { *this = ModOutput(); }
};

class Modulator {
public:
	void	SetRows(const std::vector<ModRow>& aRow);	// resets each row's state
	const std::vector<ModRow>&	GetRows() const { return m_aRow; }
	void	SetDepth(double fDepth) { m_fDepth = fDepth; }	// scales every offset; 0 to 1
	double	GetDepth() const { return m_fDepth; }
	void	SetBypass(bool bBypass) { m_bBypass = bBypass; }	// no offsets, no actions
	bool	GetBypass() const { return m_bBypass; }
	// Tempo follows the beat (the beat tracker's or Ableton Link's): ModOutput::fTempo
	void	SetFollowTempo(bool bFollow) { m_bFollowTempo = bFollow; }
	bool	GetFollowTempo() const { return m_bFollowTempo; }
	// One frame: dt is the time since the last step, in seconds.
	void	Step(const ModSources& src, double dt, ModOutput& out);
	// A row's value after smoothing and its curve, 0 to 1 (for meters)
	double	GetRowLevel(size_t iRow) const;

private:
	enum { MAX_PENDING = 16 };	// delayed hits waiting, per row
	struct State {
		double		fEnv = 0;		// smoothed source
		double		fLevel = 0;		// after the curve
		uint32_t	nCount = 0;		// trigger count last seen
		bool		bPrimed = false;	// nCount is valid
		bool		bAbove = false;		// above the threshold (actions re-arm below it)
		int64_t		iSpan = 0;		// beat-based: the span the shifted position was in
		bool		bSpanKnown = false;
		double		aPending[MAX_PENDING] = {};	// delayed hits: when they fire (m_fTime)
		int			nPending = 0;
	};
	double	m_fTime = 0;	// seconds stepped, for delayed hits
	std::vector<ModRow>	m_aRow;
	std::vector<State>	m_aState;
	double	m_fDepth = 1;
	bool	m_bBypass = false;
	bool	m_bFollowTempo = false;

	static double	Smooth(double fEnv, double fTarget, double dt, double fTime);
	static double	Shape(int nCurve, double x, double fThreshold);
};

} // namespace whorld
