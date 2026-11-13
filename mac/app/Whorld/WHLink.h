// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Ableton Link (new in the Mac port; AUDIO_PLAN.md, Phase 9.6): the session's
// tempo, beat and bars, from Ableton Live or any Link app on the network.
// While the session has peers, Link drives the beat-based modulation sources
// (Beat, Bar ... 32-Bar) in place of the beat tracker. Uses Ableton's Link
// library (GPLv2 or later; mac/third_party/link).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WHLink : NSObject
@property (class, readonly) WHLink *shared;
@property (nonatomic) BOOL enabled;			// joins the session on the network
@property (nonatomic) BOOL startStopSync;	// beats only while the session plays
@property (readonly) NSInteger peers;		// other Link apps in the session
@property (readonly) double tempo;			// the session's, BPM
@property (readonly) BOOL playing;			// the session's transport (with Start/Stop sync)
/// Link drives the beat now (enabled, with peers)
@property (readonly) BOOL drivesBeat;
/// beats since the one, and whether there's a beat now (main thread, for the meter)
- (BOOL)beatPosition:(double *)position;
/// The beat nearest now is "the one" for Bar ... 32-Bar.
- (void)markDownbeat;
/// Called on the main thread when peers, tempo or the transport change.
@property (nonatomic, copy, nullable) void (^changeHandler)(void);
@end

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
#include "whorld/Modulation.h"
// While Link drives the beat, sets the sources' beat position and tempo (as
// of now; no beat while stopped with Start/Stop sync) and returns true;
// otherwise leaves them and returns false. Any thread; not realtime-safe.
bool WHLinkRead(whorld::ModSources& sources);
#endif
