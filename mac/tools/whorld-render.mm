// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// whorld-render: render a patch or snapshot to a PNG without the app.
//
//   whorld-render <patch.whp> [--frames N] [--size WxH] [--scale S] --out frame.png
//   whorld-render <snapshot.whs> [--size WxH] [--view WxH] [--fit none|width|height|both]
//                 [--use-view-size] [--no-letterbox] --out frame.png
//   whorld-render --compare a.png b.png [--threshold T] [--diff diff.png] [--region X,Y,W,H]

#include "AudioVideoExport.h"
#include "ImageCompare.h"
#include "MetalRenderer.h"
#include "RenderJobs.h"
#include "VideoWriter.h"
#include "whorld/WhorldEngine.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <vector>
#include <string>

using namespace whorld;

namespace {

int Usage()
{
	std::fprintf(stderr,
		"usage:\n"
		"  whorld-render <patch.whp> [--frames N] [--size WxH] [--scale S] [--deferred]\n"
		"                [--ring-fade N [--eased]] [--antialias 0|1] [--metal] --out frame.png\n"
		"  whorld-render <snapshot.whs> [--size WxH] [--view WxH] [--fit none|width|height|both]\n"
		"                [--use-view-size] [--no-letterbox] [--metal] --out frame.png\n"
		"  whorld-render <snapshot.whs> --as-shown [--size WxH] [--antialias 0|1] [--metal] --out frame.png\n"
		"  (--as-shown: as the window shows it, --size being the view, with antialiasing as\n"
		"   set (default on), unlike an export, which always antialiases; --metal: drawn with Metal)\n"
		"  whorld-render --compare a.png b.png [--threshold T] [--diff diff.png] [--region X,Y,W,H]\n"
		"  whorld-render <movie.whm> [--size WxH] [--fit ...] [--use-view-size] [--start N] [--end N]\n"
		"                --video out.mov [--codec h264|hevc|prores|prores4444] [--cg]   (or --frame N --out frame.png)\n"
		"  whorld-render <patch.whp> --audio music.mp3 --video out.mov [--size WxH] [--fps N] [--codec ...]\n"
		"                [--mod modulation.json] [--audio-start S] [--duration S] [--preroll S]\n"
		"                [--tempo BPM] [--downbeat S] [--gain dB] [--range dB] [--auto-level] [--hits T] [--cg]\n"
		"  (videos are drawn with Metal where this Mac can; --cg draws them with Core Graphics)\n");
	return 2;
}

bool ParseSize(const char* psz, int& w, int& h)
{
	return std::sscanf(psz, "%dx%d", &w, &h) == 2 && w > 0 && h > 0;
}

// A frame drawn by fnDraw, written as a PNG: by Metal (coverage mode, as
// the app's view and exports) or by Core Graphics
bool DrawPNG(int w, int h, double fScale, bool bMetal, bool bDeferred,
	const std::function<void(IRenderer&)>& fnDraw, const std::string& sOut, std::string& err)
{
	if (bMetal) {
		MetalRenderer	r(w, h, fScale, 0);
		if (!r.IsValid()) {
			err = "Metal isn't available on this Mac";
			return false;
		}
		r.BeginFrame();
		fnDraw(r);
		r.EndFrame();
		std::vector<uint8_t>	aPixel;
		size_t	nStride = 0;
		if (!r.ReadPixels(aPixel, nStride)) {
			err = "can't read the Metal frame";
			return false;
		}
		CGBitmapRenderer	png(aPixel.data(), w, h, nStride, fScale);
		return png.WritePNG(sOut, &err);
	}
	CGBitmapRenderer	r(w, h, fScale);
	if (!r.IsValid()) {
		err = "can't create the image";
		return false;
	}
	r.SetDeferred(bDeferred);
	r.BeginFrame();
	fnDraw(r);
	r.EndFrame();
	return r.WritePNG(sOut, &err);
}

// the Antialiasing property, as the Properties checkbox sets it
void SetAntialias(WhorldEngine& eng, bool bOn)
{
	WhorldBase::VARIANT_PROP	prop;
	prop.llVal = 0;
	prop.boolVal = bOn;
	eng.OnSetMainProp(WhorldBase::MAIN_Antialiasing, prop);
}

bool EndsWith(const std::string& s, const char* pszSuffix)
{
	size_t	n = std::strlen(pszSuffix);
	return s.size() >= n && s.compare(s.size() - n, n, pszSuffix) == 0;
}

int Compare(int argc, char** argv)
{
	if (argc < 4)
		return Usage();
	int	nThreshold = 32;
	const char*	pszDiff = nullptr;
	int	rx = 0, ry = 0, rw = 0, rh = 0;
	for (int i = 4; i < argc; i++) {
		if (!std::strcmp(argv[i], "--threshold") && i + 1 < argc)
			nThreshold = std::atoi(argv[++i]);
		else if (!std::strcmp(argv[i], "--diff") && i + 1 < argc)
			pszDiff = argv[++i];
		else if (!std::strcmp(argv[i], "--region") && i + 1 < argc) {
			if (std::sscanf(argv[++i], "%d,%d,%d,%d", &rx, &ry, &rw, &rh) != 4)
				return Usage();
		}
		else
			return Usage();
	}
	ImageRGBA	a, b, diff;
	std::string	err;
	if (!LoadImageRGBA(argv[2], a, &err) || !LoadImageRGBA(argv[3], b, &err)) {
		std::fprintf(stderr, "%s\n", err.c_str());
		return 1;
	}
	if (rw > 0 && rh > 0) {	// compare a region only
		a = CropImage(a, rx, ry, rw, rh);
		b = CropImage(b, rx, ry, rw, rh);
	}
	ImageDiff	d = CompareImages(a, b, nThreshold, pszDiff ? &diff : nullptr);
	if (!d.bSameSize) {
		std::fprintf(stderr, "sizes differ: %dx%d vs %dx%d\n", a.nWidth, a.nHeight, b.nWidth, b.nHeight);
		return 1;
	}
	std::printf("mean abs diff %.3f, max %d, %.4f%% of pixels over %d\n",
		d.fMeanAbs, d.nMaxDiff, d.fFracOver * 100, nThreshold);
	if (pszDiff && !SaveImageRGBA(pszDiff, diff, &err))
		std::fprintf(stderr, "%s\n", err.c_str());
	return 0;
}

} // namespace

int main(int argc, char** argv)
{
	if (argc < 2)
		return Usage();
	if (!std::strcmp(argv[1], "--compare"))
		return Compare(argc, argv);
	std::string	sIn = argv[1];
	std::string	sOut;
	int	w = 1024, h = 768, vw = 0, vh = 0, nFrames = 300;
	double	fScale = 1;
	uint32_t	nFlags = 0;
	bool	bLetterbox = true;
	bool	bDeferred = false;
	bool	bMetal = true;	// videos: Metal where it can
	bool	bMetalPNG = false;	// --metal: PNGs drawn with Metal
	bool	bAsShown = false;
	int		nAntialias = -1;	// -1: the patch's own (or on, as shown)
	int		nRingFade = 0;
	bool	bRingFadeEased = false;
	std::string	sVideo;
	VideoWriter::Codec	codec = VideoWriter::CODEC_H264;
	long long	nStart = 0, nEnd = -1, nFrame = -1;
	std::string	sAudio, sMod;
	AudioVideoOptions	av;
	bool	bSizeSet = false;
	bool	bRangeSet = false;
	for (int i = 2; i < argc; i++) {
		const char*	a = argv[i];
		bool	bHasArg = i + 1 < argc;
		if (!std::strcmp(a, "--out") && bHasArg)
			sOut = argv[++i];
		else if (!std::strcmp(a, "--frames") && bHasArg)
			nFrames = std::atoi(argv[++i]);
		else if (!std::strcmp(a, "--size") && bHasArg) {
			if (!ParseSize(argv[++i], w, h))
				return Usage();
		} else if (!std::strcmp(a, "--view") && bHasArg) {
			if (!ParseSize(argv[++i], vw, vh))
				return Usage();
		} else if (!std::strcmp(a, "--scale") && bHasArg)
			fScale = std::atof(argv[++i]);
		else if (!std::strcmp(a, "--fit") && bHasArg) {
			std::string	s = argv[++i];
			nFlags &= ~uint32_t(WhorldBase::EF_SCALE_FIT_BOTH);
			if (s == "width")
				nFlags |= WhorldBase::EF_SCALE_FIT_WIDTH;
			else if (s == "height")
				nFlags |= WhorldBase::EF_SCALE_FIT_HEIGHT;
			else if (s == "both")
				nFlags |= WhorldBase::EF_SCALE_FIT_BOTH;
			else if (s != "none")
				return Usage();
		} else if (!std::strcmp(a, "--use-view-size"))
			nFlags |= WhorldBase::EF_USE_VIEW_SIZE;
		else if (!std::strcmp(a, "--no-letterbox"))
			bLetterbox = false;
		else if (!std::strcmp(a, "--deferred"))
			bDeferred = true;
		else if (!std::strcmp(a, "--cg"))
			bMetal = false;
		else if (!std::strcmp(a, "--metal"))
			bMetalPNG = true;
		else if (!std::strcmp(a, "--as-shown"))
			bAsShown = true;
		else if (!std::strcmp(a, "--antialias") && bHasArg)
			nAntialias = std::atoi(argv[++i]) != 0;
		else if (!std::strcmp(a, "--ring-fade") && bHasArg)
			nRingFade = std::atoi(argv[++i]);
		else if (!std::strcmp(a, "--eased"))
			bRingFadeEased = true;
		else if (!std::strcmp(a, "--video") && bHasArg)
			sVideo = argv[++i];
		else if (!std::strcmp(a, "--codec") && bHasArg) {
			std::string	c = argv[++i];
			if (c == "h264")
				codec = VideoWriter::CODEC_H264;
			else if (c == "hevc")
				codec = VideoWriter::CODEC_HEVC;
			else if (c == "prores")
				codec = VideoWriter::CODEC_PRORES_422;
			else if (c == "prores4444")
				codec = VideoWriter::CODEC_PRORES_4444;
			else
				return Usage();
		} else if (!std::strcmp(a, "--start") && bHasArg)
			nStart = std::atoll(argv[++i]);
		else if (!std::strcmp(a, "--end") && bHasArg)
			nEnd = std::atoll(argv[++i]);
		else if (!std::strcmp(a, "--frame") && bHasArg)
			nFrame = std::atoll(argv[++i]);
		else if (!std::strcmp(a, "--audio") && bHasArg)
			sAudio = argv[++i];
		else if (!std::strcmp(a, "--mod") && bHasArg)
			sMod = argv[++i];
		else if (!std::strcmp(a, "--fps") && bHasArg)
			av.fFrameRate = std::atof(argv[++i]);
		else if (!std::strcmp(a, "--audio-start") && bHasArg)
			av.fStart = std::atof(argv[++i]);
		else if (!std::strcmp(a, "--duration") && bHasArg)
			av.fDuration = std::atof(argv[++i]);
		else if (!std::strcmp(a, "--preroll") && bHasArg)
			av.fPreroll = std::atof(argv[++i]);
		else if (!std::strcmp(a, "--tempo") && bHasArg)
			av.fTempo = std::atof(argv[++i]);
		else if (!std::strcmp(a, "--downbeat") && bHasArg)
			av.fDownbeat = std::atof(argv[++i]);
		else if (!std::strcmp(a, "--gain") && bHasArg)
			av.analyzer.fGainDb = std::atof(argv[++i]);
		else if (!std::strcmp(a, "--range") && bHasArg)
			av.analyzer.fFloorDb = -std::max(std::atof(argv[++i]), 6.0), bRangeSet = true;
		else if (!std::strcmp(a, "--auto-level"))
			av.analyzer.bAutoLevel = true;
		else if (!std::strcmp(a, "--hits") && bHasArg)
			av.analyzer.fHitThreshold = std::atof(argv[++i]);
		else
			return Usage();
		if (!std::strcmp(a, "--size"))
			bSizeSet = true;
	}
	std::string	err;
	if (!sAudio.empty()) {	// audio-reactive video (9.9)
		if (sVideo.empty() || !EndsWith(sIn, ".whp"))
			return Usage();
		Patch	patch;
		if (!patch.Read(sIn, &err)) {
			std::fprintf(stderr, "%s: %s\n", sIn.c_str(), err.c_str());
			return 1;
		}
		av.analyzer.fCeilDb = 0;
		if (!bRangeSet)
			av.analyzer.fFloorDb = -36;	// the app's default range
		if (!sMod.empty() && !ReadModulationFile(sMod, av, &err)) {
			std::fprintf(stderr, "%s: %s\n", sMod.c_str(), err.c_str());
			return 1;
		}
		av.codec = codec;
		av.bMetal = bMetal;
		av.nWidth = bSizeSet ? w : 1920;
		av.nHeight = bSizeSet ? h : 1080;
		av.bRingFadeEased = bRingFadeEased;
		int	nLast = -1;
		bool	bOk = ExportAudioReactiveVideo(patch, sAudio, sVideo, av, [&](int64_t nDone, int64_t nTotal) {
			int	nPct = static_cast<int>(nDone * 100 / nTotal);
			if (nPct != nLast) {
				std::fprintf(stderr, "\r%d%%", nPct);
				nLast = nPct;
			}
			return true;
		}, &err);
		std::fprintf(stderr, "\n");
		if (!bOk) {
			std::fprintf(stderr, "%s\n", err.c_str());
			return 1;
		}
		return 0;
	}
	if (EndsWith(sIn, ".whm")) {	// movie: video, or one frame as PNG
		if (sVideo.empty() && (nFrame < 0 || sOut.empty()))
			return Usage();
		WhorldEngine	eng;
		eng.OnResize(SizeF{float(vw > 0 ? vw : w), float(vh > 0 ? vh : h)});
		eng.SetSnapshotLetterbox(bLetterbox);
		eng.OnMoviePlay(&sIn, true);	// paused
		if (eng.GetMovieState().nIOState != SnapMovie::IO_READ) {
			std::fprintf(stderr, "%s: can't open movie\n", sIn.c_str());
			return 1;
		}
		if (!sVideo.empty()) {
			VideoExportOptions	opts;
			opts.codec = codec;
			opts.bMetal = bMetal;
			opts.nFlags = nFlags;
			opts.szImage = IntSize{w, h};
			opts.nStartFrame = nStart;
			opts.nEndFrame = nEnd;
			if (!ExportMovieVideo(eng, sVideo, opts, nullptr, &err)) {
				std::fprintf(stderr, "%s\n", err.c_str());
				return 1;
			}
			return 0;
		}
		if (!eng.MovieExportStart(nFrame) || !eng.MovieExportStep()) {
			std::fprintf(stderr, "can't read frame %lld\n", nFrame);
			return 1;
		}
		IntSize	sz = eng.GetCaptureSize(nFlags, IntSize{w, h});
		CGBitmapRenderer	r(sz.cx, sz.cy, 1);
		r.SetDeferred(bDeferred);
		r.BeginFrame();
		eng.DrawCapture(r, nFlags, IntSize{w, h});
		r.EndFrame();
		if (!r.WritePNG(sOut, &err)) {
			std::fprintf(stderr, "%s\n", err.c_str());
			return 1;
		}
		return 0;
	}
	if (sOut.empty() || !(fScale > 0) || nFrames < 1)
		return Usage();
	if (bAsShown || bMetalPNG || nAntialias >= 0) {	// drawn here, by either renderer
		WhorldEngine	eng;
		std::function<void(IRenderer&)>	fnDraw;
		int	cx = w, cy = h;
		double	fPixelScale = fScale;
		if (EndsWith(sIn, ".whs")) {
			auto	pSnapshot = Snapshot::Read(sIn, &err);
			if (!pSnapshot) {
				std::fprintf(stderr, "%s: %s\n", sIn.c_str(), err.c_str());
				return 1;
			}
			if (bAsShown) {	// the view, paused on the snapshot (CWhorldDraw::SetSnapshot)
				eng.OnResize(SizeF{float(w / fScale), float(h / fScale)});
				eng.SetSnapshotLetterbox(bLetterbox);
				eng.OnDisplaySnapshot(*pSnapshot);
				SetAntialias(eng, nAntialias != 0);
				fnDraw = [&eng](IRenderer& r) { eng.Draw(r); };
			} else {	// an export (antialiased, as Windows' Export)
				SnapshotExportOptions	opts;
				opts.szImage = IntSize{w, h};
				opts.nFlags = nFlags;
				opts.szView = SizeF{float(vw), float(vh)};
				opts.bLetterbox = bLetterbox;
				IntSize	sz = PrepareSnapshotExport(eng, *pSnapshot, opts);
				cx = sz.cx;
				cy = sz.cy;
				fPixelScale = 1;
				fnDraw = [&eng, nFlags, w, h](IRenderer& r) { eng.DrawCapture(r, nFlags, IntSize{w, h}); };
			}
		} else {	// a patch, run for nFrames (RenderPatch), the last drawn
			Patch	patch;
			if (!patch.Read(sIn, &err)) {
				std::fprintf(stderr, "%s: %s\n", sIn.c_str(), err.c_str());
				return 1;
			}
			if (nRingFade > 0)
				patch.m_master.fFade = nRingFade;
			eng.SetFrameRate(60);
			eng.SetRingFadeEased(bRingFadeEased);
			eng.OnResize(SizeF{float(w / fScale), float(h / fScale)});
			eng.OnSetPatch(patch);
			if (nAntialias >= 0)
				SetAntialias(eng, nAntialias != 0);
			CGBitmapRenderer	scratch(16, 16, 1);	// the frames before, not kept
			for (int i = 0; i < nFrames - 1; i++) {
				scratch.BeginFrame();
				eng.Draw(scratch);
				scratch.EndFrame();
			}
			fnDraw = [&eng](IRenderer& r) { eng.Draw(r); };
		}
		if (!DrawPNG(cx, cy, fPixelScale, bMetalPNG, bDeferred, fnDraw, sOut, err)) {
			std::fprintf(stderr, "%s\n", err.c_str());
			return 1;
		}
		return 0;
	}
	std::unique_ptr<CGBitmapRenderer>	pRenderer;
	if (EndsWith(sIn, ".whs")) {
		auto	pSnapshot = Snapshot::Read(sIn, &err);
		if (!pSnapshot) {
			std::fprintf(stderr, "%s: %s\n", sIn.c_str(), err.c_str());
			return 1;
		}
		SnapshotExportOptions	opts;
		opts.szImage = IntSize{w, h};
		opts.nFlags = nFlags;
		opts.szView = SizeF{float(vw), float(vh)};
		opts.bLetterbox = bLetterbox;
		opts.bDeferred = bDeferred;
		pRenderer = RenderSnapshotExport(*pSnapshot, opts);
	} else {
		Patch	patch;
		if (!patch.Read(sIn, &err)) {
			std::fprintf(stderr, "%s: %s\n", sIn.c_str(), err.c_str());
			return 1;
		}
		PatchRenderOptions	opts;
		opts.szImage = IntSize{w, h};
		opts.fScale = fScale;
		opts.nFrames = nFrames;
		opts.bDeferred = bDeferred;
		opts.nRingFade = nRingFade;
		opts.bRingFadeEased = bRingFadeEased;
		pRenderer = RenderPatch(patch, opts);
	}
	if (!pRenderer) {
		std::fprintf(stderr, "rendering failed\n");
		return 1;
	}
	if (!pRenderer->WritePNG(sOut, &err)) {
		std::fprintf(stderr, "%s\n", err.c_str());
		return 1;
	}
	return 0;
}
