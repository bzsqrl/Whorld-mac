// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Ableton Link; see WHLink.h. The only file that includes the Link library
// (and its asio), so their headers stay out of everything else.

#import "WHLink.h"

#define LINK_PLATFORM_MACOSX 1
#include <ableton/Link.hpp>

#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>

namespace {

const double kQuantum = 4;	// beats to a bar: bar lines (and phrases) line up with the session's

} // namespace

@implementation WHLink {
	std::unique_ptr<ableton::Link>	_link;
	std::mutex	_offsetMutex;
	double	_oneOffset;		// session beat that is "the one" (Mark Downbeat, or where the session started playing), mod 128
	int64_t	_startMicros;	// when the session last started playing, as last seen (Start/Stop sync)
	std::atomic<bool>	_enabled;
	std::atomic<bool>	_startStopSync;
}

+ (WHLink *)shared
{
	static WHLink	*s;
	static dispatch_once_t	once;
	dispatch_once(&once, ^{ s = [[WHLink alloc] init]; });
	return s;
}

- (instancetype)init
{
	if ((self = [super init])) {
		_oneOffset = 0;
		_startMicros = 0;
		_enabled = false;
		_startStopSync = false;
		_link = std::make_unique<ableton::Link>(120.0);	// not joined until enabled
		__weak WHLink	*weakSelf = self;
		auto	notify = [weakSelf] {
			dispatch_async(dispatch_get_main_queue(), ^{
				WHLink	*strong = weakSelf;
				if (strong.changeHandler)
					strong.changeHandler();
			});
		};
		_link->setNumPeersCallback([notify](std::size_t) { notify(); });
		_link->setTempoCallback([notify](double) { notify(); });
		_link->setStartStopCallback([notify](bool) { notify(); });
	}
	return self;
}

- (BOOL)enabled { return _enabled.load(); }

- (void)setEnabled:(BOOL)enabled
{
	_enabled = enabled;
	_link->enable(enabled);
	if (_changeHandler)
		_changeHandler();
}

- (BOOL)startStopSync { return _startStopSync.load(); }

- (void)setStartStopSync:(BOOL)sync
{
	_startStopSync = sync;
	_link->enableStartStopSync(sync);
	if (_changeHandler)
		_changeHandler();
}

- (NSInteger)peers { return _enabled ? static_cast<NSInteger>(_link->numPeers()) : 0; }
- (double)tempo { return _link->captureAppSessionState().tempo(); }
- (BOOL)playing { return _link->captureAppSessionState().isPlaying(); }
- (BOOL)drivesBeat { return _enabled && _link->numPeers() > 0; }

// The session's beat as of now, shifted so the one (Mark Downbeat) is 0;
// false when there's no beat (not driving, or stopped with Start/Stop sync).
- (bool)readBeat:(double&)position tempo:(double&)tempo
{
	if (!self.drivesBeat)
		return false;
	auto	state = _link->captureAppSessionState();
	tempo = state.tempo();
	if (_startStopSync && !state.isPlaying())
		return false;
	double	fOne;
	{
		std::lock_guard<std::mutex>	lock(_offsetMutex);
		// Link keeps apps together within a bar, but each counts bars on its
		// own timeline; with Start/Stop sync, the beat where the session
		// started playing (Live's Play) is the one, so phrases count from it
		if (_startStopSync && state.isPlaying()) {
			int64_t	nStart = state.timeForIsPlaying().count();
			if (nStart != _startMicros) {
				_startMicros = nStart;
				double	fStart = state.beatAtTime(state.timeForIsPlaying(), kQuantum);
				_oneOffset = std::fmod(std::round(fStart / kQuantum) * kQuantum, 128.0);
			}
		}
		fOne = _oneOffset;
	}
	position = state.beatAtTime(_link->clock().micros(), kQuantum) - fOne;
	return true;
}

- (BOOL)beatPosition:(double *)position
{
	double	pos = 0, tempo = 0;
	bool	b = [self readBeat:pos tempo:tempo];
	if (position)
		*position = pos;
	return b;
}

- (void)markDownbeat
{
	if (!self.drivesBeat)
		return;
	double	fBeat = _link->captureAppSessionState().beatAtTime(_link->clock().micros(), kQuantum);
	std::lock_guard<std::mutex>	lock(_offsetMutex);
	// the nearest session beat becomes the one (only its place within the
	// 32-bar phrase matters)
	_oneOffset = std::fmod(std::round(fBeat), 128.0);
}

@end

bool WHLinkRead(whorld::ModSources& sources)
{
	WHLink	*link = [WHLink shared];
	if (!link.drivesBeat)
		return false;
	double	pos = 0, tempo = 0;
	sources.bBeat = [link readBeat:pos tempo:tempo];
	sources.fBeatPos = pos;
	sources.fTempo = tempo;
	return true;
}
