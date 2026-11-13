// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Audio input for modulation (new in the Mac port; AUDIO_PLAN.md, Phase
// 9.3). A Core Audio input device's chosen channels, mixed to mono, go
// through the AudioAnalyzer on a thread of their own; the render thread
// reads the latest results each frame (WHAudioInputRead), and the
// Modulation window's meter reads them too (reading).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// An audio device with inputs.
@interface WHAudioDevice : NSObject
@property (readonly) NSString *uid;
@property (readonly) NSString *name;
@property (readonly) NSInteger channels;	// input channels
@end

typedef NS_ENUM(NSInteger, WHAudioState) {
	WHAudioStateOff,			// no device chosen
	WHAudioStateRunning,
	WHAudioStateWaitingForPermission,
	WHAudioStateDenied,			// microphone access is off for Whorld
	WHAudioStateUnavailable,	// the device is gone or wouldn't start
};

/// The analysis as the meter shows it; values 0 to 1 except as noted.
typedef struct {
	float	level, bass, lowMid, highMid, treble, brightness;
	float	levelDb;	// relative to a full-scale sine
	uint32_t	hits, kicks, hats, beats;	// counts so far
	float	tempo;		// the beat tracker's, BPM (0 until found)
	BOOL	beatLocked;	// the tracker has the beat
} WHAudioReading;

@interface WHAudioInput : NSObject
@property (class, readonly) WHAudioInput *shared;
/// Devices with inputs, by name.
@property (class, readonly) NSArray<WHAudioDevice *> *devices;
/// The system's default input device, if any.
@property (class, readonly, nullable) WHAudioDevice *defaultDevice;

/// Chooses the input: "" for none, "default" for the system's default
/// input (following changes to it), or a device's uid. Channels: count 0
/// mixes all of them; otherwise channels first..first+count-1 (0-based),
/// mixed. Asks for microphone access if needed. Main thread.
- (void)selectDevice:(NSString *)uid channelFirst:(NSInteger)first count:(NSInteger)count;
@property (readonly) NSString *selectedUID;
@property (readonly) WHAudioState state;
/// What's running ("MacBook Pro Microphone · 1 channel · 44.1 kHz") or
/// what's wrong, for the status line.
@property (readonly) NSString *statusText;
/// The running device's input channel count (0 when not running).
@property (readonly) NSInteger runningChannels;

// analysis settings (AudioAnalyzer::Settings)
@property (nonatomic) double gainDb;
@property (nonatomic) double rangeDb;	// level and bands read 0 this far below the top (0 dB, or the recent peak with auto-level)
@property (nonatomic) BOOL autoLevel;
@property (nonatomic) double hitThreshold;	// higher: fewer, stronger hits

/// Called on the main thread when the state, the device list or the
/// running device changes.
@property (nonatomic, copy, nullable) void (^changeHandler)(void);

/// The latest analysis, for the meter. Main thread.
- (WHAudioReading)reading;
@end

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
#include "whorld/Modulation.h"
// The latest analysis as modulation sources, for the render thread (one
// reader; lock-free). Silence (and unchanged hit counts) when no input runs.
void WHAudioInputRead(whorld::ModSources& sources);
#endif
