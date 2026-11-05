// Copyleft 2025 Chris Korda (original MidiCtrlrDef.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

// ported from MidiCtrlrDef.h: the channel voice message list (MIDICHANSTATDEF),
// row for row. The controller and system status lists are UI-only and not
// needed by the engine. X-macro header: no include guard.

#ifdef MIDICHANSTATDEF

MIDICHANSTATDEF(NOTE_OFF)		// 0x80
MIDICHANSTATDEF(NOTE_ON)		// 0x90
MIDICHANSTATDEF(KEY_AFT)		// 0xa0
MIDICHANSTATDEF(CONTROL)		// 0xb0
MIDICHANSTATDEF(PATCH)			// 0xc0
MIDICHANSTATDEF(CHAN_AFT)		// 0xe0
MIDICHANSTATDEF(WHEEL)			// 0xd0

#undef MIDICHANSTATDEF
#endif
