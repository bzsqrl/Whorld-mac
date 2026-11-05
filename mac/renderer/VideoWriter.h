// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Video export (new in the Mac port; Windows Whorld exports image
// sequences only). Encodes frames drawn by CGBitmapRenderer into a QuickTime
// movie with AVFoundation. Frames are drawn straight into the encoder's
// pixel buffers, so there's no extra copy.

#include "CGRenderer.h"
#include "whorld/WhorldEngine.h"

#include <functional>
#include <memory>
#include <string>

namespace whorld {

class VideoWriter {
public:
	enum Codec {
		CODEC_H264,
		CODEC_HEVC,
		CODEC_PRORES_422,
		CODEC_PRORES_4444,	// full chroma resolution: best for Whorld's hard edges
	};

	VideoWriter();
	~VideoWriter();
	VideoWriter(const VideoWriter&) = delete;
	VideoWriter& operator=(const VideoWriter&) = delete;

	// Width and height are made even (H.264 and HEVC need even sizes).
	bool	Open(const std::string& sPath, int nWidth, int nHeight, double fFrameRate, Codec codec,
		std::string* pError = nullptr);
	int		GetWidth() const;
	int		GetHeight() const;
	// Returns a renderer that draws into the next frame's pixel buffer
	// (DIP size = pixel size), or null on error. Call EndFrame when done.
	CGBitmapRenderer*	BeginFrame();
	bool	EndFrame(std::string* pError = nullptr);	// appends the frame
	bool	Close(std::string* pError = nullptr);	// finishes the file
	void	Cancel();	// stops and deletes the partial file

	static const char*	CodecName(Codec codec);

private:
	struct Impl;
	std::unique_ptr<Impl>	m_pImpl;
};

struct VideoExportOptions {
	VideoWriter::Codec	codec = VideoWriter::CODEC_H264;
	uint32_t	nFlags = 0;		// WhorldBase::EF_* export flags
	IntSize	szImage = {0, 0};	// frame size, unless EF_USE_VIEW_SIZE
	int64_t	nStartFrame = 0;	// inclusive range of movie frames
	int64_t	nEndFrame = -1;		// -1: to the end
};

// Exports frames of the movie the engine is playing (OnMoviePlay) to a
// video, like CWhorldThread::OnMovieExport but encoding instead of writing
// PNGs. The frame rate is the movie's. Progress is called after each frame
// with the number done; returning false from it cancels. Runs on the
// caller's thread (the render thread in the app).
bool ExportMovieVideo(WhorldEngine& eng, const std::string& sPath, const VideoExportOptions& opts,
	const std::function<bool(int64_t nDone, int64_t nTotal)>& progress, std::string* pError = nullptr);

} // namespace whorld
