// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#include "whorld/OscRemote.h"
#include "whorld/Controls.h"
#include "whorld/MidiManager.h"
#include "whorld/Patch.h"

#include <cassert>
#include <cmath>
#include <unordered_map>

namespace whorld {

namespace {

// Two-letter codes, in WhorldDef.h's order (PARAMDEF, MASTERDEF).
const char* const	kParamCode[] = {
	"rg",	// Ring Growth
	"rs",	// Ring Spacing
	"lw",	// Line Width
	"sd",	// Ring Sides (PolySides)
	"rt",	// Rotate Speed
	"ar",	// Aspect Ratio
	"kr",	// Skew Radius
	"ka",	// Skew Angle
	"sf",	// Star Factor
	"pn",	// Pinwheel
	"cs",	// Color Speed
	"lt",	// Lightness
	"st",	// Saturation
	"al",	// Alpha
	"bh",	// Bk Hue
	"bl",	// Bk Lightness
	"bs",	// Bk Saturation
	"ba",	// Bk Alpha
	"ec",	// Even Curve
	"oc",	// Odd Curve
	"es",	// Even Shear
	"os",	// Odd Shear
};
static_assert(sizeof(kParamCode) / sizeof(kParamCode[0]) == WhorldBase::PARAM_COUNT, "a code per parameter");

const char* const	kMasterCode[] = {
	"sp",	// Speed
	"zm",	// Zoom
	"dp",	// Damping
	"tr",	// Trail
	"rn",	// Rings
	"tp",	// Tempo
	"hs",	// Hue Span
	"cv",	// Canvas
	"cp",	// Copies
	"sr",	// Spread
	"fd",	// Fade
};
static_assert(sizeof(kMasterCode) / sizeof(kMasterCode[0]) == WhorldBase::MASTER_COUNT, "a code per master property");

// Parameter columns, in PARAMPROPDEF order: Val, Wave, Amp, Freq, PW, Global.
const char* const	kPropCode[] = {"v", "w", "a", "f", "p", "g"};
static_assert(sizeof(kPropCode) / sizeof(kPropCode[0]) == WhorldBase::PARAM_PROP_COUNT, "a code per column");

// The rest, in MappingDef.h's MAPPINGDEF_MISC_TARGET order.
const char* const	kMiscName[] = {
	"org/x",	// OriginX
	"org/y",	// OriginY
	"fill",		// Fill
	"outline",	// Outline
	"mirror",	// Mirror
	"drag",		// OriginDrag
	"random",	// OriginRandom
	"reverse",	// Reverse
	"convex",	// Convex
	"loophue",	// LoopHue
	"zoomctr",	// ZoomCenter
	"aa",		// Antialiasing
	"rndphase",	// RandomPhase
	"rndorg",	// RandomOrigin
	"clear",	// Clear
	"pause",	// Pause
	"patch",	// Patch
};
static_assert(sizeof(kMiscName) / sizeof(kMiscName[0]) == MappingBase::MISC_TARGETS, "a name per miscellaneous target");

std::string Path(const std::string& s) { return std::string(OscRemote::PREFIX) + "/" + s; }

struct Table {
	std::vector<OscRemote::Address>	inputs;
	std::unordered_map<std::string, std::pair<int, int>>	byPath;	// path -> target, column

	Table()
	{
		for (int iParam = 0; iParam < WhorldBase::PARAM_COUNT; iParam++) {
			std::string	base = Path(std::string("p/") + kParamCode[iParam]);
			byPath[base] = {iParam, WhorldBase::PARAM_PROP_Val};	// shorthand
			for (int iProp = 0; iProp < WhorldBase::PARAM_PROP_COUNT; iProp++) {
				if (iProp == WhorldBase::PARAM_PROP_Global && WhorldBase::MapParamToGlobal(iParam) < 0)
					continue;	// no global
				std::string	path = base + "/" + kPropCode[iProp];
				inputs.push_back({path, iParam, iProp});
				byPath[path] = {iParam, iProp};
			}
		}
		for (int iMaster = 0; iMaster < WhorldBase::MASTER_COUNT; iMaster++) {
			std::string	path = Path(std::string("m/") + kMasterCode[iMaster]);
			int	iTarget = WhorldBase::PARAM_COUNT + iMaster;
			inputs.push_back({path, iTarget, -1});
			byPath[path] = {iTarget, -1};
		}
		for (int iMisc = 0; iMisc < MappingBase::MISC_TARGETS; iMisc++) {
			std::string	path = Path(kMiscName[iMisc]);
			int	iTarget = WhorldBase::PARAM_COUNT + WhorldBase::MASTER_COUNT + iMisc;
			inputs.push_back({path, iTarget, -1});
			byPath[path] = {iTarget, -1};
		}
	}
};

const Table& GetTable()
{
	static const Table	table;
	return table;
}

int MiscOf(int iTarget) { return iTarget - WhorldBase::PARAM_COUNT - WhorldBase::MASTER_COUNT; }

double Norm(double v, const WhorldBase::PARAM_INFO& info)
{
	return (v - info.fMinVal) / (info.fMaxVal - info.fMinVal);
}

}	// namespace

const std::vector<OscRemote::Address>& OscRemote::Inputs() { return GetTable().inputs; }

int OscRemote::Find(const std::string& sPath, int& iProp)
{
	const auto&	m = GetTable().byPath;
	auto	it = m.find(sPath);
	if (it == m.end()) {
		iProp = -1;
		return -1;
	}
	iProp = it->second.second;
	return it->second.first;
}

const char* OscRemote::ParamCode(int iParam) { assert(IsValidParamIdx(iParam)); return kParamCode[iParam]; }
const char* OscRemote::MasterCode(int iProp) { assert(IsValidMasterProp(iProp)); return kMasterCode[iProp]; }
const char* OscRemote::PropCode(int iProp) { assert(IsValidParamProp(iProp)); return kPropCode[iProp]; }
const char* OscRemote::MiscName(int iMisc) { assert(iMisc >= 0 && iMisc < MISC_TARGETS); return kMiscName[iMisc]; }

OscRemote::Request OscRemote::Handle(const OscMessage& msg, MidiManager& midi)
{
	Request	req;
	const std::string&	path = msg.path;
	if (path == Path("ping")) {
		req.type = Request::PING;
		return req;
	}
	if (path == Path("sync")) {
		req.type = Request::SYNC;
		return req;
	}
	const OscArg*	pArg = !msg.args.empty() && msg.args[0].IsNumber() ? &msg.args[0] : nullptr;
	if (path == Path("org")) {	// an XY pad: x and y in one message
		if (msg.args.size() >= 2 && msg.args[0].IsNumber() && msg.args[1].IsNumber()) {
			int	iFirst = PARAM_COUNT + MASTER_COUNT;
			midi.DispatchTarget(iFirst + MT_OriginX, -1, msg.args[0].Number());
			midi.DispatchTarget(iFirst + MT_OriginY, -1, msg.args[1].Number());
			req.type = Request::DISPATCHED;
		}
		return req;
	}
	int	iProp;
	int	iTarget = Find(path, iProp);
	if (iTarget < 0)
		return req;	// not ours
	req.iTarget = iTarget;
	if (iTarget < PARAM_COUNT + MASTER_COUNT) {	// parameter or master property: needs a number
		if (!pArg)
			return req;
		double	f = pArg->Number();
		if (iProp == PARAM_PROP_Wave && pArg->type != OscArg::FLOAT)	// an index
			f = (f + 0.5) / WAVEFORM_COUNT;
		midi.DispatchTarget(iTarget, iProp, f);
		req.type = Request::DISPATCHED;
		return req;
	}
	int	iMisc = MiscOf(iTarget);
	switch (iMisc) {
	case MT_Pause:
		req.type = Request::PAUSE;
		req.iVal = pArg ? (pArg->Number() != 0) : -1;
		return req;
	case MT_Patch:
		if (pArg) {
			req.type = Request::PATCH;
			req.iVal = pArg->type == OscArg::FLOAT	// normalized, as MIDI's note number
				? static_cast<int>(std::lround(pArg->f * 127)) : static_cast<int>(pArg->i);
		}
		return req;
	}
	switch (GetTargetType(iTarget)) {
	case TT_ACTION:	// a button: on press (no argument, or nonzero), not on release
		if (!pArg || pArg->Number() != 0) {
			midi.DispatchTarget(iTarget, -1, 1);
			req.type = Request::DISPATCHED;
		}
		return req;
	case TT_BOOL:
		if (!pArg) {	// no argument: the app toggles it (it knows the state)
			req.type = Request::TOGGLE;
			return req;
		}
		midi.DispatchTarget(iTarget, -1, pArg->Number() != 0 ? 1 : 0);
		req.type = Request::DISPATCHED;
		return req;
	default:	// a range: the origin
		if (pArg) {
			midi.DispatchTarget(iTarget, -1, pArg->Number());
			req.type = Request::DISPATCHED;
		}
		return req;
	}
}

bool OscRemote::StateValue(const Patch& doc, int iTarget, int iProp, OscArg& arg)
{
	if (iTarget < 0)
		return false;
	if (iTarget < PARAM_COUNT) {	// the inverse of MidiManager::PushParameter
		const PARAM_INFO&	info = GetParamInfo(iTarget);
		const PARAM_ROW&	row = doc.m_aParam.row[iTarget];
		switch (iProp) {
		case PARAM_PROP_Val: arg = OscArg::Float(Norm(row.fVal, info)); return true;
		case PARAM_PROP_Amp: arg = OscArg::Float(Norm(row.fAmp, info)); return true;
		case PARAM_PROP_Freq: arg = OscArg::Float(row.fFreq); return true;
		case PARAM_PROP_PW: arg = OscArg::Float(row.fPW); return true;
		case PARAM_PROP_Wave: arg = OscArg::Int(row.iWave); return true;
		case PARAM_PROP_Global:
			if (MapParamToGlobal(iTarget) < 0)
				return false;
			arg = OscArg::Float(row.fGlobal / (info.fMaxVal * 2) + 0.5);
			return true;
		}
		return false;
	}
	if (iTarget < PARAM_COUNT + MASTER_COUNT) {
		int	iMaster = iTarget - PARAM_COUNT;
		arg = OscArg::Float(Controls::MasterNorm01(iMaster, doc.m_master.a[iMaster]));
		return true;
	}
	const MAIN_PROPS&	m = doc.m_main;
	switch (MiscOf(iTarget)) {
	case MT_OriginX: arg = OscArg::Float(m.dptOrigin.x); return true;
	case MT_OriginY: arg = OscArg::Float(m.dptOrigin.y); return true;
	case MT_Fill: arg = OscArg::Float((m.nDrawMode & DM_FILL) ? 1 : 0); return true;
	case MT_Outline: arg = OscArg::Float((m.nDrawMode & DM_OUTLINE) ? 1 : 0); return true;
	case MT_Mirror: arg = OscArg::Float(m.bMirror); return true;
	case MT_OriginDrag: arg = OscArg::Float(m.nOrgMotion == OM_DRAG); return true;
	case MT_OriginRandom: arg = OscArg::Float(m.nOrgMotion == OM_RANDOM); return true;
	case MT_Reverse: arg = OscArg::Float(m.bReverse); return true;
	case MT_Convex: arg = OscArg::Float(m.bConvex); return true;
	case MT_LoopHue: arg = OscArg::Float(m.bLoopHue); return true;
	case MT_ZoomCenter: arg = OscArg::Float(m.bZoomCenter); return true;
	case MT_Antialiasing: arg = OscArg::Float(m.bAntialiasing); return true;
	default: return false;	// actions, pause and patch
	}
}

}	// namespace whorld
