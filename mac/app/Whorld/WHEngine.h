// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Objective-C interface to the C++ engine, for Swift. No C++ here.

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

// Origin motion types (WhorldBase OM_*)
typedef NS_ENUM(NSInteger, WHOriginMotion) {
	WHOriginMotionPark = 0,
	WHOriginMotionDrag = 1,
	WHOriginMotionRandom = 2,
};

// Parameter property columns (WhorldBase PARAM_PROP_*)
typedef NS_ENUM(NSInteger, WHParamProperty) {
	WHParamPropertyVal = 0,
	WHParamPropertyWave = 1,
	WHParamPropertyAmp = 2,
	WHParamPropertyFreq = 3,
	WHParamPropertyPW = 4,
	WHParamPropertyGlobal = 5,
};

// whorld::ControlInfo: how a pane row's slider and edit box behave.
typedef struct {
	int		rangeMin;		// slider position range
	int		rangeMax;
	int		defaultPos;		// slider default position
	int		pageSize;
	double	editScale;		// the edit box shows value / editScale
	int		editPrecision;	// digits after the point, or -1 for %g
	double	editMin;		// typed values are clamped to this range
	double	editMax;
	BOOL	editClamp;		// if YES
	double	spinDelta;		// stepper increment in value units (0: none)
} WHControlInfo;

// The pane control math (whorld::Controls), for building the panels.
@interface WHControls : NSObject
@property (class, readonly) NSInteger paramCount;
@property (class, readonly) NSInteger masterCount;
@property (class, readonly) NSInteger globalCount;
@property (class, readonly) NSInteger waveformCount;
+ (NSString *)paramName:(NSInteger)iParam;
+ (NSString *)masterName:(NSInteger)iProp;
+ (NSString *)waveformName:(NSInteger)iWave;
+ (NSString *)mainName:(NSInteger)iProp;
+ (NSString *)paramPropertyName:(NSInteger)iProp;
// normalized 0..1 master slider math (CMasterRowDlg::Norm / Denorm)
+ (double)masterNorm01:(NSInteger)iProp value:(double)value;
+ (double)masterDenorm01:(NSInteger)iProp value:(double)value;
+ (NSInteger)paramForGlobal:(NSInteger)iGlobal;	// global row to parameter index
// column: 0 Val, 1 Amp, 2 Freq, 3 PW (Controls::COL_*)
+ (WHControlInfo)paramControl:(NSInteger)iParam column:(NSInteger)column;
+ (WHControlInfo)globalControl:(NSInteger)iParam;
+ (WHControlInfo)masterControl:(NSInteger)iProp;
+ (double)paramPosition:(NSInteger)iParam value:(double)value;
+ (double)paramValue:(NSInteger)iParam position:(double)position;
+ (double)globalPosition:(NSInteger)iParam value:(double)value;
+ (double)globalValue:(NSInteger)iParam position:(double)position;
+ (double)masterPosition:(NSInteger)iProp value:(double)value;
+ (double)masterValue:(NSInteger)iProp position:(double)position;
// a new patch's values (CPatch::SetDefaults): what right-clicking a control restores
+ (double)paramDefault:(NSInteger)iParam column:(NSInteger)column;	// column as paramControl:
+ (double)masterDefault:(NSInteger)iProp;
+ (NSString *)format:(double)value control:(WHControlInfo)control;
+ (double)parse:(NSString *)text control:(WHControlInfo)control;
+ (NSString *)formatMaster:(NSInteger)iProp value:(double)value;
+ (double)parseMaster:(NSInteger)iProp text:(NSString *)text;
// spin button: returns the new value, or the same value if clamped unchanged
+ (double)spin:(double)value control:(WHControlInfo)control direction:(NSInteger)direction;
+ (NSString *)upstreamBaseline;	// Windows Whorld version this port follows
@end

// Movie state for the movie bar (WhorldEngine::MovieState)
typedef NS_ENUM(NSInteger, WHMovieIO) {
	WHMovieIOClosed = -1,
	WHMovieIOReading = 0,
	WHMovieIOWriting = 1,
};
typedef struct {
	WHMovieIO	io;
	int64_t		frameCount;	// frames in the movie being played
	int64_t		frame;		// next frame to read, or frames written
	float		frameRate;
	CGSize		frameSize;	// the movie's frame size, in DIPs
	BOOL		paused;		// playback paused
} WHMovieState;

// Image export flags (WhorldBase EF_*)
typedef NS_OPTIONS(uint32_t, WHExportFlags) {
	WHExportUseViewSize = 0x01,
	WHExportFitWidth = 0x02,
	WHExportFitHeight = 0x04,
};

// One MIDI mapping (whorld::Mapping), for Swift.
typedef struct {
	int		event;		// channel voice message index (MappingBase EVENT_*)
	int		channel;	// 0..15
	int		control;	// note or controller number, 0..127
	int		target;		// MappingBase TARGET_*
	int		prop;		// parameter property, for parameter targets
	double	start;		// range start, percent
	double	end;		// range end, percent
} WHMappingData;

// Mapping metadata (whorld::MappingBase).
@interface WHMappingInfo : NSObject
@property (class, readonly) NSInteger eventCount;
@property (class, readonly) NSInteger targetCount;
@property (class, readonly) NSInteger paramTargetCount;	// targets below this have a property
@property (class, readonly) NSInteger masterTargetCount;
+ (NSString *)eventName:(NSInteger)iEvent;
+ (NSString *)targetName:(NSInteger)iTarget;
+ (BOOL)targetHasProperty:(NSInteger)iTarget;
// a target's tag, as playlists store it (e.g. "RingSpacing", "Speed", "OriginX")
+ (NSString *)targetTag:(NSInteger)iTarget;
+ (NSInteger)targetForTag:(NSString *)tag;	// -1 if none
+ (BOOL)targetIsRange:(NSInteger)iTarget;	// a continuous or multiple-choice value (not a switch or action)
+ (WHMappingData)defaultMapping;
// MIDI learn: strip the data from an incoming message and set the mapping's
// event, channel and control from it (CMappingBar::OnMidiEvent). Returns NO
// if the message isn't a channel voice message.
+ (BOOL)learn:(uint32_t)message into:(WHMappingData *)mapping;
@end

// Owns the engine and its render thread. The main thread holds the document
// (the current patch) and sends changes to the render thread as commands,
// as CWhorldDoc does through CWhorldThread on Windows. Call from the main
// thread only.
@interface WHEngine : NSObject

// Document
- (void)newPatch;
- (BOOL)openPatchAtPath:(NSString *)path error:(NSError **)error;
@property (nonatomic, readonly, nullable) NSString *patchPath;
// The patch's author (Mac addition: the patch file's Author line), "" if not
// known. Setting it makes it one line and marks the patch edited.
@property (nonatomic, copy) NSString *patchAuthor;
// A patch file's author without opening it (the playlist's Author column):
// "" if it has none, nil if the file can't be read
+ (nullable NSString *)authorOfPatchAtPath:(NSString *)path;
// Writes the document, with the live origin from the render thread, as
// CWhorldDoc::OnSaveDocument does. Clears `modified` on success.
- (BOOL)savePatchToPath:(NSString *)path error:(NSError **)error;
// YES after any change since the last new, open or save.
@property (nonatomic) BOOL modified;

// Parameters, master and main properties of the document. Setters update
// the document and send the change to the render thread.
- (double)paramValue:(NSInteger)iParam property:(WHParamProperty)property;
- (void)setParamValue:(double)value param:(NSInteger)iParam property:(WHParamProperty)property;
- (double)masterValue:(NSInteger)iProp;
- (void)setMasterValue:(double)value prop:(NSInteger)iProp;
@property (nonatomic) CGPoint origin;	// normalized; setting it moves the origin without damping
// The origin as the render thread last drew it: where Drag or Random have
// moved it, which `origin` (the document's) doesn't follow.
@property (nonatomic, readonly) CGPoint liveOrigin;
@property (nonatomic) double hue;
@property (nonatomic) BOOL invertColor;
- (void)setOriginMotion:(WHOriginMotion)motion;
// CWhorldDoc::SetZoom: sets the master zoom and zooms, optionally damped
- (void)setZoom:(double)zoom damping:(BOOL)damping;
// snapshot letterbox option (COptions m_Snapshot_bLetterbox)
- (void)setSnapshotLetterbox:(BOOL)enable;
// Ring fade curve (Settings > Rings; WhorldEngine::SetRingFadeEased): the
// Fade master property's fade follows an S-curve if YES, else a line.
- (void)setRingFadeEased:(BOOL)eased;
// Settings > Rendering > Patch colors on load (Mac addition): a loaded patch
// starts the hue from its own Hue, or carries on from the previous patch
- (void)setHueFromPatch:(BOOL)fromPatch;
// Image > Rotate Hue (V1's, Mac addition): existing rings' hues turn 90
// degrees, and Hue goes up 90 (wrapping at 360) so new rings follow
- (void)rotateHue;
- (void)setDrawMode:(uint32_t)drawMode;
@property (nonatomic, readonly) uint32_t drawMode;

// Image menu (CWhorldDoc::OnImage*)
@property (nonatomic, readonly) BOOL fill;
@property (nonatomic, readonly) BOOL outline;
@property (nonatomic, readonly) BOOL mirror;
@property (nonatomic, readonly) BOOL reverse;
@property (nonatomic, readonly) BOOL convex;
@property (nonatomic, readonly) BOOL loopHue;
@property (nonatomic, readonly) BOOL zoomCenter;
@property (nonatomic, readonly) BOOL antialiasing;
@property (nonatomic, readonly) WHOriginMotion originMotion;
- (void)toggleFill;
- (void)toggleOutline;
- (void)toggleMirror;
- (void)toggleReverse;
- (void)toggleConvex;
- (void)toggleLoopHue;
- (void)toggleZoomCenter;
- (void)toggleAntialiasing;
- (void)originCenter;
- (void)toggleOriginDrag;
- (void)toggleOriginRandom;
- (void)randomPhase;

// Window menu (CMainFrame::OnWindow*)
@property (nonatomic, readonly) BOOL paused;
- (void)togglePause;
- (void)singleStep;
- (void)clear;

// Rendering, driven by WHRenderView's display link, which runs on a thread
// of its own (presenterRunLoop), so main-thread work can't delay frames.
// Each refresh the view calls presentFrame, which shows the frame finished
// since the last refresh,
// then requests the next frame of the given pixel size and scale (pixels per
// DIP) at the display's refresh rate. Frames are pipelined one refresh deep,
// as with a vsync'd swap chain: a frame has a whole refresh period to draw,
// and is shown at the start of a refresh, well before the compositor's
// deadline. Requests made while a frame is being drawn are coalesced.
- (void)attachLayer:(nullable CALayer *)layer;
// The layer frames go to; only the view showing it drives the engine.
@property (nonatomic, readonly, weak, nullable) CALayer *attachedLayer;
- (void)presentFrame;	// presenter thread
@property (class, nonatomic, readonly) NSRunLoop *presenterRunLoop;
- (void)requestFrameWithPixelWidth:(int)width height:(int)height scale:(double)scale
	refreshRate:(int)refreshRate;
// Cursor position for origin drag, normalized: (0, 0) top left, (1, 1) bottom right.
- (void)setCursorPosition:(CGPoint)normalized;

// MIDI input (CoreMIDI) and mappings (CMidiManager). Mappings belong to the
// playlist, as on Windows.
@property (nonatomic, readonly) NSArray<NSString *> *midiInputNames;	// current sources
@property (nonatomic, copy, nullable) NSString *midiInputName;	// selected source, or nil
@property (nonatomic) BOOL midiLearn;
- (NSInteger)mappingCount;
- (WHMappingData)mappingAt:(NSInteger)index;
- (void)setMappings:(const WHMappingData * _Nullable)mappings count:(NSInteger)count;
// Called on the main thread after the engine applied a MIDI change to the
// document (kind: 0 main properties or draw mode changed, 1 pause toggled,
// 2 play patch `value`, 3 learn message `value`, 5 parameter row `value`
// changed, 6 master property `value` changed), and when the MIDI sources
// change (kind 4).
@property (nonatomic, copy, nullable) void (^midiHandler)(NSInteger kind, uint32_t value);

// OSC remote control (new in the Mac port; WHOscServer, whorld::OscRemote):
// every MIDI mapping target has an address (/w/...), taking the values a
// mapping sends it. Incoming changes reach the document and the panels the
// way MIDI's do (midiHandler kinds 0, 1, 2, 5, 6). Whorld sends the same
// addresses back with their values as they change, and monitoring.
- (BOOL)startOSCOnPort:(NSInteger)inPort sendPort:(NSInteger)outPort host:(NSString *)host
	error:(NSError * _Nullable * _Nullable)error;
- (void)stopOSC;
@property (nonatomic, readonly) BOOL oscRunning;
@property (nonatomic, readonly) NSInteger oscClientCount;	// devices heard from lately (and the fixed host)
@property (nonatomic, readonly) NSArray<NSString *> *oscClients;
@property (class, nonatomic, readonly) NSArray<NSString *> *localIPv4Addresses;	// this Mac's, for "send to"
// Main thread, about 10 times a second: sends whatever changed (the
// patch's controls, pause, the playing patch, names, full screen).
- (void)oscSendStateWithPatch:(NSInteger)playingPatch patchName:(NSString *)patchName
	playlistName:(NSString *)playlistName fullScreen:(BOOL)fullScreen;
// Main thread, once a second: the frame statistics (Show Frame Rate's), as
// numbers and as that line of text.
- (void)oscSendStats:(NSString *)text;

// Playlist (.whl): patch paths as stored, and mappings
- (void)newPlaylist;
- (BOOL)openPlaylistAtPath:(NSString *)path error:(NSError **)error;
- (BOOL)savePlaylistToPath:(NSString *)path error:(NSError **)error;
@property (nonatomic, readonly) NSArray<NSString *> *playlistPatches;
// The panel layout saved with the playlist (Mac addition: its [Layout]
// section, the app's one-line JSON), or nil
@property (nonatomic, copy, nullable) NSString *playlistLayout;
// Loads a patch as an untitled document (CWhorldDoc::SetPatch, from
// CPlaylistBar::Play). Returns NO if it can't be read.
- (BOOL)playPatchAtPath:(NSString *)path;

// Snapshots (CWhorldApp::LoadSnapshot, SetSnapshotMode)
@property (nonatomic, readonly) BOOL snapshotMode;
// Captures the current frame's rings and writes a .whs file. The completion
// runs on the main thread with nil or an error message.
- (void)takeSnapshotToPath:(NSString *)path completion:(void (^)(NSString * _Nullable error))completion;
// Enters snapshot mode (paused, document backed up) and shows the snapshot.
- (BOOL)loadSnapshotAtPath:(NSString *)path error:(NSError **)error;
+ (nullable NSString *)snapshotInfoAtPath:(NSString *)path;	// CMainFrame::OnSnapshotInfo

// Image export (CaptureBitmap + WriteCapturedBitmap): renders the current
// frame offscreen and writes a PNG. Queued behind earlier commands.
- (void)exportImageToPath:(NSString *)path flags:(WHExportFlags)flags width:(int)width height:(int)height
	completion:(void (^)(NSString * _Nullable error))completion;
@property (nonatomic, readonly) CGSize viewSize;	// render target size in DIPs

// Movies (CMainFrame::RecordMovie, PlayMovie, PauseMovie; MovieBar)
- (void)recordMovieToPath:(nullable NSString *)path;	// nil stops recording
- (void)playMovieAtPath:(nullable NSString *)path paused:(BOOL)paused;	// nil stops playback
- (void)pauseMovie:(BOOL)pause;
- (void)seekMovie:(int64_t)frame;
@property (nonatomic, readonly) WHMovieState movieState;	// as of the last frame
// Exports frames start..end (inclusive) as img000000.png... in a folder.
// Progress and completion run on the main thread; set cancel to stop.
- (void)exportMovieToFolder:(NSString *)folder start:(int64_t)start end:(int64_t)end
	flags:(WHExportFlags)flags width:(int)width height:(int)height
	progress:(void (^)(int64_t done))progress completion:(void (^)(NSString * _Nullable error))completion;
- (void)cancelMovieExport;
// Video export (new in the Mac port): encodes the playing movie's frames
// start..end to a QuickTime movie at the movie's frame rate.
// codec: 0 H.264, 1 HEVC, 2 ProRes 422, 3 ProRes 4444. Cancel with
// cancelMovieExport; a canceled export deletes the partial file.
- (void)exportMovieVideoToPath:(NSString *)path codec:(NSInteger)codec start:(int64_t)start end:(int64_t)end
	flags:(WHExportFlags)flags width:(int)width height:(int)height
	progress:(void (^)(int64_t done))progress completion:(void (^)(NSString * _Nullable error))completion;
// Movie errors from the render thread (OnMovieError), on the main thread.
@property (nonatomic, copy, nullable) void (^movieErrorHandler)(NSString *message);
// The movie opened, closed, or changed between playing and recording (it
// changes on the render thread, after the command), on the main thread.
@property (nonatomic, copy, nullable) void (^movieStateHandler)(void);

// Renderer for the live view: YES for Metal (the default), NO for Core
// Graphics. Metal falls back to Core Graphics on its own if this Mac can't
// run it (it needs an Apple GPU) or a frame fails; setting YES retries it.
// Exports always use Core Graphics.
@property (nonatomic) BOOL preferMetal;
@property (class, nonatomic, readonly) BOOL metalAvailable;

// Syphon output (new in the Mac port; WHSyphon): a Syphon server other apps
// list as "Whorld". With width and height 0 it publishes the output's own
// frames as shown; otherwise each frame is drawn a second time at that size
// in pixels: the view's picture scaled to fit, with more of the pattern on
// the longer side. A fixed-size frame is drawn only while a client is
// receiving.
- (void)setSyphonEnabled:(BOOL)enabled width:(NSInteger)width height:(NSInteger)height;
@property (nonatomic, readonly) BOOL syphonRunning;
@property (nonatomic, readonly) BOOL syphonHasClients;
// The most frames per second the live view draws, or 0 for one per display
// refresh (up to 120 on a ProMotion display). Ring motion is per frame, as
// on Windows, so 60 also keeps patches at the speed of a 60 Hz monitor.
@property (atomic) NSInteger maxFrameRate;

// Playlist patch list editing
- (void)setPlaylistPatches:(NSArray<NSString *> *)paths;

// Statistics, updated about once a second on the main thread.
@property (nonatomic, readonly) double framesPerSecond;	// frames delivered
@property (nonatomic, readonly) double renderMilliseconds;	// mean draw time (CPU)
@property (nonatomic, readonly) double gpuMilliseconds;	// mean GPU time (Metal), else 0
@property (nonatomic, readonly) NSString *rendererName;	// "Metal" or "Core Graphics"
@property (nonatomic, readonly) NSInteger ringCount;
@property (nonatomic, readonly) int refreshRate;
@property (nonatomic, readonly) NSInteger missedFrames;	// refreshes without a new frame
@property (nonatomic, copy, nullable) void (^statsHandler)(void);

@end

// The view that displays the engine's frames. Its display link asks the
// engine for one frame per display refresh.
@interface WHRenderView : NSView
@property (nonatomic, strong, nullable) WHEngine *engine;
// If NO, render at one pixel per point and let the layer scale it up.
@property (nonatomic) BOOL fullResolution;
// The full-screen output (FullScreen.swift): the cursor is hidden while it's
// over the view (CRenderWnd::OnSetCursor), and the mouse is followed even
// when another window has the keyboard (Origin Drag with the panels in use
// on another display). Set before the view goes into its window.
@property (nonatomic) BOOL fullScreenOutput;
// Scroll wheel over the view (CRenderWnd::OnMouseWheel): delta in wheel
// notches, positive away from the user; shift if the Shift key is down.
// momentum: the scroll is coasting after the fingers lifted; inverted: the
// deltas follow the fingers (natural scrolling)
@property (nonatomic, copy, nullable) void (^wheelHandler)(double notches, BOOL shift, BOOL momentum, BOOL inverted);
// The left mouse button went down (YES) or up (NO) over the view; the
// cursor position has already been reported. With a handler, the first
// click on the view's window counts too.
@property (nonatomic, copy, nullable) void (^mouseButtonHandler)(BOOL down);
@end

NS_ASSUME_NONNULL_END
