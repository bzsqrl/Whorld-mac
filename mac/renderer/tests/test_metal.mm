// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Metal renderer tests (PORT_PLAN Phase 8, task 3), in coverage mode, as the
// app draws:
//   - the Windows golden images, as test_golden does for Core Graphics;
//   - every sample patch over several frames, against Core Graphics drawing
//     the same frames, with antialiasing on (where both follow Direct2D
//     closely), off (the patches' own setting) and mirrored.
// Skipped, with a message, where this Mac has no Apple GPU.
// WHORLD_METAL_REPORT=1 prints every comparison.

#include "ImageCompare.h"
#include "MetalRenderer.h"
#include "RenderJobs.h"
#include "TestHarness.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <vector>

using namespace whorld;
namespace fs = std::filesystem;

namespace {

// as test_golden
const int		kThreshold = 32;
const double	kMaxFracOver = 0.01;
const double	kMaxMeanAbs = 1.5;

// Metal against Core Graphics on the same frames. Antialiased, they agree
// well within the golden tolerance (worst when written: bloom_cvx, mean 0.49;
// 0.14% over), so it's the bound. Aliased, they differ a lot: strokes thinner than a pixel, which Metal
// draws by the pixel-center rule as unbroken lines, and Core Graphics by its
// own (undocumented) rule as dotted ones. Which matches Direct2D is open
// (PORT_PLAN Phase 8, "aliased output"); until it's settled, the bound is
// the worst seen when written (default_cvx, frame 160: mean 12.6; typhoon_cvx:
// 11.4% over), with some room, so only a gross regression shows.
const double	kAAMaxFracOver = kMaxFracOver;
const double	kAAMaxMeanAbs = kMaxMeanAbs;
const double	kAliasedMaxFracOver = 0.14;
const double	kAliasedMaxMeanAbs = 15.0;

const IntSize	kSize = {1024, 768};
const int		kFrames[] = {40, 160};	// frames compared; the last one ends the run

bool	g_bReport = std::getenv("WHORLD_METAL_REPORT") != nullptr;

fs::path OutDir()
{
	fs::path	dir = fs::temp_directory_path() / "whorld_metal";
	fs::create_directories(dir);
	return dir;
}

ImageRGBA MetalImage(MetalRenderer& r)
{
	std::vector<uint8_t>	px;
	size_t	nStride = 0;
	r.ReadPixels(px, nStride);
	return FromBGRA(px.data(), r.GetPixelWidth(), r.GetPixelHeight(), nStride);
}

ImageRGBA CoreGraphicsImage(CGBitmapRenderer& r)
{
	return FromBGRA(r.GetPixels(), r.GetPixelWidth(), r.GetPixelHeight(), r.GetStride());
}

bool MetalAvailable()
{
	static const bool	b = MetalRenderer::IsCoverageModeSupported();
	if (!b)
		std::printf("  skipped: no Apple GPU (Metal coverage mode needs one)\n");
	return b;
}

// Sends every call to two renderers, so both draw the same frame
class TeeRenderer : public IRenderer {
public:
	TeeRenderer(IRenderer& a, IRenderer& b) : m_a(a), m_b(b) {}
	void	SetAntialiasing(bool b) override { m_a.SetAntialiasing(b); m_b.SetAntialiasing(b); }
	void	Clear(const ColorF& c) override { m_a.Clear(c); m_b.Clear(c); }
	void	BeginPath() override { m_a.BeginPath(); m_b.BeginPath(); }
	void	AddFigure(const PointF* p, int n, bool bCurved, bool bClosed) override
	{
		m_a.AddFigure(p, n, bCurved, bClosed);
		m_b.AddFigure(p, n, bCurved, bClosed);
	}
	void	EndPath() override { m_a.EndPath(); m_b.EndPath(); }
	void	FillPath(const ColorF& c) override { m_a.FillPath(c); m_b.FillPath(c); }
	void	StrokePath(const ColorF& c, float w) override { m_a.StrokePath(c, w); m_b.StrokePath(c, w); }
	void	FillRect(const RectF& r, const ColorF& c) override { m_a.FillRect(r, c); m_b.FillRect(r, c); }
	bool	BeginQuadMirror() override
	{
		bool	a = m_a.BeginQuadMirror();
		bool	b = m_b.BeginQuadMirror();
		return a && b;
	}
	bool	EndQuadMirror() override
	{
		bool	a = m_a.EndQuadMirror();
		bool	b = m_b.EndQuadMirror();
		return a && b;
	}

private:
	IRenderer&	m_a;
	IRenderer&	m_b;
};

// draws nothing, so the engine runs between the compared frames cheaply
class NullRenderer : public IRenderer {
public:
	void	SetAntialiasing(bool) override {}
	void	Clear(const ColorF&) override {}
	void	BeginPath() override {}
	void	AddFigure(const PointF*, int, bool, bool) override {}
	void	EndPath() override {}
	void	FillPath(const ColorF&) override {}
	void	StrokePath(const ColorF&, float) override {}
	void	FillRect(const RectF&, const ColorF&) override {}
	bool	BeginQuadMirror() override { return true; }
	bool	EndQuadMirror() override { return true; }
};

void SetMainBool(WhorldEngine& eng, int iProp, bool b)
{
	WhorldEngine::VARIANT_PROP	prop{};
	prop.boolVal = b;
	eng.OnSetMainProp(iProp, prop);
}

// All the sample patches; in a Debug build every third, since the engine
// runs about 20 times slower there (all: 90 s; optimized: 6 s)
std::vector<fs::path> SamplePatches()
{
	std::vector<fs::path>	a;
	for (const auto& e : fs::directory_iterator(fs::path(WHORLD_TESTDATA_DIR) / "patches")) {
		if (e.path().extension() == ".whp")
			a.push_back(e.path());
	}
	std::sort(a.begin(), a.end());
#ifndef NDEBUG
	std::vector<fs::path>	b;
	for (size_t i = 0; i < a.size(); i += 3)
		b.push_back(a[i]);
	a.swap(b);
#endif
	return a;
}

enum Mode { AA_ON, AA_OFF, MIRRORED };

struct Worst {
	double	fMean = 0, fFrac = 0;
	std::string	sMean, sFrac;
	int		nCompared = 0;
	void	Add(const ImageDiff& d, const std::string& s)
	{
		if (d.fMeanAbs > fMean) { fMean = d.fMeanAbs; sMean = s; }
		if (d.fFracOver > fFrac) { fFrac = d.fFracOver; sFrac = s; }
		nCompared++;
	}
};

// Run each sample patch from a fresh engine and compare Metal with Core
// Graphics on the chosen frames. Core Graphics draws immediately, the
// simplest exact reference (its deferred mode, drawing bands on many
// threads, wasn't repeatable on antialiased frames; PORT_PLAN Phase 8,
// "Core Graphics in parallel").
void ComparePatches(Mode mode, double fMaxMean, double fMaxFrac)
{
	if (!MetalAvailable())
		return;
	const char	*sMode = mode == AA_ON ? "antialiased" : mode == AA_OFF ? "aliased" : "mirrored, antialiased";
	MetalRenderer	mr(kSize.cx, kSize.cy, 1, 0);
	CGBitmapRenderer	cg(kSize.cx, kSize.cy, 1);
	CHECK(mr.IsValid() && cg.IsValid());
	if (!mr.IsValid() || !cg.IsValid())
		return;
	TeeRenderer	tee(cg, mr);
	NullRenderer	null;
	Worst	worst;
	int	nLast = kFrames[std::size(kFrames) - 1];
	for (const fs::path& path : SamplePatches()) {
		std::string	name = path.stem().string(), err;
		Patch	patch;
		CHECK(patch.Read(path.string(), &err));
		WhorldEngine	eng;
		eng.SetFrameRate(60);
		eng.OnResize(cg.GetSizeDIPs());
		eng.OnSetPatch(patch);
		if (mode != AA_OFF)
			SetMainBool(eng, WhorldBase::MAIN_Antialiasing, true);
		if (mode == MIRRORED)
			SetMainBool(eng, WhorldBase::MAIN_Mirror, true);
		size_t	iNext = 0;
		for (int i = 0; i <= nLast; i++) {
			if (i != kFrames[iNext]) {
				eng.Draw(null);
				continue;
			}
			iNext++;
			cg.BeginFrame();
			mr.BeginFrame();
			eng.Draw(tee);
			cg.EndFrame();
			mr.EndFrame();
			mr.WaitUntilDone();
			ImageRGBA	a = CoreGraphicsImage(cg), b = MetalImage(mr), diff;
			ImageDiff	d = CompareImages(a, b, kThreshold, &diff);
			char	label[256];
			std::snprintf(label, sizeof(label), "%s, frame %d", name.c_str(), i);
			worst.Add(d, label);
			bool	bPass = d.bSameSize && d.fMeanAbs <= fMaxMean && d.fFracOver <= fMaxFrac;
			if (g_bReport || !bPass)
				std::printf("  %-36s mean %.3f, %.3f%% over %d %s\n", label, d.fMeanAbs,
					d.fFracOver * 100, kThreshold, bPass ? "ok" : "FAIL");
			if (!bPass) {
				std::string	base = (OutDir() / (name + "-" + std::to_string(i) + "-" + std::to_string(mode))).string();
				SaveImageRGBA(base + "-cg.png", a);
				SaveImageRGBA(base + "-metal.png", b);
				SaveImageRGBA(base + "-diff.png", diff);
				std::fprintf(stderr, "  images: %s-{cg,metal,diff}.png\n", base.c_str());
			}
			CHECK(bPass);
		}
	}
	std::printf("  %d frames compared with Core Graphics (%s); worst mean %.3f (%s), worst %.3f%% over (%s)\n",
		worst.nCompared, sMode, worst.fMean, worst.sMean.c_str(), worst.fFrac * 100, worst.sFrac.c_str());
	CHECK(worst.nCompared > 0);
}

} // namespace

// As test_golden: each snapshot exported as Windows "Snapshot > Export All"
// does (antialiased), against the PNG Windows Whorld exported
TEST(MetalGoldenSnapshots) {
	if (!MetalAvailable())
		return;
	fs::path	dirSnap = fs::path(WHORLD_TESTDATA_DIR) / "snapshots";
	fs::path	dirGold = fs::path(WHORLD_TESTDATA_DIR) / "golden";
	int	nCompared = 0;
	for (const auto& entry : fs::directory_iterator(dirSnap)) {
		if (entry.path().extension() != ".whs")
			continue;
		std::string	name = entry.path().stem().string(), err;
		fs::path	pathGold = dirGold / (name + ".png");
		if (!fs::exists(pathGold))
			continue;
		auto	pSnap = Snapshot::Read(entry.path().string(), &err);
		CHECK(pSnap != nullptr);
		if (!pSnap)
			continue;
		SnapshotExportOptions	opts;
		WhorldEngine	eng;
		IntSize	sz = PrepareSnapshotExport(eng, *pSnap, opts);
		MetalRenderer	mr(sz.cx, sz.cy, 1, 0);
		CHECK(mr.IsValid());
		if (!mr.IsValid())
			continue;
		mr.BeginFrame();
		eng.DrawCapture(mr, opts.nFlags, opts.szImage);
		mr.EndFrame();
		mr.WaitUntilDone();
		ImageRGBA	gold, mine = MetalImage(mr);
		CHECK(LoadImageRGBA(pathGold.string(), gold, &err));
		bool	bMirror = pSnap->m_drawState.bMirror;
		if (bMirror) {
			// Windows' mirrored exports are only good in the upper-left
			// quadrant (upstream bug, see test_golden); the whole mirrored
			// image is checked against Core Graphics below
			auto	pCG = RenderSnapshotExport(*pSnap, opts);
			CHECK(pCG != nullptr);
			if (pCG) {
				ImageDiff	dc = CompareImages(CoreGraphicsImage(*pCG), mine, kThreshold);
				bool	bPass = dc.bSameSize && dc.fMeanAbs <= kAAMaxMeanAbs && dc.fFracOver <= kAAMaxFracOver;
				std::printf("  %-28s mean %.3f, %.3f%% over %d against Core Graphics, whole image %s\n",
					name.c_str(), dc.fMeanAbs, dc.fFracOver * 100, kThreshold, bPass ? "ok" : "FAIL");
				CHECK(bPass);
			}
			gold = CropImage(gold, 0, 0, gold.nWidth / 2, gold.nHeight / 2);
			mine = CropImage(mine, 0, 0, mine.nWidth / 2, mine.nHeight / 2);
		}
		ImageRGBA	diff;
		ImageDiff	d = CompareImages(gold, mine, kThreshold, &diff);
		bool	bPass = d.bSameSize && d.fFracOver <= kMaxFracOver && d.fMeanAbs <= kMaxMeanAbs;
		std::printf("  %-28s mean %.3f, %.3f%% over %d%s %s\n", name.c_str(), d.fMeanAbs,
			d.fFracOver * 100, kThreshold, bMirror ? " (UL quadrant)" : "", bPass ? "ok" : "FAIL");
		if (!bPass) {
			fs::path	pathOut = OutDir() / (name + ".png"), pathDiff = OutDir() / (name + "-diff.png");
			SaveImageRGBA(pathOut.string(), mine);
			SaveImageRGBA(pathDiff.string(), diff);
			std::fprintf(stderr, "  output: %s\n  diff:   %s\n", pathOut.string().c_str(),
				pathDiff.string().c_str());
		}
		CHECK(bPass);
		nCompared++;
	}
	std::printf("  %d snapshots compared with Windows golden images (Metal, coverage mode)\n", nCompared);
	CHECK(nCompared > 0);
}

TEST(MetalMatchesCoreGraphicsAntialiased) {
	ComparePatches(AA_ON, kAAMaxMeanAbs, kAAMaxFracOver);
}

TEST(MetalMatchesCoreGraphicsAliased) {	// the sample patches' own setting
	ComparePatches(AA_OFF, kAliasedMaxMeanAbs, kAliasedMaxFracOver);
}

TEST(MetalMatchesCoreGraphicsMirrored) {
	ComparePatches(MIRRORED, kAAMaxMeanAbs, kAAMaxFracOver);
}

int main() { return RunAllTests(); }
