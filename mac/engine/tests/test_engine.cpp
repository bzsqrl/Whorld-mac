// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Tests for WhorldEngine (ported CWhorldDraw) using a recording renderer.

#include "RecordingRenderer.h"
#include "TestHarness.h"
#include "whorld/HLS.h"
#include "whorld/Random.h"
#include "whorld/WhorldEngine.h"

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <memory>

using namespace whorld;
namespace fs = std::filesystem;
using RC = RecordedCall;

namespace {

void RunFrames(WhorldEngine& eng, int nFrames, RecordingRenderer* pRec = nullptr)
{
	RecordingRenderer	scratch;
	for (int i = 0; i < nFrames; i++) {
		RecordingRenderer&	r = pRec ? *pRec : scratch;
		r.Reset();
		eng.Draw(r);
	}
}

std::unique_ptr<WhorldEngine> MakeEngine(float w = 800, float h = 600)
{
	whorld::srand(1);
	auto	p = std::make_unique<WhorldEngine>();
	p->OnResize(SizeF{w, h});
	return p;
}

Patch DefaultPatch()
{
	Patch	p;
	p.SetDefaults();
	return p;
}

bool AllFinite(const RecordingRenderer& rec)
{
	for (const auto& c : rec.calls) {
		for (const auto& pt : c.fig.pts)
			if (!std::isfinite(pt.x) || !std::isfinite(pt.y))
				return false;
	}
	return true;
}

} // namespace

TEST(DefaultPatchAddsRingEveryFiveFrames) {
	// growth 1 px/tick, spacing 5 px: first ring on frame 2, then every 5
	auto	eng = MakeEngine();
	RunFrames(*eng, 1);
	CHECK_EQ(eng->GetRingCount(), size_t(0));
	RunFrames(*eng, 1);
	CHECK_EQ(eng->GetRingCount(), size_t(1));
	RunFrames(*eng, 98);	// 100 frames total: rings from frames 2, 7, ..., 97
	CHECK_EQ(eng->GetRingCount(), size_t(20));
	CHECK_NEAR(eng->GetRings().front().fRadius, 4, 1e-9);	// newest, from frame 97
	CHECK_NEAR(eng->GetRings().back().fRadius, 99, 1e-9);	// oldest, from frame 2
	CHECK_EQ(eng->GetFrameCount(), uint64_t(100));
}

TEST(DefaultPatchDrawCalls) {
	auto	eng = MakeEngine();
	RecordingRenderer	rec;
	RunFrames(*eng, 100, &rec);	// rec holds the last frame
	CHECK_EQ(rec.calls.front().type, RC::ANTIALIAS);
	CHECK(rec.calls.front().bFlag);	// antialiasing on by default
	const RC*	clear = rec.First(RC::CLEAR);
	CHECK(clear != nullptr);
	CHECK_EQ(clear->clr.r, 0.0f);	// default background: lightness 0 = black
	CHECK_EQ(clear->clr.a, 1.0f);
	// draw mode 0: every ring is a stroked, hollow, straight pentagon
	CHECK_EQ(rec.Count(RC::BEGIN_PATH), 20);
	CHECK_EQ(rec.Count(RC::STROKE_PATH), 20);
	CHECK_EQ(rec.Count(RC::FILL_PATH), 0);
	CHECK_EQ(rec.Count(RC::BEGIN_MIRROR), 0);
	const RC*	fig = rec.First(RC::ADD_FIGURE);
	CHECK(fig != nullptr);
	if (!fig)
		return;
	CHECK(!fig->fig.bCurved);
	CHECK(!fig->fig.bFilled);
	CHECK_EQ(fig->fig.nSegments, 10);	// 5 sides, 2 vertices each
	CHECK_EQ(rec.First(RC::STROKE_PATH)->fWidth, 1.0f);
	// newest ring first: radius 4, star ratio cos(pi/5), centered in 800x600
	const double	r = 4, rOdd = 4 * std::cos(kPi / 5);
	CHECK_NEAR(fig->fig.pts[0].x, 400, 1e-4);
	CHECK_NEAR(fig->fig.pts[0].y, 300 + r, 1e-4);
	CHECK_NEAR(fig->fig.pts[1].x, 400 + std::sin(kPi / 5) * rOdd, 1e-4);
	CHECK_NEAR(fig->fig.pts[1].y, 300 + std::cos(kPi / 5) * rOdd, 1e-4);
	CHECK_NEAR(fig->fig.pts[2].x, 400 + std::sin(2 * kPi / 5) * r, 1e-4);
	CHECK_EQ(fig->fig.pts[10].x, fig->fig.pts[0].x);	// closing point repeats start
	CHECK_EQ(fig->fig.pts[10].y, fig->fig.pts[0].y);
	// ring color: hue advances 0.5 degrees per tick, HLS(hue, 0.5, 1)
	const auto&	ring = eng->GetRings().front();
	double	rr, gg, bb;
	HLS::hls2rgb(ring.fHue, 0.5, 1, rr, gg, bb);
	CHECK_NEAR(ring.clrCur.g, gg, 1e-6);
	CHECK_EQ(rec.First(RC::STROKE_PATH)->clr.g, ring.clrCur.g);
}

TEST(FillModeFillsBetweenRings) {
	auto	eng = MakeEngine();
	eng->OnSetDrawMode(Patch::DM_FILL, Patch::DM_FILL);
	RecordingRenderer	rec;
	RunFrames(*eng, 100, &rec);
	CHECK_EQ(rec.Count(RC::FILL_PATH), 20);
	CHECK_EQ(rec.Count(RC::STROKE_PATH), 20);	// outline to close gaps, width 1
	CHECK_EQ(rec.First(RC::STROKE_PATH)->fWidth, 1.0f);
	// first ring has one figure, each later ring two (it and the previous)
	CHECK_EQ(rec.Count(RC::ADD_FIGURE), 1 + 2 * 19);
	CHECK(rec.First(RC::ADD_FIGURE)->fig.bFilled);
}

TEST(OutlineModeStrokesWithBackground) {
	auto	eng = MakeEngine();
	eng->OnSetDrawMode(Patch::DM_FILL | Patch::DM_OUTLINE, Patch::DM_FILL | Patch::DM_OUTLINE);
	eng->OnSetParam(Patch::PARAM_LineWidth, 3);
	RecordingRenderer	rec;
	RunFrames(*eng, 50, &rec);
	const RC*	stroke = rec.First(RC::STROKE_PATH);
	CHECK(stroke != nullptr);
	if (!stroke)
		return;
	CHECK_EQ(stroke->fWidth, 3.0f);
	CHECK_EQ(stroke->clr.r, rec.First(RC::CLEAR)->clr.r);	// background color
}

TEST(ConvexDrawsBullseye) {
	auto	eng = MakeEngine();
	eng->OnSetDrawMode(Patch::DM_FILL, Patch::DM_FILL);
	Patch::VARIANT_PROP	prop;
	prop.llVal = 0;
	prop.boolVal = true;
	eng->OnSetMainProp(Patch::MAIN_Convex, prop);
	RecordingRenderer	rec;
	RunFrames(*eng, 100, &rec);
	// oldest ring is drawn first and only primes the previous points; the
	// other 19 fill with the previous ring's color; then the bullseye
	CHECK_EQ(rec.Count(RC::FILL_PATH), 19 + 1);
	CHECK_EQ(rec.Count(RC::ADD_FIGURE), 2 * 19 + 1);
	const auto&	rings = eng->GetRings();
	CHECK_EQ(rec.calls.back().type, RC::STROKE_PATH);	// bullseye outline is last
	const RC*	lastFill = nullptr;
	for (const auto& c : rec.calls)
		if (c.type == RC::FILL_PATH)
			lastFill = &c;
	CHECK(lastFill != nullptr && lastFill->clr.g == rings.front().clrCur.g);
}

TEST(MirrorBracketsDrawing) {
	auto	eng = MakeEngine();
	Patch::VARIANT_PROP	prop;
	prop.llVal = 0;
	prop.boolVal = true;
	eng->OnSetMainProp(Patch::MAIN_Mirror, prop);
	RecordingRenderer	rec;
	RunFrames(*eng, 20, &rec);
	CHECK_EQ(rec.calls[1].type, RC::BEGIN_MIRROR);	// before Clear
	CHECK_EQ(rec.calls[2].type, RC::CLEAR);
	CHECK_EQ(rec.calls.back().type, RC::END_MIRROR);
	rec.bMirrorOk = false;	// a failing backend still gets the End call
	rec.Reset();
	eng->Draw(rec);
	CHECK_EQ(rec.Count(RC::END_MIRROR), 1);
}

TEST(MaxRingsLimitsList) {
	auto	eng = MakeEngine();
	eng->OnSetMasterProp(Patch::MASTER_Rings, 3);
	RunFrames(*eng, 200);
	CHECK_EQ(eng->GetRingCount(), size_t(3));
}

TEST(InvisibleRingsCascadeDelete) {
	// rings grow until every vertex is off the canvas, then die
	auto	eng = MakeEngine(100, 100);
	eng->OnSetParam(Patch::PARAM_RingGrowth, 10);
	RunFrames(*eng, 500);
	// canvas is 140 x 140, so no ring survives much past radius ~100;
	// rings appear every half frame, 10 px apart
	CHECK(eng->GetRingCount() > 0);
	CHECK(eng->GetRingCount() < 30);
	for (const auto& r : eng->GetRings())
		CHECK(r.fRadius < 200);
}

TEST(PauseFreezesAndSingleStepAdvances) {
	auto	eng = MakeEngine();
	RunFrames(*eng, 50);
	eng->OnSetPause(true);
	double	fRadius = eng->GetRings().back().fRadius;
	RunFrames(*eng, 10);
	CHECK_EQ(eng->GetRings().back().fRadius, fRadius);
	eng->OnSingleStep();
	CHECK_NEAR(eng->GetRings().back().fRadius, fRadius + 1, 1e-9);
	eng->OnSetPause(false);
	RunFrames(*eng, 1);
	CHECK_NEAR(eng->GetRings().back().fRadius, fRadius + 2, 1e-9);
}

TEST(SetEmptyRestartsLikeAFreshEngine) {
	// offset 0 isn't > 0, so the first ring comes on the second frame
	auto	eng = MakeEngine();
	RunFrames(*eng, 30);
	eng->OnSetEmpty();
	CHECK_EQ(eng->GetRingCount(), size_t(0));
	RunFrames(*eng, 1);
	CHECK_EQ(eng->GetRingCount(), size_t(0));
	RunFrames(*eng, 1);
	CHECK_EQ(eng->GetRingCount(), size_t(1));
}

TEST(Determinism) {
	auto	a = MakeEngine();
	auto	b = MakeEngine();
	Patch	p = DefaultPatch();
	p.GetParamRow(Patch::PARAM_StarFactor).fAmp = 1;
	p.GetParamRow(Patch::PARAM_StarFactor).fFreq = 0.3;
	a->OnSetPatch(p);
	b->OnSetPatch(p);
	RecordingRenderer	ra, rb;
	RunFrames(*a, 120, &ra);
	RunFrames(*b, 120, &rb);
	CHECK_EQ(ra.calls.size(), rb.calls.size());
	bool	bSame = ra.calls.size() == rb.calls.size();
	for (size_t i = 0; bSame && i < ra.calls.size(); i++) {
		const auto&	fa = ra.calls[i].fig.pts;
		const auto&	fb = rb.calls[i].fig.pts;
		bSame = fa.size() == fb.size();
		for (size_t j = 0; bSame && j < fa.size(); j++)
			bSame = fa[j].x == fb[j].x && fa[j].y == fb[j].y;
	}
	CHECK(bSame);
}

TEST(PatchSetsOscillatorWaveformAndPulseWidth) {
	// Fix (not in the original, which left each oscillator's waveform and
	// pulse width as they were until the row was edited): a loaded patch's
	// oscillators use its waveforms and pulse widths from the first frame.
	auto	eng = MakeEngine();
	Patch	p = DefaultPatch();
	auto&	rowLW = p.GetParamRow(Patch::PARAM_LineWidth);
	rowLW.iWave = Patch::WAVEFORM_SINE;
	rowLW.fAmp = 1;
	rowLW.fFreq = 1;
	auto&	rowPS = p.GetParamRow(Patch::PARAM_PolySides);
	rowPS.fVal = 5;
	rowPS.iWave = Patch::WAVEFORM_PULSE;
	rowPS.fAmp = 1;
	rowPS.fFreq = 1;
	rowPS.fPW = 0.01;	// high only for the first 1% of each cycle
	eng->OnSetPatch(p);
	RunFrames(*eng, 1);	// clock 1 at 60 Hz: phase 1/60
	CHECK_NEAR(eng->GetParamValues().fLineWidth, 1 + std::sin(2 * kPi / 60), 1e-12);	// not the triangle
	CHECK_NEAR(eng->GetParamValues().fPolySides, 5 - 1, 1e-12);	// phase 1/60 is past 0.01; at 0.5 it would be high
	// a second patch replaces them, as opening another file does
	Patch	q = DefaultPatch();
	auto&	rowQ = q.GetParamRow(Patch::PARAM_LineWidth);
	rowQ.iWave = Patch::WAVEFORM_SQUARE;
	rowQ.fAmp = 1;
	rowQ.fFreq = 1;
	eng->OnSetPatch(q);
	RunFrames(*eng, 1);
	CHECK_NEAR(eng->GetParamValues().fLineWidth, 1 + 1, 1e-12);	// square, first half of its cycle
}

TEST(RandomOriginUsesMsvcSequence) {
	auto	eng = MakeEngine(800, 600);
	Patch::VARIANT_PROP	prop;
	prop.llVal = 0;
	prop.intVal = Patch::OM_RANDOM;
	eng->OnSetMainProp(Patch::MAIN_OrgMotion, prop);
	whorld::srand(1);
	RunFrames(*eng, 1);	// trigger fires on the first tick
	// y is drawn first (MSVC argument order): rand() 41 -> y, 18467 -> x
	double	fX = 18467.0 / kRandMax, fY = 41.0 / kRandMax;
	double	fDamp = Patch::m_masterDefault.fDamping;
	DPoint	org = eng->GetOrigin();
	CHECK_NEAR(org.x, 0.5 + (fX - 0.5) * fDamp, 1e-12);
	CHECK_NEAR(org.y, 0.5 + (fY - 0.5) * fDamp, 1e-12);
}

TEST(OriginAndZoomCommands) {
	auto	eng = MakeEngine(800, 600);
	eng->OnSetOrigin(DPoint(0.75, 0.25), false);
	CHECK_NEAR(eng->GetOrigin().x, 0.75, 1e-12);
	CHECK_NEAR(eng->GetOrigin().y, 0.25, 1e-12);
	eng->OnSetOriginX(0.5, true);	// damped: target moves, origin follows
	RunFrames(*eng, 1);
	double	fDamp = Patch::m_masterDefault.fDamping;
	CHECK_NEAR(eng->GetOrigin().x, 0.75 - 0.25 * fDamp, 1e-12);
	eng->OnSetZoom(2, false);
	CHECK_EQ(eng->GetZoom(), 2.0);
	eng->OnSetMasterProp(Patch::MASTER_Zoom, 0.5);	// master zoom sets zoom undamped
	CHECK_EQ(eng->GetZoom(), 0.5);
}

namespace {
std::unique_ptr<Snapshot> MakeSquareSnapshot()
{
	auto	s = Snapshot::Alloc(1);
	s->m_drawState.szTarget = SizeF{200, 100};
	s->m_drawState.fZoom = 1;
	s->m_drawState.nRings = 1;
	s->m_drawState.clrBkgnd = ColorF{0.1f, 0.2f, 0.3f, 1};
	s->m_globRing.fStarRatio = 1;
	s->m_globRing.ptScale = DPOINT{1, 1};
	s->m_globRing.fEvenShear = 1;
	s->m_globRing.fOddShear = 1;
	auto&	r = s->m_aRing[0];
	r.nSides = 4;
	r.fRadius = 10;
	r.fStarRatio = 1;
	r.ptScale = DPOINT{1, 1};
	r.fLineWidth = 2;
	r.clrCur = ColorF{1, 0, 0, 1};
	return s;
}
} // namespace

TEST(DisplaySnapshotScalesToView) {
	auto	eng = MakeEngine(500, 200);	// wider than the 2:1 snapshot
	RunFrames(*eng, 30);
	size_t	nLiveRings = eng->GetRingCount();
	auto	snap = MakeSquareSnapshot();
	eng->OnDisplaySnapshot(*snap);
	CHECK(eng->IsPaused());
	CHECK(eng->IsSnapshotMode());
	RecordingRenderer	rec;
	eng->Draw(rec);
	CHECK_EQ(eng->GetRingCount(), size_t(1));
	CHECK_EQ(rec.First(RC::CLEAR)->clr.b, 0.3f);
	// scale = min(500 / 200, 200 / 100) = 2; radius 20 around (250, 100)
	const RC*	fig = rec.First(RC::ADD_FIGURE);
	CHECK(fig != nullptr);
	if (!fig)
		return;
	CHECK_EQ(fig->fig.nSegments, 8);
	for (int k = 0; k < 8; k++) {
		double	theta = k * kPi / 4;
		CHECK_NEAR(fig->fig.pts[k].x, 250 + std::sin(theta) * 20, 1e-4);
		CHECK_NEAR(fig->fig.pts[k].y, 100 + std::cos(theta) * 20, 1e-4);
	}
	CHECK_EQ(rec.First(RC::STROKE_PATH)->fWidth, 4.0f);	// line width scaled too
	// letterbox: black bars (500 - 400) / 2 = 50 wide, left and right
	CHECK_EQ(rec.Count(RC::FILL_RECT), 2);
	const RC*	bar = rec.First(RC::FILL_RECT);
	CHECK_EQ(bar->rect.right, 50.0f);
	CHECK_EQ(bar->clr.r, 0.0f);
	CHECK_EQ(bar->clr.a, 1.0f);
	eng->SetSnapshotLetterbox(false);
	rec.Reset();
	eng->Draw(rec);
	CHECK_EQ(rec.Count(RC::FILL_RECT), 0);
	// unpausing restores the live state from before the snapshot
	eng->OnSetPause(false);
	CHECK(!eng->IsSnapshotMode());
	CHECK_EQ(eng->GetRingCount(), nLiveRings);
}

TEST(CaptureSnapshotRoundTrip) {
	auto	eng = MakeEngine();
	RunFrames(*eng, 60);
	auto	snap = eng->OnCaptureSnapshot();
	CHECK_EQ(snap->m_drawState.nRings, int(eng->GetRingCount()));
	CHECK_EQ(snap->m_drawState.szTarget.width, 800.0f);
	CHECK_EQ(snap->m_aRing.front().fRadius, eng->GetRings().front().fRadius);
	std::vector<uint8_t>	data = Snapshot::Encode(*snap);
	auto	back = Snapshot::Read(data);
	CHECK(back != nullptr && Snapshot::Encode(*back) == data);
}

TEST(DrawCaptureRestoresState) {
	auto	eng = MakeEngine(640, 480);
	Patch::VARIANT_PROP	prop;
	prop.llVal = 0;
	prop.boolVal = false;
	eng->OnSetMainProp(Patch::MAIN_Antialiasing, prop);
	RunFrames(*eng, 40);
	size_t	nRings = eng->GetRingCount();
	double	fRadius = eng->GetRings().front().fRadius;
	IntSize	sz = eng->GetCaptureSize(Patch::EF_USE_VIEW_SIZE, IntSize{10, 10});
	CHECK_EQ(sz.cx, 640);
	CHECK_EQ(sz.cy, 480);
	RecordingRenderer	rec;
	CHECK(eng->DrawCapture(rec, Patch::EF_SCALE_FIT_BOTH, IntSize{1280, 960}));
	CHECK(rec.calls.front().bFlag);	// antialiasing forced on for capture
	// frozen geometry, scaled by 2 around the new center
	const RC*	fig = rec.First(RC::ADD_FIGURE);
	CHECK(fig != nullptr && std::fabs(fig->fig.pts[0].y - (480 + fRadius * 2)) < 1e-3);
	CHECK_EQ(eng->GetRingCount(), nRings);
	CHECK_EQ(eng->GetRings().front().fRadius, fRadius);
	CHECK_EQ(eng->GetZoom(), 1.0);
	CHECK(!eng->IsPaused());
	rec.Reset();
	eng->Draw(rec);
	CHECK(!rec.calls.front().bFlag);	// back to the patch setting
}

TEST(RenderCommandDispatch) {
	auto	eng = MakeEngine();
	double	fVal = 7;
	eng->OnRenderCommand(WhorldEngine::RenderCmd(Patch::RC_SET_PARAM_Val, Patch::PARAM_RingSpacing, fVal));
	CHECK_EQ(eng->GetPatch().GetParamRow(Patch::PARAM_RingSpacing).fVal, 7.0);
	Patch*	pPatch = new Patch(DefaultPatch());
	pPatch->SetMasterProp(Patch::MASTER_Rings, 12);
	WhorldEngine::RenderCmd	cmd(Patch::RC_SET_PATCH);
	cmd.m_prop.byref = pPatch;	// engine takes ownership
	eng->OnRenderCommand(cmd);
	CHECK_EQ(eng->GetPatch().GetMasterProp(Patch::MASTER_Rings), 12.0);
	// replies go through the callback
	int	nReplies = 0;
	DPoint	ptReply(-1, -1);
	eng->SetReplyCallback([&](const WhorldEngine::Reply& r) {
		nReplies++;
		if (r.nCmd == Patch::RC_GET_ORIGIN)
			ptReply = r.ptOrigin;
		if (r.nCmd == Patch::RC_CAPTURE_SNAPSHOT)
			delete static_cast<Snapshot*>(r.pData);
	});
	eng->OnRenderCommand(WhorldEngine::RenderCmd(Patch::RC_GET_ORIGIN));
	CHECK_NEAR(ptReply.x, 0.5, 1e-12);
	eng->OnRenderCommand(WhorldEngine::RenderCmd(Patch::RC_CAPTURE_SNAPSHOT));
	Patch	out;
	WhorldEngine::RenderCmd	get(Patch::RC_GET_PATCH);
	get.m_prop.byref = &out;
	eng->OnRenderCommand(get);
	CHECK_EQ(out.GetMasterProp(Patch::MASTER_Rings), 12.0);
	CHECK_EQ(nReplies, 3);
}

TEST(SamplePatchesRunCleanly) {
	// every sample patch runs 300 frames with finite geometry
	fs::path	dir = fs::path(WHORLD_TESTDATA_DIR) / "patches";
	if (!fs::exists(dir)) {
		std::printf("  (no sample patches; skipped)\n");
		return;
	}
	int	nFiles = 0;
	size_t	nMaxRings = 0;
	for (const auto& entry : fs::directory_iterator(dir)) {
		if (entry.path().extension() != ".whp")
			continue;
		Patch	p;
		if (!p.Read(entry.path().string()))
			continue;
		nFiles++;
		auto	eng = MakeEngine(1024, 768);
		eng->OnSetPatch(p);
		RecordingRenderer	rec;
		bool	bFinite = true;
		for (int i = 0; i < 300; i++) {
			rec.Reset();
			eng->Draw(rec);
			bFinite = bFinite && AllFinite(rec);
		}
		if (!bFinite)
			std::fprintf(stderr, "  non-finite geometry: %s\n", entry.path().filename().string().c_str());
		CHECK(bFinite);
		int	nLimit = int(std::lround(p.GetMasterProp(Patch::MASTER_Rings)));
		if (nLimit < Patch::MAX_RINGS)
			CHECK(eng->GetRingCount() <= size_t(nLimit));
		nMaxRings = std::max(nMaxRings, eng->GetRingCount());
	}
	std::printf("  %d sample patches ran 300 frames; largest ring count %zu\n", nFiles, nMaxRings);
}

int main() { return RunAllTests(); }
