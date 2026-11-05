// Copyleft 2025 Chris Korda (original MidiManager.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "whorld/MidiManager.h"
#include "whorld/Controls.h"	// for master norm and denorm (MasterRowDlg.h)
#include "whorld/Round.h"

#include <algorithm>

namespace whorld {

void MidiManager::PushCmd(uint32_t nCmd, uint32_t nParam)
{
	m_sink.PushCommand(RenderCmd(nCmd, nParam));
}

void MidiManager::PushCmd(uint32_t nCmd, uint32_t nParam, double fVal)
{
	m_sink.PushCommand(RenderCmd(nCmd, nParam, fVal));
}

void MidiManager::PushCmd(uint32_t nCmd, uint32_t nParam, VARIANT_PROP prop)
{
	RenderCmd	cmd(nCmd, nParam);
	cmd.m_prop = prop;
	m_sink.PushCommand(cmd);
}

// ported from MidiManager.cpp CMidiManager::PushMasterProperty
void MidiManager::PushMasterProperty(int iProp, double fNormVal)
{
	// This method runs in the MIDI callback's worker thread context;
	// only push render commands or post messages to the main thread.
	double	fVal = Controls::MasterDenorm01(iProp, fNormVal);
	if (iProp == MASTER_Zoom) {	// if zoom
		PushCmd(RC_SET_ZOOM, true, fVal);	// with damping
	} else {	// generic case
		PushCmd(RC_SET_MASTER, iProp, fVal);
	}
	Post	post;
	post.type = Post::MASTER_PROP_CHANGE;
	post.iProp = iProp;
	post.fVal = fVal;
	m_sink.PostToMain(post);
}

// ported from MidiManager.cpp CMidiManager::PushParameter
void MidiManager::PushParameter(int iParam, int iProp, double fNormVal)
{
	// This method runs in the MIDI callback's worker thread context;
	// only push render commands or post messages to the main thread.
	const PARAM_INFO&	info = GetParamInfo(iParam);
	Post	post;
	post.type = Post::PARAM_CHANGE;
	post.iParam = iParam;
	post.iProp = iProp;
	switch (iProp) {
	case PARAM_PROP_Wave:
		{
			int	iWaveform = Trunc(fNormVal * WAVEFORM_COUNT);
			iWaveform = std::min(std::max(iWaveform, 0), WAVEFORM_COUNT - 1);
			VARIANT_PROP	prop;
			prop.llVal = 0;
			prop.intVal = iWaveform;
			PushCmd(RC_SET_PARAM_FIRST + PARAM_PROP_Wave, iParam, prop);
			post.iVal = iWaveform;	// waveform is passed as integer
		}
		break;
	case PARAM_PROP_Global:
		{
			int	iGlobal = MapParamToGlobal(iParam);
			if (iGlobal < 0) {	// if parameter lacks a global
				return;	// avoid posting a useless update
			}
			double	fVal = (fNormVal - 0.5) * info.fMaxVal * 2;
			PushCmd(RC_SET_DAMPED_GLOBAL, iParam, fVal);
			post.fVal = fVal;	// globals is passed as float
		}
		break;
	default:
		double	fVal;
		switch (iProp) {
		case PARAM_PROP_Val:
		case PARAM_PROP_Amp:
			fVal = fNormVal * (info.fMaxVal - info.fMinVal) + info.fMinVal;
			break;
		default:
			fVal = fNormVal;
		}
		post.fVal = fVal;	// all other properties are passed as float
		VARIANT_PROP	prop;
		prop.dblVal = fVal;
		PushCmd(RC_SET_PARAM_FIRST + iProp, iParam, prop);
	}
	m_sink.PostToMain(post);
}

// ported from MidiManager.cpp CMidiManager::SetOrClear
uint32_t MidiManager::SetOrClear(uint32_t nDest, uint32_t nMask, bool bIsSet)
{
	return bIsSet ? (nDest | nMask) : (nDest & ~nMask);
}

// ported from MidiManager.cpp CMidiManager::PushMiscTarget
void MidiManager::PushMiscTarget(int iMiscTarget, double fNormVal)
{
	// This method runs in the MIDI callback's worker thread context;
	// only push render commands or post messages to the main thread.
	switch (iMiscTarget) {
	case MT_OriginX:
		PushCmd(RC_SET_ORIGIN_X, true, fNormVal);	// with damping
		break;
	case MT_OriginY:
		PushCmd(RC_SET_ORIGIN_Y, true, fNormVal);	// with damping
		break;
	case MT_Fill:
		PushDrawMode(DM_FILL, fNormVal != 0);
		break;
	case MT_Outline:
		PushDrawMode(DM_OUTLINE, fNormVal != 0);
		break;
	case MT_Mirror:
		PushMainBool(MAIN_Mirror, fNormVal != 0);
		break;
	case MT_OriginDrag:
		PushOriginMotion(fNormVal != 0 ? OM_DRAG : OM_PARK);
		break;
	case MT_OriginRandom:
		PushOriginMotion(fNormVal != 0 ? OM_RANDOM : OM_PARK);
		break;
	case MT_Reverse:
		PushMainBool(MAIN_Reverse, fNormVal != 0);
		break;
	case MT_Convex:
		PushMainBool(MAIN_Convex, fNormVal != 0);
		break;
	case MT_LoopHue:
		PushMainBool(MAIN_LoopHue, fNormVal != 0);
		break;
	case MT_ZoomCenter:
		PushMainBool(MAIN_ZoomCenter, fNormVal != 0);
		break;
	case MT_Antialiasing:
		PushMainBool(MAIN_Antialiasing, fNormVal != 0);
		break;
	case MT_RandomPhase:
		PushCmd(RC_RANDOM_PHASE);
		break;
	case MT_RandomOrigin:
		PushCmd(RC_RANDOM_ORIGIN);
		break;
	case MT_Clear:
		PushCmd(RC_SET_EMPTY);
		break;
	case MT_Pause:
		{	// let main thread handle pause as its pause state is canonical
			Post	post;
			post.type = Post::PAUSE;
			m_sink.PostToMain(post);
		}
		break;
	case MT_Patch:
		{	// let main thread handle patch as read can fail
			Post	post;
			post.type = Post::PLAY_PATCH;
			post.iVal = Round(fNormVal * MIDI_NOTE_MAX);
			m_sink.PostToMain(post);
		}
		break;
	}
}

// ported from MidiManager.cpp CMidiManager::PushMainBool
void MidiManager::PushMainBool(int iProp, bool bVal)
{
	VARIANT_PROP	prop;
	prop.llVal = 0;
	prop.boolVal = bVal;
	PushCmd(RC_SET_MAIN, iProp, prop);
	Post	post;
	post.type = Post::MAIN_PROP_CHANGE;
	post.iProp = iProp;
	post.iVal = bVal;
	m_sink.PostToMain(post);
}

// ported from MidiManager.cpp CMidiManager::PushOriginMotion
void MidiManager::PushOriginMotion(int nOrgMotion)
{
	VARIANT_PROP	prop;
	prop.llVal = 0;
	prop.intVal = nOrgMotion;
	PushCmd(RC_SET_MAIN, MAIN_OrgMotion, prop);
	Post	post;
	post.type = Post::MAIN_PROP_CHANGE;
	post.iProp = MAIN_OrgMotion;
	post.iVal = prop.intVal;
	m_sink.PostToMain(post);
}

// ported from MidiManager.cpp CMidiManager::PushDrawMode
void MidiManager::PushDrawMode(uint32_t nMask, bool bEnable)
{
	uint32_t	nValue = bEnable ? nMask : 0;
	VARIANT_PROP	prop;
	prop.llVal = 0;
	prop.uintVal = nValue;
	PushCmd(RC_SET_DRAW_MODE, nMask, prop);
	Post	post;
	post.type = Post::SET_DRAW_MODE;
	post.nMask = nMask;
	post.nValue = nValue;
	m_sink.PostToMain(post);
}

// ported from MidiManager.cpp CMidiManager::OnMidiEvent (normalization)
double MidiManager::NormalizeMidiValue(int iEvent, int nMidiVal)
{
	double	fNormVal;
	if (iEvent != MIDI_CVM_WHEEL) {	// if input MIDI value is 7-bit
		// Split normalization into two ranges, to compensate for the fact that an
		// integer range with an even number of values has a fractional midpoint.
		if (nMidiVal <= MIDI_NOTES / 2) {	// if at or below MIDI center
			fNormVal = static_cast<double>(nMidiVal) / MIDI_NOTES;
		} else {	// above MIDI center; scale differently to minimize error
			fNormVal = static_cast<double>(nMidiVal - 1) / (MIDI_NOTE_MAX - 1);
		}
	} else {	// pitch bend event; input MIDI value is 14-bit
		// same as 7-bit case except it substitutes 14-bit constants
		if (nMidiVal <= MIDI_PITCH_BEND_STEPS / 2) {	// if at or below center
			fNormVal = static_cast<double>(nMidiVal) / MIDI_PITCH_BEND_STEPS;
		} else {	// above MIDI center; scale differently to minimize error
			fNormVal = static_cast<double>(nMidiVal - 1) / (MIDI_PITCH_BEND_MAX - 1);
		}
	}
	return fNormVal;
}

// ported from MidiManager.cpp CMidiManager::OnMidiEvent
void MidiManager::OnMidiEvent(uint32_t dwEvent)
{
	// This method runs in the MIDI callback's thread context;
	// data shared with other threads may require serialization.
	if (!MIDI_IS_SHORT_MSG(dwEvent))	// if event is a short MIDI message
		return;	// ignore
	// exclude system status messages
	if (MIDI_STAT(dwEvent) >= SYSEX)	// if not channel voice message
		return;	// ignore
	if (m_bLearnMode) {	// if learning mappings
		// post MIDI message to mapping bar; do NOT access bar's members directly
		Post	post;
		post.type = Post::MIDI_EVENT;
		post.nMsg = dwEvent;
		m_sink.PostToMain(post);
	}
	// lock the mapping array during iteration
	std::lock_guard<std::mutex>	lock(m_midiMaps.GetMutex());
	int	nMaps = m_midiMaps.GetCount();
	for (int iMap = 0; iMap < nMaps; iMap++) {	// for each mapping
		const Mapping&	map = m_midiMaps.GetAt(iMap);
		int	nMidiVal = map.IsInputMatch(dwEvent);	// try to map MIDI message
		if (nMidiVal >= 0) {	// if message was mapped
			// mapping result is a MIDI data value; account for range and then normalize it
			double	fNormVal = NormalizeMidiValue(map.m_iEvent, nMidiVal);
			double	fStart = map.m_fStart / 100;	// range start and end are both percentages
			double	fEnd = map.m_fEnd / 100;	// and must be converted to normalized coords
			double	fRange = fEnd - fStart;	// range can be negative if start > end
			fNormVal = fNormVal * fRange + fStart;	// apply range to normalized value
			// order must match order of ranges in mapping target enumeration
			int	iTarget = map.m_iTarget;
			if (iTarget < PARAM_COUNT) {	// if target is parameter
				PushParameter(iTarget, map.m_iProp, fNormVal);
			} else {	// target isn't parameter
				iTarget -= PARAM_COUNT;
				if (iTarget < MASTER_COUNT) {	// if target is master property
					PushMasterProperty(iTarget, fNormVal);
				} else {	// target isn't master property
					iTarget -= MASTER_COUNT;
					if (iTarget < MISC_TARGETS) {	// if miscellanous target
						PushMiscTarget(iTarget, fNormVal);
					}
				}
			}
		}
	}
}

} // namespace whorld
