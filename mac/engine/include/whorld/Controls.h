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

#pragma once

// The control math of the Windows parameter, globals and master panes:
// how a value maps to a slider position, how it is shown in its edit box,
// and the ranges typed values are clamped to. It is UI logic, but portable,
// so it lives in the engine where it can be tested.
//
// Slider positions are integers, as with the Win32 trackbar: setting a value
// moves the slider to Round(Norm(value)), and dragging sets Denorm(position).

#include <string>

namespace whorld {

// One row's control behavior.
struct ControlInfo {
	int		nRangeMin;		// slider position range
	int		nRangeMax;
	int		nDefaultPos;	// slider default position
	int		nPageSize;		// slider page size
	double	fEditScale;		// the edit box shows value / fEditScale
	int		nEditPrecision;	// digits after the point, or -1 for %g
	double	fEditMin;		// typed values are clamped to this range...
	double	fEditMax;
	bool	bEditClamp;		// ...if true
	double	fSpinDelta;		// spin button step, in value units (0: none)
};

class Controls {
public:
	enum {	// SLIDER_PAGES in ParamsRowDlg.h, GlobalsRowDlg.h, MasterRowDlg.h
		SLIDER_PAGES = 10,
	};
	// which parameter property column (the Val column has the slider)
	enum {
		COL_Val,
		COL_Amp,
		COL_Freq,
		COL_PW,
	};

// Parameter pane (ParamsRowDlg)
	static ControlInfo	ParamInfo(int iParam, int iCol);
	static double	ParamNorm(int iParam, double fVal);		// value to slider position
	static double	ParamDenorm(int iParam, double fPos);	// slider position to value

// Globals pane (GlobalsRowDlg): symmetric range, -max to max
	static ControlInfo	GlobalInfo(int iParam);
	static double	GlobalNorm(int iParam, double fVal);
	static double	GlobalDenorm(int iParam, double fPos);

// Master pane (MasterRowDlg)
	static ControlInfo	MasterInfo(int iProp);
	static double	MasterNorm(int iProp, double fVal);		// value to slider position
	static double	MasterDenorm(int iProp, double fPos);	// slider position to value
	// normalized 0..1 versions, used for MIDI mapping (CMasterRowDlg::Norm)
	static double	MasterNorm01(int iProp, double fVal);
	static double	MasterDenorm01(int iProp, double fVal);

// Edit box text (CNumEdit::ValToStr / StrToVal, CMasterRowDlg::CMyNumEdit)
	static std::string	FormatValue(const ControlInfo& info, double fVal);
	static double	ParseValue(const ControlInfo& info, const char* pszText);
	// Spin button (CNumEdit::AddSpin): step by nDir * fSpinDelta, snap tiny
	// results to zero, clamp. Returns false if the clamped value is unchanged.
	static bool		AddSpin(const ControlInfo& info, double& fVal, int nDir);
	static std::string	FormatMaster(int iProp, double fVal);
	static bool		ParseMaster(int iProp, const char* pszText, double& fVal);
};

} // namespace whorld
