// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#import <Foundation/Foundation.h>
#include <IOSurface/IOSurfaceRef.h>

NS_ASSUME_NONNULL_BEGIN

// Syphon output (new in the Mac port): a Syphon Metal server that other apps
// (Resolume, MadMapper, OBS, TouchDesigner, ...) list by the app's name
// and the server name, if any (an empty name lists as just "Whorld"). Frames
// are Whorld's own BGRA IOSurfaces, top row first, alpha premultiplied;
// publishing copies one on the GPU, on a queue of the publisher's own.
@interface WHSyphon : NSObject
- (nullable instancetype)initWithName:(NSString *)name;
// Any thread: publishes the surface (claimed with its use count until the
// GPU has copied it, so the render thread doesn't reuse it meanwhile).
- (void)publishSurface:(IOSurfaceRef)surface;
@property (nonatomic, readonly) BOOL hasClients;
- (void)stop;	// frames published after this are ignored
@end

NS_ASSUME_NONNULL_END
