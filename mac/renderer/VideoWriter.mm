// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#include "VideoWriter.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <thread>

namespace whorld {

struct VideoWriter::Impl {
	AVAssetWriter	*writer = nil;
	AVAssetWriterInput	*input = nil;
	AVAssetWriterInputPixelBufferAdaptor	*adaptor = nil;
	NSURL	*url = nil;
	int		nWidth = 0;
	int		nHeight = 0;
	CMTimeScale	nTimeScale = 0;
	int64_t	nTicksPerFrame = 0;
	int64_t	iFrame = 0;
	CVPixelBufferRef	pixelBuffer = nullptr;	// frame being drawn
	std::unique_ptr<CGBitmapRenderer>	renderer;

	static bool Fail(std::string* pError, NSString *msg)
	{
		if (pError)
			*pError = msg.UTF8String;
		return false;
	}
};

VideoWriter::VideoWriter() : m_pImpl(new Impl)
{
}

VideoWriter::~VideoWriter()
{
	if (m_pImpl->writer && m_pImpl->writer.status == AVAssetWriterStatusWriting)
		Cancel();
}

const char* VideoWriter::CodecName(Codec codec)
{
	switch (codec) {
	case CODEC_HEVC: return "HEVC";
	case CODEC_PRORES_422: return "ProRes 422";
	case CODEC_PRORES_4444: return "ProRes 4444";
	default: return "H.264";
	}
}

int VideoWriter::GetWidth() const { return m_pImpl->nWidth; }
int VideoWriter::GetHeight() const { return m_pImpl->nHeight; }

bool VideoWriter::Open(const std::string& sPath, int nWidth, int nHeight, double fFrameRate, Codec codec,
	std::string* pError)
{
	Impl&	d = *m_pImpl;
	d.nWidth = nWidth & ~1;
	d.nHeight = nHeight & ~1;
	if (d.nWidth < 2 || d.nHeight < 2)
		return Impl::Fail(pError, @"The video size is too small.");
	if (!(fFrameRate > 0))
		return Impl::Fail(pError, @"The frame rate isn't set.");
	// exact timing for fractional rates: 1000 ticks per second per fps
	d.nTimeScale = static_cast<CMTimeScale>(std::lround(fFrameRate * 1000));
	d.nTicksPerFrame = 1000;
	d.url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:sPath.c_str()]];
	[NSFileManager.defaultManager removeItemAtURL:d.url error:nil];
	NSError	*err = nil;
	d.writer = [AVAssetWriter assetWriterWithURL:d.url fileType:AVFileTypeQuickTimeMovie error:&err];
	if (!d.writer)
		return Impl::Fail(pError, err.localizedDescription ?: @"Can't create the video file.");
	NSString	*codecType = AVVideoCodecTypeH264;
	if (codec == CODEC_HEVC)
		codecType = AVVideoCodecTypeHEVC;
	else if (codec == CODEC_PRORES_422)
		codecType = AVVideoCodecTypeAppleProRes422;
	else if (codec == CODEC_PRORES_4444)
		codecType = AVVideoCodecTypeAppleProRes4444;
	NSMutableDictionary	*settings = [@{
		AVVideoCodecKey: codecType,
		AVVideoWidthKey: @(d.nWidth),
		AVVideoHeightKey: @(d.nHeight),
		// Whorld draws sRGB values. sRGB shares Rec. 709's primaries; tag the
		// sRGB transfer curve so color-managed players show the same colors
		// (tagging the 709 curve brightens everything by a couple of levels)
		AVVideoColorPropertiesKey: @{
			AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
			AVVideoTransferFunctionKey: (__bridge NSString *)kCVImageBufferTransferFunction_sRGB,
			AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
		},
	} mutableCopy];
	if (codec == CODEC_H264 || codec == CODEC_HEVC) {
		// Rings are fine detail with hard edges, so use a generous bit rate:
		// a quarter of a bit per pixel per frame (HEVC needs as much here)
		double	fBitsPerPixel = 0.25;
		double	fBitRate = d.nWidth * double(d.nHeight) * fFrameRate * fBitsPerPixel;
		settings[AVVideoCompressionPropertiesKey] = @{
			AVVideoAverageBitRateKey: @(std::min(fBitRate, 400e6)),
			AVVideoExpectedSourceFrameRateKey: @(fFrameRate),
		};
	}
	d.input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
	d.input.expectsMediaDataInRealTime = NO;
	d.adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:d.input
		sourcePixelBufferAttributes:@{
			// same layout as the renderer's bitmap: BGRA, premultiplied
			(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
			(id)kCVPixelBufferWidthKey: @(d.nWidth),
			(id)kCVPixelBufferHeightKey: @(d.nHeight),
			(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
		}];
	if (![d.writer canAddInput:d.input])
		return Impl::Fail(pError, @"This video format isn't supported.");
	[d.writer addInput:d.input];
	if (![d.writer startWriting])
		return Impl::Fail(pError, d.writer.error.localizedDescription ?: @"Can't start writing the video.");
	[d.writer startSessionAtSourceTime:kCMTimeZero];
	d.iFrame = 0;
	return true;
}

CGBitmapRenderer* VideoWriter::BeginFrame()
{
	Impl&	d = *m_pImpl;
	if (!d.writer || d.pixelBuffer)
		return nullptr;
	CVPixelBufferPoolRef	pool = d.adaptor.pixelBufferPool;
	if (!pool || CVPixelBufferPoolCreatePixelBuffer(nullptr, pool, &d.pixelBuffer) != kCVReturnSuccess)
		return nullptr;
	CVPixelBufferLockBaseAddress(d.pixelBuffer, 0);
	d.renderer = std::make_unique<CGBitmapRenderer>(
		static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(d.pixelBuffer)), d.nWidth, d.nHeight,
		CVPixelBufferGetBytesPerRow(d.pixelBuffer), 1);
	d.renderer->SetDeferred(true);
	return d.renderer.get();
}

bool VideoWriter::EndFrame(std::string* pError)
{
	Impl&	d = *m_pImpl;
	if (!d.pixelBuffer)
		return Impl::Fail(pError, @"No frame was begun.");
	d.renderer.reset();
	CVPixelBufferUnlockBaseAddress(d.pixelBuffer, 0);
	// offline encoding: wait until the encoder can take another frame
	while (!d.input.readyForMoreMediaData && d.writer.status == AVAssetWriterStatusWriting)
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	CMTime	t = CMTimeMake(d.iFrame * d.nTicksPerFrame, d.nTimeScale);
	BOOL	bOk = d.writer.status == AVAssetWriterStatusWriting
		&& [d.adaptor appendPixelBuffer:d.pixelBuffer withPresentationTime:t];
	CVPixelBufferRelease(d.pixelBuffer);
	d.pixelBuffer = nullptr;
	if (!bOk)
		return Impl::Fail(pError, d.writer.error.localizedDescription ?: @"Can't encode the frame.");
	d.iFrame++;
	return true;
}

bool VideoWriter::Close(std::string* pError)
{
	Impl&	d = *m_pImpl;
	if (!d.writer)
		return true;
	[d.input markAsFinished];
	dispatch_semaphore_t	done = dispatch_semaphore_create(0);
	[d.writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
	bool	bOk = d.writer.status == AVAssetWriterStatusCompleted;
	NSString	*msg = d.writer.error.localizedDescription;
	d.writer = nil;
	d.input = nil;
	d.adaptor = nil;
	return bOk ? true : Impl::Fail(pError, msg ?: @"Can't finish the video file.");
}

void VideoWriter::Cancel()
{
	Impl&	d = *m_pImpl;
	if (d.pixelBuffer) {
		d.renderer.reset();
		CVPixelBufferUnlockBaseAddress(d.pixelBuffer, 0);
		CVPixelBufferRelease(d.pixelBuffer);
		d.pixelBuffer = nullptr;
	}
	if (d.writer) {
		[d.writer cancelWriting];
		d.writer = nil;
		d.input = nil;
		d.adaptor = nil;
	}
	if (d.url)
		[NSFileManager.defaultManager removeItemAtURL:d.url error:nil];
}

bool ExportMovieVideo(WhorldEngine& eng, const std::string& sPath, const VideoExportOptions& opts,
	const std::function<bool(int64_t, int64_t)>& progress, std::string* pError)
{
	WhorldEngine::MovieState	ms = eng.GetMovieState();
	if (ms.nIOState != SnapMovie::IO_READ || ms.nFrameCount <= 0) {
		if (pError)
			*pError = "No movie is playing.";
		return false;
	}
	int64_t	nStart = std::min(std::max<int64_t>(opts.nStartFrame, 0), ms.nFrameCount - 1);
	int64_t	nEnd = opts.nEndFrame < 0 ? ms.nFrameCount - 1 : std::min(opts.nEndFrame, ms.nFrameCount - 1);
	if (nEnd < nStart) {
		if (pError)
			*pError = "The frame range is empty.";
		return false;
	}
	// frame size: as for image export, then rounded down to even; the
	// rounded size is passed as the image size so scaling uses it
	IntSize	sz = eng.GetCaptureSize(opts.nFlags, opts.szImage);
	sz.cx &= ~1;
	sz.cy &= ~1;
	uint32_t	nFlags = opts.nFlags & ~uint32_t(WhorldBase::EF_USE_VIEW_SIZE);
	VideoWriter	writer;
	if (!writer.Open(sPath, sz.cx, sz.cy, ms.fFrameRate, opts.codec, pError))
		return false;
	if (!eng.MovieExportStart(nStart)) {	// pauses playback and seeks
		writer.Cancel();
		if (pError)
			*pError = "Can't seek to the first frame.";
		return false;
	}
	int64_t	nTotal = nEnd - nStart + 1;
	for (int64_t i = 0; i < nTotal; i++) {
		if (!eng.MovieExportStep()) {	// read exactly one frame
			writer.Cancel();
			if (pError)
				*pError = "Can't read frame " + std::to_string(nStart + i) + ".";
			return false;
		}
		CGBitmapRenderer	*pRenderer = writer.BeginFrame();
		if (!pRenderer) {
			writer.Cancel();
			if (pError)
				*pError = "Can't get a video frame buffer.";
			return false;
		}
		pRenderer->BeginFrame();
		eng.DrawCapture(*pRenderer, nFlags, sz);
		pRenderer->EndFrame();
		if (!writer.EndFrame(pError)) {
			writer.Cancel();
			return false;
		}
		if (progress && !progress(i + 1, nTotal)) {	// canceled
			writer.Cancel();
			if (pError)
				*pError = "Canceled.";
			return false;
		}
	}
	return writer.Close(pError);
}

} // namespace whorld
