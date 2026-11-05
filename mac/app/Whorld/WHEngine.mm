// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#import "WHEngine.h"

#import <CoreMIDI/CoreMIDI.h>

#include "CGRenderer.h"
#include "VideoWriter.h"
#include <IOSurface/IOSurface.h>
#include "whorld/Controls.h"
#include "whorld/MidiManager.h"
#include "whorld/Playlist.h"
#include "whorld/Patch.h"
#include "whorld/WhorldEngine.h"

#include <chrono>
#include <cmath>
#include <atomic>
#include <condition_variable>
#include <functional>
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

@implementation WHMappingInfo
+ (NSInteger)eventCount { return whorld::MappingBase::EVENTS; }
+ (NSInteger)targetCount { return whorld::MappingBase::TARGETS; }
+ (NSInteger)paramTargetCount { return WhorldBase::PARAM_COUNT; }
+ (NSInteger)masterTargetCount { return WhorldBase::MASTER_COUNT; }
+ (NSString *)eventName:(NSInteger)i { return ToNS(whorld::MappingBase::GetEventName((int)i)); }
+ (NSString *)targetName:(NSInteger)i { return ToNS(whorld::MappingBase::GetTargetName((int)i)); }
+ (BOOL)targetHasProperty:(NSInteger)i { return whorld::MappingBase::TargetHasProperty((int)i); }
+ (WHMappingData)defaultMapping
{
	whorld::Mapping	m;
	return WHMappingData{m.m_iEvent, m.m_iChannel, m.m_iControl, m.m_iTarget, m.m_iProp, m.m_fStart, m.m_fEnd};
}
// ported from MappingBar.cpp CMappingBar::OnMidiEvent and LearnMapping
+ (BOOL)learn:(uint32_t)nInMidiMsg into:(WHMappingData *)pMap
{
	using namespace whorld;
	int	iCmd = MIDI_CMD_IDX(nInMidiMsg);	// convert MIDI status to command index
	if (iCmd < 0 || iCmd >= MIDI_CHANNEL_VOICE_MESSAGES)	// if not channel voice message
		return NO;
	// remove data from message by clearing second or both parameters
	if (iCmd <= MIDI_CVM_CONTROL) {	// if message has a note/controller
		nInMidiMsg &= ~MIDI_P2_MASK;	// only clear its second parameter
	} else {	// message doesn't have a note/controller; only status matters
		nInMidiMsg &= ~(MIDI_P1_MASK | MIDI_P2_MASK);	// clear both parameters
	}
	Mapping	m;
	m.SetInputMidiMsg(nInMidiMsg);
	pMap->event = m.m_iEvent;
	pMap->channel = m.m_iChannel;
	pMap->control = m.m_iControl;
	return YES;
}
@end

static whorld::Mapping FromWHMapping(const WHMappingData& d)
{
	whorld::Mapping	m;
	m.m_iEvent = d.event;
	m.m_iChannel = d.channel;
	m.m_iControl = d.control;
	m.m_iTarget = d.target;
	m.m_iProp = d.prop;
	m.m_fStart = d.start;
	m.m_fEnd = d.end;
	return m;
}

static WHMappingData ToWHMapping(const whorld::Mapping& m)
{
	return WHMappingData{m.m_iEvent, m.m_iChannel, m.m_iControl, m.m_iTarget, m.m_iProp, m.m_fStart, m.m_fEnd};
}

@class WHEngine;
// Receives MidiManager output on the CoreMIDI thread.
class WHMidiSink : public whorld::MidiManager::Sink {
public:
	__weak WHEngine	*m_engine = nil;
	void	PushCommand(const WhorldBase::RenderCmd& cmd) override;
	void	PostToMain(const whorld::MidiManager::Post& post) override;
};

@interface WHEngine ()
- (void)pushCommand:(const RenderCmd &)cmd;
- (void)applyMidiPost:(const whorld::MidiManager::Post &)post;
@end

void WHMidiSink::PushCommand(const WhorldBase::RenderCmd& cmd)
{
	[m_engine pushCommand:cmd];
}

void WHMidiSink::PostToMain(const whorld::MidiManager::Post& post)
{
	__weak WHEngine	*engine = m_engine;
	whorld::MidiManager::Post	copy = post;
	dispatch_async(dispatch_get_main_queue(), ^{
		[engine applyMidiPost:copy];
	});
}

@implementation WHEngine {
	// shared between threads, guarded by _mutex
	std::mutex	_mutex;
	std::condition_variable	_cv;
	// replaces CRenderThread's interlocked ring buffer; items are commands
	// or render-thread jobs, run in order
	struct QueueItem {
		RenderCmd	cmd;
		std::function<void()>	job;	// if set, run instead of the command
	};
	std::vector<QueueItem>	_queue;
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
	whorld::WhorldEngine::MovieState	_liveMovie;	// movie state after the last frame
	whorld::SizeF	_liveTarget;	// render target size in DIPs
	std::atomic<bool>	_cancelExport;
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
	// MIDI
	WHMidiSink	_midiSink;
	std::unique_ptr<whorld::MidiManager>	_midiMgr;
	MIDIClientRef	_midiClient;
	MIDIPortRef	_midiPort;
	MIDIEndpointRef	_midiSource;	// connected source, or 0
	NSString	*_midiInputName;
	std::vector<std::string>	_playlistPatches;
	// main thread only
	whorld::Patch	_doc;	// the document, as CWhorldDoc
	BOOL	_paused;
	BOOL	_modified;
	BOOL	_snapshotMode;
	std::unique_ptr<whorld::Patch>	_preSnapshotPatch;	// m_pPreSnapshotModePatch
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
		_liveMovie = _engine->GetMovieState();
		_liveTarget = whorld::SizeF{0, 0};
		_cancelExport = false;
		__weak WHEngine	*weakSelf = self;
		_engine->SetReplyCallback([weakSelf](const whorld::WhorldEngine::Reply& r) {
			if (!r.sError.empty()) {	// movie error (OnMovieError's message box)
				NSString	*msg = ToNS(r.sError);
				dispatch_async(dispatch_get_main_queue(), ^{
					WHEngine	*strong = weakSelf;
					if (strong.movieErrorHandler)
						strong.movieErrorHandler(msg);
				});
			}
		});
		_midiSink.m_engine = self;
		_midiMgr = std::make_unique<whorld::MidiManager>(_midiSink);
		[self setUpMidi];
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
	if (_midiPort)
		MIDIPortDispose(_midiPort);
	if (_midiClient)
		MIDIClientDispose(_midiClient);
	if (_thread.joinable())
		_thread.join();
	[self releaseSurfaces];
	for (const QueueItem& item : _queue) {	// free payloads the thread never took
		if (item.job)
			continue;
		if (item.cmd.m_nCmd == WhorldBase::RC_SET_PATCH)
			delete static_cast<whorld::Patch *>(item.cmd.m_prop.byref);
		else if (item.cmd.m_nCmd == WhorldBase::RC_DISPLAY_SNAPSHOT)
			delete static_cast<whorld::Snapshot *>(item.cmd.m_prop.byref);
		else if (item.cmd.m_nCmd == WhorldBase::RC_MOVIE_RECORD || item.cmd.m_nCmd == WhorldBase::RC_MOVIE_PLAY)
			delete static_cast<std::string *>(item.cmd.m_prop.byref);
	}
}

#pragma mark - Commands

- (void)pushCommand:(const RenderCmd &)cmd
{
	std::lock_guard<std::mutex>	lock(_mutex);
	_queue.push_back(QueueItem{cmd, nullptr});
}

// Runs a block on the render thread, in order with the commands.
- (void)pushJob:(std::function<void()>)job
{
	std::lock_guard<std::mutex>	lock(_mutex);
	_queue.push_back(QueueItem{RenderCmd(0), std::move(job)});
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

// CMainFrame::OnWindowPause: pauses the movie if one is playing, else the app
- (void)togglePause
{
	WHMovieState	ms = self.movieState;
	if (ms.io == WHMovieIOReading) {
		[self pauseMovie:!ms.paused];
		return;
	}
	[self setPaused:!_paused];
}

// ported from Whorld.cpp CWhorldApp::SetPause
- (void)setPaused:(BOOL)bEnable
{
	if (bEnable == _paused)	// if already in requested state
		return;	// nothing to do
	[self pushCommand:RenderCmd(WhorldBase::RC_SET_PAUSE, bEnable ? 1 : 0)];
	_paused = bEnable;	// update our paused state
	if (!bEnable) {	// if we're unpausing
		[self setSnapshotMode:NO];	// exit snapshot mode
	}
}

// ported from Whorld.cpp CWhorldApp::SetSnapshotMode
- (void)setSnapshotMode:(BOOL)bEnable
{
	if (bEnable == _snapshotMode)	// if already in requested mode
		return;	// nothing to do
	_snapshotMode = bEnable;
	if (bEnable) {	// if entering snapshot mode
		[self setPaused:YES];	// pause render updates while showing snapshot
		if (!_preSnapshotPatch)	// if pre-snapshot mode backup unmade
			_preSnapshotPatch = std::make_unique<whorld::Patch>(_doc);
		// zoom is relative to the snapshot's zoom; the render thread resets
		// its zoom to 100% when it enters snapshot mode
		_doc.m_master.fZoom = 1;
	} else {	// exiting snapshot mode
		if (_preSnapshotPatch) {
			_doc = *_preSnapshotPatch;	// copy previously saved patch to document
			_preSnapshotPatch.reset();
			[self pushPatch];	// notify views of new patch
		}
	}
}

- (BOOL)snapshotMode { return _snapshotMode; }

#pragma mark - Snapshots

- (void)takeSnapshotToPath:(NSString *)path completion:(void (^)(NSString *))completion
{
	std::string	sPath = path.fileSystemRepresentation;
	whorld::WhorldEngine	*pEngine = _engine.get();
	[self pushJob:[pEngine, sPath, completion] {
		auto	pSnapshot = pEngine->OnCaptureSnapshot();	// CWhorldThread::OnCaptureSnapshot
		std::string	sErr;
		bool	bOk = whorld::Snapshot::Write(pSnapshot.get(), sPath, &sErr);	// CMainFrame::WriteSnapshot
		NSString	*msg = bOk ? nil : ToNS(sErr);
		dispatch_async(dispatch_get_main_queue(), ^{ completion(msg); });
	}];
}

// ported from Whorld.cpp CWhorldApp::LoadSnapshot
- (BOOL)loadSnapshotAtPath:(NSString *)path error:(NSError **)error
{
	std::string	sErr;
	std::unique_ptr<whorld::Snapshot>	pSnapshot = whorld::Snapshot::Read(path.fileSystemRepresentation, &sErr,
		[self legacySnapshotSize]);
	if (!pSnapshot) {	// if read failed
		if (error) {
			*error = [NSError errorWithDomain:@"Whorld" code:5 userInfo:@{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Can't open \"%@\".", path.lastPathComponent],
				NSLocalizedRecoverySuggestionErrorKey: ToNS(sErr) }];
		}
		return NO;
	}
	[self setSnapshotMode:YES];	// enter snapshot mode
	_doc.m_main.bMirror = pSnapshot->m_drawState.bMirror;
	RenderCmd	cmd(WhorldBase::RC_DISPLAY_SNAPSHOT);	// render thread takes ownership
	cmd.m_prop.byref = pSnapshot.release();
	[self pushCommand:cmd];
	return YES;
}

// COptions::GetLegacySnapshotSize, from the preference
- (whorld::IntSize)legacySnapshotSize
{
	static const whorld::IntSize	aSize[] = {{640, 480}, {800, 600}, {1024, 768}};	// LEGACYSIZEDEF
	NSInteger	i = [NSUserDefaults.standardUserDefaults integerForKey:@"Snapshot_iLegacySize"];
	if ([NSUserDefaults.standardUserDefaults objectForKey:@"Snapshot_iLegacySize"] == nil)
		i = 1;
	return aSize[std::min<NSInteger>(std::max<NSInteger>(i, 0), 2)];
}

// ported from MainFrm.cpp CMainFrame::OnSnapshotInfo
+ (NSString *)snapshotInfoAtPath:(NSString *)path
{
	auto	pSnapshot = whorld::Snapshot::Read(path.fileSystemRepresentation);
	if (!pSnapshot)
		return nil;
	const auto&	ds = pSnapshot->m_drawState;
	int	nVersion = !(ds.nFlags & whorld::Snapshot::SF_V1) + 1;
	return [NSString stringWithFormat:@"Name:\t%@\nSize:\t%g x %g\nZoom:\t%g\nRings:\t%d\nVersion:\t%d",
		path.lastPathComponent.stringByDeletingPathExtension, ds.szTarget.width, ds.szTarget.height,
		ds.fZoom, ds.nRings, nVersion];
}

#pragma mark - Export

- (CGSize)viewSize
{
	std::lock_guard<std::mutex>	lock(_mutex);
	return CGSizeMake(_liveTarget.width, _liveTarget.height);
}

// Render thread: CWhorldDraw::CaptureBitmap and WriteCapturedBitmap
static std::string CaptureToPNG(whorld::WhorldEngine& eng, uint32_t nFlags, whorld::IntSize sz, const std::string& sPath)
{
	whorld::IntSize	szImage = eng.GetCaptureSize(nFlags, sz);
	if (szImage.cx <= 0 || szImage.cy <= 0)
		return "The image size is empty.";
	whorld::CGBitmapRenderer	renderer(szImage.cx, szImage.cy, 1);
	if (!renderer.IsValid())
		return "Can't create the image.";
	renderer.SetDeferred(true);
	renderer.BeginFrame();
	eng.DrawCapture(renderer, nFlags, sz);
	renderer.EndFrame();
	std::string	sErr;
	if (!renderer.WritePNG(sPath, &sErr))
		return sErr;
	return std::string();
}

- (void)exportImageToPath:(NSString *)path flags:(WHExportFlags)flags width:(int)width height:(int)height
	completion:(void (^)(NSString *))completion
{
	std::string	sPath = path.fileSystemRepresentation;
	whorld::WhorldEngine	*pEngine = _engine.get();
	[self pushJob:[pEngine, sPath, flags, width, height, completion] {
		std::string	sErr = CaptureToPNG(*pEngine, flags, whorld::IntSize{width, height}, sPath);
		NSString	*msg = sErr.empty() ? nil : ToNS(sErr);
		dispatch_async(dispatch_get_main_queue(), ^{ completion(msg); });
	}];
}

#pragma mark - Movies

- (void)recordMovieToPath:(NSString *)path
{
	RenderCmd	cmd(WhorldBase::RC_MOVIE_RECORD);
	cmd.m_prop.byref = path ? new std::string(path.fileSystemRepresentation) : nullptr;
	[self pushCommand:cmd];
}

// ported from MainFrm.cpp CMainFrame::PlayMovie
- (void)playMovieAtPath:(NSString *)path paused:(BOOL)paused
{
	RenderCmd	cmd(WhorldBase::RC_MOVIE_PLAY, paused ? 1 : 0);
	cmd.m_prop.byref = path ? new std::string(path.fileSystemRepresentation) : nullptr;
	[self pushCommand:cmd];
	if (path) {
		[self setSnapshotMode:YES];
	} else {
		[self setPaused:NO];	// exit snapshot mode and resume patch
	}
}

- (void)pauseMovie:(BOOL)pause
{
	[self pushCommand:RenderCmd(WhorldBase::RC_MOVIE_PAUSE, pause ? 1 : 0)];
	std::lock_guard<std::mutex>	lock(_mutex);
	_liveMovie.bPaused = pause;	// show it right away
}

- (void)seekMovie:(int64_t)frame
{
	RenderCmd	cmd(WhorldBase::RC_MOVIE_SEEK);
	cmd.m_prop.llVal = frame;
	[self pushCommand:cmd];
}

- (WHMovieState)movieState
{
	std::lock_guard<std::mutex>	lock(_mutex);
	const auto&	m = _liveMovie;
	return WHMovieState{(WHMovieIO)m.nIOState, m.nFrameCount, m.iFrame, m.fFrameRate,
		CGSizeMake(m.szFrame.width, m.szFrame.height), m.bPaused};
}

// ported from WhorldThread.cpp CWhorldThread::OnMovieExport and MakeImageSequenceFileName
- (void)exportMovieToFolder:(NSString *)folder start:(int64_t)start end:(int64_t)end
	flags:(WHExportFlags)flags width:(int)width height:(int)height
	progress:(void (^)(int64_t))progress completion:(void (^)(NSString *))completion
{
	std::string	sFolder = folder.fileSystemRepresentation;
	whorld::WhorldEngine	*pEngine = _engine.get();
	std::atomic<bool>	*pCancel = &_cancelExport;
	_cancelExport = false;
	[self pushJob:[pEngine, sFolder, start, end, flags, width, height, progress, completion, pCancel] {
		std::string	sErr;
		// end frame is inclusive, hence the plus one
		int64_t	nFrames = end - start + 1;
		if (!pEngine->MovieExportStart(start)) {
			sErr = "Can't seek to the first frame.";
		} else {
			for (int64_t iFrame = 0; iFrame < nFrames; iFrame++) {
				if (*pCancel)	// if task canceled
					break;	// abort
				if (!pEngine->MovieExportStep()) {	// if can't read frame
					sErr = "Can't read frame " + std::to_string(start + iFrame) + ".";
					break;	// fail
				}
				char	szName[32];
				std::snprintf(szName, sizeof(szName), "/img%06lld.png", static_cast<long long>(iFrame));
				sErr = CaptureToPNG(*pEngine, flags, whorld::IntSize{width, height}, sFolder + szName);
				if (!sErr.empty())
					break;
				int64_t	nDone = iFrame + 1;
				dispatch_async(dispatch_get_main_queue(), ^{ progress(nDone); });
			}
		}
		NSString	*msg = sErr.empty() ? nil : ToNS(sErr);
		dispatch_async(dispatch_get_main_queue(), ^{ completion(msg); });
	}];
}

- (void)exportMovieVideoToPath:(NSString *)path codec:(NSInteger)codec start:(int64_t)start end:(int64_t)end
	flags:(WHExportFlags)flags width:(int)width height:(int)height
	progress:(void (^)(int64_t))progress completion:(void (^)(NSString *))completion
{
	std::string	sPath = path.fileSystemRepresentation;
	whorld::WhorldEngine	*pEngine = _engine.get();
	std::atomic<bool>	*pCancel = &_cancelExport;
	_cancelExport = false;
	[self pushJob:[pEngine, sPath, codec, start, end, flags, width, height, progress, completion, pCancel] {
		whorld::VideoExportOptions	opts;
		opts.codec = static_cast<whorld::VideoWriter::Codec>(codec);
		opts.nFlags = flags;
		opts.szImage = whorld::IntSize{width, height};
		opts.nStartFrame = start;
		opts.nEndFrame = end;
		std::string	sErr;
		bool	bOk = whorld::ExportMovieVideo(*pEngine, sPath, opts, [&](int64_t nDone, int64_t) {
			dispatch_async(dispatch_get_main_queue(), ^{ progress(nDone); });
			return !*pCancel;
		}, &sErr);
		NSString	*msg = bOk ? nil : ToNS(sErr);
		dispatch_async(dispatch_get_main_queue(), ^{ completion(msg); });
	}];
}

- (void)cancelMovieExport
{
	_cancelExport = true;
}

- (void)setPlaylistPatches:(NSArray<NSString *> *)paths
{
	_playlistPatches.clear();
	for (NSString *p in paths)
		_playlistPatches.push_back(p.UTF8String);
}

- (void)singleStep
{
	[self pushCommand:RenderCmd(WhorldBase::RC_SINGLE_STEP)];
}

- (void)clear
{
	[self pushCommand:RenderCmd(WhorldBase::RC_SET_EMPTY)];
}

#pragma mark - MIDI

// Replaces CMidiManager's WinMM input (MidiWrap, MidiDevices): a CoreMIDI
// client and input port. CoreMIDI delivers Universal MIDI Packets; MIDI 1.0
// channel voice packets (type 2) carry the original status and data bytes,
// which are repacked as a WinMM short message for CMidiManager::OnMidiEvent.
- (void)setUpMidi
{
	__weak WHEngine	*weakSelf = self;
	OSStatus	err = MIDIClientCreateWithBlock(CFSTR("Whorld"), &_midiClient, ^(const MIDINotification *note) {
		if (note->messageID == kMIDIMsgSetupChanged) {	// CMidiManager::OnDeviceChange
			dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf midiSetupChanged]; });
		}
	});
	if (err != noErr)
		return;
	whorld::MidiManager	*pMgr = _midiMgr.get();
	err = MIDIInputPortCreateWithProtocol(_midiClient, CFSTR("Whorld Input"), kMIDIProtocol_1_0, &_midiPort,
		^(const MIDIEventList *evtlist, void *srcConnRefCon) {
		(void)srcConnRefCon;
		const MIDIEventPacket	*packet = &evtlist->packet[0];
		for (UInt32 i = 0; i < evtlist->numPackets; i++) {
			for (UInt32 w = 0; w < packet->wordCount; w++) {
				UInt32	word = packet->words[w];
				if ((word >> 28) == kMIDIMessageTypeChannelVoice1) {	// MIDI 1.0 channel voice
					uint32_t	status = (word >> 16) & 0xff;
					uint32_t	d1 = (word >> 8) & 0x7f;
					uint32_t	d2 = word & 0x7f;
					pMgr->OnMidiEvent(status | (d1 << 8) | (d2 << 16));
				}
			}
			packet = MIDIEventPacketNext(packet);
		}
	});
	if (err != noErr)
		_midiPort = 0;
}

static NSString *SourceName(MIDIEndpointRef src)
{
	CFStringRef	name = nullptr;
	if (MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name) != noErr || !name)
		MIDIObjectGetStringProperty(src, kMIDIPropertyName, &name);
	return name ? (__bridge_transfer NSString *)name : @"";
}

- (NSArray<NSString *> *)midiInputNames
{
	NSMutableArray	*names = [NSMutableArray array];
	ItemCount	n = MIDIGetNumberOfSources();
	for (ItemCount i = 0; i < n; i++)
		[names addObject:SourceName(MIDIGetSource(i))];
	return names;
}

- (NSString *)midiInputName { return _midiInputName; }

// CMidiManager::OpenInputDevice: connect the named source, by name so the
// choice survives reconnecting the device
- (void)setMidiInputName:(NSString *)name
{
	_midiInputName = [name copy];
	[self connectMidiInput];
}

- (void)connectMidiInput
{
	if (!_midiPort)
		return;
	if (_midiSource) {
		MIDIPortDisconnectSource(_midiPort, _midiSource);
		_midiSource = 0;
	}
	if (!_midiInputName.length)
		return;
	ItemCount	n = MIDIGetNumberOfSources();
	for (ItemCount i = 0; i < n; i++) {
		MIDIEndpointRef	src = MIDIGetSource(i);
		if ([SourceName(src) isEqualToString:_midiInputName]) {
			if (MIDIPortConnectSource(_midiPort, src, nullptr) == noErr)
				_midiSource = src;
			break;
		}
	}
}

- (void)midiSetupChanged
{
	[self connectMidiInput];	// reconnect if the device came back
	if (_midiHandler)
		_midiHandler(4, 0);
}

- (BOOL)midiLearn { return _midiMgr->IsLearnMode(); }
- (void)setMidiLearn:(BOOL)b { _midiMgr->SetLearnMode(b); }

- (NSInteger)mappingCount { return _midiMgr->m_midiMaps.GetCount(); }

- (WHMappingData)mappingAt:(NSInteger)index
{
	std::lock_guard<std::mutex>	lock(_midiMgr->m_midiMaps.GetMutex());
	return ToWHMapping(_midiMgr->m_midiMaps.GetAt((int)index));
}

- (void)setMappings:(const WHMappingData *)p count:(NSInteger)n
{
	whorld::MappingArray	arr;
	for (NSInteger i = 0; i < n; i++)
		arr.push_back(FromWHMapping(p[i]));
	_midiMgr->m_midiMaps.SetArray(arr);
}

// The main-thread side of a MIDI change (CMainFrame::OnParamChange,
// OnMasterPropChange, OnMainPropChange, OnSetDrawMode, OnPlayPatch, the
// pause command, and CMappingBar::OnMidiEvent): update the document with
// undo disabled. The render thread already has the change.
- (void)applyMidiPost:(const whorld::MidiManager::Post &)post
{
	using Post = whorld::MidiManager::Post;
	switch (post.type) {
	case Post::PARAM_CHANGE:
		{
			WhorldBase::VARIANT_PROP	v;
			v.llVal = 0;
			if (post.iProp == WhorldBase::PARAM_PROP_Wave)
				v.intVal = post.iVal;	// waveform is assumed to be integer
			else
				v.dblVal = post.fVal;	// all other properties are assumed to be float
			_doc.SetParamRC(post.iParam, post.iProp, v);
			_modified = YES;
		}
		break;
	case Post::MASTER_PROP_CHANGE:
		_doc.SetMasterProp(post.iProp, post.fVal);
		_modified = YES;
		break;
	case Post::MAIN_PROP_CHANGE:
		{
			WhorldBase::VARIANT_PROP	v;
			v.llVal = post.iVal;	// VARIANT_PROP prop = {lParam}
			_doc.SetMainProp(post.iProp, v);
			_modified = YES;
		}
		break;
	case Post::SET_DRAW_MODE:
		// first clear any bits that are non-zero in the mask; then set
		// any bits that are non-zero in both the mask and the value
		_doc.m_main.nDrawMode = (_doc.m_main.nDrawMode & ~post.nMask) | (post.nValue & post.nMask);
		_modified = YES;
		break;
	case Post::PAUSE:
		[self togglePause];
		if (_midiHandler)
			_midiHandler(1, 0);
		return;
	case Post::PLAY_PATCH:
		if (_midiHandler)
			_midiHandler(2, (uint32_t)post.iVal);
		return;
	case Post::MIDI_EVENT:
		if (_midiHandler)
			_midiHandler(3, post.nMsg);
		return;
	}
	if (_midiHandler)
		_midiHandler(0, 0);
}

#pragma mark - Playlist

- (void)newPlaylist
{
	_playlistPatches.clear();
	_midiMgr->m_midiMaps.RemoveAll();
}

// ported from Playlist.cpp CPlaylist::OnOpenDocument
- (BOOL)openPlaylistAtPath:(NSString *)path error:(NSError **)error
{
	whorld::Playlist	pl;
	std::string	sErr;
	bool	bNewer = false;
	if (!pl.Read(path.fileSystemRepresentation, &sErr, &bNewer)) {
		if (error) {
			*error = [NSError errorWithDomain:@"Whorld" code:3 userInfo:@{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Can't open \"%@\".", path.lastPathComponent],
				NSLocalizedRecoverySuggestionErrorKey: ToNS(sErr) }];
		}
		return NO;
	}
	_playlistPatches = pl.m_arrPatch;
	_midiMgr->m_midiMaps.SetArray(pl.m_arrMapping);
	return YES;
}

// ported from Playlist.cpp CPlaylist::OnSaveDocument
- (BOOL)savePlaylistToPath:(NSString *)path error:(NSError **)error
{
	whorld::Playlist	pl;
	pl.m_arrPatch = _playlistPatches;
	pl.m_arrMapping = _midiMgr->m_midiMaps.GetArray();
	std::string	sErr;
	if (!pl.Write(path.fileSystemRepresentation, &sErr)) {
		if (error) {
			*error = [NSError errorWithDomain:@"Whorld" code:4 userInfo:@{
				NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Can't save \"%@\".", path.lastPathComponent],
				NSLocalizedRecoverySuggestionErrorKey: ToNS(sErr) }];
		}
		return NO;
	}
	return YES;
}

- (NSArray<NSString *> *)playlistPatches
{
	NSMutableArray	*a = [NSMutableArray array];
	for (const std::string& s : _playlistPatches)
		[a addObject:ToNS(s)];
	return a;
}

// CPlaylistBar::Play then CWhorldDoc::SetPatch: the patch becomes an
// untitled, unmodified document
- (BOOL)playPatchAtPath:(NSString *)path
{
	whorld::Patch	patch;
	if (!patch.Read(path.fileSystemRepresentation))
		return NO;
	_doc = patch;
	_patchPath = nil;
	_modified = NO;
	[self pushPatch];
	return YES;
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
		std::vector<QueueItem>	cmds;
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
		for (QueueItem& item : cmds) {	// ProcessCommand
			if (item.job)
				item.job();
			else
				_engine->OnRenderCommand(item.cmd);
		}
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
		whorld::WhorldEngine::MovieState	movieState = _engine->GetMovieState();
		{
			std::lock_guard<std::mutex>	lock(_mutex);
			_liveOrigin = ptOrigin;
			_liveMovie = movieState;
			_liveTarget = whorld::SizeF{float(w / scale), float(h / scale)};
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
