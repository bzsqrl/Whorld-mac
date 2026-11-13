// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Modulation sources and actions (Modulation.h), as X-macro lists like
// WhorldDef.h. The tags are stored in settings files: never rename one.
// Append new entries; their order is the order shown.

#ifdef MODSOURCEDEF
//			name		trigger	text
MODSOURCEDEF(Level,		false,	"Level")		// loudness
MODSOURCEDEF(Bass,		false,	"Bass")			// 20 to 150 Hz
MODSOURCEDEF(LowMid,	false,	"Low Mid")		// 150 to 600 Hz
MODSOURCEDEF(HighMid,	false,	"High Mid")		// 600 Hz to 4 kHz
MODSOURCEDEF(Treble,	false,	"Treble")		// 4 to 16 kHz
MODSOURCEDEF(Brightness, false,	"Brightness")	// spectral centroid
MODSOURCEDEF(Hit,		true,	"Hit")			// any onset
MODSOURCEDEF(Kick,		true,	"Kick")			// bass onset
MODSOURCEDEF(Hats,		true,	"Hats")			// treble onset
MODSOURCEDEF(Beat,		true,	"Beat")			// the beat tracker's beats
#undef MODSOURCEDEF
#endif

#ifdef MODACTIONDEF
//			name			text
MODACTIONDEF(RandomPhase,	"Random Phase")
MODACTIONDEF(RandomOrigin,	"Random Origin")
MODACTIONDEF(RotateHue,		"Rotate Hue")
MODACTIONDEF(Clear,			"Clear")
MODACTIONDEF(NextPatch,		"Next Patch")
MODACTIONDEF(PrevPatch,		"Previous Patch")
MODACTIONDEF(NextSnapshot,	"Next Snapshot")
MODACTIONDEF(PrevSnapshot,	"Previous Snapshot")
#undef MODACTIONDEF
#endif
