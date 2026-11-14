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

// Beat-based rows and offsets

namespace {

// steps a modulator through a steady beat at fBpm from position fStart, in
// steps of dt, and returns the positions (unshifted) at which the row fired
std::vector<double> FirePositions(Modulator& m, double fBpm, double fStart, double fEnd, double dt = 1.0 / 120)
{
	ModSources	src;
	src.bBeat = true;
	src.fTempo = fBpm;
	std::vector<double>	fired;
	ModOutput	out;
	for (double pos = fStart; pos < fEnd; pos += dt * fBpm / 60) {
		src.fBeatPos = pos;
		m.Step(src, dt, out);
		if (m.GetRowLevel(0) > 0.999)	// a pulse starts at 1
			fired.push_back(pos);
	}
	return fired;
}

ModRow BeatRow(int iSource, double fOffset)
{
	ModRow	row = MakeRow(iSource, MB::TARGET_Zoom, 0.1);
	row.fOffset = fOffset;
	row.fRelease = 0.05;
	return row;
}

} // namespace

TEST(BeatRowsFireOnTheBeat) {
	Modulator	m;
	m.SetRows({BeatRow(ModSources::SRC_Beat, 0)});
	std::vector<double>	f = FirePositions(m, 120, 0.5, 8.5);
	CHECK_EQ(f.size(), size_t(8));	// beats 1 to 8
	for (double pos : f)
		CHECK(pos - std::floor(pos) < 1.0 / 60 * 2 + 1e-9);	// within a frame after the beat
}

TEST(OffsetsFireEarlyOrLate) {
	// at 120 BPM, 100 ms is 0.2 beat: -100 ms fires 0.2 beat before each
	// beat, +100 ms 0.2 beat after
	for (double fOffset : {-0.1, 0.1}) {
		Modulator	m;
		m.SetRows({BeatRow(ModSources::SRC_Beat, fOffset)});
		std::vector<double>	f = FirePositions(m, 120, 0.5, 8.5, 1.0 / 1000);
		CHECK(f.size() >= 7);
		for (double pos : f) {
			double	fRel = pos - std::round(pos);	// beats from the nearest beat
			CHECK_NEAR(fRel, fOffset * 2, 0.005);
		}
	}
}

TEST(BarRowsFireOnTheirSpans) {
	Modulator	m;
	m.SetRows({BeatRow(ModSources::SRC_Bar, 0)});
	std::vector<double>	f = FirePositions(m, 124, 0.5, 40.5);
	CHECK_EQ(f.size(), size_t(10));	// beats 4, 8 ... 40
	for (double pos : f)
		CHECK_NEAR(std::fmod(pos, 4), 0, 0.05);
	Modulator	m8;
	m8.SetRows({BeatRow(ModSources::SRC_Bar8, -0.2)});	// a phrase change 200 ms early
	f = FirePositions(m8, 124, 0.5, 100);
	CHECK_EQ(f.size(), size_t(3));	// before beats 32, 64, 96
	for (double pos : f)
		CHECK_NEAR(std::fmod(pos + 0.2 * 124 / 60, 32), 0, 0.05);
}

TEST(DownbeatJumpsFireOrWait) {
	// Mark Downbeat a little late: the position jumps back to just past 0
	// and Bar fires at once; a little early: it jumps to just below 0 and
	// fires when 0 comes
	Modulator	m;
	m.SetRows({BeatRow(ModSources::SRC_Bar, 0)});
	ModSources	src;
	src.bBeat = true;
	src.fTempo = 120;
	ModOutput	out;
	src.fBeatPos = 17.5;
	m.Step(src, 1.0 / 60, out);
	src.fBeatPos = 0.2;	// late mark
	m.Step(src, 1.0 / 60, out);
	CHECK_NEAR(m.GetRowLevel(0), 1, 1e-9);
	src.fBeatPos = 2.6;
	m.Step(src, 1.0, out);	// (let the pulse fade)
	src.fBeatPos = -0.3;	// early mark: nothing yet
	m.Step(src, 1.0 / 60, out);
	CHECK(m.GetRowLevel(0) < 0.5);
	src.fBeatPos = 0.01;	// the one
	m.Step(src, 1.0 / 60, out);
	CHECK_NEAR(m.GetRowLevel(0), 1, 1e-9);
	src.bBeat = false;	// no beat: nothing
	src.fBeatPos = 4.01;
	m.Step(src, 1.0, out);
	CHECK(m.GetRowLevel(0) < 0.5);
}

TEST(HitOffsetsOnlyDelay) {
	// +150 ms holds a kick's pulse back 150 ms; -150 ms can't advance it
	for (double fOffset : {0.15, -0.15}) {
		Modulator	m;
		m.SetRows({BeatRow(ModSources::SRC_Kick, fOffset)});
		ModSources	src;
		ModOutput	out;
		m.Step(src, 0.01, out);	// primes the count
		src.aCount[ModSources::SRC_Kick] = 1;
		double	fAt = -1;
		for (int i = 1; i <= 40 && fAt < 0; i++) {
			m.Step(src, 0.01, out);
			if (m.GetRowLevel(0) > 0.999)
				fAt = i * 0.01;
		}
		CHECK_NEAR(fAt, fOffset > 0 ? 0.01 + fOffset : 0.01, 0.011);
	}
}

TEST(TempoFollowsTheBeat) {
	// with Tempo following, the output carries the beat's tempo, and the
	// engine's effective Tempo takes it (render-only); without, nothing
	Modulator	m;
	m.SetRows({});
	ModSources	src;
	src.bBeat = true;
	src.fTempo = 124;
	src.fBeatPos = 3.2;
	ModOutput	out;
	m.Step(src, 1.0 / 60, out);
	CHECK_EQ(out.fTempo, 0.0);
	m.SetFollowTempo(true);
	m.Step(src, 1.0 / 60, out);
	CHECK_EQ(out.fTempo, 124.0);
	src.bBeat = false;	// no beat: the patch's tempo
	m.Step(src, 1.0 / 60, out);
	CHECK_EQ(out.fTempo, 0.0);
	auto	eng = MakeEngine();
	Patch	p = StillPatch();
	eng->OnSetPatch(p);
	ModOutput	mod;
	mod.fTempo = 124;
	eng->SetModulation(mod);
	RunFrames(*eng, 1);
	CHECK_EQ(eng->GetEffectiveMaster().fTempo, 124.0);
	CHECK_EQ(eng->GetPatch().m_master.fTempo, p.m_master.fTempo);
	eng->SetModulation(ModOutput());
	RunFrames(*eng, 1);
	CHECK_EQ(eng->GetEffectiveMaster().fTempo, p.m_master.fTempo);
}

TEST(SyncsFollowTheBeatAndCarryOn) {
	// a locked oscillator runs at the beat's rate, at the beat's place in its
	// cycle (shifted by the phase and offset); without the beat it carries
	// on at the last tempo; never locked or off: the patch's own
	Modulator	m;
	m.SetRows({});
	ModSync	sync;
	sync.iParam = MB::PARAM_LineWidth;
	sync.fBeats = 4;	// a bar
	sync.fPhase = 0.25;
	m.SetSyncs({sync});
	ModSources	src;
	ModOutput	out;
	m.Step(src, 1.0 / 60, out);	// no beat yet
	CHECK_EQ(out.aOscFreq[MB::PARAM_LineWidth], 0.0);
	src.bBeat = true;
	src.fTempo = 120;
	src.fBeatPos = 5;	// a quarter into the second bar
	m.Step(src, 1.0 / 60, out);
	CHECK_NEAR(out.aOscFreq[MB::PARAM_LineWidth], 0.5, 1e-12);	// 2 beats a second, 4 a cycle
	CHECK_NEAR(out.aOscCycle[MB::PARAM_LineWidth], 1.5, 1e-12);	// 0.25 + 0.25
	src.bBeat = false;	// the beat goes: half a second on at 120, 1/4 cycle
	m.Step(src, 0.5, out);
	CHECK_NEAR(out.aOscCycle[MB::PARAM_LineWidth], 1.75, 1e-12);
	CHECK_NEAR(out.aOscFreq[MB::PARAM_LineWidth], 0.5, 1e-12);
	src.bBeat = true;	// an offset of 100 ms late is 0.2 beat at 120
	src.fBeatPos = 0;
	sync.fOffset = 0.1;
	sync.fPhase = 0;
	m.SetSyncs({sync});
	m.Step(src, 1.0 / 60, out);
	CHECK_NEAR(out.aOscCycle[MB::PARAM_LineWidth], 1 + 1 - 0.2 / 4, 1e-12);
	m.SetBypass(true);
	m.Step(src, 1.0 / 60, out);
	CHECK_EQ(out.aOscFreq[MB::PARAM_LineWidth], 0.0);
}

TEST(BeatLfoShapesAreWhorldsWaveforms) {
	// the Beat LFO's shapes are the oscillators' waveforms, 0 to 1
	const int	aWave[ModRow::LFO_SHAPES] = {Oscillator::SINE, Oscillator::TRIANGLE,
		Oscillator::RAMP_UP, Oscillator::RAMP_DOWN, Oscillator::SQUARE};
	for (int nShape = 0; nShape < ModRow::LFO_SHAPES; nShape++) {
		Oscillator	osc(1, aWave[nShape], 1);
		for (int i = 0; i < 64; i++) {
			double	fPhase = (i + 0.3) / 64;
			osc.SetPhase(fPhase);
			CHECK_NEAR(ModRow::LfoValue(nShape, fPhase + 3), (osc.GetVal() + 1) / 2, 1e-9);
		}
	}
	CHECK_NEAR(ModRow::LfoValue(ModRow::LFO_Sine, 0.25), 1.0, 1e-12);
	CHECK_EQ(ModRow::LfoValue(ModRow::LFO_RampDown, 0), 1.0);
	CHECK_EQ(ModRow::LfoValue(ModRow::LFO_Square, 0.6), 0.0);
}

TEST(BeatLfoFollowsTheBeatAndCarriesOn) {
	// the Beat LFO is at the beat's place in its cycle (shifted by the phase
	// and offset), with no smoothing; without the beat it carries on at the
	// last tempo; never locked: 0
	Modulator	m;
	ModRow	row;
	row.iSource = ModSources::SRC_BeatLFO;
	row.iTarget = MB::TARGET_LineWidth;
	row.fAmount = 1;
	row.fAttack = 1;	// ignored
	row.fRelease = 1;
	row.fLfoBeats = 4;	// a bar
	row.nLfoShape = ModRow::LFO_RampUp;
	row.fLfoPhase = 0.25;
	m.SetRows({row});
	ModSources	src;
	ModOutput	out;
	m.Step(src, 1.0 / 60, out);	// no beat yet
	CHECK_EQ(m.GetRowLevel(0), 0.0);
	CHECK_EQ(out.aParam[MB::PARAM_LineWidth], 0.0);
	src.bBeat = true;
	src.fTempo = 120;
	src.fBeatPos = 5;	// a quarter into the second bar
	m.Step(src, 1.0 / 60, out);
	CHECK_NEAR(m.GetRowLevel(0), 0.5, 1e-12);	// 0.25 + 0.25 of the ramp
	CHECK_NEAR(out.aParam[MB::PARAM_LineWidth], 0.5, 1e-12);
	src.bBeat = false;	// the beat goes: half a second on at 120, 1/4 cycle
	m.Step(src, 0.5, out);
	CHECK_NEAR(m.GetRowLevel(0), 0.75, 1e-12);
	src.bBeat = true;	// an offset of 100 ms late is 0.2 beat at 120
	src.fBeatPos = 2;
	row.fOffset = 0.1;
	row.fLfoPhase = 0;
	row.nLfoShape = ModRow::LFO_Square;
	m.SetRows({row});
	m.Step(src, 1.0 / 60, out);
	CHECK_EQ(m.GetRowLevel(0), 1.0);	// 1.8 beats: in the first half
	src.fBeatPos = 2.1;	// 1.9 shifted: still the first half; 2.3 would be past
	m.Step(src, 1.0 / 60, out);
	CHECK_EQ(m.GetRowLevel(0), 1.0);
	src.fBeatPos = 2.3;
	m.Step(src, 1.0 / 60, out);
	CHECK_EQ(m.GetRowLevel(0), 0.0);
	m.SetBypass(true);
	m.Step(src, 1.0 / 60, out);
	CHECK_EQ(out.aParam[MB::PARAM_LineWidth], 0.0);
}

TEST(EngineLocksOscillators) {
	// a locked oscillator's value is the waveform at the beat's place as
	// the frame ends; unlocked, it carries on from there at the patch's rate
	auto	eng = MakeEngine();
	Patch	p = StillPatch();
	Patch::PARAM_ROW&	row = p.GetParamRow(MB::PARAM_LineWidth);
	row.fVal = 5;
	row.fAmp = 2;
	row.fFreq = 0.1;
	row.iWave = Oscillator::RAMP_UP;
	eng->OnSetPatch(p);
	RunFrames(*eng, 3);
	ModOutput	mod;
	for (double fCycle : {1.25, 1.6, 1.9, 1.05}) {
		mod.aOscFreq[MB::PARAM_LineWidth] = 2;
		mod.aOscCycle[MB::PARAM_LineWidth] = fCycle;
		eng->SetModulation(mod);
		RunFrames(*eng, 1);
		double	fPhase = fCycle - 1;
		CHECK_NEAR(eng->GetParamValues().fLineWidth, 5 + (fPhase * 2 - 1) * 2, 1e-9);
	}
	CHECK_EQ(eng->GetPatch().GetParamRow(MB::PARAM_LineWidth).fFreq, 0.1);	// the patch is unchanged
	eng->SetModulation(ModOutput());	// unlocked: from phase 0.05, at 0.1 Hz
	RunFrames(*eng, 1);
	double	fPhase = 0.05 + 0.1 / eng->GetFrameRate();
	CHECK_NEAR(eng->GetParamValues().fLineWidth, 5 + (fPhase * 2 - 1) * 2, 1e-9);
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
