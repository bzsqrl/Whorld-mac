// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
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
+ (NSString *)format:(double)value control:(WHControlInfo)control;
+ (double)parse:(NSString *)text control:(WHControlInfo)control;
+ (NSString *)formatMaster:(NSInteger)iProp value:(double)value;
+ (double)parseMaster:(NSInteger)iProp text:(NSString *)text;
// spin button: returns the new value, or the same value if clamped unchanged
+ (double)spin:(double)value control:(WHControlInfo)control direction:(NSInteger)direction;
@end

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
@property (nonatomic) double hue;
@property (nonatomic) BOOL invertColor;
- (void)setOriginMotion:(WHOriginMotion)motion;
// CWhorldDoc::SetZoom: sets the master zoom and zooms, optionally damped
- (void)setZoom:(double)zoom damping:(BOOL)damping;
// snapshot letterbox option (COptions m_Snapshot_bLetterbox)
- (void)setSnapshotLetterbox:(BOOL)enable;
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

// Rendering, driven by WHRenderView. Requests a frame of the given pixel
// size and scale (pixels per DIP) at the display's refresh rate; the frame
// is delivered to the layer on the main thread. Requests made while a frame
// is being drawn are coalesced.
- (void)attachLayer:(nullable CALayer *)layer;
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
// document (kind: 0 document changed, 1 pause toggled, 2 play patch `value`,
// 3 learn message `value`), and when the MIDI sources change (kind 4).
@property (nonatomic, copy, nullable) void (^midiHandler)(NSInteger kind, uint32_t value);

// Playlist (.whl): patch paths as stored, and mappings
- (void)newPlaylist;
- (BOOL)openPlaylistAtPath:(NSString *)path error:(NSError **)error;
- (BOOL)savePlaylistToPath:(NSString *)path error:(NSError **)error;
@property (nonatomic, readonly) NSArray<NSString *> *playlistPatches;
// Loads a patch as an untitled document (CWhorldDoc::SetPatch, from
// CPlaylistBar::Play). Returns NO if it can't be read.
- (BOOL)playPatchAtPath:(NSString *)path;

// Statistics, updated about once a second on the main thread.
@property (nonatomic, readonly) double framesPerSecond;	// frames delivered
@property (nonatomic, readonly) double renderMilliseconds;	// mean draw time
@property (nonatomic, readonly) NSInteger ringCount;
@property (nonatomic, readonly) int refreshRate;
@property (nonatomic, copy, nullable) void (^statsHandler)(void);

@end

// The view that displays the engine's frames. Its display link asks the
// engine for one frame per display refresh.
@interface WHRenderView : NSView
@property (nonatomic, strong, nullable) WHEngine *engine;
// If NO, render at one pixel per point and let the layer scale it up.
@property (nonatomic) BOOL fullResolution;
// Scroll wheel over the view (CRenderWnd::OnMouseWheel): delta in wheel
// notches, positive away from the user; shift if the Shift key is down.
@property (nonatomic, copy, nullable) void (^wheelHandler)(double notches, BOOL shift);
@end

NS_ASSUME_NONNULL_END
