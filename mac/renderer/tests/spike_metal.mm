// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Phase 8 spike: how close is the Metal renderer to Windows and to the Core
// Graphics renderer, and how fast is it? Not a ctest test; run by hand:
//   build/renderer/tests/spike_metal [--samples 4] [--ss 1,2,4] [--tol 0.1] [--no-golden]
//     [--no-perf] [--patches "bloom_cvx,boomer_cvx"] [--warm 300] [--frames 120]
//     [--size 3024x1964] [--scale 2]

#include "CGRenderer.h"
#include "ImageCompare.h"
#include "MetalRenderer.h"
#include "RenderJobs.h"

#include <dispatch/dispatch.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <map>
#include <sstream>
#include <string>
#include <vector>

using namespace whorld;
namespace fs = std::filesystem;

namespace {

const int		kThreshold = 32;	// as test_golden
const double	kMaxFracOver = 0.01;
const double	kMaxMeanAbs = 1.5;
int		g_nAA = -1;	// perf: force antialiasing on (1) or off (0); -1 = as the patch says

void SetAA(WhorldEngine& eng, bool b)
{
	WhorldEngine::VARIANT_PROP	prop{};
	prop.boolVal = b;
	eng.OnSetMainProp(WhorldBase::MAIN_Antialiasing, prop);
}

std::vector<std::string> Split(const std::string& s)
{
	std::vector<std::string>	v;
	std::stringstream	ss(s);
	std::string	item;
	while (std::getline(ss, item, ','))
		v.push_back(item);
	return v;
}

ImageRGBA MetalImage(MetalRenderer& r)
{
	std::vector<uint8_t>	px;
	size_t	nStride = 0;
	r.ReadPixels(px, nStride);
	return FromBGRA(px.data(), r.GetPixelWidth(), r.GetPixelHeight(), nStride);
}

// box-filter a k-times supersampled image down to its size / k
ImageRGBA Downsample(const ImageRGBA& src, int k)
{
	ImageRGBA	dst;
	dst.nWidth = src.nWidth / k;
	dst.nHeight = src.nHeight / k;
	dst.aPixel.assign(size_t(dst.nWidth) * dst.nHeight * 4, 0);
	for (int y = 0; y < dst.nHeight; y++) {
		for (int x = 0; x < dst.nWidth; x++) {
			for (int c = 0; c < 4; c++) {
				int	sum = 0;
				for (int j = 0; j < k; j++)
					for (int i = 0; i < k; i++)
						sum += src.aPixel[(size_t(y * k + j) * src.nWidth + (x * k + i)) * 4 + c];
				dst.aPixel[(size_t(y) * dst.nWidth + x) * 4 + c] = uint8_t((sum + k * k / 2) / (k * k));
			}
		}
	}
	return dst;
}

double Ms(std::chrono::steady_clock::time_point t0)
{
	return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

// CPU model of per-path coverage blending, to test the idea before building
// it on the GPU: each path's triangles set bits in a 64-sample (8 x 8 grid)
// mask per pixel, ORed for strokes and XORed for even-odd fill fans; the
// path's color is then blended once per pixel with coverage = bits / 64, as
// Direct2D and Core Graphics blend a shape by its coverage. Slow; spike only.
class CpuCoverageRenderer : public IRenderer {
public:
	CpuCoverageRenderer(int w, int h, double scale, float tol)
		: m_w(w), m_h(h), m_scale(scale), m_tol(tol), m_px(size_t(w) * h * 4, 0.0f), m_mask(size_t(w) * h, 0) {}
	void	SetAntialiasing(bool) override {}
	void	Clear(const ColorF& c) override {
		for (int y = 0; y < ClipH(); y++)
			for (int x = 0; x < ClipW(); x++) {
				float	*p = &m_px[(size_t(y) * m_w + x) * 4];
				p[0] = c.r * c.a; p[1] = c.g * c.a; p[2] = c.b * c.a; p[3] = c.a;
			}
	}
	void	BeginPath() override { m_figs.clear(); }
	void	AddFigure(const PointF* p, int n, bool bCurved, bool bFilled) override {
		gpu::Contour	ct;
		gpu::FlattenFigure(p, n, bCurved, float(m_scale), m_tol, ct);
		m_figs.push_back({std::move(ct), bFilled});
	}
	void	EndPath() override {}
	void	FillPath(const ColorF& c) override {
		std::vector<gpu::Contour>	v;
		for (auto& f : m_figs)
			if (f.second)
				v.push_back(f.first);
		std::vector<gpu::Vec2>	tris;
		gpu::FanContours(v.data(), v.size(), tris);
		Paint(tris, true, c);
	}
	void	StrokePath(const ColorF& c, float w) override {
		w = std::fabs(w);
		if (!(w > 0))
			return;
		std::vector<gpu::Contour>	v;
		for (auto& f : m_figs)
			v.push_back(f.first);
		std::vector<gpu::Vec2>	tris;
		float	wpx = w * float(m_scale);
		ColorF	cc = c;
		static const float	fMin = getenv("SPIKE_MINW") ? float(atof(getenv("SPIKE_MINW"))) : 0;
		if (wpx < fMin) {	// hypothesis: thin strokes drawn at the minimum width, fainter
			cc.a *= wpx / fMin;
			wpx = fMin;
		}
		gpu::StrokeContours(v.data(), v.size(), wpx, m_tol, tris);
		Paint(tris, false, cc);
	}
	void	FillRect(const RectF& r, const ColorF& c) override {
		std::vector<gpu::Vec2>	tris;
		gpu::RectTriangles(r.left * m_scale, r.top * m_scale, r.right * m_scale, r.bottom * m_scale, tris);
		Paint(tris, false, c);
	}
	bool	BeginQuadMirror() override { m_bMirror = true; return true; }
	bool	EndQuadMirror() override {
		if (!m_bMirror)
			return false;
		m_bMirror = false;
		int	qw = (m_w + 1) / 2, qh = (m_h + 1) / 2;
		for (int y = 0; y < m_h; y++)
			for (int x = 0; x < m_w; x++) {
				int	sx = x < qw ? x : m_w - 1 - x, sy = y < qh ? y : m_h - 1 - y;
				if (sx != x || sy != y)
					std::memcpy(&m_px[(size_t(y) * m_w + x) * 4], &m_px[(size_t(sy) * m_w + sx) * 4], 16);
			}
		return true;
	}
	ImageRGBA	Image() const {
		ImageRGBA	im;
		im.nWidth = m_w;
		im.nHeight = m_h;
		im.aPixel.resize(size_t(m_w) * m_h * 4);
		for (size_t i = 0; i < size_t(m_w) * m_h; i++) {	// BGRA premultiplied bytes, as WritePNG stores them
			for (int c = 0; c < 4; c++)
				im.aPixel[i * 4 + c] = uint8_t(std::lround(std::clamp(m_px[i * 4 + c], 0.0f, 1.0f) * 255));
		}
		return im;
	}
private:
	int		m_w, m_h;
	double	m_scale;
	float	m_tol;
	bool	m_bMirror = false;
	std::vector<float>	m_px;	// RGBA premultiplied
	std::vector<uint64_t>	m_mask;
	std::vector<std::pair<gpu::Contour, bool>>	m_figs;
	int	ClipW() const { return m_bMirror ? (m_w + 1) / 2 : m_w; }
	int	ClipH() const { return m_bMirror ? (m_h + 1) / 2 : m_h; }
	void	Paint(const std::vector<gpu::Vec2>& tris, bool bXor, const ColorF& c) {
		int	cw = ClipW(), ch = ClipH();
		const int	nBands = 16;
		uint64_t	*mask = m_mask.data();
		float	*px = m_px.data();
		const gpu::Vec2	*t = tris.data();
		size_t	nTri = tris.size() / 3;
		int	w = m_w;
		dispatch_apply(nBands, DISPATCH_APPLY_AUTO, ^(size_t b) {
			int	yb0 = int(ch * b / nBands), yb1 = int(ch * (b + 1) / nBands);
			int	bx0 = cw, bx1 = -1, by0 = yb1, by1 = yb0 - 1;	// touched area
			for (size_t i = 0; i < nTri; i++) {
				gpu::Vec2	a = t[i * 3], bb = t[i * 3 + 1], cc = t[i * 3 + 2];
				float	area = (bb.x - a.x) * (cc.y - a.y) - (bb.y - a.y) * (cc.x - a.x);
				if (area == 0)
					continue;
				if (area < 0)
					std::swap(bb, cc);
				int	x0 = std::max(0, int(std::floor(std::min({a.x, bb.x, cc.x}))));
				int	x1 = std::min(cw - 1, int(std::floor(std::max({a.x, bb.x, cc.x}))));
				int	y0 = std::max(yb0, int(std::floor(std::min({a.y, bb.y, cc.y}))));
				int	y1 = std::min(yb1 - 1, int(std::floor(std::max({a.y, bb.y, cc.y}))));
				if (x0 > x1 || y0 > y1)
					continue;
				bx0 = std::min(bx0, x0); bx1 = std::max(bx1, x1);
				by0 = std::min(by0, y0); by1 = std::max(by1, y1);
				auto	E = [](gpu::Vec2 p, gpu::Vec2 q, float x, float y) {
					return (q.x - p.x) * (y - p.y) - (q.y - p.y) * (x - p.x);
				};
				for (int y = y0; y <= y1; y++)
					for (int x = x0; x <= x1; x++) {
						uint64_t	m = 0;
						for (int k = 0; k < 64; k++) {	// n-rooks: every sample in its own row and column
							float	fx = x + (k + 0.5f) / 64, fy = y + ((k * 37) % 64 + 0.5f) / 64;
							if (E(a, bb, fx, fy) >= 0 && E(bb, cc, fx, fy) >= 0 && E(cc, a, fx, fy) >= 0)
								m |= uint64_t(1) << k;
						}
						if (bXor)
							mask[size_t(y) * w + x] ^= m;
						else
							mask[size_t(y) * w + x] |= m;
					}
			}
			// blend the path once per pixel with its coverage, and reset the mask
			for (int y = by0; y <= by1; y++)
				for (int x = bx0; x <= bx1; x++) {
					uint64_t	&m = mask[size_t(y) * w + x];
					if (!m)
						continue;
					float	cov = __builtin_popcountll(m) / 64.0f;
					m = 0;
					float	*p = &px[(size_t(y) * w + x) * 4];
					float	a = c.a * cov;
					p[0] = c.r * a + p[0] * (1 - a);
					p[1] = c.g * a + p[1] * (1 - a);
					p[2] = c.b * a + p[2] * (1 - a);
					p[3] = a + p[3] * (1 - a);
				}
		});
	}
};

void Golden(const std::vector<int>& aSamples, const std::vector<int>& aSS, float fTol, const fs::path& dirOut)
{
	fs::path	dirSnap = fs::path(WHORLD_TESTDATA_DIR) / "snapshots";
	fs::path	dirGold = fs::path(WHORLD_TESTDATA_DIR) / "golden";
	std::printf("Golden snapshots (1024x768; threshold %d; pass: mean <= %.1f and <= %.0f%% over)\n",
		kThreshold, kMaxMeanAbs, kMaxFracOver * 100);
	std::printf("  %-28s %-16s %-22s %-22s\n", "snapshot", "renderer", "vs Windows", "vs Core Graphics");
	std::vector<fs::path>	snaps;
	for (const auto& e : fs::directory_iterator(dirSnap)) {
		if (e.path().extension() == ".whs")
			snaps.push_back(e.path());
	}
	std::sort(snaps.begin(), snaps.end());
	for (const fs::path& path : snaps) {
		std::string	name = path.stem().string();
		if (getenv("SPIKE_ONLY") && name.find(getenv("SPIKE_ONLY")) == std::string::npos)
			continue;
		std::string	err;
		auto	pSnap = Snapshot::Read(path.string(), &err);
		ImageRGBA	gold;
		if (!pSnap || !LoadImageRGBA((dirGold / (name + ".png")).string(), gold, &err)) {
			std::printf("  %s: %s\n", name.c_str(), err.c_str());
			continue;
		}
		SnapshotExportOptions	opts;
		opts.bDeferred = true;
		auto	pCG = RenderSnapshotExport(*pSnap, opts);
		ImageRGBA	cg = FromBGRA(pCG->GetPixels(), pCG->GetPixelWidth(), pCG->GetPixelHeight(), pCG->GetStride());
		bool	bMirror = pSnap->m_drawState.bMirror;
		auto	Crop = [bMirror](const ImageRGBA& im) {
			return bMirror ? CropImage(im, 0, 0, im.nWidth / 2, im.nHeight / 2) : im;
		};
		ImageRGBA	goldC = Crop(gold), cgC = Crop(cg);
		auto	Row = [&](const char *label, const ImageRGBA& mine, const char *suffix) {
			ImageRGBA	diff;
			ImageDiff	dw = CompareImages(goldC, Crop(mine), kThreshold, &diff);
			ImageDiff	dc = CompareImages(cgC, Crop(mine), kThreshold);
			bool	bPass = dw.bSameSize && dw.fMeanAbs <= kMaxMeanAbs && dw.fFracOver <= kMaxFracOver;
			std::printf("  %-28s %-16s mean %.3f, %.3f%% %s  mean %.3f, %.3f%%\n", name.c_str(), label,
				dw.fMeanAbs, dw.fFracOver * 100, bPass ? "ok  " : "FAIL", dc.fMeanAbs, dc.fFracOver * 100);
			SaveImageRGBA((dirOut / (name + suffix + ".png")).string(), mine);
			SaveImageRGBA((dirOut / (name + suffix + "-diff.png")).string(), diff);
		};
		Row("core graphics", cg, "-cg");
		if (getenv("SPIKE_WIDTHS")) {	// stroke widths the snapshot uses
			struct W : public IRenderer {
				std::map<int, int>	hist;	// width in 1/4 px -> count
				int	nCurved = 0, nFig = 0;
				void	SetAntialiasing(bool) override {}
				void	Clear(const ColorF&) override {}
				void	BeginPath() override {}
				void	AddFigure(const PointF*, int, bool c, bool) override { nFig++; nCurved += c; }
				void	EndPath() override {}
				void	FillPath(const ColorF&) override {}
				void	StrokePath(const ColorF&, float w) override { hist[int(std::lround(std::fabs(w) * 4))]++; }
				void	FillRect(const RectF&, const ColorF&) override {}
				bool	BeginQuadMirror() override { return true; }
				bool	EndQuadMirror() override { return true; }
			} wr;
			WhorldEngine	eng;
			PrepareSnapshotExport(eng, *pSnap, opts);
			eng.DrawCapture(wr, opts.nFlags, opts.szImage);
			std::printf("  %s: %d figures, %d curved; stroke widths (px):", name.c_str(), wr.nFig, wr.nCurved);
			for (auto& kv : wr.hist)
				std::printf(" %.2f:%d", kv.first / 4.0, kv.second);
			std::printf("\n");
			continue;
		}
		if (getenv("SPIKE_CPU")) {
			WhorldEngine	eng;
			IntSize	sz = PrepareSnapshotExport(eng, *pSnap, opts);
			CpuCoverageRenderer	cr(sz.cx, sz.cy, 1, fTol);
			eng.DrawCapture(cr, opts.nFlags, opts.szImage);
			Row("cpu coverage64", cr.Image(), "-cpu");
		}
		for (int nSamples : aSamples)
		for (int k : aSS) {
			WhorldEngine	eng;
			IntSize	sz = PrepareSnapshotExport(eng, *pSnap, opts);
			MetalRenderer	mr(sz.cx * k, sz.cy * k, k, nSamples);
			if (!mr.IsValid()) {
				std::printf("  no Metal device\n");
				return;
			}
			mr.SetTolerance(fTol);
			mr.BeginFrame();
			eng.DrawCapture(mr, opts.nFlags, opts.szImage);
			mr.EndFrame();
			ImageRGBA	img = MetalImage(mr);
			if (k > 1)
				img = Downsample(img, k);
			char	label[32], suffix[32];
			if (nSamples) std::snprintf(label, sizeof(label), "metal %dx ss%d", nSamples, k); else std::snprintf(label, sizeof(label), "metal coverage");
			std::snprintf(suffix, sizeof(suffix), "-metal%d-ss%d", nSamples, k);
			Row(label, img, suffix);
		}
	}
	std::printf("  images: %s\n\n", dirOut.string().c_str());
}


struct Timing {
	double	fSum = 0, fMax = 0;
	int		n = 0;
	void	Add(double f) { fSum += f; fMax = std::max(fMax, f); n++; }
	double	Mean() const { return n ? fSum / n : 0; }
};

void Perf(const std::vector<std::string>& aPatch, const std::vector<int>& aSamples, float fTol,
	IntSize sz, double fScale, int nWarm, int nFrames, const fs::path& dirOut)
{
	std::printf("Performance at %dx%d px, scale %g: %d warm-up frames, then %d timed (ms per frame)\n",
		sz.cx, sz.cy, fScale, nWarm, nFrames);
	std::printf("  %-22s %-10s %-11s %-11s %-11s %-11s %-9s %s\n", "patch", "renderer", "CPU tess",
		"CPU encode", "GPU", "CG total", "vertices", "Metal vs CG (last frame)");
	for (const std::string& name : aPatch) {
		fs::path	path = fs::path(WHORLD_TESTDATA_DIR) / "patches" / (name + ".whp");
		Patch	patch;
		std::string	err;
		if (!patch.Read(path.string(), &err)) {
			std::printf("  %s: %s\n", name.c_str(), err.c_str());
			continue;
		}
		// Core Graphics, deferred (the app's current renderer)
		Timing	tCG;
		CGBitmapRenderer	cgr(sz.cx, sz.cy, fScale);
		cgr.SetDeferred(true);
		{
			WhorldEngine	eng;
			eng.SetFrameRate(60);
			eng.OnResize(cgr.GetSizeDIPs());
			eng.OnSetPatch(patch);
			for (int i = 0; i < nWarm + nFrames; i++) {
				if (g_nAA >= 0)
					SetAA(eng, g_nAA != 0);
				auto	t0 = std::chrono::steady_clock::now();
				cgr.BeginFrame();
				eng.Draw(cgr);
				cgr.EndFrame();
				if (i >= nWarm)
					tCG.Add(Ms(t0));
			}
		}
		ImageRGBA	cg = FromBGRA(cgr.GetPixels(), cgr.GetPixelWidth(), cgr.GetPixelHeight(), cgr.GetStride());
		for (int nSamples : aSamples) {
			MetalRenderer	mr(sz.cx, sz.cy, fScale, nSamples);
			if (!mr.IsValid())
				return;
			mr.SetTolerance(fTol);
			WhorldEngine	eng;
			eng.SetFrameRate(60);
			eng.OnResize(mr.GetSizeDIPs());
			eng.OnSetPatch(patch);
			Timing	tTess, tEnc, tGpu;
			size_t	nVertMax = 0;
			for (int i = 0; i < nWarm + nFrames; i++) {
				if (g_nAA >= 0)
					SetAA(eng, g_nAA != 0);
				mr.BeginFrame();
				eng.Draw(mr);
				mr.EndFrame();
				mr.WaitUntilDone();
				if (i >= nWarm) {
					const MetalRenderer::Stats&	st = mr.GetStats();
					tTess.Add(st.fTessMs);
					tEnc.Add(st.fEncodeMs);
					tGpu.Add(st.fGpuMs);
					nVertMax = std::max(nVertMax, st.nVertices);
				}
			}
			if (getenv("WHORLD_MTL_PROFILE")) {
				const auto&	p = mr.GetStats().prof;
				const double	fScreen = double(sz.cx) * sz.cy;
				const char	*aName[3] = {"fill", "stroke", "rect"};
				for (int t = 0; t < 3; t++) {
					if (p.nOps[t])
						std::printf("    %-6s ops %5zu  tris %8zu  area %6.2f screens  rasterized %6.2f screens per draw\n",
							aName[t], p.nOps[t], p.nTris[t], p.fArea[t] / fScreen, p.fPx[t] / fScreen);
				}
				std::printf("    box tris %zu, draws %zu\n", p.nBoxTris, mr.GetStats().nDraws);
				uint32_t	aCnt[7];
				if (mr.GetFragmentCounts(aCnt)) {
					const char	*aCat[7] = {"degenerate", "outside", "full", "1 edge", "2 edges", "3 edges", "empty after loop"};
					double	fTot = 0;
					for (uint32_t c : aCnt) fTot += c;
					std::printf("    mask fragments %.2f screens:", fTot / fScreen);
					for (int i = 0; i < 7; i++)
						std::printf(" %s %.0f%%", aCat[i], fTot ? 100 * aCnt[i] / fTot : 0);
					std::printf("\n");
				}
			}
			ImageRGBA	img = MetalImage(mr);
			ImageDiff	d = CompareImages(cg, img, kThreshold);
			char	label[16], cell[4][32];
			if (nSamples) std::snprintf(label, sizeof(label), "metal %dx", nSamples); else std::snprintf(label, sizeof(label), "metal cov");
			std::snprintf(cell[0], 32, "%.2f/%.2f", tTess.Mean(), tTess.fMax);
			std::snprintf(cell[1], 32, "%.2f/%.2f", tEnc.Mean(), tEnc.fMax);
			std::snprintf(cell[2], 32, "%.2f/%.2f", tGpu.Mean(), tGpu.fMax);
			std::snprintf(cell[3], 32, "%.2f/%.2f", tCG.Mean(), tCG.fMax);
			std::printf("  %-22s %-10s %-11s %-11s %-11s %-11s %-9zu mean %.3f, %.3f%% over\n", name.c_str(),
				label, cell[0], cell[1], cell[2], cell[3], nVertMax, d.fMeanAbs, d.fFracOver * 100);
			SaveImageRGBA((dirOut / (name + "-perf-metal" + std::to_string(nSamples) + ".png")).string(), img);
		}
		SaveImageRGBA((dirOut / (name + "-perf-cg.png")).string(), cg);
	}
	std::printf("  (mean/max; Metal timings are serial here: the app would overlap CPU and GPU)\n");
}

} // namespace

int main(int argc, char **argv)
{
	std::vector<int>	aSamples = {4};
	std::vector<int>	aSS = {1};
	float	fTol = 0.1f;
	bool	bGolden = true, bPerf = true;
	std::vector<std::string>	aPatch = {"default_cvx", "saturn_cvx", "fish eye_cvx", "bloom_cvx",
		"typhoon_cvx", "boomer_cvx"};
	int		nWarm = 300, nFrames = 120;
	IntSize	sz = {3024, 1964};
	double	fScale = 2;
	for (int i = 1; i < argc; i++) {
		const char	*a = argv[i];
		const char	*v = i + 1 < argc ? argv[i + 1] : "";
		if (!std::strcmp(a, "--samples")) {
			aSamples.clear();
			for (auto& s : Split(v))
				aSamples.push_back(std::atoi(s.c_str()));
			i++;
		} else if (!std::strcmp(a, "--ss")) {
			aSS.clear();
			for (auto& s : Split(v))
				aSS.push_back(std::atoi(s.c_str()));
			i++;
		} else if (!std::strcmp(a, "--tol")) {
			fTol = float(std::atof(v));
			i++;
		} else if (!std::strcmp(a, "--aa")) {
			g_nAA = std::atoi(v);
			i++;
		} else if (!std::strcmp(a, "--no-golden")) {
			bGolden = false;
		} else if (!std::strcmp(a, "--no-perf")) {
			bPerf = false;
		} else if (!std::strcmp(a, "--patches")) {
			aPatch = Split(v);
			i++;
		} else if (!std::strcmp(a, "--warm")) {
			nWarm = std::atoi(v);
			i++;
		} else if (!std::strcmp(a, "--frames")) {
			nFrames = std::atoi(v);
			i++;
		} else if (!std::strcmp(a, "--size")) {
			std::sscanf(v, "%dx%d", &sz.cx, &sz.cy);
			i++;
		} else if (!std::strcmp(a, "--scale")) {
			fScale = std::atof(v);
			i++;
		} else {
			std::fprintf(stderr, "unknown option %s\n", a);
			return 1;
		}
	}
	fs::path	dirOut = fs::temp_directory_path() / "whorld_spike";
	fs::create_directories(dirOut);
	std::printf("Flattening tolerance %.3f px\n\n", fTol);
	if (bGolden)
		Golden(aSamples, aSS, fTol, dirOut);
	if (bPerf)
		Perf(aPatch, aSamples, fTol, sz, fScale, nWarm, nFrames, dirOut);
	return 0;
}
