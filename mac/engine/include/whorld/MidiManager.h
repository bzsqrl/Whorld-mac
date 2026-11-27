// Copyleft 2025 Chris Korda (original MidiManager.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from MidiManager.h CMidiManager: dispatches incoming MIDI messages
// through the mappings. Device handling (WinMM) is the app's job; the app
// calls OnMidiEvent from its MIDI input thread.
//
// As on Windows, each mapped message goes two ways:
//   - straight to the render thread as render commands (PushCommand), so
//     MIDI control doesn't wait for the main thread;
//   - to the main thread as a notification (Post), which updates the
//     document with undo disabled, replacing PostMessage to the main frame.

#include "whorld/Mapping.h"

#include <atomic>
#include <cstdint>

namespace whorld {

class MidiManager : public MappingBase {
public:
// Types
	// A notification for the main thread (the original's posted messages).
	struct Post {
		enum Type {
			PARAM_CHANGE,		// UWM_PARAM_CHANGE: iParam, iProp, fVal (or iVal for Wave)
			MASTER_PROP_CHANGE,	// UWM_MASTER_PROP_CHANGE: iProp, fVal
			MAIN_PROP_CHANGE,	// UWM_MAIN_PROP_CHANGE: iProp, iVal
			SET_DRAW_MODE,		// UWM_SET_DRAW_MODE: nMask, nValue
			PAUSE,				// WM_COMMAND ID_WINDOW_PAUSE: toggle pause
			PLAY_PATCH,			// UWM_PLAY_PATCH: iVal is the playlist index
			MIDI_EVENT,			// UWM_MIDI_EVENT to the mapping bar (learn mode): nMsg
			ROTATE_HUE,			// Mac addition: the main thread rotates the hue 90 degrees
			MODULATION,			// Mac addition, audio modulation: iVal 0 on (fVal 1 or 0), 1 depth (fVal 0 to 1), 2 Mark Downbeat, 3 Reset Bar Count
			PATCH_MODE,			// Mac addition: iVal 1 Geometry, 0 Full (V1's MIDI PatchMode)
			AUTO_ADVANCE,		// Mac addition: iVal 1 start, 0 stop the playlist's auto-advance
			BLACKOUT,			// Mac addition: iVal 1 fade to black, 0 back
			RANDOM_PHASE,		// Mac addition: a notice; the render thread has the command
			CLEAR,				// Mac addition: a notice, as RANDOM_PHASE
			TOGGLE,				// Mac addition: a Toggle mapping pressed for a switch target, iVal: flip it (the main thread knows its state)
			CUE,				// Mac addition, cue then go: iVal 0 Go, 1 Go Now, 2 Cue Next, 3 Cue Previous, 4 Bank Up, 5 Bank Down, 16 + n pad n (0 to 15)
		};
		Type	type;
		int		iParam = 0;
		int		iProp = 0;
		double	fVal = 0;
		int		iVal = 0;
		uint32_t	nMask = 0;
		uint32_t	nValue = 0;
		uint32_t	nMsg = 0;
	};
	class Sink {	// implemented by the app; called on the MIDI thread
	public:
		virtual ~Sink() {}
		virtual void	PushCommand(const RenderCmd& cmd) = 0;	// to the render thread
		virtual void	PostToMain(const Post& post) = 0;		// to the main thread
	};

// Construction
	explicit MidiManager(Sink& sink) : m_sink(sink) {}

// Attributes
	bool	IsLearnMode() const { return m_bLearnMode; }
	void	SetLearnMode(bool bEnable) { m_bLearnMode = bEnable; }
	static uint32_t	SetOrClear(uint32_t nDest, uint32_t nMask, bool bIsSet);

// Operations
	void	OnMidiEvent(uint32_t dwEvent);	// MIDI thread
	static double	NormalizeMidiValue(int iEvent, int nMidiVal);
	// Sends a mapping target its value, as a mapping does once it has applied
	// its range (the series of target ranges in MappingBase). OnMidiEvent's
	// dispatch, factored out so OSC (OscRemote) shares it; any thread that
	// may push render commands and post to the main thread.
	void	DispatchTarget(int iTarget, int iProp, double fNormVal);

// Public data
	SafeMapping	m_midiMaps;		// MIDI mappings

protected:
	Sink&	m_sink;
	std::atomic<bool>	m_bLearnMode{false};	// true if we're learning mappings

// Helpers
	void	PushParameter(int iParam, int iProp, double fNormVal);
	void	PushMasterProperty(int iProp, double fNormVal);
	void	PushMiscTarget(int iMiscTarget, double fNormVal);
	void	PushMainBool(int iProp, bool bVal);
	void	PushOriginMotion(int nOrgMotion);
	void	PushDrawMode(uint32_t nMask, bool bEnable);
	void	PushCmd(uint32_t nCmd, uint32_t nParam = 0);
	void	PushCmd(uint32_t nCmd, uint32_t nParam, double fVal);
	void	PushCmd(uint32_t nCmd, uint32_t nParam, VARIANT_PROP prop);
};

} // namespace whorld
