// Copyleft 2025 Chris Korda (original MappingDef.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

// ported from MappingDef.h, row for row. X-macro header: no include guard.

#ifdef MAPPINGDEF

//			name		align	width	type	prefix	member			initval	minval	maxval
#ifdef MAPPINGDEF_INCLUDE_NUMBER
MAPPINGDEF(	NUMBER,		LEFT,	30,		int,	n,		0,				0,		0,		0)
#endif
#if !defined(MAPPINGDEF_OPTIONAL) || !MAPPINGDEF_OPTIONAL	// mandatory members
#ifndef MAPPINGDEF_EXCLUDE_TAGS
MAPPINGDEF(	EVENT,		LEFT,	100,	int,	i,		Event,			MIDI_CVM_CONTROL,	0,	EVENTS - 1)	// MIDI event
#endif
MAPPINGDEF(	CHANNEL,	LEFT,	60,		int,	i,		Channel,		0,		0,		MIDI_CHANNELS - 1)	// MIDI channel
MAPPINGDEF(	CONTROL,	LEFT,	60,		int,	i,		Control,		1,		0,		MIDI_NOTE_MAX)		// MIDI controller
#ifndef MAPPINGDEF_EXCLUDE_TAGS
MAPPINGDEF(	TARGET,		LEFT,	120,	int,	i,		Target,			0,		0,		TARGETS - 1)		// mapping target
MAPPINGDEF(	PROPERTY,	LEFT,	85,		int,	i,		Prop,			0,		0,		PARAM_PROP_COUNT)	// parameter property
#endif
#endif
#if !defined(MAPPINGDEF_OPTIONAL) || MAPPINGDEF_OPTIONAL	// optional members
MAPPINGDEF(	START,		LEFT,	60,		double,	f,		Start,			0,		0,		0)	// range start, as a percentage
MAPPINGDEF(	END,		LEFT,	60,		double,	f,		End,			100,	0,		0)	// range end, as a percentage
#endif

#undef MAPPINGDEF
#undef MAPPINGDEF_INCLUDE_NUMBER
#undef MAPPINGDEF_EXCLUDE_TAGS
#undef MAPPINGDEF_OPTIONAL

#endif // MAPPINGDEF

#ifdef MAPPINGUNDODEF

MAPPINGUNDODEF(PROPERTY)
MAPPINGUNDODEF(MULTI_PROPERTY)
MAPPINGUNDODEF(CUT)
MAPPINGUNDODEF(PASTE)
MAPPINGUNDODEF(INSERT)
MAPPINGUNDODEF(DELETE)
MAPPINGUNDODEF(MOVE)
MAPPINGUNDODEF(SORT)
MAPPINGUNDODEF(LEARN)
MAPPINGUNDODEF(LEARN_MULTI)
MAPPINGUNDODEF(PLAYLIST_INSERT)
MAPPINGUNDODEF(PLAYLIST_DELETE)
MAPPINGUNDODEF(PLAYLIST_MOVE)

#undef MAPPINGUNDODEF
#endif	// MAPPINGUNDODEF

#ifdef MAPPINGDEF_MISC_TARGET

//					   name				type
MAPPINGDEF_MISC_TARGET(OriginX,			RANGE)
MAPPINGDEF_MISC_TARGET(OriginY,			RANGE)
MAPPINGDEF_MISC_TARGET(Fill,			BOOL)
MAPPINGDEF_MISC_TARGET(Outline,			BOOL)
MAPPINGDEF_MISC_TARGET(Mirror,			BOOL)
MAPPINGDEF_MISC_TARGET(OriginDrag,		BOOL)
MAPPINGDEF_MISC_TARGET(OriginRandom,	BOOL)
MAPPINGDEF_MISC_TARGET(Reverse,			BOOL)
MAPPINGDEF_MISC_TARGET(Convex,			BOOL)
MAPPINGDEF_MISC_TARGET(LoopHue,			BOOL)
MAPPINGDEF_MISC_TARGET(ZoomCenter,		BOOL)
MAPPINGDEF_MISC_TARGET(Antialiasing,	BOOL)
MAPPINGDEF_MISC_TARGET(RandomPhase,		ACTION)
MAPPINGDEF_MISC_TARGET(RandomOrigin,	ACTION)
MAPPINGDEF_MISC_TARGET(Clear,			ACTION)
MAPPINGDEF_MISC_TARGET(Pause,			BOOL)
MAPPINGDEF_MISC_TARGET(Patch,			RANGE)

#undef MAPPINGDEF_MISC_TARGET
#endif // MAPPINGDEF_MISC_TARGET
