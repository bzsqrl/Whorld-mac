// Copyleft 2025 Chris Korda (original ParamsRowDlg.cpp, GlobalsRowDlg.cpp,
// MasterRowDlg.cpp, EditSliderCtrl.cpp, NumEdit.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "whorld/Controls.h"
#include "whorld/Patch.h"
#include "whorld/Round.h"
#include "MsvcFormat.h"

#include <algorithm>
#include <cassert>
#include <climits>
#include <cmath>
#include <cstdlib>

namespace whorld {

namespace {

// ported from EditSliderCtrl.h CEditSliderCtrl::INFO
struct SLIDER_INFO {
	int		nRangeMin;		// range lower limit
	int		nRangeMax;		// range upper limit
	float	fLogBase;		// if non-zero, position is exponent of this base
	float	fSliderScale;	// slider position is scaled by this factor
	int		nDefaultPos;	// default position, in slider coordinates
	int		nTicCount;		// if non-zero, number of tics, evenly spaced
	float	fEditScale;		// edit control's value is scaled by this factor
	int		nEditPrecision;	// edit control's digits to right of decimal point
};

// ported from MasterRowDlg.cpp CMasterRowDlg::m_arrSliderInfo
const SLIDER_INFO kMasterSlider[WhorldBase::MASTER_COUNT] = {
	{-100,	100,	20,		100,	0,		0,		.01f,	0},	// Speed
	{-100,	100,	10,		100,	0,		0,		.01f,	2},	// Zoom
	{0,		100,	20,		101,	50,		0,		100,	2},	// Damping
	{0,		100,	10,		100,	0,		0,		.01f,	2},	// Trail
	{0,		100,	30,		100,	100,	0,		1,		0},	// Rings
	{0,		250,	0,		1,		100,	0,		1,		2},	// Tempo
	{0,		360,	0,		1,		30,		0,		1,		0},	// Hue Loop
	{100,	300,	0,		100,	140,	0,		.01f,	0},	// Canvas
	{1,		20,		0,		1,		0,		0,		1,		0},	// Copies
	{0,		600,	0,		1,		100,	0,		1,		0},	// Spread
	{0,		200,	0,		1,		0,		0,		1,		0},	// Fade (Mac port): rings, 0 = off
};
static_assert(sizeof(kMasterSlider) / sizeof(kMasterSlider[0]) == WhorldBase::MASTER_COUNT, "one row per master property");

// ported from MasterRowDlg.cpp CMasterRowDlg::m_arrEditRange; rows not
// listed are zero, meaning "use the slider range times the edit scale"
struct DBL_RANGE {
	double	fMinVal;
	double	fMaxVal;
};
const DBL_RANGE kMasterEditRange[WhorldBase::MASTER_COUNT] = {
	{0,		1e2},	// Speed
	{1e-3,	1e2},	// Zoom
	{1e-3,	1},		// Damping
	{0,		1},		// Trail
	{0,		Patch::MAX_RINGS},	// Rings
};

// ported from MasterRowDlg.cpp CMasterRowDlg::Log, LogNorm, ExpNorm
inline double Log(double Base, double x)
{
	return std::log(x) / std::log(Base);	// log with arbitrary base
}

inline double LogNorm(double x, double Base, double Scale)
{
	// x is exponential from 0..1, result is linear from 0..Scale
	return Log(Base, x * (Base - 1) + 1) * Scale;
}

inline double ExpNorm(double x, double Base, double Scale)
{
	// x is linear from 0..Scale, result is exponential from 0..1
	return (std::pow(Base, x / Scale) - 1) / (Base - 1);
}

// ported from EditSliderCtrl.cpp CEditSliderCtrl::Norm(INFO) and Denorm(INFO)
double SliderNorm(const SLIDER_INFO& info, double fVal)
{
	if (info.fLogBase)
		fVal = std::log(fVal) / std::log(double(info.fLogBase));
	return fVal * info.fSliderScale;
}

double SliderDenorm(const SLIDER_INFO& info, double fVal)
{
	fVal /= info.fSliderScale;
	if (info.fLogBase)
		fVal = std::pow(double(info.fLogBase), fVal);
	return fVal;
}

} // namespace

// ported from ParamsRowDlg.cpp CParamsRowDlg::OnInitDialog and GetSliderDefaultPos
ControlInfo Controls::ParamInfo(int iParam, int iCol)
{
	const WhorldBase::PARAM_INFO&	info = WhorldBase::GetParamInfo(iParam);
	ControlInfo	ci = {};
	ci.nRangeMin = 0;
	ci.nRangeMax = info.nSteps;
	ci.nDefaultPos = Round((WhorldBase::GetParamDefault(iParam) - info.fMinVal)
		/ (info.fMaxVal - info.fMinVal) * info.nSteps);
	ci.nPageSize = info.nSteps / SLIDER_PAGES;
	ci.nEditPrecision = -1;	// CNumEdit default: %g
	switch (iCol) {
	case COL_Val:
		ci.fEditScale = info.fScale;
		ci.fEditMin = info.fMinVal;
		ci.fEditMax = info.fMaxVal;
		ci.bEditClamp = true;
		ci.fSpinDelta = (info.fMaxVal - info.fMinVal) / info.nSteps;
		break;
	case COL_Amp:
		ci.fEditScale = info.fScale;	// no range: amplitude can be negative
		ci.fSpinDelta = 0.01;
		break;
	case COL_Freq:
		ci.fEditScale = 1;
		ci.fEditMin = 0;
		ci.fEditMax = INT_MAX;
		ci.bEditClamp = true;
		ci.fSpinDelta = 0.01;
		break;
	case COL_PW:
		ci.fEditScale = 1;
		ci.fEditMin = 0;
		ci.fEditMax = 1;
		ci.bEditClamp = true;
		ci.fSpinDelta = 0.01;
		break;
	default:
		assert(0);
	}
	return ci;
}

// ported from ParamsRowDlg.cpp CParamsRowDlg::CMyEditSliderCtrl::Norm
double Controls::ParamNorm(int iParam, double x)
{
	const WhorldBase::PARAM_INFO&	info = WhorldBase::GetParamInfo(iParam);
	return (x - info.fMinVal) / (info.fMaxVal - info.fMinVal) * info.nSteps;
}

// ported from ParamsRowDlg.cpp CParamsRowDlg::CMyEditSliderCtrl::Denorm
double Controls::ParamDenorm(int iParam, double x)
{
	const WhorldBase::PARAM_INFO&	info = WhorldBase::GetParamInfo(iParam);
	return x / info.nSteps * (info.fMaxVal - info.fMinVal) + info.fMinVal;
}

// ported from GlobalsRowDlg.cpp CGlobalsRowDlg::OnInitDialog
ControlInfo Controls::GlobalInfo(int iParam)
{
	const WhorldBase::PARAM_INFO&	info = WhorldBase::GetParamInfo(iParam);
	double	fMinVal = -info.fMaxVal;	// for globals, minimum is negative maximum
	ControlInfo	ci = {};
	ci.nRangeMin = 0;
	ci.nRangeMax = info.nSteps;
	ci.nDefaultPos = info.nSteps / 2;
	ci.nPageSize = info.nSteps / SLIDER_PAGES;
	ci.fEditScale = info.fScale;
	ci.nEditPrecision = -1;
	ci.fEditMin = fMinVal;
	ci.fEditMax = info.fMaxVal;
	ci.bEditClamp = true;
	ci.fSpinDelta = (info.fMaxVal - fMinVal) / info.nSteps;
	return ci;
}

// ported from GlobalsRowDlg.cpp CGlobalsRowDlg::CMyEditSliderCtrl::Norm
double Controls::GlobalNorm(int iParam, double x)
{
	const WhorldBase::PARAM_INFO&	info = WhorldBase::GetParamInfo(iParam);
	// use maximum value and its negation for symmetrical range
	return (x + info.fMaxVal) / (info.fMaxVal * 2) * info.nSteps;
}

// ported from GlobalsRowDlg.cpp CGlobalsRowDlg::CMyEditSliderCtrl::Denorm
double Controls::GlobalDenorm(int iParam, double x)
{
	const WhorldBase::PARAM_INFO&	info = WhorldBase::GetParamInfo(iParam);
	// use maximum value and its negation for symmetrical range
	return x / info.nSteps * (info.fMaxVal * 2) - info.fMaxVal;
}

// ported from MasterRowDlg.cpp CMasterRowDlg::OnInitDialog and GetPropEditRange
ControlInfo Controls::MasterInfo(int iProp)
{
	assert(WhorldBase::IsValidMasterProp(iProp));
	const SLIDER_INFO&	info = kMasterSlider[iProp];
	DBL_RANGE	range = kMasterEditRange[iProp];
	if (!range.fMinVal && !range.fMaxVal) {
		range.fMinVal = info.nRangeMin * info.fEditScale;
		range.fMaxVal = info.nRangeMax * info.fEditScale;
	}
	ControlInfo	ci = {};
	ci.nRangeMin = info.nRangeMin;
	ci.nRangeMax = info.nRangeMax;
	ci.nDefaultPos = info.nDefaultPos;
	ci.nPageSize = (info.nRangeMax - info.nRangeMin) / SLIDER_PAGES;
	ci.fEditScale = info.fEditScale;
	ci.nEditPrecision = info.nEditPrecision;
	ci.fEditMin = range.fMinVal;
	ci.fEditMax = range.fMaxVal;
	ci.bEditClamp = true;
	ci.fSpinDelta = 0;	// master rows have no spin buttons
	return ci;
}

// ported from MasterRowDlg.cpp CMasterRowDlg::SliderNorm
double Controls::MasterNorm(int iProp, double fVal)
{
	const SLIDER_INFO&	info = kMasterSlider[iProp];
	switch (iProp) {
	case WhorldBase::MASTER_Damping:
		return info.fSliderScale - LogNorm(fVal, info.fLogBase, info.fSliderScale);
	case WhorldBase::MASTER_Trail:
		return LogNorm(fVal, info.fLogBase, info.fSliderScale);
	case WhorldBase::MASTER_Rings:
		return LogNorm(fVal / Patch::MAX_RINGS, info.fLogBase, info.fSliderScale);
	default:
		return SliderNorm(info, fVal);
	}
}

// ported from MasterRowDlg.cpp CMasterRowDlg::SliderDenorm
double Controls::MasterDenorm(int iProp, double fVal)
{
	const SLIDER_INFO&	info = kMasterSlider[iProp];
	switch (iProp) {
	case WhorldBase::MASTER_Damping:
		return ExpNorm(info.fSliderScale - fVal, info.fLogBase, info.fSliderScale);
	case WhorldBase::MASTER_Trail:
		return ExpNorm(fVal, info.fLogBase, info.fSliderScale);
	case WhorldBase::MASTER_Rings:
		return ExpNorm(fVal, info.fLogBase, info.fSliderScale) * Patch::MAX_RINGS;
	default:
		return SliderDenorm(info, fVal);
	}
}

// ported from MasterRowDlg.cpp CMasterRowDlg::Norm
double Controls::MasterNorm01(int iProp, double fVal)
{
	const SLIDER_INFO&	info = kMasterSlider[iProp];
	fVal = MasterNorm(iProp, fVal);
	return (fVal - info.nRangeMin) / (info.nRangeMax - info.nRangeMin);
}

// ported from MasterRowDlg.cpp CMasterRowDlg::Denorm
double Controls::MasterDenorm01(int iProp, double fVal)
{
	const SLIDER_INFO&	info = kMasterSlider[iProp];
	fVal = fVal * (info.nRangeMax - info.nRangeMin) + info.nRangeMin;
	return MasterDenorm(iProp, fVal);
}

// ported from NumEdit.cpp CNumEdit::ValToStr
std::string Controls::FormatValue(const ControlInfo& info, double fVal)
{
	double	r = fVal / info.fEditScale;
	if (info.nEditPrecision < 0)
		return detail::FormatMsvc("%g", r);
	return detail::FormatMsvc("%.*f", info.nEditPrecision, r);
}

// ported from NumEdit.cpp CNumEdit::StrToVal and the range clamp in SetVal
double Controls::ParseValue(const ControlInfo& info, const char* pszText)
{
	double	r = std::atof(pszText) * info.fEditScale;
	if (info.bEditClamp)
		r = std::min(std::max(r, info.fEditMin), info.fEditMax);
	return r;
}

// ported from NumEdit.cpp CNumEdit::AddSpin
bool Controls::AddSpin(const ControlInfo& info, double& fVal, int nDir)
{
	double	fNewVal = fVal + info.fSpinDelta * nDir;
	const double fEpsilon = 1e-10;	// quite small
	if (std::fabs(fNewVal) < fEpsilon)	// if infinitesimal
		fNewVal = 0;	// call it zero
	if (info.bEditClamp) {	// if range was specified
		fNewVal = std::min(std::max(fNewVal, info.fEditMin), info.fEditMax);
		if (fNewVal == fVal)	// if clamped value is unchanged
			return false;	// don't notify
	}
	fVal = fNewVal;
	return true;
}

// ported from MasterRowDlg.cpp CMasterRowDlg::CMyNumEdit::ValToStr
std::string Controls::FormatMaster(int iProp, double fVal)
{
	const SLIDER_INFO&	info = kMasterSlider[iProp];
	if (iProp == WhorldBase::MASTER_Damping) {	// shown inverted, as a percentage
		return detail::FormatMsvc("%.*f", info.nEditPrecision,
			info.fEditScale - fVal * info.fEditScale);
	}
	return FormatValue(MasterInfo(iProp), fVal);
}

// ported from MasterRowDlg.cpp CMasterRowDlg::CMyNumEdit::StrToVal
bool Controls::ParseMaster(int iProp, const char* pszText, double& fVal)
{
	const SLIDER_INFO&	info = kMasterSlider[iProp];
	ControlInfo	ci = MasterInfo(iProp);
	if (iProp == WhorldBase::MASTER_Damping) {
		fVal = (info.fEditScale - std::atof(pszText)) / info.fEditScale;
		fVal = std::min(std::max(fVal, ci.fEditMin), ci.fEditMax);
	} else {
		fVal = ParseValue(ci, pszText);
	}
	return true;
}

} // namespace whorld
