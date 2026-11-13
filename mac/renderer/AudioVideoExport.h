// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Audio-reactive video export (new in the Mac port; AUDIO_PLAN.md, 9.9):
// a patch rendered frame by frame to a video, moved by an audio file through
// the modulation rows, with the audio as the video's sound track. Unlike
// the live view, it's frame-exact and the same every time: each frame's
// analysis is of the audio up to that frame's moment (a little beyond, so
// hits land on the frame they're heard), at a fixed time step.

#include "VideoWriter.h"
#include "whorld/AudioAnalyzer.h"
#include "whorld/Modulation.h"
#include "whorld/Patch.h"

#include <functional>
#include <string>
#include <vector>

namespace whorld {

struct AudioVideoOptions {
	VideoWriter::Codec	codec = VideoWriter::CODEC_H264;
	int		nWidth = 1920;		// pixels; the engine draws at this size, 1 DIP a pixel
	int		nHeight = 1080;
	double	fFrameRate = 60;
	double	fStart = 0;			// seconds into the audio
	double	fDuration = -1;		// seconds; -1: to the end
	double	fPreroll = 10;		// seconds the patch runs (to fill the picture) before the video starts
	// modulation, as the live Modulator's
	std::vector<ModRow>	aRow;
	std::vector<ModSync>	aSync;
	double	fDepth = 1;
	bool	bFollowTempo = false;
	AudioAnalyzer::Settings	analyzer;
	// the beat: 0, the beat tracker's (from the music); otherwise this
	// tempo, with a beat on fDownbeat
	double	fTempo = 0;
	double	fDownbeat = -1;		// seconds into the audio: "the one" (Mark Downbeat); -1: none
	// the engine's settings, as the app's
	bool	bRingFadeEased = false;
	bool	bHueFromPatch = false;
	// Next and Previous Patch actions step through these, from iPatch
	std::vector<std::string>	aPlaylist;
	int		iPatch = -1;
};

// Reads a modulation file as the Modulation window exports it (JSON: depth,
// bypass, followTempo, rows, syncs) into the options' modulation. Rows and
// syncs this build doesn't know are skipped; bypass leaves no rows.
bool ReadModulationFile(const std::string& sPath, AudioVideoOptions& opts, std::string* pError = nullptr);

// Renders patch with the audio at sAudioPath into a movie at sPath.
// Progress is called after each frame with the number done; returning
// false cancels (and deletes the partial file). Uses whorld::rand on the
// calling thread, seeded afresh and restored after.
bool ExportAudioReactiveVideo(const Patch& patch, const std::string& sAudioPath, const std::string& sPath,
	const AudioVideoOptions& opts, const std::function<bool(int64_t nDone, int64_t nTotal)>& progress,
	std::string* pError = nullptr);

} // namespace whorld
