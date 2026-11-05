// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Tests for Controls: slider and edit-box math of the Windows panes.

#include "TestHarness.h"
#include "whorld/Controls.h"
#include "whorld/Patch.h"

#include <cmath>
#include <string>

using namespace whorld;
using WB = WhorldBase;

TEST(ParamSlider) {
	// Ring Growth: 0..10 in 1000 steps, default 1
	ControlInfo	ci = Controls::ParamInfo(WB::PARAM_RingGrowth, Controls::COL_Val);
	CHECK_EQ(ci.nRangeMax, 1000);
	CHECK_EQ(ci.nDefaultPos, 100);
	CHECK_EQ(ci.nPageSize, 100);
	CHECK_NEAR(Controls::ParamNorm(WB::PARAM_RingGrowth, 2.5), 250, 1e-9);
	CHECK_NEAR(Controls::ParamDenorm(WB::PARAM_RingGrowth, 250), 2.5, 1e-9);
	CHECK_NEAR(ci.fSpinDelta, 0.01, 1e-12);
	// Ring Sides: 3..51 in 48 steps, default 5 -> position 2
	CHECK_EQ(Controls::ParamInfo(WB::PARAM_PolySides, Controls::COL_Val).nDefaultPos, 2);
}

TEST(ParamAnglesShownInDegrees) {
	// Rotate Speed is stored in radians and shown in degrees (fScale = DTR(1))
	ControlInfo	ci = Controls::ParamInfo(WB::PARAM_RotateSpeed, Controls::COL_Val);
	CHECK_EQ(Controls::FormatValue(ci, 2.5 * kPi / 180), std::string("2.5"));
	CHECK_NEAR(Controls::ParseValue(ci, "-3"), -3 * kPi / 180, 1e-12);
	CHECK_NEAR(Controls::ParseValue(ci, "99"), 5 * kPi / 180, 1e-12);	// clamped to max
	ControlInfo	amp = Controls::ParamInfo(WB::PARAM_RotateSpeed, Controls::COL_Amp);
	CHECK_NEAR(Controls::ParseValue(amp, "-99"), -99 * kPi / 180, 1e-12);	// amplitude isn't clamped
}

TEST(ParamFreqAndPulseWidth) {
	ControlInfo	pw = Controls::ParamInfo(WB::PARAM_Alpha, Controls::COL_PW);
	CHECK_EQ(Controls::ParseValue(pw, "1.5"), 1.0);
	CHECK_EQ(Controls::FormatValue(pw, 0.25), std::string("0.25"));
	ControlInfo	freq = Controls::ParamInfo(WB::PARAM_Alpha, Controls::COL_Freq);
	CHECK_EQ(Controls::ParseValue(freq, "-2"), 0.0);
	CHECK_EQ(Controls::FormatValue(freq, 1e-5), std::string("1e-005"));	// msvcr110 %g
}

TEST(SpinButtons) {
	ControlInfo	pw = Controls::ParamInfo(WB::PARAM_Alpha, Controls::COL_PW);
	double	v = 0.995;
	CHECK(Controls::AddSpin(pw, v, 1));
	CHECK_EQ(v, 1.0);	// clamped
	CHECK(!Controls::AddSpin(pw, v, 1));	// unchanged: no notify
	v = 0.01;
	CHECK(Controls::AddSpin(pw, v, -1));
	CHECK_EQ(v, 0.0);	// snapped to zero, not 1e-18
}

TEST(GlobalSliderIsSymmetric) {
	// Line Width: 0..50; its global runs -50..50 with the default in the middle
	ControlInfo	ci = Controls::GlobalInfo(WB::PARAM_LineWidth);
	CHECK_EQ(ci.nDefaultPos, 500);
	CHECK_EQ(ci.fEditMin, -50.0);
	CHECK_NEAR(Controls::GlobalNorm(WB::PARAM_LineWidth, 0), 500, 1e-9);
	CHECK_NEAR(Controls::GlobalDenorm(WB::PARAM_LineWidth, 1000), 50, 1e-9);
	CHECK_NEAR(Controls::GlobalDenorm(WB::PARAM_LineWidth, 0), -50, 1e-9);
}

TEST(MasterLogSliders) {
	// Speed: log base 20, scale 100: 1 -> 0, 20 -> 100, 1/20 -> -100
	CHECK_NEAR(Controls::MasterNorm(WB::MASTER_Speed, 1), 0, 1e-9);
	CHECK_NEAR(Controls::MasterNorm(WB::MASTER_Speed, 20), 100, 1e-9);
	CHECK_NEAR(Controls::MasterDenorm(WB::MASTER_Speed, -100), 0.05, 1e-12);
	// Zoom: base 10
	CHECK_NEAR(Controls::MasterDenorm(WB::MASTER_Zoom, 50), std::sqrt(10.0), 1e-12);
	// Tempo and Copies are linear
	CHECK_NEAR(Controls::MasterDenorm(WB::MASTER_Tempo, 120), 120, 1e-12);
	CHECK_NEAR(Controls::MasterNorm(WB::MASTER_Copies, 7), 7, 1e-12);
	// Canvas: position is value * 100, range 100..300
	CHECK_NEAR(Controls::MasterNorm(WB::MASTER_CanvasScale, 1.4), 140, 1e-9);
}

TEST(MasterSpecialCurves) {
	// Damping is inverted and exponential: slider 0 is no damping (1)
	CHECK_NEAR(Controls::MasterDenorm(WB::MASTER_Damping, 0), 1, 1e-12);
	CHECK_NEAR(Controls::MasterDenorm(WB::MASTER_Damping, 101), 0, 1e-12);
	double	d = WB::m_masterDefault.fDamping;
	CHECK_NEAR(Controls::MasterDenorm(WB::MASTER_Damping, Controls::MasterNorm(WB::MASTER_Damping, d)), d, 1e-12);
	// Trail and Rings are exponential
	CHECK_NEAR(Controls::MasterDenorm(WB::MASTER_Trail, 100), 1, 1e-12);
	CHECK_NEAR(Controls::MasterDenorm(WB::MASTER_Rings, 100), 1000, 1e-9);
	CHECK_NEAR(Controls::MasterNorm(WB::MASTER_Rings, 0), 0, 1e-12);
	double	r = Controls::MasterDenorm(WB::MASTER_Rings, 50);	// (30^0.5 - 1) / 29 * 1000
	CHECK_NEAR(r, (std::sqrt(30.0) - 1) / 29 * 1000, 1e-9);
	// normalized versions round-trip
	CHECK_NEAR(Controls::MasterNorm01(WB::MASTER_Speed, 1), 0.5, 1e-12);
	CHECK_NEAR(Controls::MasterDenorm01(WB::MASTER_Speed, 0.5), 1, 1e-12);
}

TEST(MasterEditBoxes) {
	// Speed and Zoom are shown as percentages
	CHECK_EQ(Controls::FormatMaster(WB::MASTER_Speed, 1), std::string("100"));
	CHECK_EQ(Controls::FormatMaster(WB::MASTER_Zoom, 0.5), std::string("50.00"));
	double	v = 0;
	CHECK(Controls::ParseMaster(WB::MASTER_Speed, "250", v));
	// the Windows table stores the edit scale as float .01f, so typing 250
	// gives 250 * 0.0099999998 there too, not exactly 2.5
	CHECK_EQ(v, 250 * double(.01f));
	CHECK(Controls::ParseMaster(WB::MASTER_Speed, "1e9", v));
	CHECK_EQ(v, 100.0);	// edit range 0..100
	// Damping is shown as 100 - value * 100
	CHECK_EQ(Controls::FormatMaster(WB::MASTER_Damping, 0.186261), std::string("81.37"));
	CHECK(Controls::ParseMaster(WB::MASTER_Damping, "75", v));
	CHECK_NEAR(v, 0.25, 1e-12);
	CHECK(Controls::ParseMaster(WB::MASTER_Damping, "100", v));
	CHECK_NEAR(v, 1e-3, 1e-15);	// clamped to the minimum
	// edit ranges from the slider range when not listed
	ControlInfo	canvas = Controls::MasterInfo(WB::MASTER_CanvasScale);
	CHECK_NEAR(canvas.fEditMin, 1, 1e-6);
	CHECK_NEAR(canvas.fEditMax, 3, 1e-6);
	CHECK_EQ(Controls::FormatMaster(WB::MASTER_CanvasScale, 1.4), std::string("140"));
	CHECK_EQ(Controls::FormatMaster(WB::MASTER_Tempo, 100), std::string("100.00"));
}

int main() { return RunAllTests(); }
