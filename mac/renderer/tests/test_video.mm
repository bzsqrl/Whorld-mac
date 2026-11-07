// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Tests for video export: encode part of the sample movie, read it back
// with AVFoundation, and compare a decoded frame with the same movie frame
// rendered directly.

#include "ImageCompare.h"
#include "TestHarness.h"
#include "VideoWriter.h"

#import <AVFoundation/AVFoundation.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>

using namespace whorld;
namespace fs = std::filesystem;

namespace {

fs::path SampleMovie()
{
	return fs::path(WHORLD_TESTDATA_DIR) / "movies" / "kaleid_cvx.whm";
}

struct VideoInfo {
	int		nWidth = 0;
	int		nHeight = 0;
	int		nFrames = 0;
	double	fFrameRate = 0;
	double	fDuration = 0;
	ImageRGBA	frame;	// decoded frame at the requested index
};

// Reads every frame of a video, keeping one as RGBA.
bool ReadVideo(const fs::path& path, int iKeep, VideoInfo& info)
{
	AVURLAsset	*asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(path.c_str())] options:nil];
	NSArray	*tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
	if (tracks.count != 1)
		return false;
	AVAssetTrack	*track = tracks[0];
	info.nWidth = (int)track.naturalSize.width;
	info.nHeight = (int)track.naturalSize.height;
	info.fFrameRate = track.nominalFrameRate;
	info.fDuration = CMTimeGetSeconds(asset.duration);
	NSError	*err = nil;
	AVAssetReader	*reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
	AVAssetReaderTrackOutput	*out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
		outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
	[reader addOutput:out];
	if (![reader startReading])
		return false;
	while (CMSampleBufferRef sample = [out copyNextSampleBuffer]) {
		if (info.nFrames == iKeep) {
			CVPixelBufferRef	pb = CMSampleBufferGetImageBuffer(sample);
			CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
			info.frame = FromBGRA(static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(pb)),
				(int)CVPixelBufferGetWidth(pb), (int)CVPixelBufferGetHeight(pb), CVPixelBufferGetBytesPerRow(pb));
			CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
		}
		info.nFrames++;
		CFRelease(sample);
	}
	return reader.status == AVAssetReaderStatusCompleted;
}

// Mean absolute RGB difference over flat areas: pixels whose 3x3
// neighborhood in the reference is one color. Away from edges, chroma
// subsampling doesn't apply, so this measures the color conversion itself.
double FlatAreaError(const ImageRGBA& ref, const ImageRGBA& img, int& nFlat)
{
	double	fSum = 0;
	nFlat = 0;
	auto	At = [&ref](int x, int y) { return &ref.aPixel[(size_t(y) * ref.nWidth + x) * 4]; };
	for (int y = 1; y < ref.nHeight - 1; y++) {
		for (int x = 1; x < ref.nWidth - 1; x++) {
			const uint8_t	*c = At(x, y);
			bool	bFlat = true;
			for (int dy = -1; dy <= 1 && bFlat; dy++)
				for (int dx = -1; dx <= 1 && bFlat; dx++)
					bFlat = std::memcmp(At(x + dx, y + dy), c, 3) == 0;
			if (!bFlat)
				continue;
			const uint8_t	*d = &img.aPixel[(size_t(y) * img.nWidth + x) * 4];
			fSum += (std::abs(int(c[0]) - d[0]) + std::abs(int(c[1]) - d[1]) + std::abs(int(c[2]) - d[2])) / 3.0;
			nFlat++;
		}
	}
	return nFlat ? fSum / nFlat : 0;
}

// Renders one movie frame the same way the exporter does.
ImageRGBA RenderMovieFrame(int64_t iFrame, IntSize sz, uint32_t nFlags)
{
	WhorldEngine	eng;
	eng.OnResize(SizeF{float(sz.cx), float(sz.cy)});
	std::string	sPath = SampleMovie().string();
	eng.OnMoviePlay(&sPath, true);
	eng.MovieExportStart(iFrame);
	eng.MovieExportStep();
	CGBitmapRenderer	r(sz.cx, sz.cy, 1);
	r.SetDeferred(true);
	r.BeginFrame();
	eng.DrawCapture(r, nFlags, sz);
	r.EndFrame();
	return FromBGRA(r.GetPixels(), sz.cx, sz.cy, r.GetStride());
}

void ExportAndCheck(VideoWriter::Codec codec, double fMaxMean, double fMaxFlat)
{
	fs::path	out = fs::temp_directory_path() / (std::string("whorld_test_") + VideoWriter::CodecName(codec) + ".mov");
	WhorldEngine	eng;
	eng.OnResize(SizeF{512, 384});
	std::string	sPath = SampleMovie().string();
	eng.OnMoviePlay(&sPath, true);
	VideoExportOptions	opts;
	opts.codec = codec;
	opts.nFlags = WhorldBase::EF_SCALE_FIT_BOTH;
	opts.szImage = IntSize{512, 384};
	opts.nStartFrame = 100;
	opts.nEndFrame = 159;
	int64_t	nLast = 0;
	std::string	err;
	bool	bOk = ExportMovieVideo(eng, out.string(), opts, [&](int64_t n, int64_t) { nLast = n; return true; }, &err);
	if (!bOk)
		std::fprintf(stderr, "  %s: %s\n", VideoWriter::CodecName(codec), err.c_str());
	CHECK(bOk);
	CHECK_EQ(nLast, int64_t(60));
	VideoInfo	info;
	CHECK(ReadVideo(out, 30, info));
	CHECK_EQ(info.nFrames, 60);
	CHECK_EQ(info.nWidth, 512);
	CHECK_EQ(info.nHeight, 384);
	CHECK_NEAR(info.fFrameRate, 144, 0.5);	// the movie's rate
	CHECK_NEAR(info.fDuration, 60 / 144.0, 1e-3);
	ImageRGBA	ref = RenderMovieFrame(130, IntSize{512, 384}, WhorldBase::EF_SCALE_FIT_BOTH);
	ImageDiff	d = CompareImages(ref, info.frame, 32);
	int	nFlat = 0;
	double	fFlat = d.bSameSize ? FlatAreaError(ref, info.frame, nFlat) : 99;
	std::printf("  %s: 60 frames, 512x384, %.0f fps; frame 130 vs direct render: mean %.2f, "
		"%.2f%% over 32; flat areas %.2f (%d px)\n",
		VideoWriter::CodecName(codec), info.fFrameRate, d.fMeanAbs, d.fFracOver * 100, fFlat, nFlat);
	CHECK(d.bSameSize);
	// Colors must be right away from edges: this checks our color tagging
	// and pixel format, which we control. Overall error also depends on the
	// encoder, which differs between machines (hardware on a Mac, software
	// on CI runners: H.264 measured mean 5.4 on an M1 Max, 8.0 on CI), so
	// lossy formats only get a loose bound; ProRes 4444 a tight one.
	CHECK(fFlat <= fMaxFlat);
	CHECK(d.fMeanAbs <= fMaxMean);
	fs::remove(out);
}

} // namespace

TEST(H264Export) {
	if (!fs::exists(SampleMovie()))
		return;
	ExportAndCheck(VideoWriter::CODEC_H264, 12, 2);
}

TEST(ProResExport) {
	if (!fs::exists(SampleMovie()))
		return;
	ExportAndCheck(VideoWriter::CODEC_PRORES_422, 12, 1.5);
}

TEST(ProRes4444Export) {
	if (!fs::exists(SampleMovie()))
		return;
	ExportAndCheck(VideoWriter::CODEC_PRORES_4444, 2, 1);
}

TEST(HevcExport) {
	if (!fs::exists(SampleMovie()))
		return;
	ExportAndCheck(VideoWriter::CODEC_HEVC, 12, 2);
}

TEST(OddSizeIsRoundedDown) {
	fs::path	out = fs::temp_directory_path() / "whorld_test_odd.mov";
	VideoWriter	w;
	std::string	err;
	CHECK(w.Open(out.string(), 321, 241, 30, VideoWriter::CODEC_H264, &err));
	CHECK_EQ(w.GetWidth(), 320);
	CHECK_EQ(w.GetHeight(), 240);
	for (int i = 0; i < 3; i++) {
		CGBitmapRenderer	*r = w.BeginFrame();
		CHECK(r != nullptr);
		if (!r)
			break;
		r->BeginFrame();
		r->Clear(ColorF{1, 0, 0, 1});
		r->EndFrame();
		CHECK(w.EndFrame(&err));
	}
	CHECK(w.Close(&err));
	VideoInfo	info;
	CHECK(ReadVideo(out, 1, info));
	CHECK_EQ(info.nFrames, 3);
	CHECK(info.frame.aPixel.size() > 0 && info.frame.aPixel[0] > 200 && info.frame.aPixel[1] < 40);	// red
	fs::remove(out);
}

TEST(CancelDeletesFile) {
	if (!fs::exists(SampleMovie()))
		return;
	fs::path	out = fs::temp_directory_path() / "whorld_test_cancel.mov";
	WhorldEngine	eng;
	eng.OnResize(SizeF{320, 240});
	std::string	sPath = SampleMovie().string();
	eng.OnMoviePlay(&sPath, true);
	VideoExportOptions	opts;
	opts.szImage = IntSize{320, 240};
	std::string	err;
	CHECK(!ExportMovieVideo(eng, out.string(), opts, [](int64_t n, int64_t) { return n < 5; }, &err));
	CHECK_EQ(err, std::string("Canceled."));
	CHECK(!fs::exists(out));
}

int main() { return RunAllTests(); }
