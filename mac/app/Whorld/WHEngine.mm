// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#import "WHEngine.h"

#import <CoreMIDI/CoreMIDI.h>
#import "WHOscServer.h"
#import "WHSyphon.h"
#import "WHAudioInput.h"
#import "WHLink.h"
#include "whorld/OscRemote.h"
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <map>

#include "CGRenderer.h"
#include "MetalRenderer.h"
#include "AudioVideoExport.h"
#include "VideoWriter.h"
#include <IOSurface/IOSurface.h>
#include "whorld/Controls.h"
#include "whorld/MidiManager.h"
#include "whorld/Playlist.h"
#include "whorld/Patch.h"
#include "whorld/Version.h"
#include "whorld/WhorldEngine.h"

#include <chrono>
#include <cmath>
#include <atomic>
#include <condition_variable>
#include <deque>
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
+ (double)paramDefault:(NSInteger)i column:(NSInteger)col
{
	whorld::WhorldBase::PARAM_TABLE	t;
	whorld::WhorldBase::SetParamDefaults(t);
	const auto&	row = t.row[i];
	switch (col) {
	case 0: return row.fVal;
	case 1: return row.fAmp;
	case 2: return row.fFreq;
	case 3: return row.fPW;
	default: return row.fGlobal;
	}
}
+ (double)masterDefault:(NSInteger)i { return whorld::WhorldBase::m_masterDefault.a[i]; }
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

+ (NSString *)upstreamBaseline {
	return @(whorld::UpstreamBaseline());
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
+ (NSString *)targetTag:(NSInteger)i { return ToNS(whorld::MappingBase::GetTargetTag((int)i)); }
+ (NSInteger)targetForTag:(NSString *)tag { return whorld::MappingBase::FindTargetTag(tag.UTF8String ?: ""); }
+ (BOOL)targetIsRange:(NSInteger)i { return whorld::MappingBase::GetTargetType((int)i) == whorld::MappingBase::TT_RANGE; }
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

// The finished frame waiting for the next refresh, and statistics of frames
// as they finish. Both renderers put frames here; presentFrame takes them.
// Metal completion handlers hold it too, and can run after the engine is
// gone, hence a shared_ptr.
struct WHHandoff {
	std::mutex	m;
	// Finished frames, oldest first, at most two; one is shown per refresh.
	// A queue, not a single slot: a GPU frame can finish just after a
	// refresh, and the next one before the following refresh; with a slot
	// the first would be replaced unseen (a visible skip). Here it's shown a
	// refresh late instead.
	struct Ready {
		IOSurfaceRef	image;	// claimed (see Release)
		double	scale;
	};
	std::deque<Ready>	ready;
	static const size_t	kMaxReady = 2;
	double	gpuSum = 0;		// GPU milliseconds of Metal frames since the last read
	int		gpuFrames = 0;
	std::atomic<bool>	metalFailed{false};	// a Metal frame failed: use Core Graphics
	std::atomic<bool>	metalActive{false};	// the last frame was drawn by Metal
	std::atomic<int>	nDropped{0};	// frames replaced before being shown
	std::atomic<int>	nNoSurface{0};	// frames skipped: no free surface
	std::atomic<int>	nDone{0};		// frames finished

	~WHHandoff()
	{
		for (const Ready& r : ready)
			Release(r.image);
	}
	// A frame's surface is retained and has its use count raised from the
	// moment it's drawn until it's dropped or replaced on the layer; the
	// render thread reuses only surfaces not in use (IOSurfaceIsInUse, which
	// also covers the window server). Retain counts can't tell: Metal keeps
	// its own references to surfaces it has drawn into.
	static void	Release(IOSurfaceRef image)
	{
		IOSurfaceDecrementUseCount(image);
		CFRelease(image);
	}
	// takes over the caller's claim on image; if two frames are already
	// waiting (refreshes stalled), the oldest is dropped
	void	Put(IOSurfaceRef image, double fScale)
	{
		IOSurfaceRef	stale = nullptr;
		{
			std::lock_guard<std::mutex>	lock(m);
			if (ready.size() >= kMaxReady) {
				stale = ready.front().image;
				ready.pop_front();
			}
			ready.push_back(Ready{image, fScale});
		}
		nDone++;
		if (stale) {
			nDropped++;
			Release(stale);
		}
	}
	IOSurfaceRef	Take(double& fScale)	// the oldest frame, claimed, or null
	{
		std::lock_guard<std::mutex>	lock(m);
		if (ready.empty())
			return nullptr;
		Ready	r = ready.front();
		ready.pop_front();
		fScale = r.scale;
		return r.image;
	}
};
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

@implementation WHAudioVideoOptions
- (instancetype)init
{
	if ((self = [super init])) {
		_width = 1920;
		_height = 1080;
		_frameRate = 60;
		_duration = -1;
		_downbeat = -1;
		_rangeDb = 36;
		_hitThreshold = 4;
		_depth = 1;
		_playlistIndex = -1;
		_rows = @[];
		_syncs = @[];
	}
	return self;
}
@end

static std::vector<whorld::ModRow> ModRowsFrom(NSArray<WHModRow *> *rows)
{
	std::vector<whorld::ModRow>	a;
	for (WHModRow *r in rows) {
		whorld::ModRow	row;
		row.bOn = r.on;
		row.iSource = whorld::ModSources::FindTag(r.source.UTF8String);
		row.iAction = r.action.length ? whorld::ModActions::FindTag(r.action.UTF8String) : -1;
		row.iTarget = static_cast<int>(r.target);
		row.iProp = static_cast<int>(r.prop);
		row.fAmount = r.amount;
		row.nCurve = static_cast<int>(r.curve);
		row.bCentered = r.centered;
		row.fAttack = r.attack;
		row.fRelease = r.releaseTime;
		row.fThreshold = r.threshold;
		row.fOffset = std::clamp(r.offset, -0.3, 0.3);
		a.push_back(row);
	}
	return a;
}

static std::vector<whorld::ModSync> ModSyncsFrom(NSArray<WHModSync *> *syncs)
{
	std::vector<whorld::ModSync>	a;
	for (WHModSync *y in syncs) {
		whorld::ModSync	sync;
		sync.bOn = y.on;
		sync.iParam = static_cast<int>(y.param);
		sync.fBeats = y.beats;
		sync.fPhase = y.phase;
		sync.fOffset = std::clamp(y.offset, -0.3, 0.3);
		a.push_back(sync);
	}
	return a;
}

@implementation WHModSync
- (instancetype)init
{
	if ((self = [super init])) {
		whorld::ModSync	sync;
		_on = sync.bOn;
		_param = sync.iParam;
		_beats = sync.fBeats;
		_phase = sync.fPhase;
		_offset = sync.fOffset;
	}
	return self;
}
@end

@implementation WHModRow
- (instancetype)init
{
	if ((self = [super init])) {
		whorld::ModRow	row;
		_on = row.bOn;
		_source = @(whorld::ModSources::GetTag(row.iSource));
		_target = row.iTarget;
		_prop = row.iProp;
		_amount = row.fAmount;
		_curve = row.nCurve;
		_centered = row.bCentered;
		_attack = row.fAttack;
		_releaseTime = row.fRelease;
		_threshold = row.fThreshold;
		_offset = row.fOffset;
	}
	return self;
}

+ (NSArray<NSString *> *)sourceTags
{
	NSMutableArray	*a = [NSMutableArray array];
	for (int i = 0; i < whorld::ModSources::SOURCES; i++)
		[a addObject:@(whorld::ModSources::GetTag(i))];
	return a;
}

+ (NSArray<NSString *> *)actionTags
{
	NSMutableArray	*a = [NSMutableArray array];
	for (int i = 0; i < whorld::ModActions::ACTIONS; i++)
		[a addObject:@(whorld::ModActions::GetTag(i))];
	return a;
}

+ (NSString *)sourceName:(NSString *)tag
{
	return @(whorld::ModSources::GetName(whorld::ModSources::FindTag(tag.UTF8String)));
}

+ (NSString *)actionName:(NSString *)tag
{
	return @(whorld::ModActions::GetName(whorld::ModActions::FindTag(tag.UTF8String)));
}

+ (BOOL)isTriggerSource:(NSString *)tag
{
	return whorld::ModSources::IsTrigger(whorld::ModSources::FindTag(tag.UTF8String));
}

+ (BOOL)isModulatableTarget:(NSInteger)target prop:(NSInteger)prop
{
	return whorld::ModRow::IsModulatable(static_cast<int>(target), static_cast<int>(prop));
}
@end

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
	bool	_ringFadeEased;	// the ring fade curve setting
	bool	_ringFadeChanged;
	bool	_hueFromPatch;	// the patch colors on load setting
	bool	_hueFromPatchChanged;
	std::vector<whorld::ModRow>	_modRows;	// modulation, for the render thread
	std::vector<whorld::ModSync>	_modSyncs;
	double	_modDepth;
	bool	_modBypass;
	bool	_modFollowTempo;
	bool	_modChanged;
	std::vector<double>	_modLevels;	// from the render thread, for meters
	whorld::DPoint	_cursor;
	double	_statRenderSum;
	int		_statFrames;
	size_t	_statRings;
	whorld::DPoint	_liveOrigin;	// normalized origin after the last frame
	whorld::WhorldEngine::MovieState	_liveMovie;	// movie state after the last frame
	whorld::SizeF	_liveTarget;	// render target size in DIPs
	std::shared_ptr<WHHandoff>	_handoff;	// finished frames, for presentFrame
	bool	_preferMetal;	// the Renderer setting
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
	std::unique_ptr<whorld::MetalRenderer>	_metal;	// the live view's Metal renderer, if in use
	bool	_usingMetal;
	int		_surfWidth, _surfHeight;
	double	_surfScale;
	// Syphon's fixed-size frames (render thread)
	std::vector<Surface>	_syphonSurfaces;
	std::unique_ptr<whorld::MetalRenderer>	_syphonMetal;
	int		_syphonSurfWidth, _syphonSurfHeight;
	double	_syphonSurfScale;
	bool	_syphonUsingMetal;
	// Syphon output: set on the main thread, read by the render and
	// presenter threads, guarded by _syphonMutex
	std::mutex	_syphonMutex;
	WHSyphon	*_syphon;		// nil when off
	int		_syphonWidth, _syphonHeight;	// fixed size in pixels, or 0: the output's own
	int		_curRate;
	int		_lastMovieIO;	// render thread: for movieStateHandler
	whorld::Modulator	_modulator;	// render thread
	bool	_modulating;	// render thread: offsets were set
	bool	_modHasLast;
	std::chrono::steady_clock::time_point	_modLast;
	// MIDI
	WHMidiSink	_midiSink;
	std::unique_ptr<whorld::MidiManager>	_midiMgr;
	// OSC (main thread, except where the server's queue says)
	std::unique_ptr<WHOscServer>	_osc;
	std::map<std::string, whorld::OscArg>	_oscSent;	// last value sent (or received) per address
	NSInteger	_oscLastClients;
	MIDIClientRef	_midiClient;
	MIDIPortRef	_midiPort;
	MIDIEndpointRef	_midiSource;	// connected source, or 0
	NSString	*_midiInputName;
	std::vector<std::string>	_playlistPatches;
	// main thread only
	whorld::Patch	_doc;	// the document, as CWhorldDoc
	whorld::Patch	_loaded;	// the patch as it was loaded (Mac addition: what a key-map reset restores)
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
	double	_gpuMs;
	NSString	*_rendererName;
	IOSurfaceRef	_shownImage;	// on the layer, claimed until replaced (main thread)
	NSInteger	_ringCount;
	int		_refreshRate;
	int		_missed;	// refreshes this second with no new frame
	BOOL	_presented;	// a frame has been shown
	NSInteger	_missedFrames;
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
		_ringFadeEased = false;
		_ringFadeChanged = false;
		_hueFromPatch = false;
		_hueFromPatchChanged = false;
		_modDepth = 1;
		_modBypass = false;
		_modFollowTempo = false;
		_modChanged = false;
		_modulating = false;
		_modHasLast = false;
		_statRenderSum = 0;
		_statFrames = 0;
		_statRings = 0;
		_liveOrigin = whorld::DPoint(0.5, 0.5);
		_curRate = 0;
		_lastMovieIO = whorld::SnapMovie::IO_CLOSED;
		_surfWidth = _surfHeight = 0;
		_surfScale = 0;
		_engine = std::make_unique<whorld::WhorldEngine>();
		_doc.SetDefaults();
		_loaded = _doc;
		_statStart = CACurrentMediaTime();
		_liveMovie = _engine->GetMovieState();
		_liveTarget = whorld::SizeF{0, 0};
		_handoff = std::make_shared<WHHandoff>();
		_preferMetal = true;
		_usingMetal = false;
		_gpuMs = 0;
		_rendererName = @"";
		_shownImage = nullptr;
		_missed = 0;
		_missedFrames = 0;
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
	if (_osc)
		_osc->Stop();	// before the MIDI manager it dispatches through goes
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
	_metal.reset();	// waits for its frames on the GPU
	[self releaseSurfaces];
	_syphonMetal.reset();
	[self releaseSyphonSurfaces];
	[_syphon stop];
	if (_shownImage)
		WHHandoff::Release(_shownImage);
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
	_loaded = _doc;
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
	_loaded = patch;
	_patchPath = [path copy];
	_modified = NO;
	[self pushPatch];	// CWhorldView::OnUpdate HINT_NONE
	return YES;
}

- (NSString *)patchPath
{
	return _patchPath;
}

- (NSString *)patchAuthor { return @(_doc.m_sAuthor.c_str()) ?: @""; }

- (void)setPatchAuthor:(NSString *)author
{
	std::string	s = whorld::Patch::AuthorForFile(author.UTF8String ?: "");
	if (s == _doc.m_sAuthor)
		return;
	_doc.m_sAuthor = s;	// the render thread's copy doesn't need it
	_modified = YES;
}

+ (NSString *)authorOfPatchAtPath:(NSString *)path
{
	whorld::Patch	patch;
	if (!patch.Read(path.fileSystemRepresentation))
		return nil;
	return @(patch.m_sAuthor.c_str()) ?: @"";
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
	_loaded = _doc;	// saved: the new reset point
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

// The patch as loaded (opened, played from the playlist, or new): what a
// two-finger tap with a key-map key held restores (Mac addition)
- (double)loadedParamValue:(NSInteger)iParam property:(WHParamProperty)prop
{
	WhorldBase::VARIANT_PROP	v;
	_loaded.GetParamRC((int)iParam, (int)prop, v);
	return prop == WHParamPropertyWave ? v.intVal : v.dblVal;
}

- (double)loadedMasterValue:(NSInteger)iProp { return _loaded.GetMasterProp((int)iProp); }
- (double)loadedHue { return _loaded.m_main.fHue; }
- (CGPoint)loadedOrigin { return CGPointMake(_loaded.m_main.dptOrigin.x, _loaded.m_main.dptOrigin.y); }

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

- (CGPoint)liveOrigin
{
	std::lock_guard<std::mutex>	lock(_mutex);
	return CGPointMake(_liveOrigin.x, _liveOrigin.y);
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

- (void)rotateHue
{
	// V1's CWhorldView::RotateHue(90): new rings follow through Hue, which
	// offsets them; existing rings are rotated on the render thread
	_doc.m_main.fHue = std::fmod(_doc.m_main.fHue + 90, 360);
	[self pushMainProp:WhorldBase::MAIN_Hue];
	RenderCmd	cmd(WhorldBase::RC_ROTATE_HUE);
	cmd.m_prop.dblVal = 90;
	[self pushCommand:cmd];
	_modified = YES;
}

- (void)setModulationRows:(NSArray<WHModRow *> *)rows syncs:(NSArray<WHModSync *> *)syncs depth:(double)depth bypass:(BOOL)bypass followTempo:(BOOL)followTempo
{
	std::vector<whorld::ModRow>	a = ModRowsFrom(rows);
	std::vector<whorld::ModSync>	aSync = ModSyncsFrom(syncs);
	std::lock_guard<std::mutex>	lock(_mutex);
	_modRows = std::move(a);
	_modSyncs = std::move(aSync);
	_modDepth = depth;
	_modBypass = bypass;
	_modFollowTempo = followTempo;
	_modChanged = true;
	_frameRequested = true;
	_cv.notify_one();
}

- (NSArray<NSNumber *> *)modulationLevels
{
	std::lock_guard<std::mutex>	lock(_mutex);
	NSMutableArray	*a = [NSMutableArray arrayWithCapacity:_modLevels.size()];
	for (double f : _modLevels)
		[a addObject:@(f)];
	return a;
}

// Render thread, once per frame before drawing: the latest audio analysis
// through the routing rows, as offsets for the engine; fired actions go to
// the main thread.
- (void)stepModulation
{
	if (_modulator.GetRows().empty() && _modulator.GetSyncs().empty() && !_modulator.GetFollowTempo()) {
		if (_modulating) {	// rows removed: the patch's own values again
			_engine->SetModulation(whorld::ModOutput());
			_modulating = false;
		}
		_modHasLast = false;
		return;
	}
	auto	now = std::chrono::steady_clock::now();
	double	dt = _modHasLast ? std::chrono::duration<double>(now - _modLast).count() : 0;
	dt = std::min(dt, 0.25);	// after a stall, don't jump
	_modLast = now;
	_modHasLast = true;
	whorld::ModSources	src;
	WHAudioInputRead(src);
	WHLinkRead(src);	// Ableton Link, while it has peers, drives the beat instead of the tracker
	whorld::ModOutput	out;
	_modulator.Step(src, dt, out);
	_engine->SetModulation(out);
	_modulating = true;
	{
		std::lock_guard<std::mutex>	lock(_mutex);
		_modLevels.resize(_modulator.GetRows().size());
		for (size_t i = 0; i < _modLevels.size(); i++)
			_modLevels[i] = _modulator.GetRowLevel(i);
	}
	if (out.nActions) {
		uint32_t	nActions = out.nActions;
		__weak WHEngine	*weakSelf = self;
		dispatch_async(dispatch_get_main_queue(), ^{
			WHEngine	*strong = weakSelf;
			if (strong.modulationActionHandler)
				strong.modulationActionHandler(nActions);
		});
	}
}

- (void)setHueFromPatch:(BOOL)fromPatch
{
	std::lock_guard<std::mutex>	lock(_mutex);
	_hueFromPatch = fromPatch;
	_hueFromPatchChanged = true;
	_frameRequested = true;
	_cv.notify_one();
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

- (void)setRingFadeEased:(BOOL)eased
{
	std::lock_guard<std::mutex>	lock(_mutex);
	_ringFadeEased = eased;
	_ringFadeChanged = true;
	_frameRequested = true;	// show it now, even paused
	_cv.notify_one();
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

- (void)randomOrigin
{
	[self pushCommand:RenderCmd(WhorldBase::RC_RANDOM_ORIGIN)];
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
		auto	fn = completion;	// its own reference: the block mustn't capture the lambda's
		dispatch_async(dispatch_get_main_queue(), ^{ fn(msg); });
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

// Render thread: CWhorldDraw::CaptureBitmap and WriteCapturedBitmap. Drawn
// with Metal where this Mac can (exact every run; Core Graphics drawing on
// several threads isn't, PORT_PLAN Phase 8), else Core Graphics. The Metal
// renderer is kept for the next capture of the same size (image sequences).
static std::string CaptureToPNG(whorld::WhorldEngine& eng, uint32_t nFlags, whorld::IntSize sz, const std::string& sPath)
{
	whorld::IntSize	szImage = eng.GetCaptureSize(nFlags, sz);
	if (szImage.cx <= 0 || szImage.cy <= 0)
		return "The image size is empty.";
	if (whorld::MetalRenderer::CanDrawCoverage(szImage.cx, szImage.cy)) {
		static std::unique_ptr<whorld::MetalRenderer>	s_pMetal;	// render thread only
		if (!s_pMetal || s_pMetal->GetPixelWidth() != szImage.cx || s_pMetal->GetPixelHeight() != szImage.cy)
			s_pMetal = std::make_unique<whorld::MetalRenderer>(szImage.cx, szImage.cy, 1, 0);	// coverage mode
		if (s_pMetal->IsValid()) {
			s_pMetal->BeginFrame();
			eng.DrawCapture(*s_pMetal, nFlags, sz);
			s_pMetal->EndFrame();
			std::vector<uint8_t>	aPixel;
			size_t	nStride = 0;
			if (s_pMetal->ReadPixels(aPixel, nStride)) {
				// written by the Core Graphics bitmap's PNG writer, over these pixels
				whorld::CGBitmapRenderer	png(aPixel.data(), szImage.cx, szImage.cy, nStride, 1);
				std::string	sErr;
				if (!png.WritePNG(sPath, &sErr))
					return sErr;
				return std::string();
			}
		}
		s_pMetal.reset();	// Core Graphics, then
	}
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
		auto	fn = completion;	// its own reference: the block mustn't capture the lambda's
		dispatch_async(dispatch_get_main_queue(), ^{ fn(msg); });
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
	progress = [progress copy];	// they outlive this call
	completion = [completion copy];
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
				auto	fn = progress;	// its own reference: the block mustn't capture the lambda's
				dispatch_async(dispatch_get_main_queue(), ^{ fn(nDone); });
			}
		}
		NSString	*msg = sErr.empty() ? nil : ToNS(sErr);
		auto	fn = completion;	// its own reference: the block mustn't capture the lambda's
		dispatch_async(dispatch_get_main_queue(), ^{ fn(msg); });
	}];
}

- (void)exportAudioVideoToPath:(NSString *)path audio:(NSString *)audioPath options:(WHAudioVideoOptions *)o
	progress:(void (^)(int64_t, int64_t))progress completion:(void (^)(NSString *))completion
{
	whorld::AudioVideoOptions	opts;
	opts.codec = static_cast<whorld::VideoWriter::Codec>(o.codec);
	opts.nWidth = o.width;
	opts.nHeight = o.height;
	opts.fFrameRate = o.frameRate;
	opts.fStart = o.start;
	opts.fDuration = o.duration;
	opts.fPreroll = o.preroll;
	opts.fTempo = o.tempo;
	opts.fDownbeat = o.downbeat;
	opts.analyzer.fGainDb = o.gainDb;
	opts.analyzer.fCeilDb = 0;
	opts.analyzer.fFloorDb = -std::max(o.rangeDb, 6.0);
	opts.analyzer.bAutoLevel = o.autoLevel;
	opts.analyzer.fHitThreshold = o.hitThreshold;
	opts.aRow = ModRowsFrom(o.rows);
	opts.aSync = ModSyncsFrom(o.syncs);
	opts.fDepth = o.depth;
	opts.bFollowTempo = o.followTempo;
	opts.aPlaylist = _playlistPatches;
	opts.iPatch = static_cast<int>(o.playlistIndex);
	{
		std::lock_guard<std::mutex>	lock(_mutex);
		opts.bRingFadeEased = _ringFadeEased;
		opts.bHueFromPatch = _hueFromPatch;
	}
	// framed as the view shows it: the export is drawn at its own size, so
	// zoom by the size it fits into the view at (as Scale to Fit Both)
	whorld::Patch	patch = _doc;
	CGSize	view = self.viewSize;
	if (view.width > 0 && view.height > 0)
		patch.m_master.fZoom *= std::min(o.width / view.width, o.height / view.height);
	std::string	sPath = path.fileSystemRepresentation;
	std::string	sAudio = audioPath.fileSystemRepresentation;
	std::atomic<bool>	*pCancel = &_cancelExport;
	_cancelExport = false;
	// the blocks outlive this call: copy them off the caller's stack
	progress = [progress copy];
	completion = [completion copy];
	std::thread([patch, sAudio, sPath, opts, progress, completion, pCancel] {
		pthread_setname_np("Whorld audio-reactive export");
		std::string	sErr;
		auto	lastReport = std::chrono::steady_clock::now();
		bool	bOk = whorld::ExportAudioReactiveVideo(patch, sAudio, sPath, opts, [&](int64_t nDone, int64_t nTotal) {
			auto	now = std::chrono::steady_clock::now();
			if (nDone == nTotal || now - lastReport > std::chrono::milliseconds(100)) {
				lastReport = now;
				auto	fn = progress;	// its own reference: the block mustn't capture the lambda's
				dispatch_async(dispatch_get_main_queue(), ^{ fn(nDone, nTotal); });
			}
			return !*pCancel;
		}, &sErr);
		NSString	*msg = bOk ? nil : ToNS(sErr);
		auto	fn = completion;	// its own reference: the block mustn't capture the lambda's
		dispatch_async(dispatch_get_main_queue(), ^{ fn(msg); });
	}).detach();
}

- (void)exportMovieVideoToPath:(NSString *)path codec:(NSInteger)codec start:(int64_t)start end:(int64_t)end
	flags:(WHExportFlags)flags width:(int)width height:(int)height
	progress:(void (^)(int64_t))progress completion:(void (^)(NSString *))completion
{
	progress = [progress copy];	// they outlive this call
	completion = [completion copy];
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
			auto	fn = progress;	// its own reference: the block mustn't capture the lambda's
			dispatch_async(dispatch_get_main_queue(), ^{ fn(nDone); });
			return !*pCancel;
		}, &sErr);
		NSString	*msg = bOk ? nil : ToNS(sErr);
		auto	fn = completion;	// its own reference: the block mustn't capture the lambda's
		dispatch_async(dispatch_get_main_queue(), ^{ fn(msg); });
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
		if (_midiHandler)
			_midiHandler(5, (uint32_t)post.iParam);	// just that row
		return;
	case Post::MASTER_PROP_CHANGE:
		_doc.SetMasterProp(post.iProp, post.fVal);
		_modified = YES;
		if (_midiHandler)
			_midiHandler(6, (uint32_t)post.iProp);
		return;
	case Post::MAIN_PROP_CHANGE:
		{
			WhorldBase::VARIANT_PROP	v;
			v.llVal = post.iVal;	// VARIANT_PROP prop = {lParam}
			if (post.iProp == WhorldBase::MAIN_Hue)	// Mac addition: Hue is a double
				v.dblVal = post.fVal;
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
	case Post::ROTATE_HUE:	// Mac addition
		[self rotateHue];
		break;
	}
	if (_midiHandler)
		_midiHandler(0, 0);
}

#pragma mark - OSC

// The address Whorld reports a target's value on: the input address (for a
// parameter, with its column), so a control and its feedback share one.
static const std::map<std::pair<int, int>, std::string>& OscPathByTarget()
{
	static const std::map<std::pair<int, int>, std::string>	m = [] {
		std::map<std::pair<int, int>, std::string>	r;
		for (const auto& a : whorld::OscRemote::Inputs())
			r[{a.iTarget, a.iProp}] = a.path;
		return r;
	}();
	return m;
}

static bool OscSame(const whorld::OscArg& a, const whorld::OscArg& b)
{
	if (a.IsNumber() && b.IsNumber())	// the round trip through float32 and back isn't exact
		return std::fabs(a.Number() - b.Number()) < 1e-6;
	return a.type == b.type && a.s == b.s;
}

+ (NSArray<NSString *> *)localIPv4Addresses
{
	NSMutableArray	*out = [NSMutableArray array];
	ifaddrs	*list = nullptr;
	if (getifaddrs(&list) != 0)
		return out;
	for (ifaddrs *p = list; p; p = p->ifa_next) {
		if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET || !(p->ifa_flags & IFF_UP)
			|| (p->ifa_flags & IFF_LOOPBACK))
			continue;
		char	s[INET_ADDRSTRLEN];
		inet_ntop(AF_INET, &reinterpret_cast<sockaddr_in*>(p->ifa_addr)->sin_addr, s, sizeof(s));
		NSString	*a = @(s);
		if (![a hasPrefix:@"169.254."] && ![out containsObject:a])	// not link-local
			[out addObject:a];
	}
	freeifaddrs(list);
	return out;
}

- (BOOL)startOSCOnPort:(NSInteger)inPort sendPort:(NSInteger)outPort host:(NSString *)host error:(NSError **)error
{
	[self stopOSC];
	auto	osc = std::make_unique<WHOscServer>();
	__weak WHEngine	*weakSelf = self;
	whorld::MidiManager	*pMgr = _midiMgr.get();
	WHOscServer	*pServer = osc.get();
	std::string	err;
	bool	ok = osc->Start((int)inPort, (int)outPort, host.UTF8String ?: "",
		[weakSelf, pMgr, pServer](const std::vector<whorld::OscMessage>& msgs, in_addr_t sender) {
		// the server's queue: requests that only push render commands and
		// post to the main thread are done here, as MIDI's are
		using R = whorld::OscRemote::Request;
		for (const whorld::OscMessage& msg : msgs) {
			// modulation (Mac addition): the app's, not a mapping target
			std::string	modOn = std::string(whorld::OscRemote::PREFIX) + "/mod/on";
			std::string	modDepth = std::string(whorld::OscRemote::PREFIX) + "/mod/depth";
			if (msg.path == std::string(whorld::OscRemote::PREFIX) + "/mod/downbeat") {
				bool	bPress = msg.args.empty() || !msg.args[0].IsNumber() || msg.args[0].Number() != 0;	// not on release
				if (bPress) {
					dispatch_async(dispatch_get_main_queue(), ^{
						WHEngine	*strong = weakSelf;
						if (strong.modulationOscHandler)
							strong.modulationOscHandler(2, 1);
					});
				}
				continue;
			}
			if (msg.path == modOn || msg.path == modDepth) {
				bool	bDepth = msg.path == modDepth;
				bool	bHasArg = !msg.args.empty() && msg.args[0].IsNumber();
				double	fVal = bHasArg ? msg.args[0].Number() : -1;	// on with no argument toggles
				if (bDepth && !bHasArg)
					continue;
				dispatch_async(dispatch_get_main_queue(), ^{
					WHEngine	*strong = weakSelf;
					if (strong.modulationOscHandler)
						strong.modulationOscHandler(bDepth ? 1 : 0, bDepth ? fVal : (fVal < 0 ? -1 : fVal != 0));
				});
				continue;
			}
			R	req = whorld::OscRemote::Handle(msg, *pMgr);
			switch (req.type) {
			case R::NONE:
				break;
			case R::PING:
				{
					whorld::OscMessage	pong;
					pong.path = std::string(whorld::OscRemote::PREFIX) + "/pong";
					NSArray	*ips = [WHEngine localIPv4Addresses];
					pong.args.push_back(whorld::OscArg::String(ips.count ? [ips.firstObject UTF8String] : ""));
					pServer->SendTo(sender, pong);
				}
				break;
			case R::DISPATCHED:
				if (!msg.args.empty() && msg.args[0].IsNumber() && req.iTarget >= 0) {
					// what this device just set: don't send it back to it
					// (a fader being dragged would jump to an older value)
					int	iProp;
					whorld::OscRemote::Find(msg.path, iProp);
					whorld::OscArg	arg = msg.args[0];
					dispatch_async(dispatch_get_main_queue(), ^{
						WHEngine	*strong = weakSelf;
						auto	it = OscPathByTarget().find({req.iTarget, iProp});
						if (strong && strong->_osc && it != OscPathByTarget().end()) {
							whorld::OscArg	state;
							if (whorld::OscRemote::StateValue(strong->_doc, req.iTarget, iProp, state))
								strong->_oscSent[it->second] = state;	// the value it now has
						}
					});
				}
				break;
			default:	// the app's: on the main thread
				dispatch_async(dispatch_get_main_queue(), ^{
					[weakSelf oscRequest:req.type target:req.iTarget value:req.iVal];
				});
			}
		}
	}, err);
	if (!ok) {
		if (error)
			*error = [NSError errorWithDomain:@"Whorld" code:10 userInfo:@{NSLocalizedDescriptionKey: @(err.c_str())}];
		return NO;
	}
	_osc = std::move(osc);
	_oscSent.clear();
	_oscLastClients = 0;
	return YES;
}

- (void)stopOSC
{
	if (_osc) {
		_osc->Stop();
		_osc.reset();
	}
	_oscSent.clear();
}

- (BOOL)oscRunning { return _osc && _osc->IsRunning(); }
- (NSInteger)oscClientCount { return _osc ? _osc->ClientCount() : 0; }

- (NSArray<NSString *> *)oscClients
{
	NSMutableArray	*a = [NSMutableArray array];
	if (_osc)
		for (const std::string& s : _osc->ClientNames())
			[a addObject:@(s.c_str())];
	return a;
}

// Main thread: what OscRemote leaves to the app.
- (void)oscRequest:(int)type target:(int)iTarget value:(int)iVal
{
	using R = whorld::OscRemote::Request;
	switch (type) {
	case R::TOGGLE:	// a switch with no argument: the other way from now
		{
			whorld::OscArg	cur;
			if (whorld::OscRemote::StateValue(_doc, iTarget, -1, cur))
				_midiMgr->DispatchTarget(iTarget, -1, cur.Number() != 0 ? 0 : 1);
		}
		break;
	case R::PAUSE:
		if (iVal < 0 || (iVal != 0) != (_paused != NO)) {
			[self togglePause];
			if (_midiHandler)
				_midiHandler(1, 0);
		}
		break;
	case R::PATCH:
		if (_midiHandler)
			_midiHandler(2, (uint32_t)std::max(iVal, 0));
		break;
	case R::SYNC:	// everything again
		_oscSent.clear();
		break;
	}
}

- (void)oscSend:(const std::string&)path arg:(const whorld::OscArg&)arg
{
	auto	it = _oscSent.find(path);
	if (it != _oscSent.end() && OscSame(it->second, arg))
		return;
	_oscSent[path] = arg;
	whorld::OscMessage	msg;
	msg.path = path;
	msg.args.push_back(arg);
	_osc->Send(msg);
}

- (void)oscSendStateWithPatch:(NSInteger)playingPatch patchName:(NSString *)patchName
	playlistName:(NSString *)playlistName fullScreen:(BOOL)fullScreen
{
	if (!_osc)
		return;
	NSInteger	nClients = _osc->ClientCount();
	if (nClients == 0) {
		_oscLastClients = 0;
		return;	// nobody listening
	}
	if (nClients > _oscLastClients)
		_oscSent.clear();	// someone new: everything
	_oscLastClients = nClients;
	using whorld::OscArg;
	for (const auto& a : whorld::OscRemote::Inputs()) {
		OscArg	arg;
		if (whorld::OscRemote::StateValue(_doc, a.iTarget, a.iProp, arg))
			[self oscSend:a.path arg:arg];
	}
	std::string	p = whorld::OscRemote::PREFIX;
	[self oscSend:p + "/pause" arg:OscArg::Float(_paused ? 1 : 0)];
	[self oscSend:p + "/patch" arg:OscArg::Int(playingPatch)];
	[self oscSend:p + "/patch/name" arg:OscArg::String(patchName.UTF8String ?: "")];
	[self oscSend:p + "/patch/author" arg:OscArg::String(_doc.m_sAuthor)];
	[self oscSend:p + "/playlist/name" arg:OscArg::String(playlistName.UTF8String ?: "")];
	[self oscSend:p + "/fs" arg:OscArg::Float(fullScreen ? 1 : 0)];
	double	fDepth;
	bool	bBypass;
	{
		std::lock_guard<std::mutex>	lock(_mutex);
		fDepth = _modDepth;
		bBypass = _modBypass;
	}
	[self oscSend:p + "/mod/on" arg:OscArg::Float(bBypass ? 0 : 1)];
	[self oscSend:p + "/mod/depth" arg:OscArg::Float(fDepth)];
}

- (void)oscSendStats:(NSString *)text
{
	if (!_osc || _osc->ClientCount() == 0)
		return;
	using whorld::OscArg;
	std::string	p = std::string(whorld::OscRemote::PREFIX) + "/stat/";
	auto	send = [&](const char* name, OscArg arg) {
		whorld::OscMessage	msg;
		msg.path = p + name;
		msg.args.push_back(arg);
		_osc->Send(msg);
	};
	send("fps", OscArg::Float(self.framesPerSecond));
	send("draw", OscArg::Float(self.renderMilliseconds));
	send("gpu", OscArg::Float(self.gpuMilliseconds));
	send("hz", OscArg::Int(self.refreshRate));
	send("missed", OscArg::Int(self.missedFrames));
	send("rings", OscArg::Int(self.ringCount));
	send("renderer", OscArg::String(self.rendererName.UTF8String ?: ""));
	send("text", OscArg::String(text.UTF8String ?: ""));
}

#pragma mark - Playlist

- (void)newPlaylist
{
	_playlistPatches.clear();
	_midiMgr->m_midiMaps.RemoveAll();
	_playlistLayout = nil;
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
	_playlistLayout = pl.m_sLayout.empty() ? nil : ToNS(pl.m_sLayout);
	_midiMgr->m_midiMaps.SetArray(pl.m_arrMapping);
	return YES;
}

// ported from Playlist.cpp CPlaylist::OnSaveDocument
- (BOOL)savePlaylistToPath:(NSString *)path error:(NSError **)error
{
	whorld::Playlist	pl;
	pl.m_arrPatch = _playlistPatches;
	pl.m_arrMapping = _midiMgr->m_midiMaps.GetArray();
	pl.m_sLayout = _playlistLayout.UTF8String ?: "";
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
	_loaded = patch;
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

- (CALayer *)attachedLayer { return _layer; }

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
		bool	bCursor, bLetterbox, bLetterboxOn, bPreferMetal;
		bool	bRingFade, bRingFadeEased;
		bool	bHueFromPatchChanged, bHueFromPatch;
		bool	bModChanged;
		std::vector<whorld::ModRow>	modRows;
		std::vector<whorld::ModSync>	modSyncs;
		double	fModDepth;
		bool	bModBypass;
		bool	bModFollowTempo;
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
			bRingFade = _ringFadeChanged;
			bRingFadeEased = _ringFadeEased;
			_ringFadeChanged = false;
			bHueFromPatchChanged = _hueFromPatchChanged;
			bHueFromPatch = _hueFromPatch;
			_hueFromPatchChanged = false;
			bPreferMetal = _preferMetal;
			bModChanged = _modChanged;
			if (bModChanged) {
				modRows = _modRows;
				modSyncs = _modSyncs;
				fModDepth = _modDepth;
				bModBypass = _modBypass;
				bModFollowTempo = _modFollowTempo;
				_modChanged = false;
			}
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
		if (bRingFade)
			_engine->SetRingFadeEased(bRingFadeEased);
		if (bHueFromPatchChanged)
			_engine->SetHueFromPatch(bHueFromPatch);
		if (bModChanged) {
			_modulator.SetRows(modRows);
			_modulator.SetSyncs(modSyncs);
			_modulator.SetDepth(fModDepth);
			_modulator.SetBypass(bModBypass);
			_modulator.SetFollowTempo(bModFollowTempo);
		}
		if (w <= 0 || h <= 0)
			continue;
		if (w != _surfWidth || h != _surfHeight || scale != _surfScale) {	// RC_RESIZE
			[self releaseSurfaces];
			_metal.reset();
			_surfWidth = w;
			_surfHeight = h;
			_surfScale = scale;
			_engine->OnResize(whorld::SizeF{float(w / scale), float(h / scale)});
		}
		// Metal draws the live view unless the setting says Core Graphics,
		// this Mac can't run it, or a frame has failed on the GPU
		static const bool	bMetalOK = whorld::MetalRenderer::IsCoverageModeSupported();
		bool	bMetal = bPreferMetal && bMetalOK && !_handoff->metalFailed;
		if (bMetal != _usingMetal) {	// switch renderers: fresh surfaces
			[self releaseSurfaces];
			_metal.reset();
			_usingMetal = bMetal;
		}
		if (bMetal && !_metal) {
			_metal = std::make_unique<whorld::MetalRenderer>(w, h, scale, 0);	// coverage mode
			if (!_metal->IsValid()) {
				NSLog(@"Whorld: Metal renderer unavailable; using Core Graphics");
				_metal.reset();
				_handoff->metalFailed = true;
				continue;	// next frame switches
			}
		}
		[self stepModulation];	// Mac addition: audio modulation, before drawing
		Surface	*pSurf = [self freeSurface];
		if (!pSurf) {
			_handoff->nNoSurface++;
			continue;	// can't allocate; skip this frame
		}
		auto	t0 = std::chrono::steady_clock::now();
		IOSurfaceRef	image = pSurf->surface;
		IOSurfaceIncrementUseCount(image);	// claimed until replaced on the layer
		CFRetain(image);
		if (bMetal) {
			// The frame is handed over when the GPU finishes it; until then
			// the retain keeps the surface out of the pool.
			_metal->SetTargetSurface(image);
			_metal->BeginFrame();
			_engine->Draw(*_metal);
			std::shared_ptr<WHHandoff>	handoff = _handoff;
			_metal->EndFrame([handoff, image, scale](bool bOk, double fGpuMs) {
				if (bOk) {
					{
						std::lock_guard<std::mutex>	lock(handoff->m);
						handoff->gpuSum += fGpuMs;
						handoff->gpuFrames++;
					}
					handoff->Put(image, scale);
				} else {
					handoff->metalFailed = true;
					WHHandoff::Release(image);
				}
			});
			_metal->SetTargetSurface(nullptr);
			_handoff->metalActive = true;
		} else {
			if (!pSurf->renderer) {
				pSurf->renderer = std::make_unique<whorld::CGBitmapRenderer>(
					static_cast<uint8_t *>(IOSurfaceGetBaseAddress(image)), _surfWidth, _surfHeight,
					IOSurfaceGetBytesPerRow(image), _surfScale);
				pSurf->renderer->SetDeferred(true);	// parallel stroking and banded rasterizing
			}
			IOSurfaceLock(image, 0, nullptr);
			pSurf->renderer->BeginFrame();
			_engine->Draw(*pSurf->renderer);
			pSurf->renderer->EndFrame();
			IOSurfaceUnlock(image, 0, nullptr);
			_handoff->metalActive = false;
		}
		double	ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
		size_t	nRings = _engine->GetRingCount();
		whorld::DPoint	ptOrigin = _engine->GetOrigin();
		whorld::WhorldEngine::MovieState	movieState = _engine->GetMovieState();
		if (movieState.nIOState != _lastMovieIO) {	// tell the main thread (the movie bar)
			_lastMovieIO = movieState.nIOState;
			__weak WHEngine	*weakSelf = self;
			dispatch_async(dispatch_get_main_queue(), ^{
				WHEngine	*strong = weakSelf;
				if (strong.movieStateHandler)
					strong.movieStateHandler();
			});
		}
		{
			std::lock_guard<std::mutex>	lock(_mutex);
			_liveOrigin = ptOrigin;
			_liveMovie = movieState;
			_liveTarget = whorld::SizeF{float(w / scale), float(h / scale)};
			_statRenderSum += ms;
			_statFrames++;
			_statRings = nRings;
		}
		// Core Graphics: hand the frame to the next refresh (presentFrame)
		if (!bMetal)
			_handoff->Put(image, scale);
		[self drawSyphonFrameForWidth:w height:h scale:scale metal:bMetal];
	}
}

// Any thread: the Syphon server, if on, and its fixed size (0: none)
- (WHSyphon *)syphonServerWidth:(int *)pWidth height:(int *)pHeight
{
	std::lock_guard<std::mutex>	lock(_syphonMutex);
	*pWidth = _syphonWidth;
	*pHeight = _syphonHeight;
	return _syphon;
}

- (void)releaseSyphonSurfaces
{
	for (Surface& s : _syphonSurfaces) {
		s.renderer.reset();
		CFRelease(s.surface);
	}
	_syphonSurfaces.clear();
}

// Render thread, after the live frame: Syphon's fixed size. The same frame
// again (DrawAtSize doesn't advance), into a pool of its own, drawn as if
// the view were the fixed size divided by a scale that fits the view's
// picture in it, much as a Retina display draws a window's DIPs.
- (void)drawSyphonFrameForWidth:(int)w height:(int)h scale:(double)scale metal:(bool)bMetal
{
	int		fw, fh;
	WHSyphon	*syphon = [self syphonServerWidth:&fw height:&fh];
	if (!syphon || fw <= 0 || fh <= 0) {	// off, or the output's own size
		if (!_syphonSurfaces.empty() || _syphonMetal) {
			_syphonMetal.reset();
			[self releaseSyphonSurfaces];
		}
		return;
	}
	if (!syphon.hasClients)
		return;	// nobody receiving: don't draw
	double	fViewW = w / scale, fViewH = h / scale;	// the view in DIPs
	double	fScale = std::min(fw / fViewW, fh / fViewH);
	if (fw != _syphonSurfWidth || fh != _syphonSurfHeight || fScale != _syphonSurfScale
	|| bMetal != _syphonUsingMetal) {
		_syphonMetal.reset();
		[self releaseSyphonSurfaces];
		_syphonSurfWidth = fw;
		_syphonSurfHeight = fh;
		_syphonSurfScale = fScale;
		_syphonUsingMetal = bMetal;
	}
	if (bMetal && !_syphonMetal) {
		_syphonMetal = std::make_unique<whorld::MetalRenderer>(fw, fh, fScale, 0);	// coverage mode, as live
		if (!_syphonMetal->IsValid()) {
			_syphonMetal.reset();
			return;
		}
	}
	// drawing, and up to three waiting for Syphon's copy
	Surface	*pSurf = [self freeSurfaceIn:_syphonSurfaces width:fw height:fh max:4];
	if (!pSurf)
		return;
	IOSurfaceRef	image = pSurf->surface;
	IOSurfaceIncrementUseCount(image);	// claimed until published
	CFRetain(image);
	whorld::SizeF	szTarget{float(fw / fScale), float(fh / fScale)};
	if (bMetal) {
		_syphonMetal->SetTargetSurface(image);
		_syphonMetal->BeginFrame();
		_engine->DrawAtSize(*_syphonMetal, szTarget);
		_syphonMetal->EndFrame([syphon, image](bool bOk, double) {
			if (bOk)
				[syphon publishSurface:image];	// claims it again for the copy
			WHHandoff::Release(image);
		});
		_syphonMetal->SetTargetSurface(nullptr);
	} else {
		if (!pSurf->renderer) {
			pSurf->renderer = std::make_unique<whorld::CGBitmapRenderer>(
				static_cast<uint8_t *>(IOSurfaceGetBaseAddress(image)), fw, fh,
				IOSurfaceGetBytesPerRow(image), fScale);
			pSurf->renderer->SetDeferred(true);
		}
		IOSurfaceLock(image, 0, nullptr);
		pSurf->renderer->BeginFrame();
		_engine->DrawAtSize(*pSurf->renderer, szTarget);
		pSurf->renderer->EndFrame();
		IOSurfaceUnlock(image, 0, nullptr);
		[syphon publishSurface:image];
		WHHandoff::Release(image);
	}
}

// Main thread
- (void)setSyphonEnabled:(BOOL)enabled width:(NSInteger)width height:(NSInteger)height
{
	int		fw = 0, fh = 0;
	if (width > 0 && height > 0) {	// keep it to what Metal can draw into
		fw = int(std::clamp<NSInteger>(width, 16, 16384));
		fh = int(std::clamp<NSInteger>(height, 16, 16384));
	}
	WHSyphon	*made = nil, *old = nil;
	if (enabled && !self.syphonRunning) {
		made = [[WHSyphon alloc] initWithName:@""];	// clients list it by the app's name
		if (!made)
			NSLog(@"Whorld: can't start the Syphon server");
	}
	{
		std::lock_guard<std::mutex>	lock(_syphonMutex);
		if (!enabled) {
			old = _syphon;
			_syphon = nil;
		} else if (made) {
			_syphon = made;
		}
		_syphonWidth = fw;
		_syphonHeight = fh;
	}
	[old stop];
}

- (BOOL)syphonRunning
{
	std::lock_guard<std::mutex>	lock(_syphonMutex);
	return _syphon != nil;
}

- (BOOL)syphonHasClients
{
	int		fw, fh;
	WHSyphon	*syphon = [self syphonServerWidth:&fw height:&fh];
	return syphon.hasClients;
}

// Render thread: a surface of the current size nothing is using, creating
// one if needed (at most six).
- (Surface *)freeSurface
{
	// shown, two waiting, and up to three in flight
	return [self freeSurfaceIn:_surfaces width:_surfWidth height:_surfHeight max:6];
}

- (Surface *)freeSurfaceIn:(std::vector<Surface> &)pool width:(int)width height:(int)height max:(size_t)nMax
{
	for (Surface& s : pool) {
		if (!IOSurfaceIsInUse(s.surface))	// see WHHandoff
			return &s;
	}
	if (pool.size() >= nMax)
		return nullptr;
	NSDictionary	*props = @{
		(id)kIOSurfaceWidth: @(width),
		(id)kIOSurfaceHeight: @(height),
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
	s.surface = surface;	// the Core Graphics renderer is made when first needed
	pool.push_back(std::move(s));
	return &pool.back();
}

- (void)releaseSurfaces
{
	for (Surface& s : _surfaces) {
		s.renderer.reset();
		CFRelease(s.surface);
	}
	_surfaces.clear();
}

// The thread display links run on (WHRenderView). Frames are shown from
// here, not the main thread: a SwiftUI update of the panels (every MIDI
// controller message, for one) can hold the main thread for 100 ms, and
// every refresh it held would have shown no new frame.
+ (NSRunLoop *)presenterRunLoop
{
	static NSRunLoop	*runLoop;
	static dispatch_once_t	once;
	dispatch_once(&once, ^{
		dispatch_semaphore_t	ready = dispatch_semaphore_create(0);
		NSThread	*thread = [[NSThread alloc] initWithBlock:^{
			runLoop = NSRunLoop.currentRunLoop;
			[runLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];	// keeps it running
			dispatch_semaphore_signal(ready);
			for (;;) {
				@autoreleasepool {
					[runLoop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture];
				}
			}
		}];
		thread.name = @"Whorld present";
		thread.qualityOfService = NSQualityOfServiceUserInteractive;
		[thread start];
		dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
	});
	return runLoop;
}

// Presenter thread (presenterRunLoop), once per refresh: shows the oldest
// finished frame, if any, and once a second posts the statistics to the
// main thread. The frame and statistics state here is this thread's alone.
- (void)presentFrame
{
	double	scale;
	IOSurfaceRef	image = _handoff->Take(scale);
	if (image) {
		CALayer	*layer = _layer;
		if (layer) {
			[CATransaction begin];
			[CATransaction setDisableActions:YES];
			layer.contents = (__bridge id)image;
			layer.contentsScale = scale;
			[CATransaction commit];
		}
		int		fw, fh;
		WHSyphon	*syphon = [self syphonServerWidth:&fw height:&fh];
		if (syphon && !fw && syphon.hasClients)	// Syphon at the output's own size: this frame
			[syphon publishSurface:image];
		if (_shownImage)	// replaced on the layer: free for reuse once the window server lets go
			WHHandoff::Release(_shownImage);
		_shownImage = image;
		_deliveredFrames++;
		_presented = YES;
	} else if (_presented) {
		_missed++;	// still drawing (not counted before the first frame)
	}
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
		double	gpuSum;
		int		gpuN;
		{
			std::lock_guard<std::mutex>	lock(_handoff->m);
			gpuSum = _handoff->gpuSum;
			gpuN = _handoff->gpuFrames;
			_handoff->gpuSum = 0;
			_handoff->gpuFrames = 0;
		}
		// WHORLD_STATS=1: where frames went, for diagnosing missed refreshes
		static const bool	bLog = getenv("WHORLD_STATS") != nullptr;
		int	nDone = _handoff->nDone.exchange(0), nDropped = _handoff->nDropped.exchange(0);
		int	nNoSurface = _handoff->nNoSurface.exchange(0);
		double	gpuMs = gpuN ? gpuSum / gpuN : 0;
		double	fps = _deliveredFrames / (now - _statStart);
		double	renderMs = n ? sum / n : 0;
		NSInteger	missed = _missed;
		bool	bMetal = _handoff->metalActive;
		_missed = 0;
		_deliveredFrames = 0;
		_statStart = now;
		__weak WHEngine	*weakSelf = self;
		dispatch_async(dispatch_get_main_queue(), ^{
			WHEngine	*strong = weakSelf;
			if (!strong)
				return;
			if (bLog)
				NSLog(@"frames finished %d, dropped unseen %d, skipped for want of a surface %d", nDone, nDropped, nNoSurface);
			strong->_gpuMs = gpuMs;
			strong->_rendererName = bMetal ? @"Metal" : @"Core Graphics";
			strong->_fps = fps;
			strong->_renderMs = renderMs;
			strong->_ringCount = (NSInteger)rings;
			strong->_refreshRate = rate;
			strong->_missedFrames = missed;
			if (strong->_statsHandler)
				strong->_statsHandler();
		});
	}
}

- (double)framesPerSecond { return _fps; }
- (double)renderMilliseconds { return _renderMs; }
- (double)gpuMilliseconds { return _gpuMs; }
- (NSString *)rendererName { return _rendererName; }
+ (BOOL)metalAvailable { return whorld::MetalRenderer::IsCoverageModeSupported(); }

- (BOOL)preferMetal
{
	std::lock_guard<std::mutex>	lock(_mutex);
	return _preferMetal;
}

- (void)setPreferMetal:(BOOL)prefer
{
	{
		std::lock_guard<std::mutex>	lock(_mutex);
		_preferMetal = prefer;
	}
	if (prefer)
		_handoff->metalFailed = false;	// choosing Metal again retries it
}
- (NSInteger)ringCount { return _ringCount; }
- (int)refreshRate { return _refreshRate; }
- (NSInteger)missedFrames { return _missedFrames; }

@end

#pragma mark - WHRenderView

@implementation WHRenderView {
	CADisplayLink	*_displayLink;
	NSInteger	_linkMaxRate;	// the frame rate limit the display link was given (presenter thread)
	NSTrackingArea	*_tracking;
	// for the display link on the presenter thread, which mustn't touch
	// AppKit: the drawable's pixel size and scale, kept current on the main
	// thread, and the layer
	std::mutex	_sizeMutex;
	int		_pixelWidth, _pixelHeight;
	double	_pixelScale;
	CALayer	*_ownLayer;
	BOOL	_cursorHidden;	// fullScreenOutput: this view has hidden the cursor
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
		_ownLayer = self.layer;
		_pixelWidth = _pixelHeight = 0;
		_pixelScale = 1;
	}
	return self;
}

// Main thread: the pixel size frames are drawn at.
- (void)updateDrawableSize
{
	double	scale = _fullResolution ? (self.window.backingScaleFactor ?: 1) : 1;
	NSSize	size = self.bounds.size;
	std::lock_guard<std::mutex>	lock(_sizeMutex);
	_pixelWidth = (int)std::lround(size.width * scale);
	_pixelHeight = (int)std::lround(size.height * scale);
	_pixelScale = scale;
}

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	[self updateDrawableSize];
}

- (void)viewDidChangeBackingProperties
{
	[super viewDidChangeBackingProperties];
	[self updateDrawableSize];
}

- (void)setFullResolution:(BOOL)fullResolution
{
	_fullResolution = fullResolution;
	[self updateDrawableSize];
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
	[self updateDrawableSize];
	if (_fullScreenOutput)	// hidden if the pointer is already over it; shown again on leaving the window
		[self setCursorHidden:self.window != nil && [self mouseIsInside]];
	if (self.window) {
		// A view entering a window shows the output (the workspace's middle,
		// the detached window, the full-screen window): it's where the
		// output just moved to.
		if (_engine)
			[_engine attachLayer:self.layer];
		// paced by this view's display, run on the presenter thread
		_displayLink = [self displayLinkWithTarget:self selector:@selector(displayLinkFired:)];
		_linkMaxRate = 0;	// a new link runs at the display's rate until the first callback
		[_displayLink addToRunLoop:[WHEngine presenterRunLoop] forMode:NSRunLoopCommonModes];
	}
}

// Presenter thread: no AppKit here.
- (void)displayLinkFired:(CADisplayLink *)link
{
	// Only the view the engine draws for drives it: while the full-screen
	// window shows the picture, the hidden main window's view stays idle.
	WHEngine	*engine = _engine;
	if (!engine || engine.attachedLayer != _ownLayer)
		return;
	NSInteger	maxRate = engine.maxFrameRate;
	if (maxRate != _linkMaxRate) {	// the frame rate setting changed: takes effect from the next refresh
		_linkMaxRate = maxRate;
		link.preferredFrameRateRange = maxRate > 0
			? CAFrameRateRangeMake(maxRate, maxRate, maxRate) : CAFrameRateRangeDefault;
	}
	int		w, h;
	double	scale;
	{
		std::lock_guard<std::mutex>	lock(_sizeMutex);
		w = _pixelWidth;
		h = _pixelHeight;
		scale = _pixelScale;
	}
	CFTimeInterval	period = link.targetTimestamp - link.timestamp;
	int		rate = period > 0 ? (int)std::lround(1 / period) : 60;
	[engine presentFrame];
	[engine requestFrameWithPixelWidth:w height:h scale:scale refreshRate:rate];
}

- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if (_tracking)
		[self removeTrackingArea:_tracking];
	NSTrackingAreaOptions	opt = NSTrackingMouseMoved | NSTrackingInVisibleRect;
	if (_fullScreenOutput)
		opt |= NSTrackingActiveAlways | NSTrackingMouseEnteredAndExited | NSTrackingCursorUpdate;
	else
		opt |= NSTrackingActiveInKeyWindow;
	_tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:opt owner:self userInfo:nil];
	[self addTrackingArea:_tracking];
}

// fullScreenOutput: ported from RenderWnd.cpp CRenderWnd::OnSetCursor, which
// loads a null cursor over the full-screen render window
- (void)setCursorHidden:(BOOL)hide
{
	if (hide == _cursorHidden)
		return;
	_cursorHidden = hide;
	if (hide)
		[NSCursor hide];	// counted: each hide is matched by one unhide
	else
		[NSCursor unhide];
}

- (BOOL)mouseIsInside	// in screen coordinates, so it's right whichever display the pointer is on
{
	if (!self.window)
		return NO;
	NSRect	r = [self.window convertRectToScreen:[self convertRect:self.bounds toView:nil]];
	return NSMouseInRect(NSEvent.mouseLocation, r, NO);
}

- (void)mouseEntered:(NSEvent *)event
{
	if (_fullScreenOutput)
		[self setCursorHidden:YES];
}

- (void)mouseExited:(NSEvent *)event
{
	if (_fullScreenOutput)
		[self setCursorHidden:NO];
}

// cursor updates can also come as the pointer leaves: decide by where it is
- (void)cursorUpdate:(NSEvent *)event
{
	if (_fullScreenOutput)
		[self setCursorHidden:[self mouseIsInside]];
	else
		[super cursorUpdate:event];
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
		_wheelHandler(notches, shift, event.momentumPhase != NSEventPhaseNone, event.directionInvertedFromDevice);
}

- (void)mouseMoved:(NSEvent *)event
{
	if (_fullScreenOutput)
		[self setCursorHidden:YES];	// moves come only while it's over the view
	[self reportMouse:event];
}
- (void)mouseDragged:(NSEvent *)event { [self reportMouse:event]; }

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return _mouseButtonHandler != nil; }

- (void)mouseDown:(NSEvent *)event
{
	[self reportMouse:event];
	if (_mouseButtonHandler)
		_mouseButtonHandler(YES);
	else
		[super mouseDown:event];
}

- (void)rightMouseDown:(NSEvent *)event
{
	if (_secondaryClickHandler && _secondaryClickHandler())
		return;
	[super rightMouseDown:event];
}

- (void)mouseUp:(NSEvent *)event
{
	[self reportMouse:event];
	if (_mouseButtonHandler)
		_mouseButtonHandler(NO);
	else
		[super mouseUp:event];
}

@end
