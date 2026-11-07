// Copyleft 2025 Chris Korda (original WhorldBase.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from WhorldBase.h CWhorldBase. Differences from the original:
//   - names are std::string and come from compiled-in English strings
//     instead of string resources (see src/WhorldStrings.h);
//   - InitWhorldBase is not needed: tables are initialized statically;
//   - MFC hint classes (CParamHint, CPropHint) are UI-side and not ported;
//   - PARAM_TABLE gets 16-byte alignment from alignas instead of an
//     __m128 member.

#include "whorld/RenderCmd.h"
#include "whorld/Types.h"

#include <cstdint>
#include <string>

namespace whorld {

// Type tokens used in the type columns of WhorldDef.h (MAINDEF,
// PARAMPROPDEF). They also select the FIO_* formatted I/O type.
typedef int32_t		INT;
typedef uint32_t	UINT;
typedef double		DOUBLE;

// macro to allocate and assign a variant property for supported types
#define MAKE_VARIANT_PROP(type, val) VARIANT_PROP prop; prop.type = val;

// Anonymous structs inside unions are an extension that MSVC, clang and
// gcc all support; the original relies on them for PARAM_VALS and
// MASTER_PROPS, and ported code uses both the named members and the array.
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu-anonymous-struct"
#pragma clang diagnostic ignored "-Wnested-anon-types"
#elif defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wpedantic"
#endif

class WhorldBase : public RenderThreadBase {
public:
// Constants
	enum {	// parameters
		#define PARAMDEF(name, minval, maxval, steps, scale, initval) PARAM_##name,
		#include "whorld/WhorldDef.h"	// generate enumeration
		PARAM_COUNT
	};
	enum {	// master properties
		#define MASTERDEF(name, type, prefix, initval) MASTER_##name,
		#include "whorld/WhorldDef.h"	// generate enumeration
		MASTER_COUNT
	};
	enum {	// main properties
		#define MAINDEF(name, type, prefix, initval, variant) MAIN_##name,
		#include "whorld/WhorldDef.h"	// generate enumeration
		MAIN_COUNT
	};
	enum {	// global parameters
		#define GLOBALPARAMDEF(name) GLOBAL_##name,
		#include "whorld/WhorldDef.h"	// generate enumeration
		GLOBAL_COUNT
	};

// Types
	union PARAM_VALS {		// parameter values
		struct {
			#define PARAMDEF(name, minval, maxval, steps, scale, initval) double f##name;
			#include "whorld/WhorldDef.h"	// generate member definitions
		};
		double	a[PARAM_COUNT];	// array of parameters
	};
	struct PARAM_ROW {		// parameter row
		#define PARAMPROPDEF(name, type, prefix, variant) type prefix##name;
		#include "whorld/WhorldDef.h"	// generate member definitions
	};
	struct alignas(16) PARAM_TABLE {	// parameter table
		PARAM_ROW	row[PARAM_COUNT];	// parameter row
	};
	struct PARAM_INFO {		// information about parameters
		const char*	pszTag;		// pointer to private name string
		const char*	pszName;	// public name (replaces string resource ID)
		int		nSteps;		// number of steps for slider
		double	fMinVal;	// minimum value
		double	fMaxVal;	// maximum value
		double	fScale;		// slider control scaling factor
	};
	struct PARAM_PROP_INFO {	// information about parameter properties
		const char*	pszTag;		// pointer to private name string
		const char*	pszName;	// public name
	};
	union MASTER_PROPS {	// master properties
		struct {
			#define MASTERDEF(name, type, prefix, initval) type prefix##name;
			#include "whorld/WhorldDef.h"	// generate member definitions
		};
		double	a[MASTER_COUNT];	// array of master properties
	};
	struct MASTER_INFO {	// information about master properties
		const char*	pszTag;		// pointer to private name string
		const char*	pszName;	// public name
	};
	struct MAIN_PROPS {		// main properties
		#define MAINDEF(name, type, prefix, initval, variant) type prefix##name;
		#include "whorld/WhorldDef.h"	// generate member definitions
	};
	struct MAIN_INFO {		// information about main properties
		const char*	pszTag;		// pointer to private name string
		const char*	pszName;	// public name
		int		nFIOType;	// formatted I/O type
		int		nOffset;	// byte offset within MAIN_PROPS
	};
	class MovieExportParams {
	public:
		MovieExportParams();
		std::string	m_sFolderPath;	// path of destination folder
		IntSize	m_szFrame;		// output frame size, in pixels
		int		m_nExportFlags;	// see image export flags enum
		int64_t	m_nStartFrame;	// first frame to export
		int64_t	m_nEndFrame;	// last frame to export
	};
	class Status {		// status of dynamic members
	public:
		PARAM_VALS	params;	// parameter values
		DPoint	dptOrigin;	// normalized origin
		double	fZoom;		// zoom
		intptr_t	nRings;		// ring count
	};

// Constants
	enum {	// parameter properties
		#define PARAMPROPDEF(name, type, prefix, variant) PARAM_PROP_##name,
		#include "whorld/WhorldDef.h"	// generate enumeration
		PARAM_PROP_COUNT
	};
	enum {	// waveforms
		#define WAVEFORMDEF(name) WAVEFORM_##name,
		#include "whorld/WhorldDef.h"	// generate enumeration
		WAVEFORM_COUNT
	};
	enum {	// miscellaneous
		MAX_RINGS = 1000,	// maximum number of rings; used in master init
	};
	enum {	// draw modes
		DM_FILL		= 0x01,		// fill area between rings
		DM_OUTLINE	= 0x02,		// outline edges of filled rings
		DM_XRAY		= 0x04		// draw rings with XOR pen
	};
	enum {	// origin motion types
		OM_PARK,	// no motion
		OM_DRAG,	// cursor drag
		OM_RANDOM,	// random jump
		ORIGIN_MOTION_TYPES
	};
	enum {	// image export flags
		EF_USE_VIEW_SIZE	= 0x01,	// make image same size as view
		EF_SCALE_FIT_WIDTH	= 0x02,	// scale image to fit view width
		EF_SCALE_FIT_HEIGHT	= 0x04,	// scale image to fit view height
		EF_SCALE_FIT_BOTH	= EF_SCALE_FIT_WIDTH | EF_SCALE_FIT_HEIGHT,
	};
	enum {	// Whorld-specific render commands
		RC_START = BASE_RENDER_COMMANDS - 1,	// offset from base render commands
		// set parameter uses a range of commands, one for each parameter property;
		// m_nParam is the parameter index and m_prop is the variant data payload
		#define PARAMPROPDEF(name, type, prefix, variant) RC_SET_PARAM_##name,
		#include "whorld/WhorldDef.h"	// generate range of parameter commands
		#define RENDERCMDDEF(name, vartype) RC_##name,
		#include "whorld/WhorldDef.h"	// generate regular commands
		RENDER_COMMANDS,
		RC_SET_PARAM_FIRST = RC_START + 1,	// first set parameter command
		RC_SET_PARAM_LAST = RC_SET_PARAM_FIRST + PARAM_PROP_COUNT - 1,
	};
	enum {	// document update hints
		HINT_NONE,			// no hint
		HINT_PARAM,			// update parameter property
		HINT_MASTER,		// update master property
		HINT_MAIN,			// update main property
		HINT_ZOOM,			// update zoom
		HINT_ORIGIN,		// update origin
	};
	static const PARAM_VALS m_paramDefault;
	static const MASTER_PROPS m_masterDefault;
	static const MAIN_PROPS m_mainDefault;
	static const DPOINT INIT_ORIGIN;

// Operations
	static void SetParamDefaults(PARAM_TABLE& aParam);
	static int	FindParamByTag(const char* pszTag);
	static int	FindParamPropByTag(const char* pszTag);
	static int	FindMasterByTag(const char* pszTag);
	static int	FindMainByTag(const char* pszTag);

// Attributes
	static bool IsValidParamIdx(int iParam);
	static bool IsValidParamProp(int iProp);
	static bool IsValidMasterProp(int iMaster);
	static bool IsValidMainProp(int iMain);
	static bool IsValidGlobalParam(int iGlobal);
	static const PARAM_INFO& GetParamInfo(int iParam);
	static double GetParamDefault(int iParam);
	static std::string GetParamName(int iParam);
	static const PARAM_PROP_INFO& GetParamPropInfo(int iProp);
	static std::string GetParamPropName(int iProp);
	static const MASTER_INFO& GetMasterInfo(int iMaster);
	static std::string GetMasterName(int iMaster);
	static const MAIN_INFO& GetMainInfo(int iMain);
	static std::string GetMainName(int iMain);
	static int MapGlobalToParam(int iGlobal);
	static int MapParamToGlobal(int iParam);
	static std::string GetWaveformName(int iWave);
	static const char* GetRenderCmdName(int nCmd);

protected:
// Rendering types
	class DRAW_STATE {
	public:
		#define STATEDEF(type, name) type name;
		#include "whorld/WhorldDef.h"	//  generate struct members
	};
	struct RING {	// per-ring data
		#define RINGDEF(type, name) type name;
		#include "whorld/WhorldDef.h"	//  generate struct members
	};
	struct GLOB_RING {	// global ring offsets
		#define GLOBRINGDEF(type, name) type name;
		#include "whorld/WhorldDef.h"	//  generate struct members
	};
	static const GLOB_RING	m_globalRingDefault;	// default global ring

private:
	// use attribute methods instead, for range-checking
	static const PARAM_INFO m_arrParamInfo[PARAM_COUNT];
	static const PARAM_PROP_INFO m_arrParamPropInfo[PARAM_PROP_COUNT];
	static const MASTER_INFO m_arrMasterInfo[MASTER_COUNT];
	static const MAIN_INFO m_arrMainInfo[MAIN_COUNT];
	static const char* const m_arrWaveformName[WAVEFORM_COUNT];
	static const int m_arrGlobalToParam[GLOBAL_COUNT];
	static const int m_arrParamToGlobal[PARAM_COUNT];
	static const char* const m_arrRenderCmdName[RENDER_COMMANDS];
};

#if defined(__clang__)
#pragma clang diagnostic pop
#elif defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

static_assert(sizeof(WhorldBase::PARAM_VALS) == sizeof(double) * WhorldBase::PARAM_COUNT,
	"PARAM_VALS named members must overlay the array exactly");
static_assert(sizeof(WhorldBase::MASTER_PROPS) == sizeof(double) * WhorldBase::MASTER_COUNT,
	"MASTER_PROPS named members must overlay the array exactly");

inline bool WhorldBase::IsValidParamIdx(int iParam)
{
	return iParam >= 0 && iParam < PARAM_COUNT;
}

inline bool WhorldBase::IsValidParamProp(int iProp)
{
	return iProp >= 0 && iProp < PARAM_PROP_COUNT;
}

inline bool WhorldBase::IsValidMasterProp(int iMaster)
{
	return iMaster >= 0 && iMaster < MASTER_COUNT;
}

inline bool WhorldBase::IsValidMainProp(int iMain)
{
	return iMain >= 0 && iMain < MAIN_COUNT;
}

inline bool WhorldBase::IsValidGlobalParam(int iGlobal)
{
	return iGlobal >= 0 && iGlobal < GLOBAL_COUNT;
}

} // namespace whorld
