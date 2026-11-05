// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#import "WHEngine.h"

#include "CGRenderer.h"
#include <IOSurface/IOSurface.h>
#include "whorld/Controls.h"
#include "whorld/Patch.h"
#include "whorld/WhorldEngine.h"

#include <chrono>
#include <cmath>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <pthread.h>
#include <thread>
#include <vector>

using whorld::WhorldBase;
using RenderCmd = WhorldBase::RenderCmd;

using whorld::Controls;

static WHControlInfo ToWH(const whorld::ControlInfo& ci)
{
	return WHControlInfo{ci.nRangeMin, ci.nRangeMax, ci.nDefaultPos, ci.nPageSize, ci.fEditScale,
		ci.nEditPrecision, ci.fEditMin, ci.fEditMax, ci.bEditClamp, ci.fSpinDelta};
}

static whorld::ControlInfo FromWH(const WHControlInfo& c)
{
	return whorld::ControlInfo{c.rangeMin, c.rangeMax, c.defaultPos, c.pageSize, c.editScale,
		c.editPrecision, c.editMin, c.editMax, (bool)c.editClamp, c.spinDelta};
}

static NSString *ToNS(const std::string& s)
{
	return [NSString stringWithUTF8String:s.c_str()];
}

@implementation WHControls
+ (NSInteger)paramCount { return WhorldBase::PARAM_COUNT; }
+ (NSInteger)masterCount { return WhorldBase::MASTER_COUNT; }
+ (NSInteger)globalCount { return WhorldBase::GLOBAL_COUNT; }
+ (NSInteger)waveformCount { return WhorldBase::WAVEFORM_COUNT; }
+ (NSString *)paramName:(NSInteger)i { return ToNS(WhorldBase::GetParamName((int)i)); }
+ (NSString *)masterName:(NSInteger)i { return ToNS(WhorldBase::GetMasterName((int)i)); }
+ (NSString *)waveformName:(NSInteger)i { return ToNS(WhorldBase::GetWaveformName((int)i)); }
+ (NSInteger)paramForGlobal:(NSInteger)i { return WhorldBase::MapGlobalToParam((int)i); }
+ (NSString *)mainName:(NSInteger)i { return ToNS(WhorldBase::GetMainName((int)i)); }
+ (NSString *)paramPropertyName:(NSInteger)i { return ToNS(WhorldBase::GetParamPropName((int)i)); }
+ (double)masterNorm01:(NSInteger)i value:(double)v { return Controls::MasterNorm01((int)i, v); }
+ (double)masterDenorm01:(NSInteger)i value:(double)v { return Controls::MasterDenorm01((int)i, v); }
+ (WHControlInfo)paramControl:(NSInteger)i column:(NSInteger)col { return ToWH(Controls::ParamInfo((int)i, (int)col)); }
+ (WHControlInfo)globalControl:(NSInteger)i { return ToWH(Controls::GlobalInfo((int)i)); }
+ (WHControlInfo)masterControl:(NSInteger)i { return ToWH(Controls::MasterInfo((int)i)); }
+ (double)paramPosition:(NSInteger)i value:(double)v { return Controls::ParamNorm((int)i, v); }
+ (double)paramValue:(NSInteger)i position:(double)p { return Controls::ParamDenorm((int)i, p); }
+ (double)globalPosition:(NSInteger)i value:(double)v { return Controls::GlobalNorm((int)i, v); }
+ (double)globalValue:(NSInteger)i position:(double)p { return Controls::GlobalDenorm((int)i, p); }
+ (double)masterPosition:(NSInteger)i value:(double)v { return Controls::MasterNorm((int)i, v); }
+ (double)masterValue:(NSInteger)i position:(double)p { return Controls::MasterDenorm((int)i, p); }
+ (NSString *)format:(double)v control:(WHControlInfo)c { return ToNS(Controls::FormatValue(FromWH(c), v)); }
+ (double)parse:(NSString *)t control:(WHControlInfo)c { return Controls::ParseValue(FromWH(c), t.UTF8String); }
+ (NSString *)formatMaster:(NSInteger)i value:(double)v { return ToNS(Controls::FormatMaster((int)i, v)); }
+ (double)parseMaster:(NSInteger)i text:(NSString *)t
{
	double	v = 0;
	Controls::ParseMaster((int)i, t.UTF8String, v);
	return v;
}
+ (double)spin:(double)v control:(WHControlInfo)c direction:(NSInteger)dir
{
	Controls::AddSpin(FromWH(c), v, (int)dir);
	return v;
}
@end

@implementation WHEngine {
	// shared between threads, guarded by _mutex
	std::mutex	_mutex;
	std::condition_variable	_cv;
	std::vector<RenderCmd>	_queue;	// replaces CRenderThread's interlocked ring buffer
	bool	_quit;
	bool	_frameRequested;
	int		_reqWidth, _reqHeight;
	double	_reqScale;
	int		_reqRate;
	bool	_cursorChanged;
	bool	_letterbox;
	bool	_letterboxChanged;
	whorld::DPoint	_cursor;
	double	_statRenderSum;
	int		_statFrames;
	size_t	_statRings;
	whorld::DPoint	_liveOrigin;	// normalized origin after the last frame
	// render thread only
	std::thread	_thread;
	std::unique_ptr<whorld::WhorldEngine>	_engine;
	// Frames are drawn straight into IOSurfaces that the layer displays
	// without copying. A small pool lets the next frame go into a surface
	// the compositor isn't using.
	struct Surface {
		IOSurfaceRef	surface;
		std::unique_ptr<whorld::CGBitmapRenderer>	renderer;
	};
	std::vector<Surface>	_surfaces;
	int		_surfWidth, _surfHeight;
	double	_surfScale;
	int		_curRate;
	// main thread only
	whorld::Patch	_doc;	// the document, as CWhorldDoc
	BOOL	_paused;
	BOOL	_modified;
	NSString	*_patchPath;
	__weak CALayer	*_layer;
	int		_deliveredFrames;
	CFTimeInterval	_statStart;
	double	_fps;
	double	_renderMs;
	NSInteger	_ringCount;
	int		_refreshRate;
}

- (instancetype)init
{
	if ((self = [super init])) {
		_quit = false;
		_frameRequested = false;
		_reqWidth = _reqHeight = 0;
		_reqScale = 1;
		_reqRate = 60;
		_cursorChanged = false;
		_letterbox = true;
		_letterboxChanged = false;
		_statRenderSum = 0;
		_statFrames = 0;
		_statRings = 0;
		_liveOrigin = whorld::DPoint(0.5, 0.5);
		_curRate = 0;
		_surfWidth = _surfHeight = 0;
		_surfScale = 0;
		_engine = std::make_unique<whorld::WhorldEngine>();
		_doc.SetDefaults();
		_statStart = CACurrentMediaTime();
		[self pushPatch];
		// unretained: the thread must not keep the engine alive; dealloc joins it
		__unsafe_unretained WHEngine	*unretained = self;
		_thread = std::thread([unretained] { [unretained renderLoop]; });
	}
	return self;
}

- (void)dealloc
{
	{
		std::lock_guard<std::mutex>	lock(_mutex);
		_quit = true;
	}
	_cv.notify_all();
	if (_thread.joinable())
		_thread.join();
	[self releaseSurfaces];
	for (const RenderCmd& cmd : _queue) {	// free payloads the thread never took
		if (cmd.m_nCmd == WhorldBase::RC_SET_PATCH)
			delete static_cast<whorld::Patch *>(cmd.m_prop.byref);
	}
}

#pragma mark - Commands

- (void)pushCommand:(const RenderCmd &)cmd
{
	std::lock_guard<std::mutex>	lock(_mutex);
	_queue.push_back(cmd);
}

// ported from WhorldThread.cpp CWhorldThread::SetPatch: send a heap copy
- (void)pushPatch
{
	RenderCmd	cmd(WhorldBase::RC_SET_PATCH);
	cmd.m_prop.byref = new whorld::Patch(_doc);
	[self pushCommand:cmd];
}

- (void)pushMainProp:(int)iProp
{
	_modified = YES;
	// ported from CWhorldView::OnUpdate HINT_MAIN: send the document's value
	RenderCmd	cmd(WhorldBase::RC_SET_MAIN, iProp);
	_doc.GetMainProp(iProp, cmd.m_prop);
	[self pushCommand:cmd];
}

- (void)setMainBool:(int)iProp value:(bool)b
{
	WhorldBase::VARIANT_PROP	prop;
	prop.llVal = 0;
	prop.boolVal = b;
	_doc.SetMainProp(iProp, prop);
	[self pushMainProp:iProp];
}

#pragma mark - Document

// CWhorldDoc::OnNewDocument: default patch
- (void)newPatch
{
	_doc.SetDefaults();
	_patchPath = nil;
	_modified = NO;
	[self pushPatch];
}

- (BOOL)openPatchAtPath:(NSString *)path error:(NSError **)error
{
	whorld::Patch	patch;
	std::string	sErr;
	if (!patch.Read(path.fileSystemRepresentation, &sErr)) {
		if (error) {
			*error = [NSError errorWithDomain:@"Whorld" code:1 userInfo:@{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Can't open \"%@\".", path.lastPathComponent],
				NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithUTF8String:sErr.c_str()] }];
		}
		return NO;
	}
	_doc = patch;
	_patchPath = [path copy];
	_modified = NO;
	[self pushPatch];	// CWhorldView::OnUpdate HINT_NONE
	return YES;
}

- (NSString *)patchPath
{
	return _patchPath;
}

- (BOOL)modified { return _modified; }
- (void)setModified:(BOOL)modified { _modified = modified; }

// ported from WhorldDoc.cpp CWhorldDoc::OnSaveDocument
- (BOOL)savePatchToPath:(NSString *)path error:(NSError **)error
{
	{	// get fresh origin from render thread
		std::lock_guard<std::mutex>	lock(_mutex);
		_doc.m_main.dptOrigin = _liveOrigin;
	}
	std::string	sErr;
	if (!_doc.Write(path.fileSystemRepresentation, &sErr)) {
		if (error) {
			*error = [NSError errorWithDomain:@"Whorld" code:2 userInfo:@{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Can't save \"%@\".", path.lastPathComponent],
				NSLocalizedRecoverySuggestionErrorKey: ToNS(sErr) }];
		}
		return NO;
	}
	_patchPath = [path copy];
	_modified = NO;
	return YES;
}

#pragma mark - Parameters

- (double)paramValue:(NSInteger)iParam property:(WHParamProperty)prop
{
	WhorldBase::VARIANT_PROP	v;
	_doc.GetParamRC((int)iParam, (int)prop, v);
	return prop == WHParamPropertyWave ? v.intVal : v.dblVal;
}

// ported from WhorldDoc.cpp CWhorldDoc::SetParam and CWhorldView::OnUpdate HINT_PARAM
- (void)setParamValue:(double)value param:(NSInteger)iParam property:(WHParamProperty)prop
{
	WhorldBase::VARIANT_PROP	v;
	v.llVal = 0;
	if (prop == WHParamPropertyWave)
		v.intVal = (int)value;
	else
		v.dblVal = value;
	_doc.SetParamRC((int)iParam, (int)prop, v);
	_modified = YES;
	RenderCmd	cmd(WhorldBase::RC_SET_PARAM_FIRST + (uint32_t)prop, (uint32_t)iParam);
	cmd.m_prop = v;
	[self pushCommand:cmd];
}

- (double)masterValue:(NSInteger)iProp
{
	return _doc.GetMasterProp((int)iProp);
}

// ported from WhorldDoc.cpp CWhorldDoc::SetMasterProp and HINT_MASTER
- (void)setMasterValue:(double)value prop:(NSInteger)iProp
{
	_doc.SetMasterProp((int)iProp, value);
	_modified = YES;
	[self pushCommand:RenderCmd(WhorldBase::RC_SET_MASTER, (uint32_t)iProp, value)];
}

- (CGPoint)origin
{
	return CGPointMake(_doc.m_main.dptOrigin.x, _doc.m_main.dptOrigin.y);
}

- (void)setOrigin:(CGPoint)pt
{
	_doc.m_main.dptOrigin = whorld::DPoint(pt.x, pt.y);
	[self pushMainProp:WhorldBase::MAIN_Origin];	// OnMainPropChange: OnSetOrigin, no damping
}

- (double)hue { return _doc.m_main.fHue; }

- (void)setHue:(double)hue
{
	_doc.m_main.fHue = hue;
	[self pushMainProp:WhorldBase::MAIN_Hue];
}

- (BOOL)invertColor { return _doc.m_main.bInvertColor; }

- (void)setInvertColor:(BOOL)b
{
	[self setMainBool:WhorldBase::MAIN_InvertColor value:b];
}

- (uint32_t)drawMode { return _doc.m_main.nDrawMode; }

// ported from WhorldDoc.cpp CWhorldDoc::SetZoom
- (void)setZoom:(double)zoom damping:(BOOL)damping
{
	RenderCmd	cmd(WhorldBase::RC_SET_ZOOM, damping ? 1 : 0, zoom);
	[self pushCommand:cmd];
	_doc.m_master.fZoom = zoom;
	_modified = YES;
}

- (void)setSnapshotLetterbox:(BOOL)enable
{
	std::lock_guard<std::mutex>	lock(_mutex);
	_letterbox = enable;
	_letterboxChanged = true;
}

#pragma mark - Image menu

- (BOOL)fill { return (_doc.m_main.nDrawMode & WhorldBase::DM_FILL) != 0; }
- (BOOL)outline { return (_doc.m_main.nDrawMode & WhorldBase::DM_OUTLINE) != 0; }
- (BOOL)mirror { return _doc.m_main.bMirror; }
- (BOOL)reverse { return _doc.m_main.bReverse; }
- (BOOL)convex { return _doc.m_main.bConvex; }
- (BOOL)loopHue { return _doc.m_main.bLoopHue; }
- (BOOL)zoomCenter { return _doc.m_main.bZoomCenter; }
- (BOOL)antialiasing { return _doc.m_main.bAntialiasing; }
- (WHOriginMotion)originMotion { return (WHOriginMotion)_doc.m_main.nOrgMotion; }

// CWhorldDoc::SetDrawMode
- (void)setDrawMode:(uint32_t)nDrawMode
{
	_doc.m_main.nDrawMode = nDrawMode;
	[self pushMainProp:WhorldBase::MAIN_DrawMode];
}

- (void)toggleFill { [self setDrawMode:_doc.m_main.nDrawMode ^ WhorldBase::DM_FILL]; }
- (void)toggleOutline { [self setDrawMode:_doc.m_main.nDrawMode ^ WhorldBase::DM_OUTLINE]; }
- (void)toggleMirror { [self setMainBool:WhorldBase::MAIN_Mirror value:!_doc.m_main.bMirror]; }
- (void)toggleReverse { [self setMainBool:WhorldBase::MAIN_Reverse value:!_doc.m_main.bReverse]; }
- (void)toggleConvex { [self setMainBool:WhorldBase::MAIN_Convex value:!_doc.m_main.bConvex]; }
- (void)toggleLoopHue { [self setMainBool:WhorldBase::MAIN_LoopHue value:!_doc.m_main.bLoopHue]; }
- (void)toggleZoomCenter { [self setMainBool:WhorldBase::MAIN_ZoomCenter value:!_doc.m_main.bZoomCenter]; }
- (void)toggleAntialiasing { [self setMainBool:WhorldBase::MAIN_Antialiasing value:!_doc.m_main.bAntialiasing]; }

// CWhorldDoc::SetOriginMotion
- (void)setOriginMotion:(WHOriginMotion)nMotion
{
	_doc.m_main.nOrgMotion = (int)nMotion;
	[self pushMainProp:WhorldBase::MAIN_OrgMotion];
}

// CWhorldDoc::OnImageOriginCenter
- (void)originCenter
{
	[self setOriginMotion:WHOriginMotionPark];
	RenderCmd	cmd(WhorldBase::RC_SET_ORIGIN, 0);	// center, no damping
	cmd.m_prop.fltPt = whorld::PointF{0.5f, 0.5f};
	[self pushCommand:cmd];
}

- (void)toggleOriginDrag
{
	[self setOriginMotion:_doc.m_main.nOrgMotion == WhorldBase::OM_DRAG ? WHOriginMotionPark : WHOriginMotionDrag];
}

- (void)toggleOriginRandom
{
	[self setOriginMotion:_doc.m_main.nOrgMotion == WhorldBase::OM_RANDOM ? WHOriginMotionPark : WHOriginMotionRandom];
}

- (void)randomPhase
{
	[self pushCommand:RenderCmd(WhorldBase::RC_RANDOM_PHASE)];
}

#pragma mark - Window menu

- (BOOL)paused { return _paused; }

- (void)togglePause
{
	_paused = !_paused;
	[self pushCommand:RenderCmd(WhorldBase::RC_SET_PAUSE, _paused ? 1 : 0)];
}

- (void)singleStep
{
	[self pushCommand:RenderCmd(WhorldBase::RC_SINGLE_STEP)];
}

- (void)clear
{
	[self pushCommand:RenderCmd(WhorldBase::RC_SET_EMPTY)];
}

#pragma mark - Rendering

- (void)attachLayer:(CALayer *)layer
{
	_layer = layer;
}

- (void)setCursorPosition:(CGPoint)normalized
{
	std::lock_guard<std::mutex>	lock(_mutex);
	_cursor = whorld::DPoint(normalized.x, normalized.y);
	_cursorChanged = true;
}

- (void)requestFrameWithPixelWidth:(int)width height:(int)height scale:(double)scale
	refreshRate:(int)refreshRate
{
	{
		std::lock_guard<std::mutex>	lock(_mutex);
		_reqWidth = width;
		_reqHeight = height;
		_reqScale = scale;
		if (refreshRate > 0)
			_reqRate = refreshRate;
		_frameRequested = true;
	}
	_cv.notify_one();
}

// Render thread: replaces CRenderThread::ThreadFunc. Each display refresh
// it drains the command queue, then draws one frame (RenderFrame).
- (void)renderLoop
{
	// The render thread drives the display: run it on performance cores.
	pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
	pthread_setname_np("Whorld render");
	for (;;) {
		std::vector<RenderCmd>	cmds;
		int		w, h, rate;
		double	scale;
		bool	bCursor, bLetterbox, bLetterboxOn;
		whorld::DPoint	cursor;
		{
			std::unique_lock<std::mutex>	lock(_mutex);
			_cv.wait(lock, [self] { return _quit || _frameRequested; });
			if (_quit)
				break;
			_frameRequested = false;
			cmds.swap(_queue);
			w = _reqWidth;
			h = _reqHeight;
			scale = _reqScale;
			rate = _reqRate;
			bCursor = _cursorChanged;
			cursor = _cursor;
			_cursorChanged = false;
			bLetterbox = _letterboxChanged;
			bLetterboxOn = _letterbox;
			_letterboxChanged = false;
		}
		for (const RenderCmd& cmd : cmds)	// ProcessCommand
			_engine->OnRenderCommand(cmd);
		if (rate != _curRate) {	// display frequency changed
			_engine->SetFrameRate(rate);
			_curRate = rate;
		}
		if (bCursor)
			_engine->SetCursorPosition(cursor);
		if (bLetterbox)
			_engine->SetSnapshotLetterbox(bLetterboxOn);
		if (w <= 0 || h <= 0)
			continue;
		if (w != _surfWidth || h != _surfHeight || scale != _surfScale) {	// RC_RESIZE
			[self releaseSurfaces];
			_surfWidth = w;
			_surfHeight = h;
			_surfScale = scale;
			_engine->OnResize(whorld::SizeF{float(w / scale), float(h / scale)});
		}
		Surface	*pSurf = [self freeSurface];
		if (!pSurf)
			continue;	// can't allocate; skip this frame
		auto	t0 = std::chrono::steady_clock::now();
		IOSurfaceLock(pSurf->surface, 0, nullptr);
		pSurf->renderer->BeginFrame();
		_engine->Draw(*pSurf->renderer);
		pSurf->renderer->EndFrame();
		IOSurfaceUnlock(pSurf->surface, 0, nullptr);
		IOSurfaceRef	image = pSurf->surface;
		CFRetain(image);
		double	ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
		size_t	nRings = _engine->GetRingCount();
		whorld::DPoint	ptOrigin = _engine->GetOrigin();
		{
			std::lock_guard<std::mutex>	lock(_mutex);
			_liveOrigin = ptOrigin;
			_statRenderSum += ms;
			_statFrames++;
			_statRings = nRings;
		}
		__weak WHEngine	*weakSelf = self;
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf deliverImage:image scale:scale];
			CFRelease(image);
		});
	}
}

// Render thread: a surface of the current size the compositor isn't
// using, creating one if needed (at most four).
- (Surface *)freeSurface
{
	for (Surface& s : _surfaces) {
		if (!IOSurfaceIsInUse(s.surface) && CFGetRetainCount(s.surface) == 1)
			return &s;
	}
	if (_surfaces.size() >= 4)
		return nullptr;
	NSDictionary	*props = @{
		(id)kIOSurfaceWidth: @(_surfWidth),
		(id)kIOSurfaceHeight: @(_surfHeight),
		(id)kIOSurfaceBytesPerElement: @4,
		(id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
	};
	IOSurfaceRef	surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
	if (!surface)
		return nullptr;
	// tag the pixels as sRGB, matching the renderer's color space
	CGColorSpaceRef	space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CFDataRef	icc = CGColorSpaceCopyICCData(space);
	if (icc) {
		IOSurfaceSetValue(surface, kIOSurfaceColorSpace, icc);
		CFRelease(icc);
	}
	CGColorSpaceRelease(space);
	Surface	s;
	s.surface = surface;
	s.renderer = std::make_unique<whorld::CGBitmapRenderer>(
		static_cast<uint8_t *>(IOSurfaceGetBaseAddress(surface)), _surfWidth, _surfHeight,
		IOSurfaceGetBytesPerRow(surface), _surfScale);
	s.renderer->SetDeferred(true);	// parallel stroking and banded rasterizing
	_surfaces.push_back(std::move(s));
	return &_surfaces.back();
}

- (void)releaseSurfaces
{
	for (Surface& s : _surfaces) {
		s.renderer.reset();
		CFRelease(s.surface);
	}
	_surfaces.clear();
}

- (void)deliverImage:(IOSurfaceRef)image scale:(double)scale
{
	CALayer	*layer = _layer;
	if (layer) {
		[CATransaction begin];
		[CATransaction setDisableActions:YES];
		layer.contents = (__bridge id)image;
		layer.contentsScale = scale;
		[CATransaction commit];
	}
	_deliveredFrames++;
	CFTimeInterval	now = CACurrentMediaTime();
	if (now - _statStart >= 1) {
		double	sum;
		int		n;
		size_t	rings;
		int		rate;
		{
			std::lock_guard<std::mutex>	lock(_mutex);
			sum = _statRenderSum;
			n = _statFrames;
			rings = _statRings;
			rate = _reqRate;
			_statRenderSum = 0;
			_statFrames = 0;
		}
		_fps = _deliveredFrames / (now - _statStart);
		_renderMs = n ? sum / n : 0;
		_ringCount = (NSInteger)rings;
		_refreshRate = rate;
		_deliveredFrames = 0;
		_statStart = now;
		if (_statsHandler)
			_statsHandler();
	}
}

- (double)framesPerSecond { return _fps; }
- (double)renderMilliseconds { return _renderMs; }
- (NSInteger)ringCount { return _ringCount; }
- (int)refreshRate { return _refreshRate; }

@end

#pragma mark - WHRenderView

@implementation WHRenderView {
	CADisplayLink	*_displayLink;
	NSTrackingArea	*_tracking;
}

- (instancetype)initWithFrame:(NSRect)frame
{
	if ((self = [super initWithFrame:frame])) {
		_fullResolution = YES;
		self.wantsLayer = YES;
		self.layer.backgroundColor = NSColor.blackColor.CGColor;
		self.layer.contentsGravity = kCAGravityResize;
		self.layer.magnificationFilter = kCAFilterLinear;
		self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
	}
	return self;
}

- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)setEngine:(WHEngine *)engine
{
	_engine = engine;
	[engine attachLayer:self.layer];
}

- (void)viewDidMoveToWindow
{
	[super viewDidMoveToWindow];
	[_displayLink invalidate];
	_displayLink = nil;
	if (self.window) {
		_displayLink = [self displayLinkWithTarget:self selector:@selector(displayLinkFired:)];
		[_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
	}
}

- (void)displayLinkFired:(CADisplayLink *)link
{
	double	scale = _fullResolution ? (self.window.backingScaleFactor ?: 1) : 1;
	NSSize	size = self.bounds.size;
	int		w = (int)std::lround(size.width * scale);
	int		h = (int)std::lround(size.height * scale);
	CFTimeInterval	period = link.targetTimestamp - link.timestamp;
	int		rate = period > 0 ? (int)std::lround(1 / period) : 60;
	[_engine requestFrameWithPixelWidth:w height:h scale:scale refreshRate:rate];
}

- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if (_tracking)
		[self removeTrackingArea:_tracking];
	_tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
		options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
		owner:self userInfo:nil];
	[self addTrackingArea:_tracking];
}

- (void)reportMouse:(NSEvent *)event
{
	NSPoint	pt = [self convertPoint:event.locationInWindow fromView:nil];
	NSSize	size = self.bounds.size;
	if (size.width <= 0 || size.height <= 0)
		return;
	// view y points up; the engine's normalized y points down
	[_engine setCursorPosition:CGPointMake(pt.x / size.width, 1 - pt.y / size.height)];
}

- (void)scrollWheel:(NSEvent *)event
{
	if (!_wheelHandler)
		return;
	// a mouse wheel reports lines (about one per notch); a trackpad reports
	// points, so treat 10 points as a notch
	BOOL	shift = (event.modifierFlags & NSEventModifierFlagShift) != 0;
	// macOS turns Shift + wheel into horizontal scrolling
	double	delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : (shift ? event.scrollingDeltaX : 0);
	double	notches = event.hasPreciseScrollingDeltas ? delta / 10 : delta;
	if (notches != 0)
		_wheelHandler(notches, shift);
}

- (void)mouseMoved:(NSEvent *)event { [self reportMouse:event]; }
- (void)mouseDragged:(NSEvent *)event { [self reportMouse:event]; }

@end
