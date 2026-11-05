// Copyleft 2025 Chris Korda (original WhorldDraw.cpp, WhorldThread.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "whorld/WhorldEngine.h"
#include "whorld/HLS.h"
#include "whorld/Random.h"
#include "whorld/Round.h"

#include <algorithm>
#include <cassert>
#include <climits>
#include <cmath>
#include <cstring>

namespace whorld {

#define DTOF(x) static_cast<float>(x)
#define FTOD(x) static_cast<double>(x)
#define M_PI_ kPi

namespace {

// Globals.h CLAMP, with the original's min/max argument order
template <typename T, typename L, typename H>
inline T Clamp(T x, L lo, H hi)
{
	return std::min<T>(std::max<T>(x, static_cast<T>(lo)), static_cast<T>(hi));
}

// CKD2DRectF helpers (D2DHelper.h)
inline float Width(const RectF& r) { return r.right - r.left; }
inline float Height(const RectF& r) { return r.bottom - r.top; }
inline void OffsetRect(RectF& r, float dx, float dy)
{
	r.left += dx;
	r.top += dy;
	r.right += dx;
	r.bottom += dy;
}
inline bool PtInRect(const RectF& r, const PointF& pt)
{
	return pt.x >= r.left && pt.y >= r.top && pt.x < r.right && pt.y < r.bottom;
}

inline ColorF MakeColor(float r, float g, float b, float a = 1)	// D2D1::ColorF
{
	return ColorF{r, g, b, a};
}

} // namespace

const double WhorldEngine::MIN_ASPECT_RATIO = 1e-9;
const double WhorldEngine::MIN_STAR_RATIO = 1e-2;

// ported from WhorldDraw.cpp CWhorldDraw::CWhorldDraw
WhorldEngine::WhorldEngine()
	: m_oscOrigin(DEFAULT_FRAME_RATE, 1)
{
	SetDefaults();
	m_params = m_paramDefault;
	std::memset(&m_globs, 0, sizeof(m_globs));
	m_globRing = m_globalRingDefault;
	SetParamDefaults(m_aPrevParam);
	std::memset(m_aPt, 0, sizeof(m_aPt));
	m_nFrameCount = 0;
	m_posDel = m_aRing.end();
	m_szTarget = SizeF{0, 0};
	m_rCanvas = RectF{0, 0, 0, 0};	// SetRectEmpty
	m_fNewGrowth = 0;
	m_nMaxRings = INT_MAX;
	m_bIsPaused = false;
	m_bSnapshotMode = false;
	m_bFlushHistory = false;
	m_bCopying = false;
	m_fRingOffset = 0;
	m_fHue = 0;
	m_clrRing = MakeColor(0, 0, 0);	// D2D1::ColorF(0): black, alpha 1
	m_clrBkgnd = MakeColor(0, 0, 0);
	m_fHueLoopPos = 0;
	m_fHueLoopBase = 0;
	m_fCopyTheta = 0;
	m_fCopyDelta = 0;
	m_ptOrigin = DPoint(0, 0);
	m_ptOriginTarget = DPoint(0, 0);
	m_fZoom = 1;
	m_fZoomTarget = 1;
	m_nFrameRate = DEFAULT_FRAME_RATE;
	std::memset(&m_dsSnapshot, 0, sizeof(m_dsSnapshot));
	// CreateUserResources creates both brushes as ColorF(0, 255, 0, 0.5f)
	m_clrBkgndBrush = MakeColor(0, 255, 0, 0.5f);
	m_clrDrawBrush = MakeColor(0, 255, 0, 0.5f);
	m_bAntialiasMode = m_main.bAntialiasing;	// CreateUserResources
	m_bHasCursor = false;
	m_ptCursor = DPoint(0.5, 0.5);
	m_bSnapshotLetterbox = true;	// COptions default for m_Snapshot_bLetterbox
	m_bIsMoviePaused = false;
	m_bMovieSingleStep = false;
}

// ported from WhorldDraw.cpp CWhorldDraw::OnResize
void WhorldEngine::OnResize(SizeF szTarget)
{
	m_szTarget = szTarget;
}

void WhorldEngine::SetCursorPosition(DPoint ptNormalized)
{
	m_ptCursor = ptNormalized;
	m_bHasCursor = true;
}

void WhorldEngine::PostReply(uint32_t nCmd, void* pData, DPoint ptOrigin) const
{
	if (m_fnReply) {
		Reply	reply = {nCmd, pData, ptOrigin, std::string()};
		m_fnReply(reply);
	} else if (nCmd == RC_CAPTURE_SNAPSHOT) {
		delete static_cast<Snapshot*>(pData);	// nobody to take ownership
	}
}

// Drawing

// ported from WhorldDraw.cpp CWhorldDraw::Wrap
inline double WhorldEngine::Wrap(double fVal, double fLimit)
{
	double	r = std::fmod(fVal, fLimit);
	return fVal < 0 ? r + fLimit : r;
}

// ported from WhorldDraw.cpp CWhorldDraw::Reflect
inline double WhorldEngine::Reflect(double fVal, double fLimit)
{
	double	m = fLimit * 2;
	double	r = Wrap(fVal, m);
	return r < fLimit ? r : m - r;
}

// ported from WhorldDraw.cpp CWhorldDraw::UpdateHue
inline void WhorldEngine::UpdateHue(double fDeltaTick)
{
	if (m_main.bLoopHue) {	// if looping hue
		if (m_master.fHueSpan) {	// if non-zero loop length
			m_fHueLoopPos += m_params.fColorSpeed * fDeltaTick;
			m_fHue = m_fHueLoopBase -
				Reflect(m_fHueLoopPos, m_master.fHueSpan);
		} else {	// avoid divide by zero
			m_fHue = m_fHueLoopBase;
		}
	} else {	// not looping hue
		m_fHue += m_params.fColorSpeed * fDeltaTick;
	}
	m_fHue = Wrap(m_fHue, 360);
}

// ported from WhorldDraw.cpp CWhorldDraw::OnHueSpanChange
void WhorldEngine::OnHueSpanChange()
{
	if (m_main.bLoopHue) {	// if looping hue
		m_fHueLoopPos = 0;
		m_fHueLoopBase = m_fHue;
	}
}

// ported from WhorldDraw.cpp CWhorldDraw::SetAntialiasing; the renderer
// receives the mode at the start of each Draw
void WhorldEngine::SetAntialiasing(bool bEnable)
{
	m_bAntialiasMode = bEnable;
}

// ported from WhorldDraw.cpp CWhorldDraw::ResizeCanvas
void WhorldEngine::ResizeCanvas()
{
	double	fScale = m_master.fCanvasScale * m_fZoom;
	RectF	rCanvas = {0, 0, DTOF(m_szTarget.width * fScale), DTOF(m_szTarget.height * fScale)};
	OffsetRect(rCanvas, (m_szTarget.width - Width(rCanvas)) / 2, (m_szTarget.height - Height(rCanvas)) / 2);
	m_rCanvas = rCanvas;
}

// ported from WhorldDraw.cpp CWhorldDraw::OnCopiesChange
void WhorldEngine::OnCopiesChange()
{
	int	nCount = Round(m_master.fCopies);
	if (nCount > 1) {	// if multiple copies desired
		m_fCopyDelta = M_PI_ * 2 / nCount;
		m_fCopyTheta = m_fCopyDelta / 2;
		m_bCopying = m_master.fSpread != 0;
	} else {	// one copy only
		m_bCopying = false;
	}
}

// ported from WhorldDraw.cpp CWhorldDraw::RandDouble
inline double WhorldEngine::RandDouble()
{
	return FTOD(whorld::rand()) / kRandMax;
}

// ported from WhorldDraw.cpp CWhorldDraw::OnTempoChange
void WhorldEngine::OnTempoChange()
{
	if (m_master.fTempo) {	// if non-zero tempo
		m_oscOrigin.SetFreq(m_master.fTempo / 60);
	}
}

// ported from WhorldDraw.cpp CWhorldDraw::OnOriginMotionChange
void WhorldEngine::OnOriginMotionChange()
{
	switch (m_main.nOrgMotion) {
	case OM_RANDOM:
		m_oscOrigin.Reset();
		break;
	}
}

// ported from WhorldDraw.cpp CWhorldDraw::SetOriginTarget
void WhorldEngine::SetOriginTarget(DPoint ptOrigin, bool bDamping)
{
	// origin in render target coordinates (DIPs), NOT normalized
	m_ptOriginTarget = ptOrigin;	// update target
	if (!bDamping || m_bSnapshotMode) {	// if not damping
		m_ptOrigin = ptOrigin;	// go directly to target
	}
}

// ported from WhorldDraw.cpp CWhorldDraw::UpdateOrigin
void WhorldEngine::UpdateOrigin()
{
	switch (m_main.nOrgMotion) {
	case OM_DRAG:
		{
			if (m_bHasCursor) {	// replaces GetCursorPos and ScreenToClient
				DPoint	pt(m_ptCursor);	// normalized cursor position
				pt.x = Clamp(pt.x, 0, 1);	// limit to within client window
				pt.y = Clamp(pt.y, 0, 1);
				m_ptOriginTarget = (pt - 0.5) * DPoint(m_szTarget);	// convert to DIPs
			}
		}
		break;
	case OM_RANDOM:
		if (m_master.fTempo) {	// if non-zero tempo
			if (m_oscOrigin.IsTrigger()) {	// if origin oscillator triggered
				// The original's DPoint ptRand(RandDouble(), RandDouble())
				// evaluates its arguments in an unspecified order. MSVC
				// typically evaluates arguments right to left, so y is drawn
				// first; clang goes left to right. Make the order explicit.
				// (Assumed; see PORT_PLAN.md "Port notes".)
				double	fRandY = RandDouble();
				double	fRandX = RandDouble();
				DPoint	ptRand(fRandX, fRandY);	// generate normalized random point
				m_ptOriginTarget = (ptRand - 0.5) * DPoint(m_szTarget);	// convert to DIPs
			}
		}
		break;
	}
	// increment origin by a fraction of its distance from target origin
	m_ptOrigin += (m_ptOriginTarget - m_ptOrigin) * m_master.fDamping;
}

// ported from WhorldDraw.cpp CWhorldDraw::UpdateZoom
void WhorldEngine::UpdateZoom()
{
	double	fPrevZoom = m_fZoom;	// save previous zoom
	// increment zoom by a fraction of its distance from target zoom
	m_fZoom += (m_fZoomTarget - m_fZoom) * m_master.fDamping;
	// apply zoom to ring origins to match V1 trail behavior
	double	fDeltaZoom = m_fZoom / fPrevZoom;	// delta is a scaling factor
	DPoint	ptLeadOrg;
	if (m_main.bZoomCenter) {	// if zooming relative to center of view
		ptLeadOrg = DPoint(0, 0);	// zoom rings in view-centric space
		m_ptOrigin *= fDeltaZoom;
		m_ptOriginTarget *= fDeltaZoom;
	} else {	// zoom relative to center of rings
		ptLeadOrg = m_ptOrigin;	// zoom rings in ring-centric space
	}
	for (RING& rp : m_aRing) {	// for each ring
		// subtract lead origin, scale by delta zoom, add lead origin
		rp.ptOrigin = (DPoint(rp.ptOrigin) - ptLeadOrg) * fDeltaZoom + ptLeadOrg;
	}
}

// ported from WhorldDraw.cpp CWhorldDraw::OnGlobalsChange
void WhorldEngine::OnGlobalsChange()
{
	// set damped global parameter values to their targets
	for (int iGlobal = 0; iGlobal < GLOBAL_COUNT; iGlobal++) {	// for each global parameter
		int	iParam = MapGlobalToParam(iGlobal);	// map from global index to parameter index
		m_globs.a[iParam] = GetParamRow(iParam).fGlobal;	// set damped value from target
	}
}

// ported from WhorldDraw.cpp CWhorldDraw::UpdateGlobals
void WhorldEngine::UpdateGlobals()
{
	// increment damped global parameter values towards their targets
	for (int iGlobal = 0; iGlobal < GLOBAL_COUNT; iGlobal++) {	// for each global parameter
		int	iParam = MapGlobalToParam(iGlobal);	// map from global index to parameter index
		const PARAM_ROW&	row = GetParamRow(iParam);	// dereference
		// increment parameter by a fraction of its distance from target parameter
		m_globs.a[iParam] += (row.fGlobal - m_globs.a[iParam]) * m_master.fDamping;
	}
}

// ported from WhorldDraw.cpp CWhorldDraw::RemoveAllRings
void WhorldEngine::RemoveAllRings()
{
	m_aRing.clear();
	m_posDel = m_aRing.end();	// avoid bogus delete
}

// ported from WhorldDraw.cpp CWhorldDraw::AddRing
void WhorldEngine::AddRing()
{
	m_params.fRingSpacing = std::max<double>(m_params.fRingSpacing, 1);
	m_params.fPolySides = Clamp(m_params.fPolySides, 3, MAX_SIDES);
	m_params.fLightness = Clamp(m_params.fLightness, 0, 1);
	m_params.fSaturation = Clamp(m_params.fSaturation, 0, 1);
	double	fR, fG, fB;
	HLS::hls2rgb(m_fHue, m_params.fLightness, m_params.fSaturation, fR, fG, fB);
	m_clrRing = MakeColor(DTOF(fR), DTOF(fG), DTOF(fB), DTOF(m_params.fAlpha));
	RING	ring;
	std::memset(&ring, 0, sizeof(ring));	// every member is set below; zeroed for tidiness
	bool	bReverse = m_params.fRingGrowth < 0;
	double	fRingOffset = bReverse ? -m_fRingOffset : m_fRingOffset;
	ring.fRotDelta = m_params.fRotateSpeed;
	ring.fRot = ring.fRotDelta * fRingOffset - ring.fRotDelta * m_fNewGrowth;
	if (m_params.fRingGrowth >= 0)
		ring.fRadius = m_fRingOffset - m_fNewGrowth;
	else {	// if inward growth, start at outermost edge of canvas
		ring.fRadius = (std::max(Width(m_rCanvas), Height(m_rCanvas)) / 2
			/ m_fZoom - m_fRingOffset) - m_fNewGrowth;
	}
	// don't let rings get too flat, or they'll never die
	double	fAspect = std::max(std::pow(2, m_params.fAspectRatio), MIN_ASPECT_RATIO);
	ring.ptScale.x = fAspect > 1 ? fAspect : 1;
	ring.ptScale.y = fAspect < 1 ? 1 / fAspect : 1;
	ring.ptShiftDelta.x = std::sin(m_params.fSkewAngle) * m_params.fSkewRadius;
	ring.ptShiftDelta.y = std::cos(m_params.fSkewAngle) * m_params.fSkewRadius;
	ring.ptShift.x = ring.ptShiftDelta.x * fRingOffset - ring.ptShiftDelta.x * m_fNewGrowth;
	ring.ptShift.y = ring.ptShiftDelta.y * fRingOffset - ring.ptShiftDelta.y * m_fNewGrowth;
	if (m_bCopying) {
		ring.ptShift.x += std::sin(m_fCopyTheta) * m_master.fSpread;
		ring.ptShift.y += std::cos(m_fCopyTheta) * m_master.fSpread;
		m_fCopyTheta += m_fCopyDelta;
	}
	ring.clrCur = m_clrRing;
	ring.nSides = static_cast<short>(Round(m_params.fPolySides));
	ring.nDrawMode = static_cast<short>(m_main.nDrawMode);
	ring.bDelete = false;
	ring.nReserved = 0;
	// don't let stars get too thin, or they'll never die
	double	fRad = std::max(std::pow(2, m_params.fStarFactor), MIN_STAR_RATIO);
	// use trig to find distance from origin to middle of a side
	// b is unknown, A is at origin, c is radius, b = cos(A) * c
	ring.fStarRatio = std::cos(M_PI_ / ring.nSides) * fRad;
	ring.fPinwheel = M_PI_ / ring.nSides * m_params.fPinwheel;
	ring.fLineWidth = DTOF(m_params.fLineWidth);
	ring.fHue = m_fHue;
	ring.fLightness = m_params.fLightness;
	ring.fSaturation = m_params.fSaturation;
	ring.ptOrigin = m_ptOrigin;
	ring.fEvenCurve = m_params.fEvenCurve;
	ring.fOddCurve = m_params.fOddCurve / ring.fStarRatio;
	ring.fEvenShear = m_params.fEvenShear;
	ring.fOddShear = m_params.fOddShear;
	if (!m_aRing.empty()) {	// if ring list has elements
		const RING& ringStart = bReverse ? m_aRing.back() : m_aRing.front();
		double	fRingSpacing = bReverse ? -m_params.fRingSpacing : m_params.fRingSpacing;
		ring.bSkipFill = std::fabs(ring.fRadius + fRingSpacing - ringStart.fRadius) > m_params.fRingSpacing * 2;
	} else {	// ring list is empty
		ring.bSkipFill = bReverse;
	}
	// add ring to list
	if (bReverse)
		m_aRing.push_back(ring);
	else
		m_aRing.push_front(ring);
	while (m_aRing.size() > static_cast<size_t>(m_nMaxRings)) {
		if (bReverse)
			m_aRing.pop_front();
		else
			m_aRing.pop_back();
	}
}

// ported from WhorldDraw.cpp CWhorldDraw::TimerHook
void WhorldEngine::TimerHook()
{
	int	nRings = std::max(Round(m_master.fRings), 0);	// keep ring count positive
	m_nMaxRings = nRings >= MAX_RINGS ? INT_MAX : nRings;
	UpdateOrigin();
	UpdateZoom();
	UpdateGlobals();
	double	fSpeed = m_main.bReverse ? -m_master.fSpeed : m_master.fSpeed;
	double	afPrevClock[PARAM_COUNT];
	for (int iParam = 0; iParam < PARAM_COUNT; iParam++) {
		afPrevClock[iParam] = m_aOsc[iParam].GetClock();
		m_aOsc[iParam].SetTimerFreq(m_nFrameRate);
	}
	if (m_bFlushHistory) {	// if flushing history
		m_aPrevParam = m_aParam;	// suppress oscillator interpolation
		for (int iParam = 0; iParam < PARAM_COUNT; iParam++) {	// for each parameter
			// set parameter's oscillator frequency without compensating phase
			m_aOsc[iParam].SetFreqSync(m_aParam.row[iParam].fFreq);
		}
		m_bFlushHistory = false;	// reset flushing history flag
	}
	static const int RG = PARAM_RingGrowth;
	const PARAM_ROW&	rowRG = m_aParam.row[RG];
	m_aOsc[RG].SetClock(afPrevClock[RG] + 1);
	m_fNewGrowth = (rowRG.fVal + m_aOsc[RG].GetVal() * rowRG.fAmp) * fSpeed;
	double	fAbsGrowth = std::fabs(m_fNewGrowth);
	double	fPrevFracTick = 0;
	while (m_fRingOffset > 0) {
		double	fFracTick = fAbsGrowth ? (1 - m_fRingOffset / fAbsGrowth) : 0;
		for (int iParam = 0; iParam < PARAM_COUNT; iParam++) {
			const PARAM_ROW&	prev = m_aPrevParam.row[iParam];
			const PARAM_ROW&	cur = m_aParam.row[iParam];
			m_aOsc[iParam].SetClock(afPrevClock[iParam] + fFracTick);
			double	fAmp = prev.fAmp + (cur.fAmp - prev.fAmp) * fFracTick;
			m_params.a[iParam] = prev.fVal + (cur.fVal - prev.fVal) * fFracTick
				+ m_aOsc[iParam].GetVal() * fAmp;
		}
		m_params.fRingGrowth *= fSpeed;
		m_params.fColorSpeed *= fSpeed;
		UpdateHue(fFracTick - fPrevFracTick);
		AddRing();
		m_fRingOffset -= m_params.fRingSpacing;
		fPrevFracTick = fFracTick;
	}
	m_fRingOffset += fAbsGrowth;
	m_params.fRingGrowth = m_fNewGrowth;
	m_aOsc[RG].SetClock(afPrevClock[RG] + 1);
	for (int iParam = 1; iParam < PARAM_COUNT; iParam++) {	// skip ring growth; assume it's first row
		const PARAM_ROW&	cur = m_aParam.row[iParam];
		m_aOsc[iParam].SetClock(afPrevClock[iParam] + 1);
		if (cur.fFreq != m_aPrevParam.row[iParam].fFreq)
			m_aOsc[iParam].SetFreq(cur.fFreq);
		m_params.a[iParam] = cur.fVal + m_aOsc[iParam].GetVal() * cur.fAmp;
	}
	m_aPrevParam = m_aParam;
	m_params.fColorSpeed *= fSpeed;
	UpdateHue(1 - fPrevFracTick);
	double	fR, fG, fB;
	m_params.fBkLightness = Clamp(m_params.fBkLightness, 0, 1);
	m_params.fBkSaturation = Clamp(m_params.fBkSaturation, 0, 1);
	HLS::hls2rgb(m_params.fBkHue, m_params.fBkLightness, m_params.fBkSaturation, fR, fG, fB);
	m_clrBkgnd = MakeColor(DTOF(fR), DTOF(fG), DTOF(fB), DTOF(m_params.fBkAlpha));
	// update rings
	RingPos	posNext = m_aRing.begin();
	DPoint	ptPrevOrg(m_ptOrigin);
	double	fTrail = 1 - m_master.fTrail;
	bool	bReverse = m_params.fRingGrowth < 0;
	m_posDel = m_aRing.end();
	while (posNext != m_aRing.end()) {	// ring loop
		RingPos	posCur = posNext;
		// update ring origins
		RING&	ring = *posNext++;
		ring.ptOrigin.x += (ptPrevOrg.x - ring.ptOrigin.x) * fTrail;
		ring.ptOrigin.y += (ptPrevOrg.y - ring.ptOrigin.y) * fTrail;
		ptPrevOrg = ring.ptOrigin;
		// increment cumulative ring properties
		ring.fRadius += m_params.fRingGrowth;
		ring.fRot += ring.fRotDelta * m_params.fRingGrowth;
		ring.ptShift.x += ring.ptShiftDelta.x * m_params.fRingGrowth;
		ring.ptShift.y += ring.ptShiftDelta.y * m_params.fRingGrowth;
		if (bReverse) {	// if reverse
			if (ring.fRadius <= 0) {
				m_aRing.erase(posCur);
			}
		} else {	// forward
			if (ring.bDelete) {
				m_aRing.erase(posCur);
				m_posDel = posNext;	// save position after last deletion for cascade
			}
		}
	}
	m_globRing.fRot = m_globs.fRotateSpeed / 5 * 180;
	m_globRing.fStarRatio = std::max(std::pow(2, m_globs.fStarFactor), MIN_STAR_RATIO);
	m_globRing.fPinwheel = m_globs.fPinwheel;
	double	r = std::max(std::pow(2, m_globs.fAspectRatio), MIN_ASPECT_RATIO);
	m_globRing.ptScale.x = r > 1 ? r : 1;
	m_globRing.ptScale.y = r < 1 ? 1 / r : 1;
	m_globRing.ptShift.x = std::sin(m_globs.fSkewAngle) * m_globs.fSkewRadius;
	m_globRing.ptShift.y = std::cos(m_globs.fSkewAngle) * m_globs.fSkewRadius;
	m_globRing.fEvenCurve = m_globs.fEvenCurve;
	m_globRing.fOddCurve = m_globs.fOddCurve / m_globRing.fStarRatio;
	m_globRing.fEvenShear = m_globs.fEvenShear + 1;
	m_globRing.fOddShear = m_globs.fOddShear + 1;
	m_globRing.fLineWidth = DTOF(m_globs.fLineWidth);
	m_globRing.nPolySides = Round(m_globs.fPolySides);
}

// ported from WhorldDraw.cpp CWhorldDraw::DrawRing
inline void WhorldEngine::DrawRing(IRenderer& renderer, bool bFilled,
	int iFirstPoint, int nPoints, int nVertices, bool bCurved) const
{
	// BeginFigure, then AddBeziers(nVertices) or AddLines(nPoints - 1), EndFigure(closed)
	renderer.AddFigure(&m_aPt[iFirstPoint], bCurved ? nVertices : nPoints - 1, bCurved, bFilled);
}

// ported from WhorldDraw.cpp CWhorldDraw::DrawOutline
inline void WhorldEngine::DrawOutline(IRenderer& renderer, const RING& ring, float fLineWidth) const
{
	ColorF	clrBrush;
	if (ring.nDrawMode & DM_OUTLINE) {	// if ring is outlined
		clrBrush = m_clrBkgndBrush;	// use background color
	} else {	// ring isn't outlined
		// outline anyway to ensure rings overlap completely
		fLineWidth = 1;	// override line width
		clrBrush = m_clrDrawBrush;	// use fill color
	}
	renderer.StrokePath(clrBrush, fLineWidth);
}

// ported from WhorldDraw.cpp CWhorldDraw::OnDraw
bool WhorldEngine::Draw(IRenderer& renderer)
{
	renderer.SetAntialiasing(m_bAntialiasMode);	// device state on Windows
	ResizeCanvas();	// order matters: AddRing uses m_rCanvas
	if (!m_bIsPaused) {	// if unpaused
		TimerHook();	// do time-based updates
	} else {	// paused
		if (m_movie.IsReading()) {	// if playing movie
			ReadMovieFrame();	// read its next frame
		}
	}
	// after reading movie frame but before any drawing
	if (m_main.bMirror) {	// if mirroring
		renderer.BeginQuadMirror();	// clip drawing to top left quadrant
	}
	renderer.Clear(m_clrBkgnd);	// clear to specified color
	m_clrBkgndBrush = m_clrBkgnd;
	bool	bConvex = m_main.bConvex;
	// Ring iteration replaces POSITION with GetNext (head to tail) or, in
	// convex mode, GetPrev (tail to head). bLast is the original's
	// "posNext == NULL" after fetching the current ring.
	auto	itFwd = m_aRing.begin();
	auto	itRev = m_aRing.rbegin();
	auto	HasNext = [&]() { return bConvex ? itRev != m_aRing.rend() : itFwd != m_aRing.end(); };
	auto	GetNextRing = [&]() -> RING& { return bConvex ? *itRev++ : *itFwd++; };
	ColorF	clrPrev = {0, 0, 0, 0};	// uninitialized in the original if no rings
	bool	bPrevSkipFill = false;
	if (bConvex) {
		if (!m_aRing.empty()) {
			const RING&	ringTail = m_aRing.back();
			clrPrev = ringTail.clrCur;
			bPrevSkipFill = ringTail.bSkipFill;
		}
	}
	DPoint	ptWndCenter(m_szTarget.width / 2, m_szTarget.height / 2);
	int		nPoints = 0;			// number of points in current ring
	int		nPrevPoints = 0;		// number of points in previous ring
	int		nPrevVertices = 0;		// number of vertices in previous ring if it's curved
	bool	bPrevCurved = false;	// true if previous ring is curved, else it's straight
	double	fZoom = m_fZoom;
	double	fSnapshotScale = 0;		// prevents uninitialized variable compiler warning
	if (m_bSnapshotMode) {	// if we're displaying a snapshot
		double	fSnapshotHorzScale = FTOD(m_szTarget.width) / m_dsSnapshot.szTarget.width;
		double	fSnapshotVertScale = FTOD(m_szTarget.height) / m_dsSnapshot.szTarget.height;
		fZoom *= std::min(fSnapshotHorzScale, fSnapshotVertScale);
		fSnapshotScale = fZoom;
		fZoom *= m_dsSnapshot.fZoom;
	}
	while (HasNext()) {	// ring loop
		RING&	ring = GetNextRing();
		bool	bLast = !HasNext();
		double	fLineWidth = ring.fLineWidth + m_globRing.fLineWidth;
		DPoint	ptOrg(ring.ptOrigin);
		if (m_bSnapshotMode) {	// if we're displaying a snapshot
			ptOrg *= fSnapshotScale;	// apply snapshot scaling to ring's origin
			fLineWidth *= fSnapshotScale;	// and line width
			if (m_dsSnapshot.nFlags & Snapshot::SF_V1) {	// if V1 snapshot
				// V1 shifted filled ring colors by one ring in convex mode, so V2's
				// fix for that must be disabled to display a V1 snapshot correctly.
				clrPrev = ring.clrCur;	// emulate legacy convex mode color behavior
			}
		}
		RectF	rBounds(m_rCanvas);
		OffsetRect(rBounds, DTOF(ptOrg.x), DTOF(ptOrg.y));
		int		nSides = ring.nSides + m_globRing.nPolySides;
		nSides = Clamp(nSides, 1, MAX_SIDES);
		double	fRot = ring.fRot + m_globRing.fRot;
		double	afRot[2] = {fRot, fRot + ring.fPinwheel + M_PI_ / nSides * m_globRing.fPinwheel};
		double	fRad = ring.fRadius * fZoom;
		double	arRad[2] = {fRad, fRad * ring.fStarRatio * m_globRing.fStarRatio};
		DPoint	ptScale(DPoint(ring.ptScale) * m_globRing.ptScale);
		DPoint	aptRad[2] = {ptScale * arRad[0], ptScale * arRad[1]};
		DPoint	ptShift((DPoint(ring.ptShift) * fZoom + DPoint(m_globRing.ptShift) * fRad)
			+ ptOrg + ptWndCenter);
		double	fDelta = M_PI_ / nSides;
		int		nVertices = nSides * 2;	// two vertices per side
		bool	bRingVisible = false;
		double	fCurveLenCW[2];
		fCurveLenCW[0] = ring.fEvenCurve + m_globRing.fEvenCurve;
		fCurveLenCW[1] = ring.fOddCurve + m_globRing.fOddCurve;
		bool	bCurved = fCurveLenCW[0] != 0 || fCurveLenCW[1] != 0;
		if (bCurved) {	// if ring is curved
			nPoints = nVertices * 3 + 1;	// three per Bezier plus one for start point
		} else {	// ring is straight
			nPoints = nVertices + 1;	// one extra for end point, same as start point
		}
		if (ring.nDrawMode & DM_FILL) {	// if ring is filled
			// The original uses memcpy, whose source and destination overlap
			// when this ring has fewer points than the previous one. MSVC's
			// memcpy handles overlap like memmove, so use memmove.
			std::memmove(m_aPt + nPoints, m_aPt, nPrevPoints * sizeof(PointF));
		}
		if (bCurved) {	// if ring is curved
			double	fCurveLenCCW[2];
			fCurveLenCCW[0] = fCurveLenCW[0] * (ring.fEvenShear + m_globRing.fEvenShear);
			fCurveLenCCW[1] = fCurveLenCW[1] * (ring.fOddShear + m_globRing.fOddShear);
			// current ring's final control point clobbers previous ring's first point
			PointF	ptPrevRingStart = m_aPt[nPoints];	// so make a backup
			PointF	*pPt = &m_aPt[2];	// first two points are set after loop
			for (int iVert = 0; iVert < nVertices; iVert++) {	// innermost loop
				int	bOdd = iVert & 1;
				double	fTheta = fDelta * iVert + afRot[bOdd];
				DPoint	pt;	// compute curve points from real vertex
				pt.x = std::sin(fTheta) * aptRad[bOdd].x + ptShift.x;
				pt.y = std::cos(fTheta) * aptRad[bOdd].y + ptShift.y;
				PointF	ptStart = {DTOF(pt.x), DTOF(pt.y)};	// single precision
				if (PtInRect(rBounds, ptStart))
					bRingVisible = true;
				DPoint	ptVec(pt - ptShift);	// vector from vertex to origin
				double	rLen = fCurveLenCW[bOdd];	// get clockwise curve vector length
				PointF	ptCtrl2 =
					{DTOF(pt.x - ptVec.y * rLen), DTOF(pt.y + ptVec.x * rLen)};
				*pPt++ = ptCtrl2;	// previous segment's second control point
				*pPt++ = ptStart;	// current segment's start point
				rLen = fCurveLenCCW[bOdd];	// get counter-clockwise curve vector length
				PointF	ptCtrl1 =
					{DTOF(pt.x + ptVec.y * rLen), DTOF(pt.y - ptVec.x * rLen)};
				*pPt++ = ptCtrl1;	// current segment's first control point
			}
			m_aPt[0] = m_aPt[nPoints - 1];	// set start point
			m_aPt[1] = m_aPt[nPoints];	// set first segment's first control point
			m_aPt[nPoints] = ptPrevRingStart;	// restore previous ring's start point
		} else {	// ring is straight
			for (int iVert = 0; iVert < nVertices; iVert++) {	// innermost loop
				int	bOdd = iVert & 1;
				double	fTheta = fDelta * iVert + afRot[bOdd];
				PointF	pt;
				pt.x = DTOF(std::sin(fTheta) * aptRad[bOdd].x + ptShift.x);
				pt.y = DTOF(std::cos(fTheta) * aptRad[bOdd].y + ptShift.y);
				m_aPt[iVert] = pt;
				if (PtInRect(rBounds, pt))
					bRingVisible = true;
			}
			m_aPt[nPoints - 1] = m_aPt[0];	// close figure
		}
		if (!m_bIsPaused)	// if unpaused
			ring.bDelete = !bRingVisible;	// mark invisible ring for deletion
		if (ring.nDrawMode & DM_FILL) {	// if ring is filled
			if (!ring.bSkipFill && !bPrevSkipFill) {	// if not skipping ring
				if (!bConvex || nPrevPoints) {	// if concave or previous ring is valid
					renderer.BeginPath();	// OPEN_GEOMETRY_SINK
					DrawRing(renderer, true, 0, nPoints, nVertices, bCurved);
					if (nPrevPoints) {	// if previous ring is valid
						DrawRing(renderer, true, nPoints, nPrevPoints, nPrevVertices, bPrevCurved);
					}
					renderer.EndPath();	// CLOSE_GEOMETRY_SINK
					m_clrDrawBrush = bConvex ? clrPrev : ring.clrCur;
					renderer.FillPath(m_clrDrawBrush);
					DrawOutline(renderer, ring, DTOF(fLineWidth));
				}
				if (bConvex && bLast) {	// if convex and last ring, draw bullseye
					renderer.BeginPath();
					DrawRing(renderer, true, 0, nPoints, nVertices, bCurved);
					renderer.EndPath();
					m_clrDrawBrush = ring.clrCur;
					renderer.FillPath(m_clrDrawBrush);
					DrawOutline(renderer, ring, DTOF(fLineWidth));
				}
			}
		} else {	// ring is line
			renderer.BeginPath();
			DrawRing(renderer, false, 0, nPoints, nVertices, bCurved);
			renderer.EndPath();
			m_clrDrawBrush = ring.clrCur;
			renderer.StrokePath(m_clrDrawBrush, DTOF(fLineWidth));
		}
		nPrevPoints = nPoints;
		nPrevVertices = nVertices;
		clrPrev = ring.clrCur;
		bPrevSkipFill = ring.bSkipFill;
		bPrevCurved = bCurved;
	}
	if (m_main.bMirror) {	// if mirroring
		renderer.EndQuadMirror();	// copy top left quadrant to the other three
	}
	if (!m_bIsPaused) {	// if unpaused
		if (m_posDel != m_aRing.end()) {  // if delete requested
			RING&	ring = *m_posDel;
			ring.bDelete = true;	// cascade delete
		}
		if (m_movie.IsWriting()) {
			if (!m_movie.Write(*GetSnapshot())) {
				OnMovieError(RC_MOVIE_RECORD);
			}
		}
	} else {	// paused
		// if we're displaying a snapshot and it should be letterboxed
		if (m_bSnapshotMode && m_bSnapshotLetterbox) {
			DrawSnapshotLetterbox(renderer);	// sets background brush color
		}
	}
	m_nFrameCount++;
	return true;
}

// ported from WhorldDraw.cpp CWhorldDraw::DrawSnapshotLetterbox
void WhorldEngine::DrawSnapshotLetterbox(IRenderer& renderer)
{
	const float fMinBarEpsilon = 0.5;	// half a device-independent pixel
	m_clrBkgndBrush = MakeColor(0, 0, 0);	// set background color to black
	double	fSnapshotHorzScale = FTOD(m_szTarget.width) / m_dsSnapshot.szTarget.width;
	double	fSnapshotVertScale = FTOD(m_szTarget.height) / m_dsSnapshot.szTarget.height;
	if (fSnapshotHorzScale > fSnapshotVertScale) {	// if target is too wide for snapshot
		// draw vertical bars left and right of snapshot
		float	fBarWidth = DTOF((m_szTarget.width - (m_dsSnapshot.szTarget.width * fSnapshotVertScale)) / 2);
		if (fBarWidth < fMinBarEpsilon)	// if width is less than epsilon
			return;	// don't draw infinitesimal bars
		renderer.FillRect(RectF{0, 0, fBarWidth, m_szTarget.height}, m_clrBkgndBrush);
		renderer.FillRect(
			RectF{m_szTarget.width - fBarWidth, 0, m_szTarget.width, m_szTarget.height}, m_clrBkgndBrush);
	} else {	// if target is too narrow for snapshot
		// draw horizontal bars above and below snapshot
		float	fBarHeight = DTOF((m_szTarget.height - (m_dsSnapshot.szTarget.height * fSnapshotHorzScale)) / 2);
		if (fBarHeight < fMinBarEpsilon)	// if height is less than epsilon
			return;	// don't draw infinitesimal bars
		renderer.FillRect(RectF{0, 0, m_szTarget.width, fBarHeight}, m_clrBkgndBrush);
		renderer.FillRect(
			RectF{0, m_szTarget.height - fBarHeight, m_szTarget.width, m_szTarget.height}, m_clrBkgndBrush);
	}
}

// ported from WhorldDraw.cpp CWhorldDraw::CaptureBitmap (image size)
IntSize WhorldEngine::GetCaptureSize(uint32_t nFlags, IntSize szImage) const
{
	if (nFlags & EF_USE_VIEW_SIZE) {	// if using view size as image size
		szImage.cx = Round(m_szTarget.width);	// override specified image size
		szImage.cy = Round(m_szTarget.height);
	}
	return szImage;
}

// ported from WhorldDraw.cpp CWhorldDraw::CaptureBitmap (step 2, drawing)
// and WhorldThread.cpp CWhorldThread::OnCaptureBitmap (antialiasing on)
bool WhorldEngine::DrawCapture(IRenderer& renderer, uint32_t nFlags, IntSize szImage)
{
	szImage = GetCaptureSize(nFlags, szImage);
	bool	bPrevAntialias = m_main.bAntialiasing;	// CSetAntialiasing saves state
	SetAntialiasing(true);	// enable antialiasing
	// CSaveObj: save pause state, zoom and target size; set pause state
	bool	bSavePaused = m_bIsPaused;
	double	fSaveZoom = m_fZoom;
	SizeF	szSaveTarget = m_szTarget;
	m_bIsPaused = true;
	uint32_t	nScaleType = nFlags & EF_SCALE_FIT_BOTH;
	if (nScaleType) {	// if scaling
		double	fHorzScale = FTOD(szImage.cx) / std::max(m_szTarget.width, 1.0f);
		double	fVertScale = FTOD(szImage.cy) / std::max(m_szTarget.height, 1.0f);
		double	fScale;
		switch (nScaleType) {
		case EF_SCALE_FIT_WIDTH:
			fScale = fHorzScale;	// fit width only
			break;
		case EF_SCALE_FIT_HEIGHT:
			fScale = fVertScale;	// fit height only
			break;
		default:	// fit both width and height
			fScale = std::min(fHorzScale, fVertScale);
		}
		m_fZoom *= fScale;	// apply scale to zoom
	}
	m_szTarget = SizeF{DTOF(szImage.cx), DTOF(szImage.cy)};	// set target size to image size
	bool	bResult = Draw(renderer);	// draw as usual; geometry is frozen because we're paused
	// restore state (CSaveObj destructors, then ~CSetAntialiasing)
	m_szTarget = szSaveTarget;
	m_fZoom = fSaveZoom;
	m_bIsPaused = bSavePaused;
	SetAntialiasing(bPrevAntialias);
	return bResult;
}

// ported from WhorldDraw.cpp CWhorldDraw::GetSnapshot
std::unique_ptr<Snapshot> WhorldEngine::GetSnapshot() const
{
	int	nRings = static_cast<int>(m_aRing.size());
	std::unique_ptr<Snapshot>	pSnapshot(Snapshot::Alloc(nRings));
	GetSnapshotDrawState(nRings, pSnapshot->m_drawState);	// save drawing state
	pSnapshot->m_globRing = m_globRing;	// save global ring data
	// save ring list
	std::copy(m_aRing.begin(), m_aRing.end(), pSnapshot->m_aRing.begin());
	return pSnapshot;
}

// ported from WhorldDraw.cpp CWhorldDraw::SetSnapshot
void WhorldEngine::SetSnapshot(const Snapshot& snapshot)
{
	int	nRings = SetSnapshotDrawState(snapshot.m_drawState);	// restore drawing state
	m_globRing = snapshot.m_globRing;	// restore global ring data
	// restore ring list
	RemoveAllRings();	// empty ring list
	for (int iRing = 0; iRing < nRings; iRing++) {	// for each snapshot ring
		m_aRing.push_back(snapshot.m_aRing[iRing]);	// add ring to list
	}
}

// ported from WhorldDraw.cpp CWhorldDraw::EnterSnapshotMode
void WhorldEngine::EnterSnapshotMode()
{
	if (m_pPrevSnapshot == nullptr) {	// if not already in snapshot mode
		m_pPrevSnapshot = GetSnapshot();	// take snapshot of current state
		m_fZoom = 1;	// in snapshot mode, zoom is relative to snapshot's zoom
	}
	m_bIsPaused = true;	// pause display; pointless otherwise
	m_bSnapshotMode = true;
}

// ported from WhorldDraw.cpp CWhorldDraw::ExitSnapshotMode
void WhorldEngine::ExitSnapshotMode()
{
	m_bSnapshotMode = false;
	if (m_pPrevSnapshot != nullptr) {	// if previous snapshot exists
		// snapshot is deleted when smart pointer goes out of scope
		std::unique_ptr<const Snapshot>	pSnapshot(std::move(m_pPrevSnapshot));	// take ownership
		SetSnapshot(*pSnapshot);	// restore snapshot
	}
}

// ported from WhorldDraw.cpp CWhorldDraw::GetSnapshotDrawState
inline void WhorldEngine::GetSnapshotDrawState(int nRings, DRAW_STATE& drawState) const
{
	// the original asserts !m_bSnapshotMode: snapshots of snapshots aren't allowed
	drawState.szTarget = m_szTarget;
	drawState.fZoom = m_fZoom;
	drawState.clrBkgnd = m_clrBkgnd;
	drawState.nRings = nRings;
	drawState.bConvex = m_main.bConvex;
	drawState.nFlags = 0;
	drawState.bMirror = m_main.bMirror;
	drawState.nReserved = 0;
}

// ported from WhorldDraw.cpp CWhorldDraw::SetSnapshotDrawState
inline int WhorldEngine::SetSnapshotDrawState(const DRAW_STATE& drawState)
{
	m_dsSnapshot = drawState;	// copy entire draw state
	m_clrBkgnd = drawState.clrBkgnd;	// update background color
	m_main.bConvex = drawState.bConvex;	// update convex flag
	m_main.bMirror = drawState.bMirror;	// update mirror flag
	return drawState.nRings;	// return ring count
}

// ported from WhorldDraw.cpp CWhorldDraw::SetFrameRate
bool WhorldEngine::SetFrameRate(uint32_t nFrameRate)
{
	if (!nFrameRate) {
		assert(0);	// zero frame rate is intolerable
		return false;	// avoid divide by zero when calculating period
	}
	m_nFrameRate = nFrameRate;
	m_oscOrigin.SetTimerFreq(nFrameRate);
	return true;
}

// Property change handlers

// ported from WhorldThread.cpp CWhorldThread::OnMasterPropChange
void WhorldEngine::OnMasterPropChange(int iProp)
{
	switch (iProp) {
	case MASTER_Copies:
	case MASTER_Spread:
		OnCopiesChange();
		break;
	case MASTER_Zoom:
		OnSetZoom(m_master.fZoom, false);
		break;
	case MASTER_Tempo:
		OnTempoChange();
		break;
	case MASTER_HueSpan:
		OnHueSpanChange();
		break;
	}
}

// ported from WhorldThread.cpp CWhorldThread::OnMainPropChange
void WhorldEngine::OnMainPropChange(int iProp)
{
	switch (iProp) {
	case MAIN_Origin:
		OnSetOrigin(m_main.dptOrigin, false);
		break;
	case MAIN_OrgMotion:
		OnOriginMotionChange();
		break;
	case MAIN_LoopHue:
		OnHueSpanChange();
		break;
	case MAIN_Antialiasing:
		SetAntialiasing(m_main.bAntialiasing);
		break;
	}
}

void WhorldEngine::OnMasterPropChange()
{
	for (int iProp = 0; iProp < MASTER_COUNT; iProp++) {	// for each master property
		OnMasterPropChange(iProp);
	}
}

void WhorldEngine::OnMainPropChange()
{
	for (int iProp = 0; iProp < MAIN_COUNT; iProp++) {	// for each main property
		OnMainPropChange(iProp);
	}
}

// Command handlers (WhorldThread.cpp): these run in the render thread's context

// ported from WhorldThread.cpp CWhorldThread::OnSetParam
void WhorldEngine::OnSetParam(int iParam, double fVal)
{
	GetParamRow(iParam).fVal = fVal;
}

// ported from WhorldThread.cpp CWhorldThread::OnSetWaveform
void WhorldEngine::OnSetWaveform(int iParam, int iWave)
{
	GetParamRow(iParam).iWave = iWave;
	m_aOsc[iParam].SetWaveform(iWave);
}

// ported from WhorldThread.cpp CWhorldThread::OnSetAmplitude
void WhorldEngine::OnSetAmplitude(int iParam, double fAmp)
{
	GetParamRow(iParam).fAmp = fAmp;
}

// ported from WhorldThread.cpp CWhorldThread::OnSetFrequency
void WhorldEngine::OnSetFrequency(int iParam, double fFreq)
{
	GetParamRow(iParam).fFreq = fFreq;
	m_aOsc[iParam].SetFreq(fFreq);
}

// ported from WhorldThread.cpp CWhorldThread::OnSetPulseWidth
void WhorldEngine::OnSetPulseWidth(int iParam, double fPW)
{
	GetParamRow(iParam).fPW = fPW;
	m_aOsc[iParam].SetPulseWidth(fPW);
}

// ported from WhorldThread.cpp CWhorldThread::OnSetGlobalParam
void WhorldEngine::OnSetGlobalParam(int iParam, double fGlobal)
{
	GetParamRow(iParam).fGlobal = fGlobal;
	m_globs.a[iParam] = fGlobal;
}

// ported from WhorldThread.cpp CWhorldThread::OnSetMasterProp
void WhorldEngine::OnSetMasterProp(int iProp, double fVal)
{
	Patch::SetMasterProp(iProp, fVal);
	OnMasterPropChange(iProp);
}

// ported from WhorldThread.cpp CWhorldThread::OnSetMainProp
void WhorldEngine::OnSetMainProp(int iProp, const VARIANT_PROP& prop)
{
	Patch::SetMainProp(iProp, prop);
	OnMainPropChange(iProp);
}

// ported from WhorldThread.cpp CWhorldThread::OnSetPatch
void WhorldEngine::OnSetPatch(const Patch& patch)
{
	// Upstream behavior: only the patch data is copied. Oscillator waveforms
	// and pulse widths are NOT updated from the patch (only OnSetWaveform and
	// OnSetPulseWidth do that). See PORT_PLAN.md "Upstream notes".
	Patch&	self = *this;	// upcast to patch data base class
	self = patch;	// copy patch data to base class
	OnMasterPropChange();	// handle master property changes
	OnMainPropChange();	// handle main property changes
	OnGlobalsChange();	// handle global parameter changes
	m_bFlushHistory = true;	// suppress interpolation to avoid glitch
}

// ported from WhorldThread.cpp CWhorldThread::OnGetPatch (reply via return)
void WhorldEngine::OnGetPatch(Patch& patch) const
{
	patch = *this;
}

// ported from WhorldThread.cpp CWhorldThread::OnGetStatus (reply via return)
void WhorldEngine::OnGetStatus(Status& status) const
{
	status.params = m_params;
	status.dptOrigin = GetOrigin();
	status.fZoom = m_fZoom;
	status.nRings = static_cast<intptr_t>(m_aRing.size());
}

// ported from WhorldThread.cpp CWhorldThread::OnSetFrameRate
bool WhorldEngine::OnSetFrameRate(uint32_t nFrameRate)
{
	return SetFrameRate(nFrameRate);
}

// ported from WhorldThread.cpp CWhorldThread::OnSetPause
void WhorldEngine::OnSetPause(bool bIsPaused)
{
	m_bIsPaused = bIsPaused;
	if (!bIsPaused) {	// if unpausing
		ExitSnapshotMode();
	}
}

// ported from WhorldThread.cpp CWhorldThread::OnSingleStep
void WhorldEngine::OnSingleStep()
{
	if (m_bIsPaused) {
		if (m_movie.IsReading()) {
			if (m_bIsMoviePaused) {
				m_bMovieSingleStep = true;
			}
		} else {
			TimerHook();
		}
	}
}

// ported from WhorldThread.cpp CWhorldThread::OnSetEmpty
void WhorldEngine::OnSetEmpty()
{
	RemoveAllRings();
	m_fRingOffset = 0;	// add a ring ASAP
}

// ported from WhorldThread.cpp CWhorldThread::OnRandomPhase
void WhorldEngine::OnRandomPhase()
{
	for (int iParam = 0; iParam < PARAM_COUNT; iParam++) {
		m_aOsc[iParam].SetPhase(RandDouble());
	}
}

// ported from WhorldThread.cpp CWhorldThread::OnRandomOrigin
void WhorldEngine::OnRandomOrigin()
{
	// argument order: see UpdateOrigin
	double	fRandY = RandDouble();
	double	fRandX = RandDouble();
	DPoint	ptRand(fRandX, fRandY);	// generate normalized random point
	m_ptOriginTarget = (ptRand - 0.5) * DPoint(m_szTarget);	// convert to DIPs
}

// ported from WhorldThread.cpp CWhorldThread::OnSetZoom
void WhorldEngine::OnSetZoom(double fZoom, bool bDamping)
{
	m_fZoomTarget = fZoom;
	if (!bDamping || m_bSnapshotMode) {	// if not damping
		m_fZoom = fZoom;	// go directly to target
	}
}

// ported from WhorldThread.cpp CWhorldThread::OnSetOrigin
void WhorldEngine::OnSetOrigin(DPoint ptOrigin, bool bDamping)
{
	SetOriginTarget(DPoint((ptOrigin - 0.5) * DPoint(m_szTarget)), bDamping);	// denormalize origin
}

// ported from WhorldThread.cpp CWhorldThread::OnSetOriginX
void WhorldEngine::OnSetOriginX(double fOriginX, bool bDamping)
{
	SetOriginTarget(DPoint((fOriginX - 0.5) * m_szTarget.width,	// denormalize x-coord
		m_ptOriginTarget.y), bDamping);
}

// ported from WhorldThread.cpp CWhorldThread::OnSetOriginY
void WhorldEngine::OnSetOriginY(double fOriginY, bool bDamping)
{
	SetOriginTarget(DPoint(m_ptOriginTarget.x,
		(fOriginY - 0.5) * m_szTarget.height), bDamping);	// denormalize y-coord
}

// ported from WhorldThread.cpp CWhorldThread::GetOrigin
DPoint WhorldEngine::GetOrigin() const
{
	if (!m_szTarget.width || !m_szTarget.height) {
		return DPoint(0, 0);	// avoid divide by zero
	}
	return DPoint(m_ptOrigin) / DPoint(m_szTarget) + 0.5;	// normalize
}

// ported from WhorldThread.cpp CWhorldThread::OnCaptureSnapshot
std::unique_ptr<Snapshot> WhorldEngine::OnCaptureSnapshot() const
{
	return GetSnapshot();
}

// ported from WhorldThread.cpp CWhorldThread::OnDisplaySnapshot
bool WhorldEngine::OnDisplaySnapshot(const Snapshot& snapshot)
{
	EnterSnapshotMode();
	SetSnapshot(snapshot);
	return true;
}

// ported from WhorldThread.cpp CWhorldThread::OnSetDampedGlobal
void WhorldEngine::OnSetDampedGlobal(int iParam, double fGlobal)
{
	GetParamRow(iParam).fGlobal = fGlobal;	// set target only
}

// ported from WhorldThread.cpp CWhorldThread::OnSetDrawMode
void WhorldEngine::OnSetDrawMode(uint32_t nMask, uint32_t nVal)
{
	m_main.nDrawMode &= ~nMask;	// clear specified bits
	m_main.nDrawMode |= (nVal & nMask);	// set specified bits
}

// ported from WhorldThread.cpp CWhorldThread::OnSetSnapshotSize
void WhorldEngine::OnSetSnapshotSize(IntSize szSnapshot)
{
	// if we're currently displaying a legacy snapshot
	if (m_dsSnapshot.nFlags & Snapshot::SF_V1) {
		m_dsSnapshot.szTarget = SizeF{DTOF(szSnapshot.cx), DTOF(szSnapshot.cy)};	// update its frame size
	}
}

// ported from WhorldDraw.cpp CWhorldDraw::ReadMovieFrame
bool WhorldEngine::ReadMovieFrame()
{
	if (m_movie.IsEndOfFile()) {	// if end of movie reached
		return true;	// nothing to do
	}
	// if movie is paused and single step flag isn't set
	if (m_bIsMoviePaused && !m_bMovieSingleStep) {
		return true;	// nothing to do
	}
	m_bMovieSingleStep = false;	// reset single step flag
	std::unique_ptr<const Snapshot>	pSnapshot(m_movie.Read());
	if (pSnapshot == nullptr) {	// if read snapshot failed
		OnMovieError(RC_MOVIE_PLAY);
		return false;
	}
	SetSnapshot(*pSnapshot);
	return true;
}

// ported from WhorldDraw.cpp CWhorldDraw::OnMovieError: report and close
void WhorldEngine::OnMovieError(uint32_t nCmd)
{
	std::string	sError = m_movie.GetLastError();
	m_movie.Close();	// close movie to avoid flood of errors
	if (m_fnReply) {	// replaces HandleError's message box
		Reply	reply = {nCmd, nullptr, DPoint(0, 0), sError};
		m_fnReply(reply);
	}
}

// ported from WhorldThread.cpp CWhorldThread::OnMovieRecord
void WhorldEngine::OnMovieRecord(const std::string* psPath)
{
	if (psPath != nullptr) {	// if path specified
		// start recording
		m_movie.SetFrameRate(static_cast<float>(m_nFrameRate));
		m_movie.SetTargetSize(m_szTarget);
		if (!m_movie.Open(*psPath, true)) {
			OnMovieError(RC_MOVIE_RECORD);
		}
	} else {	// no path; stop recording
		if (!m_movie.Close()) {
			OnMovieError(RC_MOVIE_RECORD);
		}
	}
}

// ported from WhorldThread.cpp CWhorldThread::OnMoviePlay
void WhorldEngine::OnMoviePlay(const std::string* psPath, bool bPaused)
{
	if (psPath != nullptr) {	// if path specified
		// start playback
		if (!m_movie.Open(*psPath, false)) {
			OnMovieError(RC_MOVIE_PLAY);
			return;
		}
		m_bIsMoviePaused = bPaused;
		EnterSnapshotMode();
	} else {	// no path; stop playback
		m_movie.Close();
	}
}

// ported from WhorldThread.cpp CWhorldThread::OnMoviePause
void WhorldEngine::OnMoviePause(bool bEnable)
{
	m_bIsMoviePaused = bEnable;
}

// ported from WhorldThread.cpp CWhorldThread::OnMovieSeek
void WhorldEngine::OnMovieSeek(int64_t iFrame)
{
	if (m_movie.SeekFrame(iFrame)) {	// if seek succeeds
		if (m_bIsMoviePaused) {	// if movie is paused
			m_bMovieSingleStep = true;	// set single step flag
			ReadMovieFrame();	// read exactly one frame
		}
	} else {	// seek failed
		OnMovieError(RC_MOVIE_SEEK);
	}
}

// ported from WhorldThread.cpp CWhorldThread::OnMovieExport (setup)
bool WhorldEngine::MovieExportStart(int64_t iStartFrame)
{
	m_bIsMoviePaused = true;	// pause playback during export
	if (!m_movie.SeekFrame(iStartFrame)) {
		OnMovieError(RC_MOVIE_EXPORT);
		return false;	// fail
	}
	return true;
}

// ported from WhorldThread.cpp CWhorldThread::OnMovieExport (per frame)
bool WhorldEngine::MovieExportStep()
{
	m_bMovieSingleStep = true;
	return ReadMovieFrame();
}

WhorldEngine::MovieState WhorldEngine::GetMovieState() const
{
	MovieState	ms;
	ms.nIOState = m_movie.GetIOState();
	ms.nFrameCount = m_movie.IsReading() ? m_movie.GetFrameCount() : 0;
	ms.iFrame = m_movie.IsReading() ? m_movie.GetReadFrameIdx() : m_movie.GetFramesWritten();
	ms.fFrameRate = m_movie.GetFrameRate();
	ms.szFrame = m_movie.GetTargetSize();
	ms.bPaused = m_bIsMoviePaused;
	return ms;
}

// ported from WhorldThread.cpp CWhorldThread::OnRenderCommand. Commands
// carrying pointers follow the original's ownership rules: SET_PATCH and
// DISPLAY_SNAPSHOT take ownership of a heap object; GET_PATCH and
// GET_STATUS write to the caller's object and reply with its address;
// CAPTURE_SNAPSHOT replies with a new Snapshot the receiver must delete.
void WhorldEngine::OnRenderCommand(const RenderCmd& cmd)
{
	switch (cmd.m_nCmd) {
	case RC_SET_PARAM_Val:
		OnSetParam(cmd.m_nParam, cmd.m_prop.dblVal);
		break;
	case RC_SET_PARAM_Wave:
		OnSetWaveform(cmd.m_nParam, cmd.m_prop.intVal);
		break;
	case RC_SET_PARAM_Amp:
		OnSetAmplitude(cmd.m_nParam, cmd.m_prop.dblVal);
		break;
	case RC_SET_PARAM_Freq:
		OnSetFrequency(cmd.m_nParam, cmd.m_prop.dblVal);
		break;
	case RC_SET_PARAM_PW:
		OnSetPulseWidth(cmd.m_nParam,  cmd.m_prop.dblVal);
		break;
	case RC_SET_PARAM_Global:
		OnSetGlobalParam(cmd.m_nParam, cmd.m_prop.dblVal);
		break;
	case RC_SET_MASTER:
		OnSetMasterProp(cmd.m_nParam, cmd.m_prop.dblVal);
		break;
	case RC_SET_MAIN:
		OnSetMainProp(cmd.m_nParam, cmd.m_prop);
		break;
	case RC_SET_PATCH:
		{
			std::unique_ptr<const Patch>	pPatch(static_cast<const Patch*>(cmd.m_prop.byref));
			OnSetPatch(*pPatch);	// recipient is responsible for deletion
		}
		break;
	case RC_GET_PATCH:
		OnGetPatch(*static_cast<Patch*>(cmd.m_prop.byref));
		PostReply(cmd.m_nCmd, cmd.m_prop.byref);
		break;
	case RC_GET_STATUS:
		OnGetStatus(*static_cast<Status*>(cmd.m_prop.byref));
		PostReply(cmd.m_nCmd, cmd.m_prop.byref);
		break;
	case RC_SET_EMPTY:
		OnSetEmpty();
		break;
	case RC_SET_FRAME_RATE:
		OnSetFrameRate(cmd.m_nParam);
		break;
	case RC_SET_PAUSE:
		OnSetPause(cmd.m_nParam != 0);
		break;
	case RC_SINGLE_STEP:
		OnSingleStep();
		break;
	case RC_RANDOM_PHASE:
		OnRandomPhase();
		break;
	case RC_RANDOM_ORIGIN:
		OnRandomOrigin();
		break;
	case RC_SET_ZOOM:
		OnSetZoom(cmd.m_prop.dblVal, cmd.m_nParam != 0);
		break;
	case RC_SET_ORIGIN:
		OnSetOrigin(cmd.m_prop.fltPt, cmd.m_nParam != 0);
		break;
	case RC_SET_ORIGIN_X:
		OnSetOriginX(cmd.m_prop.dblVal, cmd.m_nParam != 0);
		break;
	case RC_SET_ORIGIN_Y:
		OnSetOriginY(cmd.m_prop.dblVal, cmd.m_nParam != 0);
		break;
	case RC_GET_ORIGIN:
		PostReply(cmd.m_nCmd, nullptr, GetOrigin());
		break;
	case RC_CAPTURE_SNAPSHOT:
		PostReply(cmd.m_nCmd, OnCaptureSnapshot().release());
		break;
	case RC_DISPLAY_SNAPSHOT:
		{
			std::unique_ptr<const Snapshot>	pSnapshot(static_cast<const Snapshot*>(cmd.m_prop.byref));
			if (pSnapshot != nullptr)	// original fails with E_INVALIDARG if null
				OnDisplaySnapshot(*pSnapshot);
		}
		break;
	case RC_SET_DAMPED_GLOBAL:
		OnSetDampedGlobal(cmd.m_nParam, cmd.m_prop.dblVal);
		break;
	case RC_SET_DRAW_MODE:
		OnSetDrawMode(cmd.m_nParam, cmd.m_prop.uintVal);
		break;
	case RC_SET_SNAPSHOT_SIZE:
		OnSetSnapshotSize(cmd.m_prop.szVal);
		break;
	case RC_MOVIE_RECORD:	// takes ownership of a heap std::string path, or null
		{
			std::unique_ptr<const std::string>	psPath(static_cast<const std::string*>(cmd.m_prop.byref));
			OnMovieRecord(psPath.get());
		}
		break;
	case RC_MOVIE_PLAY:
		{
			std::unique_ptr<const std::string>	psPath(static_cast<const std::string*>(cmd.m_prop.byref));
			OnMoviePlay(psPath.get(), cmd.m_nParam != 0);
		}
		break;
	case RC_MOVIE_PAUSE:
		OnMoviePause(cmd.m_nParam != 0);
		break;
	case RC_MOVIE_SEEK:
		// The original passes m_prop.intVal, truncating to 32 bits (see
		// PORT_PLAN.md "Upstream notes"); the full 64-bit value is used here.
		OnMovieSeek(cmd.m_prop.llVal);
		break;
	case RC_CAPTURE_BITMAP:	// host-side: GetCaptureSize and DrawCapture
	case RC_MOVIE_EXPORT:	// host-side: MovieExportStart / MovieExportStep
		break;
	default:
		assert(0);	// missing command case
	};
}

} // namespace whorld
