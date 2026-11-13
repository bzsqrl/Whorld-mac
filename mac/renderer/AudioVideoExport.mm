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

// The beat, found ahead. Live, the beat tracker can only follow: it takes a
// few seconds to lock, and it may lock on an ambient intro before the music
// starts, then retune. Offline the whole file is there, so a first pass
// runs the tracker over all of it, and the beat at any moment is taken from
// the tracker's estimate a few seconds later, once it has settled, carried
// back. On that grid, the music's first beat is the first kick on it with
// kicks on most of the beats after it; beat-driven behavior starts there.
class BeatMap {
public:
	// a hit is counted this long after its onset: about half the analysis
	// window (measured: kicks then land within 2 ms of the grid)
	static constexpr double	kHitDelay = 0.0213;
	static constexpr double	kSettle = 16;	// seconds ahead the tracker's estimate is taken from

	bool Build(NSURL *url, double fStart, double fDuration, const AudioAnalyzer::Settings& settings)
	{
		AudioSource	audio;
		if (!audio.Open(url, fStart, fDuration, nullptr))
			return false;
		AudioAnalyzer	analyzer;
		analyzer.Reset(kAudioRate);
		analyzer.SetSettings(settings);
		m_nHop = static_cast<int64_t>(analyzer.GetHopSize());
		uint32_t	nKicks = 0, nHits = 0;
		for (;;) {
			std::vector<float>&	pending = audio.Pending();
			while (static_cast<int64_t>(pending.size()) < m_nHop && !audio.AtEnd()) {
				if (CMSampleBufferRef buf = audio.Next())
					CFRelease(buf);
			}
			if (static_cast<int64_t>(pending.size()) < m_nHop)
				break;
			analyzer.Process(pending.data(), static_cast<size_t>(m_nHop));	// one analysis
			pending.erase(pending.begin(), pending.begin() + static_cast<ptrdiff_t>(m_nHop));
			const ModSources&	src = analyzer.GetSources();
			double	t = TimeOf(m_aState.size());
			m_aState.push_back(State{src.bBeat && src.fTempo > 0, src.fBeatPos, src.fTempo});
			if (src.aCount[ModSources::SRC_Kick] != nKicks)
				m_aKick.push_back(t - kHitDelay);
			if (src.aCount[ModSources::SRC_Hit] != nHits)
				m_aHit.push_back(t - kHitDelay);
			nKicks = src.aCount[ModSources::SRC_Kick];
			nHits = src.aCount[ModSources::SRC_Hit];
		}
		FindFirstBeat();
		return true;
	}

	// The beat at t (seconds into the range): its position and tempo; false
	// where the tracker had no beat. The settled estimate (kSettle later,
	// carried back at the rate its positions advance, since a small error in
	// the tempo it reports would add up over that time) decides the phase
	// and numbering; where the tracker's own estimate at t agrees on the
	// phase, its position is used (it's the more exact one nearby).
	bool At(double t, double& fPos, double& fTempo) const
	{
		if (m_aState.empty())
			return false;
		size_t	iSettled = IndexAt(t + kSettle);
		const State&	st = m_aState[iSettled];
		if (!st.bBeat)
			return false;
		double	fRate = st.fTempo;	// beats a minute, as the positions advance
		double	tSettled = TimeOf(iSettled);
		size_t	iBack = IndexAt(tSettled - 8);
		const State&	back = m_aState[iBack];
		if (back.bBeat && iBack < iSettled) {
			double	fSlope = (st.fPos - back.fPos) / (tSettled - TimeOf(iBack)) * 60;
			if (std::fabs(fSlope - st.fTempo) < 1.5)
				fRate = fSlope;
		}
		double	fSettled = st.fPos - (tSettled - t) * fRate / 60;
		const State&	here = m_aState[IndexAt(t)];
		if (here.bBeat) {
			double	fHere = here.fPos + (t - TimeOf(IndexAt(t))) * here.fTempo / 60;
			double	c = fSettled - fHere;
			if (std::fabs(c - std::round(c)) < 0.15) {	// the same phase: renumbered only
				fPos = fHere + std::round(c);
				fTempo = here.fTempo;
				return true;
			}
		}
		fPos = fSettled;
		fTempo = fRate;
		return true;
	}

	bool	HasFirstBeat() const { return m_bFirst; }
	double	FirstBeatTime() const { return m_fFirstTime; }	// seconds into the range
	double	FirstBeatPos() const { return m_fFirstPos; }	// a whole number

private:
	struct State {
		bool	bBeat;
		double	fPos;
		double	fTempo;
	};
	int64_t	m_nHop = 512;
	std::vector<State>	m_aState;	// after each analysis
	std::vector<double>	m_aKick, m_aHit;	// onset times, seconds
	bool	m_bFirst = false;
	double	m_fFirstTime = 0;
	double	m_fFirstPos = 0;

	// the time of analysis i, seconds into the range
	double TimeOf(size_t i) const
	{
		return static_cast<double>(i + 1) * static_cast<double>(m_nHop) / kAudioRate;
	}

	// the last analysis at or before t (the first, if t is before it)
	size_t IndexAt(double t) const
	{
		double	f = std::floor(t * kAudioRate / static_cast<double>(m_nHop)) - 1;
		return static_cast<size_t>(std::clamp(f, 0.0, static_cast<double>(m_aState.size() - 1)));
	}

	// the first onset on the settled grid with onsets on at least 3 of the 4
	// beats after it: kicks if the music has them, else any hit
	void FindFirstBeat()
	{
		for (const std::vector<double>* pa : {&m_aKick, &m_aHit}) {
			for (double tk : *pa) {
				double	fPos, fTempo;
				if (!At(tk, fPos, fTempo))
					continue;
				double	fPeriod = 60 / fTempo;
				double	fTol = std::min(0.07, fPeriod * 0.15);	// a hit this close to a beat is on it
				double	q = std::round(fPos);
				if (std::fabs(fPos - q) * fPeriod > fTol)
					continue;
				auto	onBeat = [&](double t) {
					auto	it = std::lower_bound(pa->begin(), pa->end(), t - fTol);
					return it != pa->end() && *it <= t + fTol;
				};
				double	tBeat = tk - (fPos - q) * fPeriod;
				int	nOn = 0;
				for (int k = 1; k <= 4; k++)
					nOn += onBeat(tBeat + k * fPeriod);
				if (nOn >= 3) {
					m_bFirst = true;
					m_fFirstTime = std::max(tBeat, 0.0);
					m_fFirstPos = q;
					return;
				}
			}
		}
	}
};

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
	bool	bMarkDownbeat = opts.fDownbeat >= fStart;
	// the beat: the tracker's, settled and carried back, from the music's
	// first beat (the one, unless a downbeat is marked); or a set tempo
	BeatMap	beats;
	bool	bBeatMap = opts.fTempo <= 0 && beats.Build(url, fStart, fDuration, opts.analyzer);
	double	fShift = 0;	// subtracted from the tracker's positions, so the one is 0
	if (bBeatMap) {
		double	fPos, fTempo;
		if (bMarkDownbeat && beats.At(opts.fDownbeat - fStart, fPos, fTempo))
			fShift = std::round(fPos);	// the beat nearest the downbeat
		else if (beats.HasFirstBeat())
			fShift = beats.FirstBeatPos();
	}
	// the beat is known a little before it starts, so rows firing early
	// (a negative offset, up to 300 ms) fire on the first beat too
	const double	kLead = 0.35;
	double	fBeatsFrom = 0;	// seconds into the video: no beat before
	if (opts.fTempo > 0)
		fBeatsFrom = bMarkDownbeat ? opts.fDownbeat - fStart - kLead : 0;	// a set tempo: from its downbeat
	else if (beats.HasFirstBeat())
		fBeatsFrom = beats.FirstBeatTime() - kLead;
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
			size_t	n = static_cast<size_t>(std::min<int64_t>(nUntil - nAnalyzed, static_cast<int64_t>(pending.size())));
			analyzer.Process(pending.data(), n);
			pending.erase(pending.begin(), pending.begin() + static_cast<ptrdiff_t>(n));
			nAnalyzed += static_cast<int64_t>(n);
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
		} else {	// the tracker's, settled
			double	fPos = 0, fTempo = 0;
			src.bBeat = bBeatMap && beats.At(t, fPos, fTempo);
			src.fBeatPos = fPos - fShift;
			src.fTempo = fTempo;
		}
		if (t < fBeatsFrom)	// before the music's first beat (a silent or ambient intro): no beat yet
			src.bBeat = false;
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
