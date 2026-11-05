// Copyleft 2025 Chris Korda (original Midi.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from Midi.h: MIDI constants and short-message helpers. A short
// message packs status, data 1 and data 2 into the low three bytes of a
// uint32_t, as WinMM's MIM_DATA does: status | (p1 << 8) | (p2 << 16).

#include <cstdint>

namespace whorld {

enum {	// channel voice messages
	NOTE_OFF 		= 0x80,
	NOTE_ON			= 0x90,
	KEY_AFT			= 0xa0,
	CONTROL 		= 0xb0,
	PATCH			= 0xc0,
	CHAN_AFT 		= 0xd0,
	WHEEL			= 0xe0,
};

enum {	// system messages (only the first is used: the channel/system boundary)
	SYSEX			= 0xf0,
};

enum {
	MIDI_CHANNELS	= 16,
	MIDI_CHAN_MAX	= MIDI_CHANNELS - 1,
	MIDI_NOTES		= 128,
	MIDI_NOTE_MAX	= MIDI_NOTES - 1,
	MIDI_PITCH_BEND_STEPS	= 0x4000,
	MIDI_PITCH_BEND_MAX		= MIDI_PITCH_BEND_STEPS - 1,
};

enum {	// MIDI channel voice messages
	#define MIDICHANSTATDEF(name) MIDI_CVM_##name,
	#include "whorld/MidiCtrlrDef.h"	// generate enum
	MIDI_CHANNEL_VOICE_MESSAGES
};

enum {	// bitmasks for MIDI message components
	MIDI_CHAN_MASK	= 0x00000f,	// channel nibble
	MIDI_CMD_MASK	= 0x0000f0,	// command nibble
	MIDI_STAT_MASK	= 0x0000ff,	// status byte
	MIDI_P1_MASK	= 0x00ff00,	// 1st parameter byte
	MIDI_P2_MASK	= 0xff0000,	// 2nd parameter byte
};

inline int MIDI_STAT(uint32_t msg) { return msg & 0xff; }			// LOBYTE
inline int MIDI_P1(uint32_t msg) { return (msg >> 8) & 0xff; }		// HIBYTE
inline int MIDI_P2(uint32_t msg) { return (msg >> 16) & 0xff; }		// LOBYTE(HIWORD)
inline int MIDI_CMD(uint32_t msg) { return msg & 0xf0; }
inline int MIDI_CHAN(uint32_t msg) { return msg & 0x0f; }
inline int MIDI_CMD_IDX(uint32_t msg) { return (MIDI_CMD(msg) >> 4) - 8; }
inline int MIDI_IDX_CMD(int idx) { return (idx + 8) << 4; }
inline bool MIDI_IS_SHORT_MSG(uint32_t msg) { return !(msg & 0xff000000); }

inline uint32_t MakeMidiMsg(int Cmd, int Chan, int P1, int P2)
{
	return static_cast<uint32_t>(Cmd + Chan + (P1 << 8) + (P2 << 16));
}

} // namespace whorld
