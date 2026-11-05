// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
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

#include "ImageCompare.h"
#include "RenderJobs.h"
#include "VideoWriter.h"
#include "whorld/WhorldEngine.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

using namespace whorld;

namespace {

int Usage()
{
	std::fprintf(stderr,
		"usage:\n"
		"  whorld-render <patch.whp> [--frames N] [--size WxH] [--scale S] [--deferred] --out frame.png\n"
		"  whorld-render <snapshot.whs> [--size WxH] [--view WxH] [--fit none|width|height|both]\n"
		"                [--use-view-size] [--no-letterbox] --out frame.png\n"
		"  whorld-render --compare a.png b.png [--threshold T] [--diff diff.png] [--region X,Y,W,H]\n"
		"  whorld-render <movie.whm> [--size WxH] [--fit ...] [--use-view-size] [--start N] [--end N]\n"
		"                --video out.mov [--codec h264|hevc|prores|prores4444]   (or --frame N --out frame.png)\n");
	return 2;
}

bool ParseSize(const char* psz, int& w, int& h)
{
	return std::sscanf(psz, "%dx%d", &w, &h) == 2 && w > 0 && h > 0;
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
	std::string	sVideo;
	VideoWriter::Codec	codec = VideoWriter::CODEC_H264;
	long long	nStart = 0, nEnd = -1, nFrame = -1;
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
		else
			return Usage();
	}
	std::string	err;
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
