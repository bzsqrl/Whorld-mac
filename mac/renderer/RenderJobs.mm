// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#include "RenderJobs.h"
#include "whorld/WhorldEngine.h"

namespace whorld {

std::unique_ptr<CGBitmapRenderer> RenderSnapshotExport(const Snapshot& snapshot,
	const SnapshotExportOptions& opts)
{
	WhorldEngine	eng;
	SizeF	szView = opts.szView;
	if (!(szView.width > 0 && szView.height > 0))
		szView = SizeF{float(opts.szImage.cx), float(opts.szImage.cy)};
	eng.OnResize(szView);
	eng.SetSnapshotLetterbox(opts.bLetterbox);
	eng.OnDisplaySnapshot(snapshot);	// CMainFrame::OnSnapshotExportAll: LoadSnapshot
	IntSize	sz = eng.GetCaptureSize(opts.nFlags, opts.szImage);	// then CaptureBitmap
	auto	pRenderer = std::make_unique<CGBitmapRenderer>(sz.cx, sz.cy, 1);
	if (!pRenderer->IsValid())
		return nullptr;
	pRenderer->SetDeferred(opts.bDeferred);
	pRenderer->BeginFrame();
	eng.DrawCapture(*pRenderer, opts.nFlags, opts.szImage);
	pRenderer->EndFrame();
	return pRenderer;
}

std::unique_ptr<CGBitmapRenderer> RenderPatch(const Patch& patch, const PatchRenderOptions& opts)
{
	auto	pRenderer = std::make_unique<CGBitmapRenderer>(opts.szImage.cx, opts.szImage.cy, opts.fScale);
	if (!pRenderer->IsValid())
		return nullptr;
	pRenderer->SetDeferred(opts.bDeferred);
	WhorldEngine	eng;
	eng.SetFrameRate(opts.nFrameRate);
	eng.OnResize(pRenderer->GetSizeDIPs());
	eng.OnSetPatch(patch);
	for (int i = 0; i < opts.nFrames; i++) {
		pRenderer->BeginFrame();
		eng.Draw(*pRenderer);
		pRenderer->EndFrame();
	}
	return pRenderer;
}

} // namespace whorld
