// Copyleft 2025 Chris Korda (original WhorldDraw.h, WhorldThread.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from WhorldDraw.h CWhorldDraw, plus the command handlers from
// WhorldThread.h CWhorldThread (the parts that run in the render thread's
// context and aren't Windows-specific).
//
// On Windows, CWhorldDraw inherits the render thread and Direct2D device
// context. Here the engine owns no thread and no device: the host calls
// Draw() once per displayed frame with an IRenderer, and calls the command
// handlers (or OnRenderCommand) between frames on the same thread.
//
// Not ported yet: movie recording and playback (Phase 6). Bitmap capture is
// split: the engine draws the capture (DrawCapture); creating the
// offscreen target and writing the image file are the host's job.

#include "whorld/IRenderer.h"
#include "whorld/Oscillator.h"
#include "whorld/Patch.h"
#include "whorld/Snapshot.h"

#include <cstdint>
#include <functional>
#include <list>
#include <memory>

namespace whorld {

class WhorldEngine : protected Patch {
public:
// Construction
	WhorldEngine();

// Types
	using Patch::PARAM_VALS;
	using Patch::PARAM_ROW;
	using Patch::RenderCmd;
	using Patch::Status;
	using Patch::VARIANT_PROP;
	using Patch::RING;
	using Patch::GLOB_RING;
	using Patch::DRAW_STATE;
	// Replaces PostMsgToMainWnd for replies (UWM_GET_PATCH_REPLY,
	// UWM_GET_STATUS_REPLY, UWM_GET_ORIGIN_REPLY, UWM_SNAPSHOT_CAPTURE).
	// The app supplies the callback and hops to its main queue.
	struct Reply {
		uint32_t	nCmd;		// command that produced the reply (RC_*)
		void*		pData;		// Patch*, Status* or Snapshot* (owned by the receiver)
		DPoint		ptOrigin;	// for RC_GET_ORIGIN: normalized origin
	};
	typedef std::function<void(const Reply&)> ReplyCallback;

// Host interface (replaces CRenderThread / CD2DDevCtx callbacks)
	void	SetReplyCallback(ReplyCallback fn) { m_fnReply = std::move(fn); }
	void	OnResize(SizeF szTarget);	// size of render target in DIPs
	bool	Draw(IRenderer& renderer);	// OnDraw: one frame; ticks unless paused
	bool	SetFrameRate(uint32_t nFrameRate);
	// OM_DRAG reads the cursor every frame on Windows (GetCursorPos). The
	// host reports it instead, normalized to the view: (0, 0) top left,
	// (1, 1) bottom right; values outside are clamped by the engine.
	void	SetCursorPosition(DPoint ptNormalized);
	void	SetSnapshotLetterbox(bool bEnable) { m_bSnapshotLetterbox = bEnable; }
	// Bitmap capture (CWhorldDraw::CaptureBitmap). GetCaptureSize applies
	// EF_USE_VIEW_SIZE; the host creates an offscreen renderer of that many
	// pixels at scale 1 and calls DrawCapture, which renders the frozen
	// frame with antialiasing on, as OnCaptureBitmap does.
	IntSize	GetCaptureSize(uint32_t nFlags, IntSize szImage) const;
	bool	DrawCapture(IRenderer& renderer, uint32_t nFlags, IntSize szImage);

// Commands (ported from CWhorldThread::OnRenderCommand and handlers)
	void	OnRenderCommand(const RenderCmd& cmd);
	void	OnSetParam(int iParam, double fVal);
	void	OnSetWaveform(int iParam, int iWave);
	void	OnSetAmplitude(int iParam, double fAmp);
	void	OnSetFrequency(int iParam, double fFreq);
	void	OnSetPulseWidth(int iParam, double fPW);
	void	OnSetGlobalParam(int iParam, double fGlobal);
	void	OnSetMasterProp(int iProp, double fVal);
	void	OnSetMainProp(int iProp, const VARIANT_PROP& prop);
	void	OnSetPatch(const Patch& patch);
	void	OnGetPatch(Patch& patch) const;
	void	OnGetStatus(Status& status) const;
	bool	OnSetFrameRate(uint32_t nFrameRate);
	void	OnSetPause(bool bIsPaused);
	void	OnSingleStep();
	void	OnSetEmpty();
	void	OnRandomPhase();
	void	OnRandomOrigin();
	void	OnSetZoom(double fZoom, bool bDamping);
	void	OnSetOrigin(DPoint ptOrigin, bool bDamping);
	void	OnSetOriginX(double fOriginX, bool bDamping);
	void	OnSetOriginY(double fOriginY, bool bDamping);
	DPoint	GetOrigin() const;
	std::unique_ptr<Snapshot>	OnCaptureSnapshot() const;
	bool	OnDisplaySnapshot(const Snapshot& snapshot);
	void	OnSetDampedGlobal(int iParam, double fGlobal);
	void	OnSetDrawMode(uint32_t nMask, uint32_t nVal);
	void	OnSetSnapshotSize(IntSize szSnapshot);

// Attributes (for the host and tests)
	const Patch&	GetPatch() const { return *this; }
	bool	IsPaused() const { return m_bIsPaused; }
	bool	IsSnapshotMode() const { return m_bSnapshotMode; }
	size_t	GetRingCount() const { return m_aRing.size(); }
	const std::list<RING>&	GetRings() const { return m_aRing; }
	const PARAM_VALS&	GetParamValues() const { return m_params; }
	ColorF	GetBackgroundColor() const { return m_clrBkgnd; }
	double	GetZoom() const { return m_fZoom; }
	uint64_t	GetFrameCount() const { return m_nFrameCount; }
	uint32_t	GetFrameRate() const { return m_nFrameRate; }

protected:
// Constants
	enum {
		MAX_SIDES = 50,			// maximum number of sides a ring can have
		MAX_VERTICES = MAX_SIDES * 2,	// rings have 2 vertices per side (even/odd)
		MAX_POINTS = MAX_VERTICES * 3 + 2,	// enough for worst-case curved ring
		DEFAULT_FRAME_RATE = 60,	// in Hertz
	};
	static const double MIN_ASPECT_RATIO;
	static const double MIN_STAR_RATIO;
	typedef std::list<RING>::iterator RingPos;	// replaces POSITION

// Data members
	ColorF	m_clrBkgndBrush;	// background brush color (replaces m_pBkgndBrush)
	ColorF	m_clrDrawBrush;		// drawing brush color (replaces m_pDrawBrush)
	PARAM_VALS	m_params;	// parameters
	PARAM_VALS	m_globs;	// global parameters
	GLOB_RING	m_globRing;	// global ring offsets
	std::list<RING>	m_aRing;	// array of rings
	Oscillator	m_aOsc[PARAM_COUNT];	// array of oscillators
	PARAM_TABLE	m_aPrevParam;	// previous parameter table
	PointF	m_aPt[MAX_POINTS * 2];	// enough for two rings
	uint64_t	m_nFrameCount;	// frame count
	RingPos	m_posDel;		// if not end, position of ring after last deletion
	SizeF	m_szTarget;		// size of render target in DIPs
	RectF	m_rCanvas;		// ring dies when ALL its vertices are off canvas
	double	m_fNewGrowth;	// new ring growth, computed at start of TimerHook
	int		m_nMaxRings;	// maximum number of rings
	bool	m_bIsPaused;	// if true, we're paused
	bool	m_bSnapshotMode;	// if true, we're displaying a snapshot
	bool	m_bFlushHistory;	// if true, next TimerHook won't interpolate oscillators
	bool	m_bCopying;		// if true, add a rotating skew to new ring origins
	double	m_fRingOffset;	// size of gap since last ring, in pixels
	double	m_fHue;			// hue of new rings, in degrees
	ColorF	m_clrRing;		// color of new rings
	ColorF	m_clrBkgnd;		// background color
	double	m_fHueLoopPos;	// hue loop position, in degrees
	double	m_fHueLoopBase;	// hue loop's base hue, in degrees
	double	m_fCopyTheta;	// copy rotation angle, in radians
	double	m_fCopyDelta;	// copy rotation angle increment, in radians per frame
	TriggerOscillator	m_oscOrigin;	// trigger oscillator for origin motion
	DPoint	m_ptOrigin;		// distance from origin to window center, in DIPs
	DPoint	m_ptOriginTarget;	// target point for damped origin motion
	double	m_fZoom;		// current zoom, as a scaling factor
	double	m_fZoomTarget;	// target zoom for damped zooming
	uint32_t	m_nFrameRate;	// current frame rate in Hertz
	std::unique_ptr<const Snapshot>	m_pPrevSnapshot;	// render state before snapshot mode
	DRAW_STATE	m_dsSnapshot;	// snapshot draw state
	// replacements for state the original reads from the device or app
	bool	m_bAntialiasMode;	// device antialiasing mode (SetAntialiasing)
	bool	m_bHasCursor;		// true once the host has reported a cursor position
	DPoint	m_ptCursor;			// normalized cursor position (OM_DRAG)
	bool	m_bSnapshotLetterbox;	// theApp.m_options.m_Snapshot_bLetterbox
	ReplyCallback	m_fnReply;	// replaces PostMsgToMainWnd

// Helpers
	static double	Wrap(double fVal, double fLimit);
	static double	Reflect(double fVal, double fLimit);
	void	UpdateHue(double fDeltaTick);
	void	OnHueSpanChange();
	void	SetAntialiasing(bool bEnable);
	void	ResizeCanvas();
	void	OnCopiesChange();
	void	RemoveAllRings();
	void	AddRing();
	static double	RandDouble();
	void	OnTempoChange();
	void	OnOriginMotionChange();
	void	SetOriginTarget(DPoint ptOrigin, bool bDamping);
	void	UpdateOrigin();
	void	UpdateZoom();
	void	OnGlobalsChange();
	void	UpdateGlobals();
	void	TimerHook();
	void	DrawRing(IRenderer& renderer, bool bFilled,
		int iFirstPoint, int nPoints, int nVertices, bool bCurved) const;
	void	DrawOutline(IRenderer& renderer, const RING& ring, float fLineWidth) const;
	std::unique_ptr<Snapshot>	GetSnapshot() const;
	void	SetSnapshot(const Snapshot& snapshot);
	void	EnterSnapshotMode();
	void	ExitSnapshotMode();
	void	GetSnapshotDrawState(int nRings, DRAW_STATE& drawState) const;
	int		SetSnapshotDrawState(const DRAW_STATE& drawState);
	void	DrawSnapshotLetterbox(IRenderer& renderer);
	void	OnMasterPropChange(int iProp);
	void	OnMainPropChange(int iProp);
	void	OnMasterPropChange();
	void	OnMainPropChange();
	void	PostReply(uint32_t nCmd, void* pData, DPoint ptOrigin = DPoint(0, 0)) const;
};

} // namespace whorld
