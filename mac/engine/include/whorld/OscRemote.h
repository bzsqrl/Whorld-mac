// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// OSC remote control (new in the Mac port): an address for everything a
// MIDI mapping can control, and the same values. A number sent to an
// address is what a MIDI mapping with Start 0 and End 1 would send its
// target (MidiManager::DispatchTarget), so 0 to 1 covers a slider's range;
// numbers outside 0 to 1 act like a mapping with a wider Start and End.
//
//   /w/p/<param>/<column>  a parameter's column: v value, w waveform, a
//                          amplitude, f frequency, p pulse width, g global
//                          (/w/p/<param> alone is its value)
//   /w/m/<master>          a master property
//   /w/<name>              the rest: switches (1 on, 0 off, no argument
//                          toggles), actions (no argument or nonzero), the
//                          origin (/w/org/x, /w/org/y, or /w/org x y), pause
//                          and the playlist's patch
//
// Waveform and patch take a whole number (int argument) as the index; a
// float is normalized as MIDI's is. Whorld sends the same addresses back
// with the current values (StateValue), and its own monitoring addresses.

#include "whorld/Mapping.h"
#include "whorld/Osc.h"

#include <string>
#include <vector>

namespace whorld {

class MidiManager;
class Patch;

class OscRemote : public MappingBase {
public:
	static constexpr const char*	PREFIX = "/w";

	struct Address {
		std::string	path;
		int		iTarget;	// mapping target (MappingBase TARGETS)
		int		iProp;		// parameter column (PARAM_PROP_*), or -1
	};
	// Every address that controls something: one per target, and one per
	// column of each parameter (Global only where the parameter has one).
	static const std::vector<Address>&	Inputs();
	// The target an address controls, or -1 (with the shorthands too).
	static int	Find(const std::string& sPath, int& iProp);

	static const char*	ParamCode(int iParam);	// "rg" for Ring Growth
	static const char*	MasterCode(int iProp);	// "fd" for Fade
	static const char*	PropCode(int iProp);	// "v" for Val
	static const char*	MiscName(int iMiscTarget);	// "mirror"

	// What a message asks for. DISPATCHED: done (pushed to the render
	// thread and posted to the main thread, as MIDI is). The rest are the
	// app's to do: TOGGLE a switch target (no argument), PAUSE (iVal 1, 0,
	// or -1 to toggle), PATCH (iVal: the playlist index), PING, SYNC.
	struct Request {
		enum Type { NONE, DISPATCHED, TOGGLE, PAUSE, PATCH, PING, SYNC };
		Type	type = NONE;
		int		iTarget = -1;
		int		iVal = 0;
	};
	static Request	Handle(const OscMessage& msg, MidiManager& midi);

	// A target's current value as Whorld sends it back (the inverse of what
	// Handle does with a number); false for actions, pause and patch, which
	// the patch doesn't hold.
	static bool	StateValue(const Patch& doc, int iTarget, int iProp, OscArg& arg);
};

}	// namespace whorld
