// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Audio-reactive video export; see AudioVideoExport.h. The audio file is
// decoded (AVAssetReader, resampled to 48 kHz stereo) only as far as the
// frames need: each buffer goes to the movie's sound track and, mixed to
// mono, to the analyzer.

#include "AudioVideoExport.h"

#include "whorld/Random.h"
#include "whorld/WhorldEngine.h"

#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include <cmath>
#include <memory>

namespace whorld {

namespace {

const double kAudioRate = 48000;

// Draws nothing: the patch runs ahead (pre-roll) without the cost of drawing
class NullRenderer : public IRenderer {
public:
	void	SetAntialiasing(bool) override {}
	void	Clear(const ColorF&) override {}
	void	BeginPath() override {}
	void	AddFigure(const PointF*, int, bool, bool) override {}
	void	EndPath() override {}
	void	FillPath(const ColorF&) override {}
	void	StrokePath(const ColorF&, float) override {}
	void	FillRect(const RectF&, const ColorF&) override {}
	bool	BeginQuadMirror() override { return false; }
	bool	EndQuadMirror() override { return false; }
};

// The audio file, decoded a buffer at a time
class AudioSource {
public:
	~AudioSource() { [m_reader cancelReading]; }

	// the file's length in seconds, or a negative number if it can't be read
	static double Length(NSURL *url)
	{
		NSError	*err = nil;
		AVAudioFile	*file = [[AVAudioFile alloc] initForReading:url error:&err];
		if (!file || file.processingFormat.sampleRate <= 0)
			return -1;
		return static_cast<double>(file.length) / file.processingFormat.sampleRate;
	}

	bool Open(NSURL *url, double fStart, double fDuration, std::string* pError)
	{
		AVURLAsset	*asset = [AVURLAsset URLAssetWithURL:url options:nil];
		__block NSArray<AVAssetTrack *>	*tracks = nil;
		dispatch_semaphore_t	done = dispatch_semaphore_create(0);
		[asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> *a, NSError *) {
			tracks = a;
			dispatch_semaphore_signal(done);
		}];
		dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
		if (!tracks.count)
			return Fail(pError, "The audio file has no sound in it.");
		NSError	*err = nil;
		m_reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
		if (!m_reader)
			return Fail(pError, err.localizedDescription.UTF8String ?: "Can't read the audio file.");
		m_output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tracks.firstObject outputSettings:@{
			AVFormatIDKey: @(kAudioFormatLinearPCM),
			AVSampleRateKey: @(kAudioRate),
			AVNumberOfChannelsKey: @2,
			AVLinearPCMBitDepthKey: @32,
			AVLinearPCMIsFloatKey: @YES,
			AVLinearPCMIsNonInterleaved: @NO,
			AVLinearPCMIsBigEndianKey: @NO,
		}];
		m_output.alwaysCopiesSampleData = NO;
		if (![m_reader canAddOutput:m_output])
			return Fail(pError, "Can't decode the audio file.");
		[m_reader addOutput:m_output];
		m_reader.timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds(fStart, 48000), CMTimeMakeWithSeconds(fDuration, 48000));
		if (![m_reader startReading])
			return Fail(pError, m_reader.error.localizedDescription.UTF8String ?: "Can't decode the audio file.");
		return true;
	}

	// Decodes the next buffer: its mono samples are added to the pending
	// ones, and the buffer, retimed from 0, is returned for the sound track
	// (the caller releases it). Null at the end.
	CMSampleBufferRef Next()
	{
		if (m_bEnd)
			return nullptr;
		CMSampleBufferRef	buf = [m_output copyNextSampleBuffer];
		if (!buf) {
			m_bEnd = true;
			return nullptr;
		}
		CMItemCount	nFrames = CMSampleBufferGetNumSamples(buf);
		AudioBufferList	abl = {};
		CMBlockBufferRef	block = nullptr;
		if (CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buf, nullptr, &abl, sizeof(abl), nullptr, nullptr,
			kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &block) == noErr && abl.mNumberBuffers == 1) {
			const float	*p = static_cast<const float *>(abl.mBuffers[0].mData);
			size_t	n = std::min<size_t>(nFrames, abl.mBuffers[0].mDataByteSize / (2 * sizeof(float)));
			for (size_t i = 0; i < n; i++)
				m_aMono.push_back(0.5f * (p[2 * i] + p[2 * i + 1]));
		}
		if (block)
			CFRelease(block);
		// contiguous times from 0, at the decoded sample count
		CMSampleTimingInfo	timing = {CMTimeMake(1, static_cast<int32_t>(kAudioRate)),
			CMTimeMake(m_nDecoded, static_cast<int32_t>(kAudioRate)), kCMTimeInvalid};
		CMSampleBufferRef	retimed = nullptr;
		CMSampleBufferCreateCopyWithNewTiming(nullptr, buf, 1, &timing, &retimed);
		CFRelease(buf);
		m_nDecoded += nFrames;
		return retimed;
	}

	int64_t	Decoded() const { return m_nDecoded; }
	bool	AtEnd() const { return m_bEnd; }
	// samples decoded but not yet analyzed, from sample Analyzed()
	std::vector<float>&	Pending() { return m_aMono; }

private:
	AVAssetReader	*m_reader = nil;
	AVAssetReaderTrackOutput	*m_output = nil;
	std::vector<float>	m_aMono;
	int64_t	m_nDecoded = 0;
	bool	m_bEnd = false;

	static bool Fail(std::string* pError, const char* psz)
	{
		if (pError)
			*pError = psz;
		return false;
	}
};

// Restores the calling thread's random sequence on the way out
class SaveRand {
public:
	SaveRand() : m_nState(detail::RandState()) {}
	~SaveRand() { detail::RandState() = m_nState; }
private:
	uint32_t	m_nState;
};

// Where the beat tracker first finds the beat, from a pass of its own over
// the audio (analyzing exactly as the export does, the same samples and the
// same downbeat), so the export can carry that beat back to its first frame
// instead of waiting the few seconds the tracker takes to lock
struct FirstBeat {
	bool	bFound = false;
	int64_t	nAt = 0;		// samples analyzed when it was found
	double	fBeatPos = 0;	// the beat position then
	double	fTempo = 0;
};

FirstBeat FindFirstBeat(NSURL *url, double fStart, double fDuration, const AudioAnalyzer::Settings& settings,
	int64_t iDownbeat)
{
	const double	kMaxSeconds = 30;	// it locks within a few seconds of steady music
	FirstBeat	fb;
	AudioSource	audio;
	if (!audio.Open(url, fStart, std::min(fDuration, kMaxSeconds), nullptr))
		return fb;
	AudioAnalyzer	analyzer;
	analyzer.Reset(kAudioRate);
	analyzer.SetSettings(settings);
	const int64_t	kChunk = static_cast<int64_t>(analyzer.GetHopSize());
	int64_t	nAnalyzed = 0;
	for (;;) {
		while (audio.Pending().empty() && !audio.AtEnd()) {
			if (CMSampleBufferRef buf = audio.Next())
				CFRelease(buf);
		}
		std::vector<float>&	pending = audio.Pending();
		if (pending.empty())
			return fb;	// no beat in the time scanned
		int64_t	nStop = nAnalyzed + kChunk;
		if (iDownbeat >= nAnalyzed && iDownbeat < nStop)
			nStop = iDownbeat;
		size_t	n = static_cast<size_t>(std::min<int64_t>(nStop - nAnalyzed, static_cast<int64_t>(pending.size())));
		analyzer.Process(pending.data(), n);
		pending.erase(pending.begin(), pending.begin() + static_cast<ptrdiff_t>(n));
		nAnalyzed += static_cast<int64_t>(n);
		if (nAnalyzed == iDownbeat) {
			analyzer.MarkDownbeat();
			iDownbeat = -1;
		}
		const ModSources&	src = analyzer.GetSources();
		if (src.bBeat && src.fTempo > 0) {
			fb.bFound = true;
			fb.nAt = nAnalyzed;
			fb.fBeatPos = src.fBeatPos;
			fb.fTempo = src.fTempo;
			return fb;
		}
	}
}

} // namespace

bool ReadModulationFile(const std::string& sPath, AudioVideoOptions& opts, std::string* pError)
{
	NSData	*data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:sPath.c_str()]];
	NSDictionary	*file = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
	if (![file isKindOfClass:NSDictionary.class]) {
		if (pError)
			*pError = "It isn't a Whorld modulation file.";
		return false;
	}
	// missing fields read as the app's defaults (ModRowSetting, ModSyncSetting)
	auto	num = [](NSDictionary *d, NSString *key, double fDefault) {
		id	v = d[key];
		return [v isKindOfClass:NSNumber.class] ? [v doubleValue] : fDefault;
	};
	auto	str = [](NSDictionary *d, NSString *key, const char* pszDefault) {
		id	v = d[key];
		return std::string([v isKindOfClass:NSString.class] ? [v UTF8String] : pszDefault);
	};
	opts.fDepth = std::clamp(num(file, @"depth", 1), 0.0, 1.0);
	opts.bFollowTempo = num(file, @"followTempo", 0) != 0;
	bool	bBypass = num(file, @"bypass", 0) != 0;
	opts.aRow.clear();
	opts.aSync.clear();
	if (bBypass)
		return true;
	for (NSDictionary *r in file[@"rows"]) {
		if (![r isKindOfClass:NSDictionary.class])
			continue;
		ModRow	row;
		row.bOn = num(r, @"on", 1) != 0;
		row.iSource = ModSources::FindTag(str(r, @"source", "Bass"));
		std::string	sAction = str(r, @"action", "");
		row.iAction = sAction.empty() ? -1 : ModActions::FindTag(sAction);
		row.iTarget = MappingBase::FindTargetTag(str(r, @"target", "LineWidth"));
		row.iProp = static_cast<int>(num(r, @"prop", 0));
		row.fAmount = num(r, @"amount", 0.25);
		row.nCurve = static_cast<int>(num(r, @"curve", 0));
		row.bCentered = num(r, @"centered", 0) != 0;
		row.fAttack = num(r, @"attackMs", 10) / 1000;
		row.fRelease = num(r, @"releaseMs", 200) / 1000;
		row.fThreshold = num(r, @"threshold", 0.5);
		row.fOffset = std::clamp(num(r, @"offsetMs", 0), -300.0, 300.0) / 1000;
		bool	bKnown = ModSources::IsValid(row.iSource)
			&& (sAction.empty() ? ModRow::IsModulatable(row.iTarget, row.iProp) : row.IsAction());
		if (bKnown)
			opts.aRow.push_back(row);
	}
	for (NSDictionary *y in file[@"syncs"]) {
		if (![y isKindOfClass:NSDictionary.class])
			continue;
		ModSync	sync;
		sync.bOn = num(y, @"on", 1) != 0;
		sync.iParam = MappingBase::FindTargetTag(str(y, @"param", "LineWidth"));
		sync.fBeats = num(y, @"beats", 4);
		double	fDeg = std::fmod(num(y, @"phaseDeg", 0), 360);
		sync.fPhase = (fDeg < 0 ? fDeg + 360 : fDeg) / 360;
		sync.fOffset = std::clamp(num(y, @"offsetMs", 0), -300.0, 300.0) / 1000;
		if (sync.iParam >= 0 && sync.iParam < MappingBase::PARAM_COUNT && sync.fBeats > 0)
			opts.aSync.push_back(sync);
	}
	return true;
}

bool ExportAudioReactiveVideo(const Patch& patch, const std::string& sAudioPath, const std::string& sPath,
	const AudioVideoOptions& opts, const std::function<bool(int64_t, int64_t)>& progress, std::string* pError)
{
	auto	fail = [pError](const std::string& s) {
		if (pError)
			*pError = s;
		return false;
	};
	if (!(opts.fFrameRate > 0))
		return fail("The frame rate isn't set.");
	NSURL	*url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:sAudioPath.c_str()]];
	double	fLength = AudioSource::Length(url);
	if (fLength < 0)
		return fail("Can't read the audio file.");
	double	fStart = std::clamp(opts.fStart, 0.0, fLength);
	double	fDuration = opts.fDuration < 0 ? fLength - fStart : std::min(opts.fDuration, fLength - fStart);
	int64_t	nTotal = static_cast<int64_t>(std::floor(fDuration * opts.fFrameRate));
	if (nTotal <= 0)
		return fail("The audio is too short.");
	AudioSource	audio;
	if (!audio.Open(url, fStart, fDuration, pError))
		return false;
	VideoWriter	writer;
	if (!writer.Open(sPath, opts.nWidth, opts.nHeight, opts.fFrameRate, opts.codec, pError, kAudioRate))
		return false;
	// a fresh engine, the same every time
	SaveRand	saveRand;
	whorld::srand(1);
	WhorldEngine	eng;
	eng.OnResize(SizeF{static_cast<float>(writer.GetWidth()), static_cast<float>(writer.GetHeight())});
	eng.SetFrameRate(static_cast<uint32_t>(std::max(std::lround(opts.fFrameRate), 1L)));
	eng.SetRingFadeEased(opts.bRingFadeEased);
	eng.SetHueFromPatch(opts.bHueFromPatch);
	auto	setPatch = [&eng](Patch p) {
		p.m_main.bAntialiasing = true;	// as every export draws (CaptureBitmap)
		eng.OnSetPatch(p);
	};
	setPatch(patch);
	double	dt = 1 / opts.fFrameRate;
	NullRenderer	nullRenderer;
	for (int64_t i = static_cast<int64_t>(std::lround(opts.fPreroll * opts.fFrameRate)); i > 0; i--)
		eng.Draw(nullRenderer);
	// modulation
	Modulator	mod;
	mod.SetRows(opts.aRow);
	mod.SetSyncs(opts.aSync);
	mod.SetDepth(opts.fDepth);
	mod.SetFollowTempo(opts.bFollowTempo);
	AudioAnalyzer	analyzer;
	analyzer.Reset(kAudioRate);
	analyzer.SetSettings(opts.analyzer);
	// the analysis reads half a window ahead, so a hit lands on the frame
	// where it's heard rather than a few frames after
	int64_t	nLookahead = static_cast<int64_t>(analyzer.GetWindowSize() / 2);
	int64_t	nAnalyzed = 0;
	bool	bMarkDownbeat = opts.fTempo <= 0 && opts.fDownbeat >= fStart;
	int64_t	iDownbeat = bMarkDownbeat ? static_cast<int64_t>(std::llround((opts.fDownbeat - fStart) * kAudioRate)) : -1;
	// the beat from the first frame: where the tracker finds it, carried back
	FirstBeat	firstBeat;
	if (opts.fTempo <= 0)
		firstBeat = FindFirstBeat(url, fStart, fDuration, opts.analyzer, iDownbeat);
	int		iPatch = opts.iPatch;
	auto	stepPatch = [&](int nStep) {
		int	n = static_cast<int>(opts.aPlaylist.size());
		if (!n)
			return;
		iPatch = iPatch >= 0 && iPatch < n ? (iPatch + nStep + n) % n : (nStep > 0 ? 0 : n - 1);
		Patch	p;
		if (p.Read(opts.aPlaylist[iPatch]))
			setPatch(p);
	};
	// decodes to sample nUntil (or the end), sending it to the sound track
	auto	decodeTo = [&](int64_t nUntil) {
		while (audio.Decoded() < nUntil && !audio.AtEnd()) {
			if (CMSampleBufferRef buf = audio.Next()) {
				writer.AppendAudio(buf);
				CFRelease(buf);
			} else {
				writer.EndAudio();
			}
		}
	};
	// analyzes to sample nUntil (or the end)
	auto	analyzeTo = [&](int64_t nUntil) {
		while (nAnalyzed < nUntil) {
			decodeTo(nAnalyzed + 1);
			std::vector<float>&	pending = audio.Pending();
			if (pending.empty())
				break;	// the end
			int64_t	nStop = nUntil;
			if (iDownbeat >= nAnalyzed && iDownbeat < nStop)
				nStop = iDownbeat;	// stop there to mark it
			size_t	n = static_cast<size_t>(std::min<int64_t>(nStop - nAnalyzed, static_cast<int64_t>(pending.size())));
			analyzer.Process(pending.data(), n);
			pending.erase(pending.begin(), pending.begin() + static_cast<ptrdiff_t>(n));
			nAnalyzed += static_cast<int64_t>(n);
			if (nAnalyzed == iDownbeat) {
				analyzer.MarkDownbeat();
				iDownbeat = -1;
			}
		}
	};
	for (int64_t iFrame = 0; iFrame < nTotal; iFrame++) {
		double	t = static_cast<double>(iFrame) / opts.fFrameRate;	// seconds into the video
		// the encoder interleaves sound and picture, half a second at a
		// time, and waits for sound ahead of the frames: keep it well ahead
		decodeTo(static_cast<int64_t>((t + 2) * kAudioRate));
		analyzeTo(static_cast<int64_t>(std::floor(t * kAudioRate)) + nLookahead);
		ModSources	src = analyzer.GetSources();
		if (opts.fTempo > 0) {	// a set tempo, with a beat on the downbeat
			double	fOne = opts.fDownbeat >= 0 ? opts.fDownbeat : fStart;
			src.bBeat = true;
			src.fTempo = opts.fTempo;
			src.fBeatPos = (fStart + t - fOne) * opts.fTempo / 60;
		} else if (src.bBeat && src.fTempo > 0) {	// the tracker's, as of the frame's moment
			// it's as of the last analysis, which came at the last whole hop
			int64_t	nAtAnalysis = nAnalyzed - nAnalyzed % static_cast<int64_t>(analyzer.GetHopSize());
			src.fBeatPos += (t - static_cast<double>(nAtAnalysis) / kAudioRate) * src.fTempo / 60;
		} else if (firstBeat.bFound && nAnalyzed < firstBeat.nAt) {	// before it locks: its first beat, carried back
			src.bBeat = true;
			src.fTempo = firstBeat.fTempo;
			src.fBeatPos = firstBeat.fBeatPos + (t - static_cast<double>(firstBeat.nAt) / kAudioRate) * firstBeat.fTempo / 60;
		}
		ModOutput	out;
		mod.Step(src, iFrame ? dt : 0, out);
		uint32_t	nActions = out.nActions;
		for (int iAction = 0; iAction < ModActions::ACTIONS; iAction++) {
			if (!(nActions & (1u << iAction)))
				continue;
			switch (iAction) {	// as the app carries them out; snapshots don't apply here
			case ModActions::ACT_RandomPhase: eng.OnRandomPhase(); break;
			case ModActions::ACT_RandomOrigin: eng.OnRandomOrigin(); break;
			case ModActions::ACT_RotateHue: {
				WhorldEngine::VARIANT_PROP	prop = {};
				prop.dblVal = std::fmod(eng.GetPatch().m_main.fHue + 90, 360);
				eng.OnSetMainProp(WhorldBase::MAIN_Hue, prop);
				eng.OnRotateHue(90);
				break;
			}
			case ModActions::ACT_Clear: eng.OnSetEmpty(); break;
			case ModActions::ACT_NextPatch: stepPatch(1); break;
			case ModActions::ACT_PrevPatch: stepPatch(-1); break;
			default: break;
			}
		}
		eng.SetModulation(out);
		CGBitmapRenderer	*pRenderer = writer.BeginFrame();
		if (!pRenderer) {
			writer.Cancel();
			return fail("Can't get a video frame buffer.");
		}
		pRenderer->BeginFrame();
		eng.Draw(*pRenderer);
		pRenderer->EndFrame();
		if (!writer.EndFrame(pError)) {
			writer.Cancel();
			return false;
		}
		if (progress && !progress(iFrame + 1, nTotal)) {
			writer.Cancel();
			return fail("Canceled.");
		}
	}
	decodeTo(INT64_MAX);	// the rest of the sound track
	return writer.Close(pError);
}

} // namespace whorld
