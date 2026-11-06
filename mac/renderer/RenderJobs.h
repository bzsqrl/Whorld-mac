// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Offscreen rendering jobs shared by whorld-render and the golden tests.

#include "CGRenderer.h"
#include "whorld/Patch.h"
#include "whorld/Snapshot.h"
#include "whorld/WhorldEngine.h"

#include <memory>

namespace whorld {

struct SnapshotExportOptions {
	IntSize	szImage = {1024, 768};	// export image size in pixels
	uint32_t	nFlags = 0;			// WhorldBase::EF_* export flags
	SizeF	szView = {0, 0};		// view size in DIPs; 0 = same as image
	bool	bLetterbox = true;		// snapshot letterbox option
	bool	bDeferred = false;		// CGBitmapRenderer deferred mode
};

// Sets up an engine to export a snapshot as Windows "Snapshot > Export All"
// does (display the snapshot in snapshot mode) and returns the bitmap size.
// Then draw with eng.DrawCapture(renderer, opts.nFlags, opts.szImage).
IntSize	PrepareSnapshotExport(WhorldEngine& eng, const Snapshot& snapshot,
	const SnapshotExportOptions& opts);

// Reproduce Windows "Snapshot > Export All" for one snapshot: display the
// snapshot in the engine (snapshot mode), then capture a bitmap.
std::unique_ptr<CGBitmapRenderer> RenderSnapshotExport(const Snapshot& snapshot,
	const SnapshotExportOptions& opts);

struct PatchRenderOptions {
	IntSize	szImage = {1024, 768};	// output size in pixels
	double	fScale = 1;				// pixels per DIP
	int		nFrames = 300;			// frames to run; the last one is kept
	uint32_t	nFrameRate = 60;	// engine frame rate in Hz
	bool	bDeferred = false;		// CGBitmapRenderer deferred mode
};

// Run a patch for nFrames frames from a fresh engine and keep the last frame.
std::unique_ptr<CGBitmapRenderer> RenderPatch(const Patch& patch, const PatchRenderOptions& opts);

} // namespace whorld
