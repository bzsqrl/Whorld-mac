// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Golden-image tests: render each snapshot in mac/testdata/snapshots the
// way Windows "Snapshot > Export All" does (1024 x 768, no scale-to-fit)
// and compare with the PNG Windows Whorld 2.0.20 exported.

#include "ImageCompare.h"
#include "RenderJobs.h"
#include "TestHarness.h"

#include <cstdio>
#include <filesystem>
#include <string>

using namespace whorld;
namespace fs = std::filesystem;

namespace {
// Direct2D and Core Graphics antialias edges slightly differently; allow
// that, but nothing structural. Worst sample at the time of writing:
// bloom_cvx, 0.70% of pixels over 32, mean 0.72.
const int		kThreshold = 32;		// per-pixel max RGB difference
const double	kMaxFracOver = 0.01;	// at most 1% of pixels over the threshold
const double	kMaxMeanAbs = 1.5;		// mean absolute difference, 0..255
} // namespace

static void CompareGoldens(bool bDeferred)
{
	fs::path	dirSnap = fs::path(WHORLD_TESTDATA_DIR) / "snapshots";
	fs::path	dirGold = fs::path(WHORLD_TESTDATA_DIR) / "golden";
	fs::path	dirOut = fs::temp_directory_path() / "whorld_golden";
	fs::create_directories(dirOut);
	int	nCompared = 0;
	for (const auto& entry : fs::directory_iterator(dirSnap)) {
		if (entry.path().extension() != ".whs")
			continue;
		std::string	name = entry.path().stem().string();
		fs::path	pathGold = dirGold / (name + ".png");
		if (!fs::exists(pathGold))
			continue;
		std::string	err;
		auto	pSnap = Snapshot::Read(entry.path().string(), &err);
		CHECK(pSnap != nullptr);
		if (!pSnap)
			continue;
		SnapshotExportOptions	opts;
		opts.bDeferred = bDeferred;
		auto	pRenderer = RenderSnapshotExport(*pSnap, opts);
		CHECK(pRenderer != nullptr);
		if (!pRenderer)
			continue;
		fs::path	pathOut = dirOut / (name + (bDeferred ? "-deferred.png" : ".png"));
		CHECK(pRenderer->WritePNG(pathOut.string(), &err));
		ImageRGBA	gold, mine;
		CHECK(LoadImageRGBA(pathGold.string(), gold, &err));
		CHECK(LoadImageRGBA(pathOut.string(), mine, &err));
		// Mirrored exports on Windows reuse the live window's stale mirror
		// bitmap (upstream bug, see PORT_PLAN.md), so only the upper-left
		// quadrant, drawn before mirroring, is comparable.
		if (pSnap->m_drawState.bMirror) {
			gold = CropImage(gold, 0, 0, gold.nWidth / 2, gold.nHeight / 2);
			mine = CropImage(mine, 0, 0, mine.nWidth / 2, mine.nHeight / 2);
		}
		ImageRGBA	diff;
		ImageDiff	d = CompareImages(gold, mine, kThreshold, &diff);
		CHECK(d.bSameSize);
		bool	bPass = d.bSameSize && d.fFracOver <= kMaxFracOver && d.fMeanAbs <= kMaxMeanAbs;
		std::printf("  %-28s mean %.3f, %.3f%% over %d%s %s\n", name.c_str(), d.fMeanAbs,
			d.fFracOver * 100, kThreshold, pSnap->m_drawState.bMirror ? " (UL quadrant)" : "",
			bPass ? "ok" : "FAIL");
		if (!bPass) {
			fs::path	pathDiff = dirOut / (name + "-diff.png");
			SaveImageRGBA(pathDiff.string(), diff);
			std::fprintf(stderr, "  output: %s\n  diff:   %s\n", pathOut.string().c_str(),
				pathDiff.string().c_str());
		}
		CHECK(bPass);
		nCompared++;
	}
	std::printf("  %d snapshots compared with Windows golden images (%s)\n", nCompared,
		bDeferred ? "deferred, banded" : "immediate");
	CHECK(nCompared > 0);
}

TEST(GoldenSnapshotsImmediate) {
	CompareGoldens(false);
}

TEST(GoldenSnapshotsDeferred) {	// the mode the app uses
	CompareGoldens(true);
}

int main() { return RunAllTests(); }
