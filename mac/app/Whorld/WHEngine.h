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

// Owns the engine and its render thread. The main thread holds the document
// (the current patch) and sends changes to the render thread as commands,
// as CWhorldDoc does through CWhorldThread on Windows. Call from the main
// thread only.
@interface WHEngine : NSObject

// Document
- (void)newPatch;
- (BOOL)openPatchAtPath:(NSString *)path error:(NSError **)error;
@property (nonatomic, readonly, nullable) NSString *patchPath;

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
@end

NS_ASSUME_NONNULL_END
