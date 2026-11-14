// Copyleft 2025 Chris Korda (original Mapping.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from Mapping.h: MIDI mappings (CMappingBase, CMapping,
// CMappingArray, CSafeMapping). A mapping routes one MIDI channel voice
// message (event, channel, controller) to a target: a parameter property,
// a master property, or a miscellaneous target, over a start..end range.

#include "whorld/IniFile.h"
#include "whorld/Midi.h"
#include "whorld/WhorldBase.h"

#include <mutex>
#include <string>
#include <vector>

namespace whorld {

class MappingBase : public WhorldBase {
public:
// Constants
	enum {	// properties, corresponding to mapping columns
		#define MAPPINGDEF(name, align, width, type, prefix, member, initval, minval, maxval) PROP_##name,
		#include "whorld/MappingDef.h"	// generate member var enumeration
		PROPERTIES
	};
	enum {	// events, equivalent to MIDI channel voice messages
		#define MIDICHANSTATDEF(name) EVENT_##name,
		#include "whorld/MidiCtrlrDef.h"	// generate enumeration
		EVENTS
	};
	enum {	// mapping targets, in a series of ranges
		#define PARAMDEF(name, minval, maxval, steps, scale, initval) TARGET_##name,
		#include "whorld/WhorldDef.h"	// generate parameter range
		#define MASTERDEF(name, type, prefix, initval) TARGET_##name,
		#include "whorld/WhorldDef.h"	// generate master property range
		#define MAPPINGDEF_MISC_TARGET(name, type) TARGET_##name,
		#include "whorld/MappingDef.h"	// generate miscellaneous target range
		TARGETS
	};
	enum {	// miscellaneous targets
		#define MAPPINGDEF_MISC_TARGET(name, type) MT_##name,
		#include "whorld/MappingDef.h"	// generate enumeration
		MISC_TARGETS
	};
	enum {	// target types
		TT_RANGE,	// continuous or multiple-choice property
		TT_BOOL,	// on/off or true/false binary property
		TT_ACTION,	// triggered or one-shot command (bang)
		TARGET_TYPES
	};

// Attributes
	static bool		IsValidEvent(int iEvent) { return iEvent >= 0 && iEvent < EVENTS; }
	static bool		IsValidTarget(int iTarget) { return iTarget >= 0 && iTarget < TARGETS; }
	// Mac additions (MappingDef.h): Windows Whorld doesn't have them
	static bool		IsMacOnlyTarget(int iTarget) { return iTarget >= TARGET_Hue && iTarget < TARGETS; }
	static bool		TargetHasProperty(int iTarget) { return iTarget < PARAM_COUNT; }	// parameters come first
	static const char*	GetEventTag(int iEvent);
	static std::string	GetEventName(int iEvent);
	static const char*	GetTargetTag(int iTarget);
	static std::string	GetTargetName(int iTarget);
	static int		GetTargetType(int iTarget);
	static int		FindEventTag(const std::string& sName);
	static int		FindTargetTag(const std::string& sName);
	static bool		IsIntegerProperty(int iProp);
};

class Mapping : public MappingBase {
public:
	Mapping() { SetDefaults(); }

// Public data
	#define MAPPINGDEF(name, align, width, type, prefix, member, initval, minval, maxval) \
		type m_##prefix##member;
	#include "whorld/MappingDef.h"	// generate member var definitions

// Attributes
	VARIANT_PROP	GetProperty(int iProp) const;
	void	SetProperty(int iProp, VARIANT_PROP prop);
	uint32_t	GetInputMidiMsg() const;
	void	SetInputMidiMsg(uint32_t nInMidiMsg);
	int		IsInputMatch(uint32_t nInMidiMsg) const;
	bool	TargetHasProperty() const { return MappingBase::TargetHasProperty(m_iTarget); }

// Operations
	void	SetDefaults();
	void	Read(const IniFile& fIn, const std::string& sSection);
	void	Write(IniFile& fOut, const std::string& sSection) const;
	int		Compare(int iProp, const Mapping& mapping) const;
	static int	Compare(int iProp, VARIANT_PROP prop1, VARIANT_PROP prop2);
	bool	operator==(const Mapping& m) const;
	bool	operator!=(const Mapping& m) const { return !(*this == m); }
};

class MappingArray : public std::vector<Mapping> {
public:
	void	Read(const IniFile& fIn);
	void	Write(IniFile& fOut) const;
};

// ported from Mapping.h CSafeMapping: the mapping array behind a mutex, so
// the MIDI input thread can iterate while the main thread edits.
class SafeMapping : public WhorldBase {
public:
	std::mutex&	GetMutex() const { return m_mutex; }
	int		GetCount() const { return static_cast<int>(m_arrMapping.size()); }
	const Mapping&	GetAt(int iMapping) const { return m_arrMapping[iMapping]; }
	MappingArray	GetArray() const;
	void	SetArray(const MappingArray& arrMapping);
	void	SetAt(int iMapping, const Mapping& mapping);
	void	RemoveAll();
	void	Read(const IniFile& fIn);
	void	Write(IniFile& fOut) const;

protected:
	MappingArray	m_arrMapping;	// array of mappings
	mutable std::mutex	m_mutex;	// serializes access to mappings
};

} // namespace whorld
