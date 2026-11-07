// Copyleft 2025 Chris Korda (original WhorldBase.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "whorld/WhorldBase.h"
#include "whorld/FormatIO.h"
#include "WhorldStrings.h"

#include <cassert>
#include <cmath>
#include <cstddef>
#include <cstring>

namespace whorld {

#define PI kPi	// abbreviation used in some parameter ranges
#define DTR(x) (x * (PI / 180))	// degrees to radians conversion

// ported from WhorldBase.cpp; all tables below are generated from
// WhorldDef.h exactly as in the original.

const WhorldBase::PARAM_INFO WhorldBase::m_arrParamInfo[PARAM_COUNT] = {
	#define PARAMDEF(name, minval, maxval, steps, scale, initval) \
		{#name, IDS_PARAM_##name, steps, minval, maxval, scale},
	#include "whorld/WhorldDef.h"	// generate array init list
};

const WhorldBase::PARAM_PROP_INFO WhorldBase::m_arrParamPropInfo[PARAM_PROP_COUNT] = {
	#define PARAMPROPDEF(name, type, prefix, variant) {#name, IDS_PROW_##name},
	#include "whorld/WhorldDef.h"	// generate array init list
};

const char* const WhorldBase::m_arrWaveformName[WAVEFORM_COUNT] = {
	#define WAVEFORMDEF(name) IDS_WAVE_##name,
	#include "whorld/WhorldDef.h"	// generate array init list
};

const int WhorldBase::m_arrGlobalToParam[GLOBAL_COUNT] = {
	#define GLOBALPARAMDEF(name) PARAM_##name,
	#include "whorld/WhorldDef.h"	// generate array init list
};

const WhorldBase::PARAM_VALS WhorldBase::m_paramDefault = {{
	#define PARAMDEF(name, minval, maxval, steps, scale, initval) initval,
	#include "whorld/WhorldDef.h"	// generate array init list
}};

const WhorldBase::MASTER_PROPS WhorldBase::m_masterDefault = {{
	#define MASTERDEF(name, type, prefix, initval) initval,
	#include "whorld/WhorldDef.h"	// generate array init list
}};

const DPOINT WhorldBase::INIT_ORIGIN = {0.5, 0.5};

const WhorldBase::MAIN_PROPS WhorldBase::m_mainDefault = {
	#define MAINDEF(name, type, prefix, initval, variant) initval,
	#include "whorld/WhorldDef.h"	// generate array init list
};

const WhorldBase::MASTER_INFO WhorldBase::m_arrMasterInfo[MASTER_COUNT] = {
	#define MASTERDEF(name, type, prefix, initval) \
		{#name, IDS_MASTER_##name},
	#include "whorld/WhorldDef.h"	// generate array init list
};

const WhorldBase::MAIN_INFO WhorldBase::m_arrMainInfo[MAIN_COUNT] = {
	#define MAINDEF(name, type, prefix, initval, variant) \
		{#name, IDS_MAIN_##name, FIO_##type, offsetof(MAIN_PROPS, prefix##name)},
	#include "whorld/WhorldDef.h"	// generate array init list
};

const char* const WhorldBase::m_arrRenderCmdName[RENDER_COMMANDS] = {
	"RESIZE",			// base class commands come first
	"FULL_SCREEN",
	#define PARAMPROPDEF(name, type, prefix, variant) "SET_PARAM_" #name,
	#include "whorld/WhorldDef.h"	// generate range of parameter commands
	#define RENDERCMDDEF(name, vartype) #name,
	#include "whorld/WhorldDef.h"	// generate regular commands
};

// The original fills this at startup in InitWhorldBase: -1 for parameters
// that lack a global, else the global's index. Built statically here.
namespace {
struct ParamToGlobalTable {
	int	a[WhorldBase::PARAM_COUNT];
};
constexpr int kGlobalToParam[] = {
	#define GLOBALPARAMDEF(name) WhorldBase::PARAM_##name,
	#include "whorld/WhorldDef.h"
};
constexpr ParamToGlobalTable MakeParamToGlobal()
{
	ParamToGlobalTable	t{};
	for (int iParam = 0; iParam < WhorldBase::PARAM_COUNT; iParam++)
		t.a[iParam] = -1;
	for (int iGlobal = 0; iGlobal < WhorldBase::GLOBAL_COUNT; iGlobal++)
		t.a[kGlobalToParam[iGlobal]] = iGlobal;
	return t;
}
constexpr ParamToGlobalTable kParamToGlobal = MakeParamToGlobal();
} // namespace

const int WhorldBase::m_arrParamToGlobal[PARAM_COUNT] = {
	#define PARAMDEF(name, minval, maxval, steps, scale, initval) \
		kParamToGlobal.a[PARAM_##name],
	#include "whorld/WhorldDef.h"
};

const WhorldBase::GLOB_RING WhorldBase::m_globalRingDefault = {
	0,	// fRot
	1,	// fStarRatio
	0,	// fPinwheel
	{1, 1},	// ptScale
	{0, 0},	// ptShift
	0,	// fEvenCurve
	0,	// fOddCurve
	1,	// fEvenShear
	1,	// fOddShear
	0,	// fLineWidth
	0,	// nPolySides
	0,	// nReserved (implicitly zero in the original)
};

// ported from WhorldBase.cpp CWhorldBase::SetParamDefaults
void WhorldBase::SetParamDefaults(PARAM_TABLE& aParam)
{
	static const PARAM_ROW rowDefault = {0, 0, 0, 0, 0.5, 0};
	for (int iParam = 0; iParam < PARAM_COUNT; iParam++) {	// for each parameter
		PARAM_ROW&	row = aParam.row[iParam];
		row = rowDefault;
		row.fVal = m_paramDefault.a[iParam];
	}
}

// ported from WhorldBase.h (inline attribute and lookup methods)

const WhorldBase::PARAM_INFO& WhorldBase::GetParamInfo(int iParam)
{
	assert(IsValidParamIdx(iParam));
	return m_arrParamInfo[iParam];
}

double WhorldBase::GetParamDefault(int iParam)
{
	assert(IsValidParamIdx(iParam));
	return m_paramDefault.a[iParam];
}

std::string WhorldBase::GetParamName(int iParam)
{
	assert(IsValidParamIdx(iParam));
	return m_arrParamInfo[iParam].pszName;
}

const WhorldBase::PARAM_PROP_INFO& WhorldBase::GetParamPropInfo(int iProp)
{
	assert(IsValidParamProp(iProp));
	return m_arrParamPropInfo[iProp];
}

std::string WhorldBase::GetParamPropName(int iProp)
{
	assert(IsValidParamProp(iProp));
	return m_arrParamPropInfo[iProp].pszName;
}

const WhorldBase::MASTER_INFO& WhorldBase::GetMasterInfo(int iMaster)
{
	assert(IsValidMasterProp(iMaster));
	return m_arrMasterInfo[iMaster];
}

std::string WhorldBase::GetMasterName(int iMaster)
{
	assert(IsValidMasterProp(iMaster));
	return m_arrMasterInfo[iMaster].pszName;
}

const WhorldBase::MAIN_INFO& WhorldBase::GetMainInfo(int iMain)
{
	assert(IsValidMainProp(iMain));
	return m_arrMainInfo[iMain];
}

std::string WhorldBase::GetMainName(int iMain)
{
	assert(IsValidMainProp(iMain));
	return m_arrMainInfo[iMain].pszName;
}

std::string WhorldBase::GetWaveformName(int iWave)
{
	assert(iWave >= 0 && iWave < WAVEFORM_COUNT);
	return m_arrWaveformName[iWave];
}

int WhorldBase::MapGlobalToParam(int iGlobal)
{
	assert(IsValidGlobalParam(iGlobal));
	return m_arrGlobalToParam[iGlobal];
}

int WhorldBase::MapParamToGlobal(int iParam)
{
	assert(IsValidParamIdx(iParam));
	return m_arrParamToGlobal[iParam];
}

const char* WhorldBase::GetRenderCmdName(int nCmd)
{
	assert(nCmd >= 0 && nCmd < RENDER_COMMANDS);
	return m_arrRenderCmdName[nCmd];
}

int WhorldBase::FindParamByTag(const char* pszTag)
{
	for (int iParam = 0; iParam < PARAM_COUNT; iParam++) {	// for each parameter
		if (!std::strcmp(pszTag, m_arrParamInfo[iParam].pszTag))	// if tag found
			return iParam;	// return parameter index
	}
	return -1;	// tag not found
}

int WhorldBase::FindParamPropByTag(const char* pszTag)
{
	for (int iProp = 0; iProp < PARAM_PROP_COUNT; iProp++) {	// for each parameter property
		if (!std::strcmp(pszTag, m_arrParamPropInfo[iProp].pszTag))	// if tag found
			return iProp;	// return parameter property index
	}
	return -1;	// tag not found
}

int WhorldBase::FindMasterByTag(const char* pszTag)
{
	for (int iMaster = 0; iMaster < MASTER_COUNT; iMaster++) {	// for each master property
		if (!std::strcmp(pszTag, m_arrMasterInfo[iMaster].pszTag))	// if tag found
			return iMaster;	// return master property index
	}
	return -1;	// tag not found
}

int WhorldBase::FindMainByTag(const char* pszTag)
{
	for (int iMain = 0; iMain < MAIN_COUNT; iMain++) {	// for each main property
		if (!std::strcmp(pszTag, m_arrMainInfo[iMain].pszTag))	// if tag found
			return iMain;	// return main property index
	}
	return -1;	// tag not found
}

// ported from WhorldBase.cpp CWhorldBase::CMovieExportParams::CMovieExportParams
WhorldBase::MovieExportParams::MovieExportParams()
{
	m_szFrame = IntSize{0, 0};
	m_nExportFlags = 0;
	m_nStartFrame = 0;
	m_nEndFrame = 0;
}

} // namespace whorld
