// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Tests for modulation (Mac addition, AUDIO_PLAN.md): the Modulator's
// routing and timing, and the engine's render-only offsets.

#include "RecordingRenderer.h"
#include "TestHarness.h"
#include "whorld/Controls.h"
#include "whorld/Modulation.h"
#include "whorld/Random.h"
#include "whorld/Round.h"
#include "whorld/Snapshot.h"
#include "whorld/WhorldEngine.h"

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <memory>

using namespace whorld;
namespace fs = std::filesystem;
using MB = MappingBase;

namespace {

ModRow MakeRow(int iSource, int iTarget, double fAmount, int iProp = MB::PARAM_PROP_Val)
{
	ModRow	row;
	row.iSource = iSource;
	row.iTarget = iTarget;
	row.iProp = iProp;
	row.fAmount = fAmount;
	row.fAttack = 0;
	row.fRelease = 0;
	return row;
}

std::unique_ptr<WhorldEngine> MakeEngine(float w = 800, float h = 600)
{
	whorld::srand(1);
	auto	p = std::make_unique<WhorldEngine>();
	p->OnResize(SizeF{w, h});
	return p;
}

// the default patch with every oscillator still, so values are exact
Patch StillPatch()
{
	Patch	p;
	p.SetDefaults();
	for (int i = 0; i < Patch::PARAM_COUNT; i++)
		p.GetParamRow(i).fAmp = 0;
	return p;
}

void RunFrames(WhorldEngine& eng, int nFrames, RecordingRenderer* pRec = nullptr)
{
	RecordingRenderer	scratch;
	for (int i = 0; i < nFrames; i++) {
		RecordingRenderer&	r = pRec ? *pRec : scratch;
		eng.Draw(r);
	}
}

bool SameCalls(const RecordingRenderer& a, const RecordingRenderer& b)
{
	if (a.calls.size() != b.calls.size())
		return false;
	for (size_t i = 0; i < a.calls.size(); i++) {
		const RecordedCall&	ca = a.calls[i];
		const RecordedCall&	cb = b.calls[i];
		if (ca.type != cb.type || ca.fWidth != cb.fWidth || ca.bFlag != cb.bFlag
		|| ca.clr.r != cb.clr.r || ca.clr.g != cb.clr.g || ca.clr.b != cb.clr.b || ca.clr.a != cb.clr.a
		|| ca.fig.pts.size() != cb.fig.pts.size())
			return false;
		for (size_t j = 0; j < ca.fig.pts.size(); j++) {
			if (ca.fig.pts[j].x != cb.fig.pts[j].x || ca.fig.pts[j].y != cb.fig.pts[j].y)
				return false;
		}
	}
	return true;
}

double ValRange(int iParam)
{
	const auto&	info = WhorldBase::GetParamInfo(iParam);
	return info.fMaxVal - info.fMinVal;
}

} // namespace

// Modulator

TEST(TagsRoundTrip) {
	for (int i = 0; i < ModSources::SOURCES; i++)
		CHECK_EQ(ModSources::FindTag(ModSources::GetTag(i)), i);
	for (int i = 0; i < ModActions::ACTIONS; i++)
		CHECK_EQ(ModActions::FindTag(ModActions::GetTag(i)), i);
	CHECK_EQ(ModSources::FindTag("NoSuchSource"), -1);
	CHECK(ModSources::IsTrigger(ModSources::SRC_Kick));
	CHECK(!ModSources::IsTrigger(ModSources::SRC_Bass));
	CHECK(ModActions::ACTIONS <= 32);	// they're bits in ModOutput::nActions
}

TEST(ModulatableTargets) {
	CHECK(ModRow::IsModulatable(MB::TARGET_RingSpacing, MB::PARAM_PROP_Val));
	CHECK(ModRow::IsModulatable(MB::TARGET_Pinwheel, MB::PARAM_PROP_Global));
	CHECK(!ModRow::IsModulatable(MB::TARGET_RingGrowth, MB::PARAM_PROP_Global));	// not a global
	CHECK(!ModRow::IsModulatable(MB::TARGET_RingSpacing, MB::PARAM_PROP_Amp));
	CHECK(ModRow::IsModulatable(MB::TARGET_Zoom, 0));
	CHECK(ModRow::IsModulatable(MB::TARGET_Hue, 0));
	CHECK(ModRow::IsModulatable(MB::TARGET_OriginY, 0));
	CHECK(!ModRow::IsModulatable(MB::TARGET_Fill, 0));
}

TEST(AttackAndReleaseAreTimeConstants) {
	Modulator	m;
	ModRow	row = MakeRow(ModSources::SRC_Level, MB::TARGET_RingSpacing, 1);
	row.fAttack = 0.1;
	row.fRelease = 0.2;
	m.SetRows({row});
	ModSources	src;
	ModOutput	out;
	src.aValue[ModSources::SRC_Level] = 1;
	m.Step(src, 0.1, out);	// one attack time: 63% of the way
	double	fUp = 1 - std::exp(-1.0);
	CHECK_NEAR(out.aParam[MB::TARGET_RingSpacing], fUp, 1e-12);
	CHECK(out.bActive);
	src.aValue[ModSources::SRC_Level] = 0;
	m.Step(src, 0.2, out);	// one release time: 37% left
	CHECK_NEAR(out.aParam[MB::TARGET_RingSpacing], fUp * std::exp(-1.0), 1e-12);
}

TEST(SmoothingIsFrameRateIndependent) {
	ModRow	row = MakeRow(ModSources::SRC_Bass, MB::TARGET_LineWidth, 1);
	row.fAttack = 0.05;
	Modulator	a, b;
	a.SetRows({row});
	b.SetRows({row});
	ModSources	src;
	src.aValue[ModSources::SRC_Bass] = 0.8;
	ModOutput	oa, ob;
	a.Step(src, 0.1, oa);
	for (int i = 0; i < 12; i++)	// 120 Hz for the same 0.1 s
		b.Step(src, 0.1 / 12, ob);
	CHECK_NEAR(oa.aParam[MB::TARGET_LineWidth], ob.aParam[MB::TARGET_LineWidth], 1e-12);
}

TEST(CurvesPolarityDepthAndSums) {
	ModSources	src;
	src.aValue[ModSources::SRC_Level] = 0.25;
	ModOutput	out;
	Modulator	m;
	ModRow	soft = MakeRow(ModSources::SRC_Level, MB::TARGET_RingSpacing, 1);
	soft.nCurve = ModRow::CURVE_Soft;
	ModRow	hard = MakeRow(ModSources::SRC_Level, MB::TARGET_LineWidth, 1);
	hard.nCurve = ModRow::CURVE_Hard;
	ModRow	gate = MakeRow(ModSources::SRC_Level, MB::TARGET_PolySides, 1);
	gate.nCurve = ModRow::CURVE_Gate;
	gate.fThreshold = 0.2;
	ModRow	centered = MakeRow(ModSources::SRC_Level, MB::TARGET_StarFactor, 0.5);
	centered.bCentered = true;
	ModRow	twice = MakeRow(ModSources::SRC_Level, MB::TARGET_StarFactor, 0.5);	// adds to the row above
	ModRow	global = MakeRow(ModSources::SRC_Level, MB::TARGET_Pinwheel, -1, MB::PARAM_PROP_Global);
	ModRow	master = MakeRow(ModSources::SRC_Level, MB::TARGET_Speed, 1);
	ModRow	hue = MakeRow(ModSources::SRC_Level, MB::TARGET_Hue, 1);
	ModRow	orgX = MakeRow(ModSources::SRC_Level, MB::TARGET_OriginX, 0.4);
	m.SetRows({soft, hard, gate, centered, twice, global, master, hue, orgX});
	m.Step(src, 1.0 / 60, out);
	CHECK_NEAR(out.aParam[MB::TARGET_RingSpacing], 0.5, 1e-12);
	CHECK_NEAR(out.aParam[MB::TARGET_LineWidth], 0.0625, 1e-12);
	CHECK_NEAR(out.aParam[MB::TARGET_PolySides], 1, 1e-12);
	CHECK_NEAR(out.aParam[MB::TARGET_StarFactor], (0.25 - 0.5) * 0.5 + 0.25 * 0.5, 1e-12);
	CHECK_NEAR(out.aGlobal[MB::TARGET_Pinwheel], -0.25, 1e-12);
	CHECK_EQ(out.aParam[MB::TARGET_Pinwheel], 0.0);	// the Global column, not Val
	CHECK_NEAR(out.aMaster[Patch::MASTER_Speed], 0.25, 1e-12);
	CHECK_NEAR(out.fHue, 0.25, 1e-12);
	CHECK_NEAR(out.fOriginX, 0.1, 1e-12);
	m.SetDepth(0.5);
	m.Step(src, 1.0 / 60, out);
	CHECK_NEAR(out.aParam[MB::TARGET_RingSpacing], 0.25, 1e-12);
	m.SetBypass(true);
	m.Step(src, 1.0 / 60, out);
	CHECK(!out.bActive);
	CHECK_EQ(out.aParam[MB::TARGET_RingSpacing], 0.0);
}

TEST(OffRowsAndOtherTargetsDoNothing) {
	ModSources	src;
	src.aValue[ModSources::SRC_Level] = 1;
	ModRow	off = MakeRow(ModSources::SRC_Level, MB::TARGET_RingSpacing, 1);
	off.bOn = false;
	ModRow	amp = MakeRow(ModSources::SRC_Level, MB::TARGET_RingSpacing, 1, MB::PARAM_PROP_Amp);
	ModRow	fill = MakeRow(ModSources::SRC_Level, MB::TARGET_Fill, 1);
	Modulator	m;
	m.SetRows({off, amp, fill});
	ModOutput	out;
	m.Step(src, 1.0 / 60, out);
	CHECK(!out.bActive);
	CHECK_EQ(out.aParam[MB::TARGET_RingSpacing], 0.0);
}

TEST(TriggersPulseAndDecay) {
	ModRow	row = MakeRow(ModSources::SRC_Kick, MB::TARGET_LineWidth, 0.5);
	row.fRelease = 0.1;
	Modulator	m;
	m.SetRows({row});
	ModSources	src;
	src.aCount[ModSources::SRC_Kick] = 7;	// hits before the row existed don't fire
	ModOutput	out;
	m.Step(src, 1.0 / 60, out);
	CHECK_EQ(out.aParam[MB::TARGET_LineWidth], 0.0);
	src.aCount[ModSources::SRC_Kick] = 9;	// two hits in one frame: one pulse
	m.Step(src, 1.0 / 60, out);
	CHECK_NEAR(out.aParam[MB::TARGET_LineWidth], 0.5, 1e-12);
	m.Step(src, 0.1, out);	// decays over the release
	CHECK_NEAR(out.aParam[MB::TARGET_LineWidth], 0.5 * std::exp(-1.0), 1e-12);
	CHECK_NEAR(m.GetRowLevel(0), std::exp(-1.0), 1e-12);
}

TEST(ActionsFireOnceAndRearm) {
	ModRow	kick;
	kick.iSource = ModSources::SRC_Kick;
	kick.iAction = ModActions::ACT_NextPatch;
	ModRow	loud;
	loud.iSource = ModSources::SRC_Level;
	loud.iAction = ModActions::ACT_RandomPhase;
	loud.fAttack = 0;
	loud.fRelease = 0;
	loud.fThreshold = 0.5;
	Modulator	m;
	m.SetRows({kick, loud});
	ModSources	src;
	ModOutput	out;
	m.Step(src, 1.0 / 60, out);	// primes the trigger count
	CHECK_EQ(out.nActions, 0u);
	CHECK(!out.bActive);	// actions don't move controls
	src.aCount[ModSources::SRC_Kick] = 1;
	src.aValue[ModSources::SRC_Level] = 0.9;
	m.Step(src, 1.0 / 60, out);
	CHECK_EQ(out.nActions, (1u << ModActions::ACT_NextPatch) | (1u << ModActions::ACT_RandomPhase));
	m.Step(src, 1.0 / 60, out);	// still loud, no new hit: nothing
	CHECK_EQ(out.nActions, 0u);
	src.aValue[ModSources::SRC_Level] = 0.1;	// re-arms below the threshold
	m.Step(src, 1.0 / 60, out);
	src.aValue[ModSources::SRC_Level] = 0.9;
	m.Step(src, 1.0 / 60, out);
	CHECK_EQ(out.nActions, 1u << ModActions::ACT_RandomPhase);
	m.SetBypass(true);	// bypass fires nothing
	src.aCount[ModSources::SRC_Kick] = 2;
	m.Step(src, 1.0 / 60, out);
	CHECK_EQ(out.nActions, 0u);
}

// Engine

TEST(ZeroModulationIsBitIdentical) {
	// active modulation with every offset zero draws exactly what no
	// modulation draws, for the sample patches (oscillators, copies, mirror...)
	fs::path	dir = fs::path(WHORLD_TESTDATA_DIR) / "patches";
	std::vector<Patch>	aPatch;
	aPatch.push_back(StillPatch());
	if (fs::exists(dir)) {
		for (const auto& entry : fs::directory_iterator(dir)) {
			Patch	p;
			if (entry.path().extension() == ".whp" && p.Read(entry.path().string()))
				aPatch.push_back(p);
			if (aPatch.size() >= 25)
				break;
		}
	}
	ModOutput	zero;
	zero.bActive = true;
	int	nSame = 0;
	for (const Patch& p : aPatch) {
		auto	a = MakeEngine();
		auto	b = MakeEngine();
		a->OnSetPatch(p);
		b->OnSetPatch(p);
		RecordingRenderer	ra, rb;
		for (int i = 0; i < 90; i++) {
			b->SetModulation(zero);
			a->Draw(ra);
			b->Draw(rb);
		}
		nSame += SameCalls(ra, rb);
	}
	CHECK_EQ(nSame, static_cast<int>(aPatch.size()));
	std::printf("  %zu patches\n", aPatch.size());
}

TEST(ParamOffsetIsRenderOnly) {
	auto	eng = MakeEngine();
	Patch	p = StillPatch();
	eng->OnSetPatch(p);
	const int	RS = Patch::PARAM_RingSpacing;
	double	fBase = p.GetParamRow(RS).fVal;
	ModOutput	mod;
	mod.bActive = true;
	mod.aParam[RS] = 0.1;
	eng->SetModulation(mod);
	RunFrames(*eng, 2);
	CHECK_NEAR(eng->GetParamValues().a[RS], fBase + 0.1 * ValRange(RS), 1e-9);
	CHECK_EQ(eng->GetPatch().GetParamRow(RS).fVal, fBase);	// the patch is untouched
	Patch	out;
	eng->OnGetPatch(out);
	CHECK_EQ(out.GetParamRow(RS).fVal, fBase);
	eng->SetModulation(ModOutput());	// off: back to the patch's value exactly
	RunFrames(*eng, 2);
	CHECK_EQ(eng->GetParamValues().a[RS], fBase);
}

TEST(OffsetsStopAtTheSliderEnds) {
	auto	eng = MakeEngine();
	Patch	p = StillPatch();
	const int	LW = Patch::PARAM_LineWidth;
	const auto&	info = WhorldBase::GetParamInfo(LW);
	ModOutput	mod;
	mod.bActive = true;
	mod.aParam[LW] = 1;	// a whole slider up, from the middle
	p.GetParamRow(LW).fVal = (info.fMinVal + info.fMaxVal) / 2;
	eng->OnSetPatch(p);
	eng->SetModulation(mod);
	RunFrames(*eng, 1);
	CHECK_NEAR(eng->GetParamValues().a[LW], info.fMaxVal, 1e-9);
	// a patch value beyond the slider (typed in) isn't pulled back by an
	// offset in the same direction
	p.GetParamRow(LW).fVal = info.fMaxVal * 2;
	eng->OnSetPatch(p);
	RunFrames(*eng, 1);
	CHECK_NEAR(eng->GetParamValues().a[LW], info.fMaxVal * 2, 1e-9);
	mod.aParam[LW] = -3;	// down (rows can add up past a slider) stops at the bottom
	eng->SetModulation(mod);
	RunFrames(*eng, 1);
	CHECK_NEAR(eng->GetParamValues().a[LW], info.fMinVal, 1e-9);
}

TEST(GlobalOffsetIsAddedToTheDampedGlobal) {
	auto	eng = MakeEngine();
	eng->OnSetPatch(StillPatch());
	const int	PW = Patch::PARAM_Pinwheel;
	ModOutput	mod;
	mod.bActive = true;
	mod.aGlobal[PW] = 0.25;	// a quarter of -max to max
	eng->SetModulation(mod);
	RunFrames(*eng, 1);
	auto	snap = eng->OnCaptureSnapshot();
	CHECK_NEAR(snap->m_globRing.fPinwheel, 0.25 * 2 * WhorldBase::GetParamInfo(PW).fMaxVal, 1e-9);
	CHECK_EQ(eng->GetPatch().GetParamRow(PW).fGlobal, 0.0);
}

TEST(MasterOffsetsFollowTheSlider) {
	auto	eng = MakeEngine();
	Patch	p = StillPatch();
	eng->OnSetPatch(p);
	ModOutput	mod;
	mod.bActive = true;
	mod.aMaster[Patch::MASTER_Speed] = 0.1;
	mod.aMaster[Patch::MASTER_Damping] = -0.2;	// a logarithmic slider
	eng->SetModulation(mod);
	RunFrames(*eng, 1);
	double	fSpeed = Controls::MasterDenorm01(Patch::MASTER_Speed,
		Controls::MasterNorm01(Patch::MASTER_Speed, p.m_master.fSpeed) + 0.1);
	double	fDamping = Controls::MasterDenorm01(Patch::MASTER_Damping,
		Controls::MasterNorm01(Patch::MASTER_Damping, p.m_master.fDamping) - 0.2);
	CHECK_NEAR(eng->GetEffectiveMaster().fSpeed, fSpeed, 1e-9);
	CHECK_NEAR(eng->GetEffectiveMaster().fDamping, fDamping, 1e-9);
	CHECK_EQ(eng->GetPatch().m_master.fSpeed, p.m_master.fSpeed);
	// Speed scales ring growth, as the slider would
	const int	RG = Patch::PARAM_RingGrowth;
	CHECK_NEAR(eng->GetParamValues().a[RG], p.GetParamRow(RG).fVal * fSpeed, 1e-9);
	eng->SetModulation(ModOutput());
	RunFrames(*eng, 1);
	CHECK_EQ(eng->GetEffectiveMaster().fSpeed, p.m_master.fSpeed);
}

TEST(CopiesFollowTheirOffsetAndReturn) {
	// Copies take effect through their change handler; the offset turns
	// copying on (more distinct ring origins), and ending it turns it off
	Patch	p = StillPatch();
	p.m_master.fCopies = 1;
	p.m_master.fSpread = 100;
	auto	plain = MakeEngine();
	auto	eng = MakeEngine();
	plain->OnSetPatch(p);
	eng->OnSetPatch(p);
	ModOutput	mod;
	mod.bActive = true;
	mod.aMaster[Patch::MASTER_Copies] = 0.5;
	eng->SetModulation(mod);
	RunFrames(*plain, 60);
	RunFrames(*eng, 60);
	CHECK(Round(eng->GetEffectiveMaster().fCopies) > 1);
	auto	shifted = [](const WhorldEngine& e) {
		int	n = 0;
		for (const auto& ring : e.GetRings())
			n += ring.ptShift.x != 0 || ring.ptShift.y != 0;
		return n;
	};
	CHECK_EQ(shifted(*plain), 0);
	CHECK(shifted(*eng) > 0);
	eng->SetModulation(ModOutput());
	RunFrames(*eng, 1);
	CHECK_EQ(eng->GetEffectiveMaster().fCopies, 1.0);
}

TEST(HueZoomAndOriginOffsets) {
	auto	plain = MakeEngine();
	auto	eng = MakeEngine();
	Patch	p = StillPatch();
	plain->OnSetPatch(p);
	eng->OnSetPatch(p);
	ModOutput	mod;
	mod.bActive = true;
	mod.fHue = 0.25;	// 90 degrees
	mod.fOriginX = 0.1;	// a tenth of the view to the right
	mod.aMaster[Patch::MASTER_Zoom] = 0.1;
	eng->SetModulation(mod);
	RunFrames(*plain, 200);
	RunFrames(*eng, 200);
	double	fHueA = plain->GetRings().front().fHue;
	double	fHueB = eng->GetRings().front().fHue;
	CHECK_NEAR(std::fmod(fHueB - fHueA + 360, 360), 90, 1e-6);
	CHECK_NEAR(eng->GetOrigin().x, 0.6, 1e-3);	// damped toward its target
	CHECK_NEAR(eng->GetOrigin().y, 0.5, 1e-9);
	double	fZoom = eng->GetEffectiveMaster().fZoom;
	CHECK(fZoom > p.m_master.fZoom);
	CHECK_NEAR(eng->GetZoom(), fZoom, 1e-3);
	CHECK_EQ(eng->GetPatch().m_master.fZoom, p.m_master.fZoom);
	CHECK_EQ(eng->GetPatch().m_main.dptOrigin.x, p.m_main.dptOrigin.x);
}

int main() { return RunAllTests(); }
