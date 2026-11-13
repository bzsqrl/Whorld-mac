// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Audio input for modulation; see WHAudioInput.h and AUDIO_PLAN.md.
//
// Threads: the device's IO thread (InputProc) only mixes the chosen
// channels into a lock-free ring; an analysis thread drains it through the
// AudioAnalyzer and publishes the results in two lock-free triple buffers,
// one for the render thread (WHAudioInputRead) and one for the meter
// (reading). The main thread starts and stops the device. Nothing on the
// IO thread allocates, locks or calls Objective-C.

#import "WHAudioInput.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>

#include "whorld/AudioAnalyzer.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <mutex>
#include <thread>
#include <vector>

namespace {

double SteadySeconds()
{
	return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

struct Published {
	whorld::ModSources	src;
	double	fTime = 0;	// when published (SteadySeconds), to carry the beat position on to now
	float	levelDb = -200;
	float	tempo = 0;
	bool	beatLocked = false;
	int		beatInBar = -1;
	int		barInPhrase = -1;
};

// One writer, one reader, lock-free: the writer fills Back() and
// publishes; the reader takes the newest published copy.
class TripleBuffer {
public:
	Published&	Back() { return m_buf[m_back]; }
	void	Publish() { m_back = m_mid.exchange(m_back | kFresh, std::memory_order_acq_rel) & 3; }
	const Published&	Read()
	{
		if (m_mid.load(std::memory_order_relaxed) & kFresh)
			m_front = m_mid.exchange(m_front, std::memory_order_acq_rel) & 3;
		return m_buf[m_front];
	}

private:
	static constexpr int	kFresh = 4;
	Published	m_buf[3];
	std::atomic<int>	m_mid{1};
	int		m_back = 0;
	int		m_front = 2;
};

// One producer (the IO thread), one consumer (the analysis thread), lock-free.
class SampleRing {
public:
	explicit SampleRing(size_t nSize) : m_buf(nSize), m_mask(nSize - 1) {}	// a power of two
	void	Push(const float* p, size_t n)
	{
		size_t	w = m_write.load(std::memory_order_relaxed);
		size_t	r = m_read.load(std::memory_order_acquire);
		n = std::min(n, m_buf.size() - (w - r));	// drop what doesn't fit
		for (size_t i = 0; i < n; i++)
			m_buf[(w + i) & m_mask] = p[i];
		m_write.store(w + n, std::memory_order_release);
	}
	size_t	Pop(float* p, size_t nMax)
	{
		size_t	w = m_write.load(std::memory_order_acquire);
		size_t	r = m_read.load(std::memory_order_relaxed);
		size_t	n = std::min(w - r, nMax);
		for (size_t i = 0; i < n; i++)
			p[i] = m_buf[(r + i) & m_mask];
		m_read.store(r + n, std::memory_order_release);
		return n;
	}

private:
	std::vector<float>	m_buf;
	size_t	m_mask;
	std::atomic<size_t>	m_write{0};
	std::atomic<size_t>	m_read{0};
};

// What the IO callback needs; set up before the unit starts, torn down
// after it stops.
struct Capture {
	AudioUnit	unit = nullptr;
	AudioBufferList	*abl = nullptr;
	std::vector<float>	data;	// abl's buffers
	std::vector<float>	mix;
	UInt32	nMaxFrames = 0;
	UInt32	nChannels = 0;
	UInt32	iFirst = 0;		// channels mixed
	UInt32	nCount = 0;
	SampleRing	*ring = nullptr;
	dispatch_semaphore_t	sem = nullptr;
};

OSStatus InputProc(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
	UInt32 bus, UInt32 nFrames, AudioBufferList *)
{
	Capture	*c = static_cast<Capture *>(ref);
	if (nFrames > c->nMaxFrames)
		return noErr;
	for (UInt32 i = 0; i < c->nChannels; i++) {
		c->abl->mBuffers[i].mDataByteSize = nFrames * sizeof(float);
		c->abl->mBuffers[i].mData = c->data.data() + size_t(i) * c->nMaxFrames;
	}
	OSStatus	err = AudioUnitRender(c->unit, flags, ts, bus, nFrames, c->abl);
	if (err != noErr)
		return err;
	float	*mix = c->mix.data();
	const float	*first = static_cast<const float *>(c->abl->mBuffers[c->iFirst].mData);
	std::copy(first, first + nFrames, mix);
	for (UInt32 ch = c->iFirst + 1; ch < c->iFirst + c->nCount; ch++) {
		const float	*p = static_cast<const float *>(c->abl->mBuffers[ch].mData);
		for (UInt32 i = 0; i < nFrames; i++)
			mix[i] += p[i];
	}
	if (c->nCount > 1) {
		float	fScale = 1.0f / static_cast<float>(c->nCount);
		for (UInt32 i = 0; i < nFrames; i++)
			mix[i] *= fScale;
	}
	c->ring->Push(mix, nFrames);
	dispatch_semaphore_signal(c->sem);
	return noErr;
}

// Core Audio property helpers

template <typename T>
bool GetProp(AudioObjectID obj, AudioObjectPropertySelector sel, T& value,
	AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal)
{
	AudioObjectPropertyAddress	addr = {sel, scope, kAudioObjectPropertyElementMain};
	UInt32	size = sizeof(T);
	return AudioObjectGetPropertyData(obj, &addr, 0, nullptr, &size, &value) == noErr;
}

NSString *StringProp(AudioObjectID obj, AudioObjectPropertySelector sel)
{
	CFStringRef	s = nullptr;
	if (!GetProp(obj, sel, s) || !s)
		return @"";
	return CFBridgingRelease(s);
}

NSInteger InputChannels(AudioObjectID dev)
{
	AudioObjectPropertyAddress	addr = {kAudioDevicePropertyStreamConfiguration,
		kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
	UInt32	size = 0;
	if (AudioObjectGetPropertyDataSize(dev, &addr, 0, nullptr, &size) != noErr || !size)
		return 0;
	std::vector<uint8_t>	buf(size);
	auto	*list = reinterpret_cast<AudioBufferList *>(buf.data());
	if (AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, list) != noErr)
		return 0;
	NSInteger	n = 0;
	for (UInt32 i = 0; i < list->mNumberBuffers; i++)
		n += list->mBuffers[i].mNumberChannels;
	return n;
}

std::vector<AudioObjectID> AllDevices()
{
	AudioObjectPropertyAddress	addr = {kAudioHardwarePropertyDevices,
		kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
	UInt32	size = 0;
	if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, nullptr, &size) != noErr)
		return {};
	std::vector<AudioObjectID>	ids(size / sizeof(AudioObjectID));
	if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, ids.data()) != noErr)
		return {};
	return ids;
}

AudioObjectID DefaultInputDevice()
{
	AudioObjectID	dev = kAudioObjectUnknown;
	GetProp(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice, dev);
	return dev;
}

NSString *RateText(double fRate)
{
	double	k = fRate / 1000;
	return std::fabs(k - std::round(k)) < 1e-6 ? [NSString stringWithFormat:@"%.0f kHz", k]
		: [NSString stringWithFormat:@"%.1f kHz", k];
}

} // namespace

@interface WHAudioDevice ()
- (instancetype)initWithID:(AudioObjectID)dev;
@property (readonly) AudioObjectID deviceID;
@end

@implementation WHAudioDevice
- (instancetype)initWithID:(AudioObjectID)dev
{
	if ((self = [super init])) {
		_deviceID = dev;
		_uid = StringProp(dev, kAudioDevicePropertyDeviceUID);
		_name = StringProp(dev, kAudioObjectPropertyName);
		_channels = InputChannels(dev);
	}
	return self;
}
@end

@implementation WHAudioInput {
	SampleRing	*_ring;
	Capture	_capture;
	dispatch_semaphore_t	_sem;
	std::thread	_thread;
	std::atomic<bool>	_quit;
	// main thread → analysis thread
	std::mutex	_setMutex;
	whorld::AudioAnalyzer::Settings	_settings;
	bool	_settingsChanged;
	double	_resetRate;		// 0: silent
	bool	_resetPending;
	std::atomic<bool>	_markDownbeat;
	// analysis thread → readers
	TripleBuffer	_forRender;
	TripleBuffer	_forMeter;
	// main thread state
	NSString	*_selectedUID;
	NSInteger	_channelFirst;
	NSInteger	_channelCount;
	AudioObjectID	_runningDevice;
	NSInteger	_runningChannels;
	NSString	*_statusText;
	WHAudioState	_state;
	AudioObjectPropertyListenerBlock	_aliveListener;
	AudioObjectPropertyListenerBlock	_rateListener;
	uint64_t	_generation;	// permission replies for an earlier choice are ignored
}

+ (WHAudioInput *)shared
{
	static WHAudioInput	*s;
	static dispatch_once_t	once;
	dispatch_once(&once, ^{ s = [[WHAudioInput alloc] init]; });
	return s;
}

+ (NSArray<WHAudioDevice *> *)devices
{
	NSMutableArray	*a = [NSMutableArray array];
	for (AudioObjectID dev : AllDevices()) {
		WHAudioDevice	*d = [[WHAudioDevice alloc] initWithID:dev];
		if (d.channels > 0 && d.uid.length)
			[a addObject:d];
	}
	[a sortUsingComparator:^(WHAudioDevice *x, WHAudioDevice *y) { return [x.name localizedStandardCompare:y.name]; }];
	return a;
}

+ (WHAudioDevice *)defaultDevice
{
	AudioObjectID	dev = DefaultInputDevice();
	if (dev == kAudioObjectUnknown)
		return nil;
	WHAudioDevice	*d = [[WHAudioDevice alloc] initWithID:dev];
	return d.channels > 0 ? d : nil;
}

- (instancetype)init
{
	if ((self = [super init])) {
		_ring = new SampleRing(1 << 16);	// about 1.4 s at 48 kHz
		_sem = dispatch_semaphore_create(0);
		_quit = false;
		_markDownbeat = false;
		_settingsChanged = true;
		_resetRate = 0;
		_resetPending = true;
		_selectedUID = @"";
		_statusText = @"Off";
		_state = WHAudioStateOff;
		_runningDevice = kAudioObjectUnknown;
		_gainDb = _settings.fGainDb;
		_rangeDb = _settings.fCeilDb - _settings.fFloorDb;
		_autoLevel = _settings.bAutoLevel;
		_hitThreshold = _settings.fHitThreshold;
		__weak WHAudioInput	*weakSelf = self;
		_thread = std::thread([weakSelf] {
			pthread_setname_np("Whorld audio analysis");
			WHAudioInput	*strong = weakSelf;
			if (strong)
				[strong analysisLoop];
		});
		// the device list and the default input
		AudioObjectPropertyAddress	devs = {kAudioHardwarePropertyDevices,
			kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
		AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &devs, dispatch_get_main_queue(),
			^(UInt32, const AudioObjectPropertyAddress *) { [weakSelf devicesChanged]; });
		AudioObjectPropertyAddress	def = {kAudioHardwarePropertyDefaultInputDevice,
			kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
		AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &def, dispatch_get_main_queue(),
			^(UInt32, const AudioObjectPropertyAddress *) { [weakSelf defaultChanged]; });
	}
	return self;
}

// The shared instance lives as long as the app; no dealloc teardown.

// MARK: Analysis thread

- (void)analysisLoop
{
	whorld::AudioAnalyzer	analyzer;
	uint32_t	aBase[whorld::ModSources::SOURCES] = {};	// counts from earlier devices
	bool	bRunning = false;
	std::vector<float>	chunk(1024);
	auto	publish = [&] {
		for (TripleBuffer *tb : {&_forRender, &_forMeter}) {
			Published&	p = tb->Back();
			if (bRunning) {
				p.src = analyzer.GetSources();
				p.levelDb = static_cast<float>(analyzer.GetLevelDb());
				p.tempo = static_cast<float>(analyzer.GetBeatTracker().GetTempo());
				p.beatLocked = analyzer.GetBeatTracker().IsLocked();
				p.beatInBar = analyzer.GetBeatTracker().GetBeatInBar();
				p.barInPhrase = analyzer.GetBeatTracker().GetBarInPhrase();
			} else {
				p.beatInBar = -1;
				p.barInPhrase = -1;
				p.src = whorld::ModSources();
				p.levelDb = -200;
				p.tempo = 0;
				p.beatLocked = false;
			}
			for (int i = 0; i < whorld::ModSources::SOURCES; i++)
				p.src.aCount[i] = aBase[i] + (bRunning ? analyzer.GetSources().aCount[i] : 0);
			p.fTime = SteadySeconds();
			tb->Publish();
		}
	};
	publish();
	while (!_quit.load()) {
		dispatch_semaphore_wait(_sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC));
		bool	bReset = false;
		double	fRate = 0;
		{
			std::lock_guard<std::mutex>	lock(_setMutex);
			if (_settingsChanged) {
				analyzer.SetSettings(_settings);
				_settingsChanged = false;
			}
			if (_resetPending) {
				bReset = true;
				fRate = _resetRate;
				_resetPending = false;
			}
		}
		if (bReset) {	// a new device (or none): keep the counts going up
			while (_ring->Pop(chunk.data(), chunk.size()))
				;	// the old device's samples
			if (bRunning) {
				for (int i = 0; i < whorld::ModSources::SOURCES; i++)
					aBase[i] += analyzer.GetSources().aCount[i];
			}
			bRunning = fRate > 0;
			if (bRunning)
				analyzer.Reset(fRate);
			publish();
		}
		if (!bRunning)
			continue;
		if (_markDownbeat.exchange(false))
			analyzer.MarkDownbeat();
		uint64_t	nBefore = analyzer.GetAnalysisCount();
		size_t	n;
		while ((n = _ring->Pop(chunk.data(), chunk.size())) > 0)
			analyzer.Process(chunk.data(), n);
		if (analyzer.GetAnalysisCount() != nBefore)
			publish();
	}
}

- (void)requestResetAtRate:(double)fRate
{
	{
		std::lock_guard<std::mutex>	lock(_setMutex);
		_resetRate = fRate;
		_resetPending = true;
	}
	dispatch_semaphore_signal(_sem);
}

// MARK: Readers

- (WHAudioReading)reading
{
	const Published&	p = _forMeter.Read();
	using S = whorld::ModSources;
	WHAudioReading	r = {};
	r.level = p.src.aValue[S::SRC_Level];
	r.bass = p.src.aValue[S::SRC_Bass];
	r.lowMid = p.src.aValue[S::SRC_LowMid];
	r.highMid = p.src.aValue[S::SRC_HighMid];
	r.treble = p.src.aValue[S::SRC_Treble];
	r.brightness = p.src.aValue[S::SRC_Brightness];
	r.levelDb = p.levelDb;
	r.hits = p.src.aCount[S::SRC_Hit];
	r.kicks = p.src.aCount[S::SRC_Kick];
	r.hats = p.src.aCount[S::SRC_Hats];
	r.beats = p.src.aCount[S::SRC_Beat];
	r.tempo = p.tempo;
	r.beatLocked = p.beatLocked;
	r.beatInBar = p.beatInBar;
	r.barInPhrase = p.barInPhrase;
	return r;
}

- (void)markDownbeat
{
	_markDownbeat = true;
	dispatch_semaphore_signal(_sem);
}

- (void)readSources:(whorld::ModSources&)sources
{
	const Published&	p = _forRender.Read();
	sources = p.src;
	// the beat position as of now: analyses come every 10.7 ms or so, frames
	// in between, and beat-based rows fire on it to the frame
	if (sources.bBeat && sources.fTempo > 0)
		sources.fBeatPos += std::max(0.0, SteadySeconds() - p.fTime) * sources.fTempo / 60;
}

// MARK: Settings

- (void)updateSettings
{
	{
		std::lock_guard<std::mutex>	lock(_setMutex);
		_settings.fGainDb = _gainDb;
		_settings.fCeilDb = 0;
		_settings.fFloorDb = -std::max(_rangeDb, 6.0);
		_settings.bAutoLevel = _autoLevel;
		_settings.fHitThreshold = _hitThreshold;
		_settingsChanged = true;
	}
	dispatch_semaphore_signal(_sem);
}

- (void)setGainDb:(double)gainDb { _gainDb = gainDb; [self updateSettings]; }
- (void)setRangeDb:(double)rangeDb { _rangeDb = rangeDb; [self updateSettings]; }
- (void)setAutoLevel:(BOOL)autoLevel { _autoLevel = autoLevel; [self updateSettings]; }
- (void)setHitThreshold:(double)hitThreshold { _hitThreshold = hitThreshold; [self updateSettings]; }

// MARK: Device

- (NSString *)selectedUID { return _selectedUID; }
- (WHAudioState)state { return _state; }
- (NSString *)statusText { return _statusText; }
- (NSInteger)runningChannels { return _runningChannels; }

- (void)notify
{
	if (_changeHandler)
		_changeHandler();
}

- (void)setState:(WHAudioState)state text:(NSString *)text
{
	_state = state;
	_statusText = text;
	[self notify];
}

- (void)selectDevice:(NSString *)uid channelFirst:(NSInteger)first count:(NSInteger)count
{
	_selectedUID = [uid copy];
	_channelFirst = std::max<NSInteger>(first, 0);
	_channelCount = std::max<NSInteger>(count, 0);
	_generation++;
	[self stopDevice];
	if (!uid.length) {
		[self setState:WHAudioStateOff text:@"Off"];
		return;
	}
	switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
	case AVAuthorizationStatusAuthorized:
		[self startDevice];
		break;
	case AVAuthorizationStatusNotDetermined: {
		[self setState:WHAudioStateWaitingForPermission text:@"Waiting for permission to use audio input…"];
		uint64_t	gen = _generation;
		__weak WHAudioInput	*weakSelf = self;
		[AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
			dispatch_async(dispatch_get_main_queue(), ^{
				WHAudioInput	*strong = weakSelf;
				if (!strong || strong->_generation != gen)
					return;	// chosen again since
				if (granted)
					[strong startDevice];
				else
					[strong setDenied];
			});
		}];
		break;
	}
	default:
		[self setDenied];
		break;
	}
}

- (void)setDenied
{
	[self setState:WHAudioStateDenied text:@"Audio input is off for Whorld: turn it on in System Settings > Privacy & Security > Microphone."];
}

- (AudioObjectID)deviceForSelection
{
	if ([_selectedUID isEqualToString:@"default"])
		return DefaultInputDevice();
	for (AudioObjectID dev : AllDevices()) {
		if ([StringProp(dev, kAudioDevicePropertyDeviceUID) isEqualToString:_selectedUID])
			return dev;
	}
	return kAudioObjectUnknown;
}

- (void)startDevice
{
	[self stopDevice];
	AudioObjectID	dev = [self deviceForSelection];
	if (dev == kAudioObjectUnknown || InputChannels(dev) <= 0) {
		[self setState:WHAudioStateUnavailable text:@"The audio input isn't connected."];
		return;
	}
	NSString	*name = StringProp(dev, kAudioObjectPropertyName);
	auto	fail = [&](NSString *what, OSStatus err) {
		[self disposeUnit];
		[self setState:WHAudioStateUnavailable
			text:[NSString stringWithFormat:@"%@ wouldn't start (%@, error %d).", name, what, (int)err]];
	};
	AudioComponentDescription	desc = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput,
		kAudioUnitManufacturer_Apple, 0, 0};
	AudioComponent	comp = AudioComponentFindNext(nullptr, &desc);
	OSStatus	err = comp ? AudioComponentInstanceNew(comp, &_capture.unit) : -1;
	if (err != noErr)
		return fail(@"no input unit", err);
	AudioUnit	unit = _capture.unit;
	UInt32	one = 1, zero = 0;
	if ((err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, sizeof(one))) != noErr
	|| (err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, sizeof(zero))) != noErr)
		return fail(@"input", err);
	if ((err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, sizeof(dev))) != noErr)
		return fail(@"device", err);
	AudioStreamBasicDescription	hw = {};
	UInt32	size = sizeof(hw);
	if ((err = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size)) != noErr
	|| hw.mChannelsPerFrame == 0 || hw.mSampleRate <= 0)
		return fail(@"format", err);
	UInt32	nCh = hw.mChannelsPerFrame;
	AudioStreamBasicDescription	client = {};
	client.mSampleRate = hw.mSampleRate;
	client.mFormatID = kAudioFormatLinearPCM;
	client.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
	client.mBytesPerPacket = sizeof(float);
	client.mFramesPerPacket = 1;
	client.mBytesPerFrame = sizeof(float);
	client.mChannelsPerFrame = nCh;
	client.mBitsPerChannel = 32;
	if ((err = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, sizeof(client))) != noErr)
		return fail(@"format", err);
	UInt32	nMax = 0;
	size = sizeof(nMax);
	AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &nMax, &size);
	nMax = std::max<UInt32>(nMax, 4096);
	_capture.nMaxFrames = nMax;
	_capture.nChannels = nCh;
	// the chosen channels, within what the device has
	UInt32	iFirst = static_cast<UInt32>(std::min<NSInteger>(_channelFirst, nCh - 1));
	UInt32	nCount = _channelCount ? static_cast<UInt32>(std::min<NSInteger>(_channelCount, nCh - iFirst)) : nCh - iFirst;
	if (!_channelCount)
		iFirst = 0, nCount = nCh;
	_capture.iFirst = iFirst;
	_capture.nCount = nCount;
	_capture.data.assign(size_t(nCh) * nMax, 0);
	_capture.mix.assign(nMax, 0);
	_capture.abl = static_cast<AudioBufferList *>(std::calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * nCh));
	_capture.abl->mNumberBuffers = nCh;
	for (UInt32 i = 0; i < nCh; i++) {
		_capture.abl->mBuffers[i].mNumberChannels = 1;
		_capture.abl->mBuffers[i].mDataByteSize = nMax * sizeof(float);
		_capture.abl->mBuffers[i].mData = _capture.data.data() + size_t(i) * nMax;
	}
	_capture.ring = _ring;
	_capture.sem = _sem;
	AURenderCallbackStruct	cb = {InputProc, &_capture};
	if ((err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, sizeof(cb))) != noErr)
		return fail(@"callback", err);
	if ((err = AudioUnitInitialize(unit)) != noErr)
		return fail(@"initialize", err);
	[self requestResetAtRate:hw.mSampleRate];
	if ((err = AudioOutputUnitStart(unit)) != noErr)
		return fail(@"start", err);
	_runningDevice = dev;
	_runningChannels = nCh;
	[self watchDevice:dev];
	NSString	*channels = nCount == nCh
		? (nCh == 1 ? @"1 channel" : [NSString stringWithFormat:@"%u channels mixed", nCh])
		: nCount == 1 ? [NSString stringWithFormat:@"channel %u", iFirst + 1]
		: [NSString stringWithFormat:@"channels %u–%u mixed", iFirst + 1, iFirst + nCount];
	[self setState:WHAudioStateRunning
		text:[NSString stringWithFormat:@"%@ · %@ · %@", name, channels, RateText(hw.mSampleRate)]];
}

- (void)disposeUnit
{
	if (_capture.unit) {
		AudioOutputUnitStop(_capture.unit);
		AudioUnitUninitialize(_capture.unit);
		AudioComponentInstanceDispose(_capture.unit);	// the IO callback has finished
		_capture.unit = nullptr;
	}
	std::free(_capture.abl);
	_capture.abl = nullptr;
}

- (void)stopDevice
{
	[self unwatchDevice];
	bool	bWasRunning = _capture.unit != nullptr;
	[self disposeUnit];
	_runningDevice = kAudioObjectUnknown;
	_runningChannels = 0;
	if (bWasRunning)
		[self requestResetAtRate:0];	// silence for the meter and the render thread
}

// The running device going away or changing rate
- (void)watchDevice:(AudioObjectID)dev
{
	__weak WHAudioInput	*weakSelf = self;
	_aliveListener = ^(UInt32, const AudioObjectPropertyAddress *) { [weakSelf runningDeviceChanged]; };
	_rateListener = _aliveListener;
	AudioObjectPropertyAddress	alive = {kAudioDevicePropertyDeviceIsAlive,
		kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
	AudioObjectAddPropertyListenerBlock(dev, &alive, dispatch_get_main_queue(), _aliveListener);
	AudioObjectPropertyAddress	rate = {kAudioDevicePropertyNominalSampleRate,
		kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
	AudioObjectAddPropertyListenerBlock(dev, &rate, dispatch_get_main_queue(), _rateListener);
}

- (void)unwatchDevice
{
	if (_runningDevice == kAudioObjectUnknown || !_aliveListener)
		return;
	AudioObjectPropertyAddress	alive = {kAudioDevicePropertyDeviceIsAlive,
		kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
	AudioObjectRemovePropertyListenerBlock(_runningDevice, &alive, dispatch_get_main_queue(), _aliveListener);
	AudioObjectPropertyAddress	rate = {kAudioDevicePropertyNominalSampleRate,
		kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
	AudioObjectRemovePropertyListenerBlock(_runningDevice, &rate, dispatch_get_main_queue(), _rateListener);
	_aliveListener = nil;
	_rateListener = nil;
}

- (void)runningDeviceChanged
{
	if (_runningDevice == kAudioObjectUnknown)
		return;
	UInt32	alive = 1;
	GetProp(_runningDevice, kAudioDevicePropertyDeviceIsAlive, alive);
	if (!alive) {
		[self stopDevice];
		[self setState:WHAudioStateUnavailable text:@"The audio input was disconnected."];
		return;
	}
	[self startDevice];	// the sample rate changed: start again at the new one
}

- (void)devicesChanged
{
	// a chosen device that was missing may have come back
	if (_state == WHAudioStateUnavailable && _selectedUID.length)
		[self startDevice];
	[self notify];
}

- (void)defaultChanged
{
	if ([_selectedUID isEqualToString:@"default"] && _state != WHAudioStateDenied
	&& _state != WHAudioStateWaitingForPermission)
		[self startDevice];
	else
		[self notify];
}

@end

void WHAudioInputRead(whorld::ModSources& sources)
{
	[[WHAudioInput shared] readSources:sources];
}
