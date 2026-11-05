// Copyleft 2025 Chris Korda (original Mapping.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "whorld/Mapping.h"

#include <algorithm>
#include <cassert>
#include <cstring>

namespace whorld {

#define RK_MAPPING_COUNT "Count"	// registry keys
#define RK_MAPPING_SECTION "Mapping"
#define RK_MAPPING_EVENT "Event"
#define RK_MAPPING_TARGET "Target"
#define RK_MAPPING_PROPERTY "Prop"

namespace {

const char* const kChanStatTag[MIDI_CHANNEL_VOICE_MESSAGES] = {
	#define MIDICHANSTATDEF(name) #name,
	#include "whorld/MidiCtrlrDef.h"
};

// IDS_CHAN_STAT_* in Whorld.rc
const char* const kChanStatName[MIDI_CHANNEL_VOICE_MESSAGES] = {
	"Note Off", "Note On", "Key Aftertouch", "Control", "Patch", "Channel Aftertouch", "Wheel",
};

const char* const kMiscTargetTag[MappingBase::MISC_TARGETS] = {
	#define MAPPINGDEF_MISC_TARGET(name, type) #name,
	#include "whorld/MappingDef.h"
};

// IDS_MAP_TARGET_* in Whorld.rc
const char* const kMiscTargetName[MappingBase::MISC_TARGETS] = {
	"Origin X", "Origin Y", "Fill", "Outline", "Mirror", "Origin Drag", "Origin Random", "Reverse",
	"Convex", "Loop Hue", "Zoom Center", "Antialiasing", "Random Phase", "Random Origin", "Clear",
	"Pause", "Patch",
};

const int kMiscTargetType[MappingBase::MISC_TARGETS] = {
	#define MAPPINGDEF_MISC_TARGET(name, type) MappingBase::TT_##type,
	#include "whorld/MappingDef.h"
};

template<class T> int SortCompareTpl(const T& a, const T& b)	// Globals.h
{
	if (a < b)
		return -1;
	if (a > b)
		return 1;
	return 0;
}

} // namespace

// ported from Mapping.h/.cpp: tags and names. The original builds target
// tables in CMappingBase::Initialize: parameters, then master properties,
// then miscellaneous targets.
const char* MappingBase::GetEventTag(int iEvent)
{
	assert(IsValidEvent(iEvent));
	return kChanStatTag[iEvent];
}

std::string MappingBase::GetEventName(int iEvent)
{
	assert(IsValidEvent(iEvent));
	return kChanStatName[iEvent];
}

const char* MappingBase::GetTargetTag(int iTarget)
{
	assert(IsValidTarget(iTarget));
	if (iTarget < PARAM_COUNT)
		return GetParamInfo(iTarget).pszTag;
	iTarget -= PARAM_COUNT;
	if (iTarget < MASTER_COUNT)
		return GetMasterInfo(iTarget).pszTag;
	return kMiscTargetTag[iTarget - MASTER_COUNT];
}

std::string MappingBase::GetTargetName(int iTarget)
{
	assert(IsValidTarget(iTarget));
	if (iTarget < PARAM_COUNT)
		return GetParamName(iTarget);
	iTarget -= PARAM_COUNT;
	if (iTarget < MASTER_COUNT)
		return GetMasterName(iTarget);
	return kMiscTargetName[iTarget - MASTER_COUNT];
}

int MappingBase::GetTargetType(int iTarget)
{
	assert(IsValidTarget(iTarget));
	// parameters and master properties are zero-initialized: TT_RANGE
	if (iTarget < PARAM_COUNT + MASTER_COUNT)
		return TT_RANGE;
	return kMiscTargetType[iTarget - PARAM_COUNT - MASTER_COUNT];
}

int MappingBase::FindEventTag(const std::string& sName)	// ARRAY_FIND
{
	for (int i = 0; i < EVENTS; i++) {
		if (sName == kChanStatTag[i])
			return i;
	}
	return -1;
}

int MappingBase::FindTargetTag(const std::string& sName)	// ARRAY_FIND
{
	for (int i = 0; i < TARGETS; i++) {
		if (sName == GetTargetTag(i))
			return i;
	}
	return -1;
}

bool MappingBase::IsIntegerProperty(int iProp)
{
	switch (iProp) {
	case PROP_START:	// list non-integer properties here
	case PROP_END:
		return false;
	default:
		return true;
	}
}

// ported from Mapping.cpp CMapping::SetDefaults
void Mapping::SetDefaults()
{
	#define MAPPINGDEF(name, align, width, type, prefix, member, initval, minval, maxval) \
		m_##prefix##member = initval;
	#include "whorld/MappingDef.h"	// generate member var initialization
}

// ported from Mapping.cpp CMapping::GetProperty
Mapping::VARIANT_PROP Mapping::GetProperty(int iProp) const
{
	assert(iProp >= 0 && iProp < PROPERTIES);
	VARIANT_PROP	prop;
	prop.llVal = 0;	// clear entire property
	switch (iProp) {
	#define MAPPINGDEF(name, align, width, type, prefix, member, initval, minval, maxval) \
		case PROP_##name: prop.type##Val = m_##prefix##member; break;
	#include "whorld/MappingDef.h"	// generate cases for each member var
	}
	return prop;
}

// ported from Mapping.cpp CMapping::SetProperty
void Mapping::SetProperty(int iProp, VARIANT_PROP prop)
{
	assert(iProp >= 0 && iProp < PROPERTIES);
	switch (iProp) {
	#define MAPPINGDEF(name, align, width, type, prefix, member, initval, minval, maxval) \
		case PROP_##name: m_##prefix##member = prop.type##Val; break;
	#include "whorld/MappingDef.h"	// generate cases for each member
	}
}

// ported from Mapping.cpp CMapping::Compare
int Mapping::Compare(int iProp, VARIANT_PROP prop1, VARIANT_PROP prop2)
{
	assert(iProp >= 0 && iProp < PROPERTIES);
	switch (iProp) {
	#define MAPPINGDEF(name, align, width, type, prefix, member, initval, minval, maxval) \
		case PROP_##name: return SortCompareTpl(prop1.type##Val, prop2.type##Val);
	#include "whorld/MappingDef.h"	// generate cases for each member
	}
	return 0;
}

int Mapping::Compare(int iProp, const Mapping& mapping) const
{
	return Compare(iProp, GetProperty(iProp), mapping.GetProperty(iProp));
}

bool Mapping::operator==(const Mapping& m) const
{
	for (int iProp = 0; iProp < PROPERTIES; iProp++) {
		if (Compare(iProp, m))
			return false;
	}
	return true;
}

#define STAY_POSITIVE(x) x = std::max(x, 0)

// ported from Mapping.cpp CMapping::Read
void Mapping::Read(const IniFile& fIn, const std::string& sSection)
{
	SetDefaults();	// init members to default values
	std::string	sTag;
	// read event tag
	sTag = fIn.GetString(sSection, RK_MAPPING_EVENT);
	m_iEvent = FindEventTag(sTag);
	STAY_POSITIVE(m_iEvent);	// avoid downstream range error
	// read target tag
	sTag = fIn.GetString(sSection, RK_MAPPING_TARGET);
	m_iTarget = FindTargetTag(sTag);
	STAY_POSITIVE(m_iTarget);	// avoid downstream range error
	if (TargetHasProperty()) {	// if target has a property
		// read property tag
		sTag = fIn.GetString(sSection, RK_MAPPING_PROPERTY);
		m_iProp = FindParamPropByTag(sTag.c_str());
		STAY_POSITIVE(m_iProp);	// avoid downstream range error
	} else {	// target doesn't have a property
		m_iProp = PARAM_PROP_Val;	// set property to reasonable default
	}
	#define MAPPINGDEF_EXCLUDE_TAGS	// tags were already read above
	#define MAPPINGDEF(name, align, width, type, prefix, member, initval, minval, maxval) \
		fIn.Get(sSection, #member, m_##prefix##member);
	#include "whorld/MappingDef.h"	// generate profile reads for remaining members
}

// ported from Mapping.cpp CMapping::Write
void Mapping::Write(IniFile& fOut, const std::string& sSection) const
{
	// write event tag
	fOut.WriteString(sSection, RK_MAPPING_EVENT, GetEventTag(m_iEvent));
	// write target tag
	fOut.WriteString(sSection, RK_MAPPING_TARGET, GetTargetTag(m_iTarget));
	if (TargetHasProperty()) {	// if target has a property
		// write property tag
		fOut.WriteString(sSection, RK_MAPPING_PROPERTY, GetParamPropInfo(m_iProp).pszTag);
	}
	#define MAPPINGDEF_EXCLUDE_TAGS	// tags were already written above
	// mandatory members are always written, regardless of their value
	#define MAPPINGDEF_OPTIONAL 0	// include mandatory members, exclude optional ones
	#define MAPPINGDEF(name, align, width, type, prefix, member, initval, minval, maxval) \
		fOut.Put(sSection, #member, m_##prefix##member);
	#include "whorld/MappingDef.h"	// generate profile writes for mandatory members
	#define MAPPINGDEF_EXCLUDE_TAGS	// tags were already written above
	// optional members are only written if they differ from their initial value
	#define MAPPINGDEF_OPTIONAL 1	// include optional members, exclude mandatory ones
	#define MAPPINGDEF(name, align, width, type, prefix, member, initval, minval, maxval) \
		if (m_##prefix##member != initval) \
			fOut.Put(sSection, #member, m_##prefix##member);
	#include "whorld/MappingDef.h"	// generate profile writes for optional members
}

// ported from Mapping.cpp CMappingArray::Read
void MappingArray::Read(const IniFile& fIn)
{
	int	nItems = fIn.GetInt(RK_MAPPING_SECTION, RK_MAPPING_COUNT, 0);
	resize(std::max(nItems, 0));
	for (int iItem = 0; iItem < nItems; iItem++) {	// for each mapping
		at(iItem).Read(fIn, RK_MAPPING_SECTION "\\" + std::to_string(iItem));
	}
}

// ported from Mapping.cpp CMappingArray::Write
void MappingArray::Write(IniFile& fOut) const
{
	int	nItems = static_cast<int>(size());
	fOut.WriteInt(RK_MAPPING_SECTION, RK_MAPPING_COUNT, nItems);
	for (int iItem = 0; iItem < nItems; iItem++) {	// for each mapping
		at(iItem).Write(fOut, RK_MAPPING_SECTION "\\" + std::to_string(iItem));
	}
}

// ported from Mapping.cpp CMapping::GetInputMidiMsg
uint32_t Mapping::GetInputMidiMsg() const
{
	return MakeMidiMsg(MIDI_IDX_CMD(m_iEvent), m_iChannel, m_iControl, 0);
}

// ported from Mapping.cpp CMapping::SetInputMidiMsg
void Mapping::SetInputMidiMsg(uint32_t nInMidiMsg)
{
	// channel voice messages only; caller is responsible for ensuring this
	int	iCmd = MIDI_CMD_IDX(nInMidiMsg);	// convert MIDI status to event index
	assert(iCmd >= 0 && iCmd < EVENTS);	// check event index range
	m_iEvent = iCmd;	// set event to channel voice command index
	m_iChannel = MIDI_CHAN(nInMidiMsg);	// set channel index
	m_iControl = MIDI_P1(nInMidiMsg);	// set note/controller number
}

// ported from Mapping.cpp CMapping::IsInputMatch
int Mapping::IsInputMatch(uint32_t nInMidiMsg) const
{
	int	iChan = MIDI_CHAN(nInMidiMsg);	// channel index
	if (iChan != m_iChannel) {	// if channel doesn't match
		return -1;	// fail
	}
	int	iCmd = MIDI_CMD_IDX(nInMidiMsg);	// command index
	if (iCmd != m_iEvent) {	// if event doesn't match
		return -1;	// fail
	}
	int	nP1 = MIDI_P1(nInMidiMsg);	// parameter 1
	int	nP2 = MIDI_P2(nInMidiMsg);	// parameter 2
	if (iCmd <= MIDI_CVM_CONTROL) {	// if command has a note/controller
		if (nP1 != m_iControl) {	// if control doesn't match
			return -1;	// fail
		}
		return nP2;	// data is P2
	} else {	// command doesn't have a note/controller
		if (iCmd == MIDI_CVM_WHEEL) {
			return nP1 | (nP2 << 7);	// data is P1 and P2
		} else {
			return nP1;	// data is P1
		}
	}
}

MappingArray SafeMapping::GetArray() const
{
	std::lock_guard<std::mutex>	lock(m_mutex);
	return m_arrMapping;
}

void SafeMapping::SetArray(const MappingArray& arrMapping)
{
	std::lock_guard<std::mutex>	lock(m_mutex); // exclusive write
	m_arrMapping = arrMapping;
}

void SafeMapping::SetAt(int iMapping, const Mapping& mapping)
{
	std::lock_guard<std::mutex>	lock(m_mutex); // exclusive write
	m_arrMapping[iMapping] = mapping;
}

void SafeMapping::RemoveAll()
{
	std::lock_guard<std::mutex>	lock(m_mutex); // exclusive write
	m_arrMapping.clear();
}

void SafeMapping::Read(const IniFile& fIn)
{
	MappingArray	arr;
	arr.Read(fIn);
	std::lock_guard<std::mutex>	lock(m_mutex); // exclusive write
	m_arrMapping = arr;
}

void SafeMapping::Write(IniFile& fOut) const
{
	std::lock_guard<std::mutex>	lock(m_mutex);
	m_arrMapping.Write(fOut);
}

} // namespace whorld
