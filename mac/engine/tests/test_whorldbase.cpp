// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Tests for WhorldBase: the tables generated from WhorldDef.h.

#include "TestHarness.h"
#include "whorld/FormatIO.h"
#include "whorld/WhorldBase.h"

#include <cmath>
#include <cstddef>
#include <string>

using namespace whorld;

// Expose protected rendering types for layout checks.
struct BaseProbe : WhorldBase {
	using WhorldBase::RING;
	using WhorldBase::GLOB_RING;
	using WhorldBase::DRAW_STATE;
	static const GLOB_RING& GlobDefault() { return m_globalRingDefault; }
};

TEST(Counts) {
	CHECK_EQ(int(WhorldBase::PARAM_COUNT), 22);
	CHECK_EQ(int(WhorldBase::PARAM_PROP_COUNT), 6);
	CHECK_EQ(int(WhorldBase::MASTER_COUNT), 11);	// Windows' 10, plus Fade (Mac port)
	CHECK_EQ(int(WhorldBase::MAIN_COUNT), 11);
	CHECK_EQ(int(WhorldBase::GLOBAL_COUNT), 12);
	CHECK_EQ(int(WhorldBase::WAVEFORM_COUNT), 8);
}

TEST(ParamInfo) {
	const auto&	ring = WhorldBase::GetParamInfo(WhorldBase::PARAM_RingGrowth);
	CHECK_EQ(std::string(ring.pszTag), std::string("RingGrowth"));
	CHECK_EQ(std::string(ring.pszName), std::string("Ring Growth"));
	CHECK_EQ(ring.nSteps, 1000);
	CHECK_EQ(ring.fMaxVal, 10.0);
	const auto&	rot = WhorldBase::GetParamInfo(WhorldBase::PARAM_RotateSpeed);
	CHECK_NEAR(rot.fMinVal, -5 * kPi / 180, 1e-15);
	CHECK_NEAR(rot.fMaxVal, 5 * kPi / 180, 1e-15);
	CHECK_NEAR(rot.fScale, kPi / 180, 1e-15);
	const auto&	skew = WhorldBase::GetParamInfo(WhorldBase::PARAM_SkewAngle);
	CHECK_EQ(skew.fMinVal, -kPi);
	CHECK_EQ(WhorldBase::GetParamName(WhorldBase::PARAM_PolySides), std::string("Ring Sides"));
	CHECK_EQ(WhorldBase::GetParamInfo(WhorldBase::PARAM_PolySides).nSteps, 48);
}

TEST(ParamDefaults) {
	CHECK_EQ(WhorldBase::m_paramDefault.fRingGrowth, 1.0);
	CHECK_EQ(WhorldBase::m_paramDefault.fRingSpacing, 5.0);
	CHECK_EQ(WhorldBase::m_paramDefault.fPolySides, 5.0);
	CHECK_EQ(WhorldBase::m_paramDefault.fColorSpeed, 0.5);
	CHECK_EQ(WhorldBase::m_paramDefault.fOddShear, 0.0);
	// named members overlay the array
	CHECK_EQ(WhorldBase::m_paramDefault.a[WhorldBase::PARAM_Lightness], 0.5);
	CHECK_EQ(WhorldBase::GetParamDefault(WhorldBase::PARAM_Saturation), 1.0);
}

TEST(SetParamDefaults) {
	WhorldBase::PARAM_TABLE	t;
	WhorldBase::SetParamDefaults(t);
	for (int i = 0; i < WhorldBase::PARAM_COUNT; i++) {
		const auto&	row = t.row[i];
		CHECK_EQ(row.fVal, WhorldBase::GetParamDefault(i));
		CHECK_EQ(row.iWave, 0);
		CHECK_EQ(row.fAmp, 0.0);
		CHECK_EQ(row.fFreq, 0.0);
		CHECK_EQ(row.fPW, 0.5);
		CHECK_EQ(row.fGlobal, 0.0);
	}
	CHECK_EQ(alignof(WhorldBase::PARAM_TABLE), size_t(16));
}

TEST(MasterAndMainDefaults) {
	const auto&	m = WhorldBase::m_masterDefault;
	CHECK_EQ(m.fSpeed, 1.0);
	CHECK_EQ(m.fDamping, 0.186261);
	CHECK_EQ(m.fRings, 1000.0);
	CHECK_EQ(m.fCanvasScale, 1.4);
	CHECK_EQ(m.a[WhorldBase::MASTER_Spread], 100.0);
	const auto&	d = WhorldBase::m_mainDefault;
	CHECK(d.dptOrigin == DPoint(0.5, 0.5));
	CHECK_EQ(d.nDrawMode, 0u);
	CHECK_EQ(d.bMirror, false);
	CHECK_EQ(d.bAntialiasing, true);
	CHECK_EQ(WhorldBase::GetMasterName(WhorldBase::MASTER_CanvasScale), std::string("Canvas"));
}

TEST(MainInfoOffsetsAndTypes) {
	using MP = WhorldBase::MAIN_PROPS;
	const auto&	org = WhorldBase::GetMainInfo(WhorldBase::MAIN_Origin);
	CHECK_EQ(org.nFIOType, int(FIO_DPOINT));
	CHECK_EQ(org.nOffset, int(offsetof(MP, dptOrigin)));
	CHECK_EQ(WhorldBase::GetMainInfo(WhorldBase::MAIN_DrawMode).nFIOType, int(FIO_UINT));
	CHECK_EQ(WhorldBase::GetMainInfo(WhorldBase::MAIN_OrgMotion).nFIOType, int(FIO_INT));
	CHECK_EQ(WhorldBase::GetMainInfo(WhorldBase::MAIN_Hue).nFIOType, int(FIO_DOUBLE));
	CHECK_EQ(WhorldBase::GetMainInfo(WhorldBase::MAIN_Antialiasing).nFIOType, int(FIO_BYTE));
	CHECK_EQ(WhorldBase::GetMainInfo(WhorldBase::MAIN_Antialiasing).nOffset,
		int(offsetof(MP, bAntialiasing)));
	CHECK_EQ(WhorldBase::GetMainName(WhorldBase::MAIN_OrgMotion), std::string("Origin Motion"));
}

TEST(FindByTag) {
	CHECK_EQ(WhorldBase::FindParamByTag("OddShear"), int(WhorldBase::PARAM_OddShear));
	CHECK_EQ(WhorldBase::FindParamByTag("NoSuchParam"), -1);
	CHECK_EQ(WhorldBase::FindParamPropByTag("PW"), int(WhorldBase::PARAM_PROP_PW));
	CHECK_EQ(WhorldBase::FindParamPropByTag("Global"), int(WhorldBase::PARAM_PROP_Global));
	CHECK_EQ(WhorldBase::FindMasterByTag("Tempo"), int(WhorldBase::MASTER_Tempo));
	CHECK_EQ(WhorldBase::FindMainByTag("ZoomCenter"), int(WhorldBase::MAIN_ZoomCenter));
	CHECK_EQ(WhorldBase::FindMainByTag("zoomcenter"), -1);	// case-sensitive
}

TEST(GlobalMapping) {
	CHECK_EQ(WhorldBase::MapGlobalToParam(WhorldBase::GLOBAL_LineWidth), int(WhorldBase::PARAM_LineWidth));
	CHECK_EQ(WhorldBase::MapGlobalToParam(WhorldBase::GLOBAL_OddShear), int(WhorldBase::PARAM_OddShear));
	CHECK_EQ(WhorldBase::MapParamToGlobal(WhorldBase::PARAM_RingGrowth), -1);
	CHECK_EQ(WhorldBase::MapParamToGlobal(WhorldBase::PARAM_ColorSpeed), -1);
	CHECK_EQ(WhorldBase::MapParamToGlobal(WhorldBase::PARAM_SkewAngle), int(WhorldBase::GLOBAL_SkewAngle));
	for (int g = 0; g < WhorldBase::GLOBAL_COUNT; g++)
		CHECK_EQ(WhorldBase::MapParamToGlobal(WhorldBase::MapGlobalToParam(g)), g);
}

TEST(RenderCommands) {
	CHECK_EQ(int(WhorldBase::RC_SET_PARAM_FIRST), 2);
	CHECK_EQ(int(WhorldBase::RC_SET_PARAM_Val), 2);
	CHECK_EQ(int(WhorldBase::RC_SET_PARAM_LAST), int(WhorldBase::RC_SET_PARAM_Global));
	CHECK_EQ(int(WhorldBase::RC_SET_MASTER), 8);
	CHECK_EQ(int(WhorldBase::RENDER_COMMANDS), 35);
	CHECK_EQ(std::string(WhorldBase::GetRenderCmdName(0)), std::string("RESIZE"));
	CHECK_EQ(std::string(WhorldBase::GetRenderCmdName(WhorldBase::RC_SET_PARAM_PW)), std::string("SET_PARAM_PW"));
	CHECK_EQ(std::string(WhorldBase::GetRenderCmdName(WhorldBase::RC_SET_MASTER)), std::string("SET_MASTER"));
	CHECK_EQ(std::string(WhorldBase::GetRenderCmdName(WhorldBase::RC_MOVIE_EXPORT)), std::string("MOVIE_EXPORT"));
	WhorldBase::RenderCmd	cmd(WhorldBase::RC_SET_ZOOM, 1);
	CHECK_EQ(cmd.m_prop.llVal, int64_t(0));
	double	z = 1.5;
	WhorldBase::RenderCmd	cz(WhorldBase::RC_SET_ZOOM, 1, z);
	CHECK_EQ(cz.m_prop.dblVal, 1.5);
}

TEST(WaveformNames) {
	CHECK_EQ(WhorldBase::GetWaveformName(WhorldBase::WAVEFORM_TRIANGLE), std::string("Triangle"));
	CHECK_EQ(WhorldBase::GetWaveformName(WhorldBase::WAVEFORM_RANDOM_RAMP), std::string("Rand Ramp"));
}

TEST(GlobalRingDefault) {
	const auto&	g = BaseProbe::GlobDefault();
	CHECK_EQ(g.fRot, 0.0);
	CHECK_EQ(g.fStarRatio, 1.0);
	CHECK_EQ(g.ptScale.x, 1.0);
	CHECK_EQ(g.ptScale.y, 1.0);
	CHECK_EQ(g.ptShift.x, 0.0);
	CHECK_EQ(g.fEvenShear, 1.0);
	CHECK_EQ(g.fOddShear, 1.0);
	CHECK_EQ(g.nPolySides, 0);
}

int main() { return RunAllTests(); }
