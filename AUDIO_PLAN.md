# Audio reactivity and Ableton Link — plan

Status: **planned 2026-11-13**, not started. A Mac addition (Windows Whorld has nothing like it). The checklist is in `PORT_PLAN.md`, Phase 9; this file is the design.

## Goal

Make Whorld respond to music, for synaesthetic visuals: live from an audio input (analysis), and in time with other apps and devices (Ableton Link). The user chooses what responds to what, without spoiling the patches themselves.

## Decisions (confirmed with the user, 2026-11-13)

- **Order:** audio analysis first, then Ableton Link.
- **Ableton Link is approved** as a dependency. It's dual-licensed GPLv2-or-later or proprietary; Whorld uses it under the GPL (GPLv2-or-later code can be combined into a GPLv3 program). Never use it in Conduit (MIT, with proprietary NDI).
- **Modulation settings live in Settings** (like the key map), with **Export and Import**. They're never written into patches or playlists.
- **Offline audio-file render:** wanted, but not a priority. The analyzer and modulation are designed so it can be added later without rework (see "Offline render").

## Principles

1. **Modulate, don't replace.** A modulation is an offset added to the control's value as the engine renders, beside the patch's own oscillator. It never changes the document. The patch isn't marked Edited, saving writes the patch's own values, the panels show the patch's values, and bypassing modulation restores the patch exactly. (MIDI mappings still set values, as now.)
2. **Nothing on the audio thread touches the engine.** The audio I/O callback only copies samples into a lock-free ring buffer; analysis runs on its own thread; the render thread reads the latest results once per frame without locks. So audio and rendering can't make each other glitch.
3. **Time-based, not frame-based.** Smoothing, pulses and beat phase are computed from real time (seconds, Link's clock), so modulation behaves the same at 60 and 120 Hz and offline.
4. **Portable and testable.** The analyzer and the modulator are plain C++ in `mac/engine`, unit-tested with synthetic signals on macOS and Linux. Only audio capture and Link live in the app.
5. **Zero modulation is bit-identical.** With modulation off (or every offset zero), frames match the current engine exactly; the golden-image tests must still pass.

## Architecture

```
 audio input ──► ring buffer ──► analysis thread ──► Features (latest, lock-free)
 (Core Audio IO thread)          AudioAnalyzer (C++)                │
                                                                    ▼
 Ableton Link ──────────────────────────────────────► LinkState ──► render thread, once per frame:
 (its own network thread)       captured per frame                  Modulator::Step(features, link, dt)
                                                                     → per-control offsets
                                                                     → WhorldEngine::SetModulation(offsets)
                                                                     → triggers (actions) → main thread
```

### Engine (portable C++, `mac/engine`)

- **Modulation offsets.** New render-only arrays, never part of `Patch` or the document:
  - `m_aParamMod[PARAM_COUNT]` (Value column) and `m_aGlobalMod[PARAM_COUNT]` (Global column);
  - master offsets (Speed, Zoom, Damping, Trail, Hue Span, Canvas, Copies, Spread, Tempo, Hue);
  - origin X/Y offset.
- **Where they're added.** `TimerHook` combines value + oscillator in three places: Ring Growth, the interpolated loop and the end-of-frame loop (`WhorldEngine.cpp`, the `m_params.a[iParam] = ... + m_aOsc[iParam].GetVal() * fAmp` lines). Add `+ m_aParamMod[iParam]` at each. Globals are added in `UpdateGlobals`. Master properties: audit every read of `m_master.*` and read through an "effective master" accessor (base + offset) where the value drives drawing. This is the one invasive change; each site gets a comment, and `PORT_PLAN.md` "Port notes" records it.
- **Clamping.** An offset is clamped so base + offset stays within the control's slider range (the `PARAMDEF` min and max, the master limits). The patch's own oscillator isn't clamped, as now.
- **`AudioAnalyzer`** (new, `AudioAnalyzer.h/.cpp`; built in 9.2, details below as built). Input is mono float samples at any rate. Its parameters:
  - Hann window of 2048 samples, hop 512 (about 94 analyses a second at 48 kHz);
  - its own radix-2 real FFT (portable and deterministic; about 20 µs, so roughly 0.2% of one core).

  It produces `Features`; all values are 0–1 unless stated:
  - **Level:** RMS (Hann-weighted, which is steadier), after input gain, in dB relative to a full-scale sine (as AES17 meters read), so a full-scale sine is 0 dB in Level and in its band alike. Mapped over a range (default −60 to 0 dB); optional auto-level (the recent peak, falling 3 dB a second, reads 1).
  - **Bands:** Bass 20–150 Hz, Low Mid 150–600 Hz, High Mid 600 Hz–4 kHz, Treble 4–16 kHz, as energy in dB mapped like Level.
  - **Brightness:** spectral centroid on a log scale.
  - **Onsets:** spectral flux (the rise in log-compressed magnitude, averaged per bin, then over two hops) overall, bass only ("kick") and treble only ("hats"). A hit is flux above an adaptive threshold. Each kind keeps a hit **counter**, so the render thread can't miss a hit that falls between frames. As built, after tuning on synthetic signals:
    - the threshold is the recent median (0.5 s) plus 4 median absolute deviations (×1.5 for the bass detector, which averages only a few bins and so has noisier flux). Robust statistics: steady hiss doesn't hit, and a hit doesn't raise the bar for the next one;
    - a hit must also reach 40% of the last hit's flux, decaying over 0.3 s, so a hit's aftermath isn't a hit while an equal hit soon after is;
    - a refractory time of 80 ms; kicks at least 180 ms apart, because a kick's tail beats against a bassline and swells again 100–180 ms later, heard as roughness, not a second kick;
    - detection comes about 12 ms after a kick starts.
- **`Modulator`** (new, `Modulation.h/.cpp`): the routing table and its per-frame step.
  - **Inputs:** the rows (below), `Features`, `LinkState` and dt in seconds.
  - **Per row:**
    1. read the source;
    2. shape it (curve, polarity);
    3. smooth it (one-pole, attack time going up, release time going down: `y += (x − y)·(1 − e^(−dt/τ))`);
    4. scale by amount × depth;
    5. add to the target's offset (several rows can share a target; their offsets sum).
  - **Triggers** (hits, beats, bars) fire actions; pulses are 1 at the hit and decay with the row's release.
  - **Pure and deterministic:** same inputs, same outputs, so it's testable and works offline.
- **Who steps it (as built, 9.1):** the engine doesn't own the `Modulator`. The host's render loop (`WHEngine.mm`) owns it, installs new rows from Settings, steps it once per frame with the latest sources, passes the `ModOutput` to `WhorldEngine::SetModulation` before `Draw`, and carries out the actions it reports. So the engine only adds offsets, and offline render and tests can drive the same `Modulator` directly.
- **Targets in 9.1:** a parameter's Value or Global column, every master property, Hue, Origin X and Y. The oscillator columns (Amplitude, Frequency, Pulse Width) aren't modulatable yet; Amplitude ("bass drives the wobble") is a good later addition.

### App (Swift / Objective-C++)

- **Audio input** (`WHAudioInput.mm`).
  - `AVAudioEngine`'s input node, with the device chosen by setting the input unit's current device (`kAudioOutputUnitProperty_CurrentDevice`). Channels are mixed to mono, or one channel or a pair is chosen.
  - It follows device changes and disconnection (it falls back to none and says so).
  - **Permission:** `NSMicrophoneUsageDescription` in Info.plist (macOS asks for any input device, not just microphones). Hardened runtime is off, so no entitlement is needed; if it's ever turned on, add `com.apple.security.device.audio-input`.
- **Audio input controls** (as built in 9.3, at the top of the Modulation window, the user's choice on 2026-11-13; Settings was full):
  - input device (None by default, so nothing changes until chosen);
  - channels, gain, auto-level;
  - a live meter of level and the four bands, with hit lights;
  - onset sensitivity;
  - latency offset in ms (see "Latency").
- **Window > Modulation…** (its own window, like Key Map). A table of rows:

  | Column | Meaning |
  |---|---|
  | On | the row's switch |
  | Source | Level, Bass, Low Mid, High Mid, Treble, Brightness, Hit, Kick, Hats; later the Link sources |
  | Live | a small meter of the source after shaping, so you see what it does |
  | Target | any continuous control, as in the Key Map: a parameter's Value or Global, Master, Hue, Origin X/Y; or an **action** for triggers |
  | Amount | −100% to +100% of the target's slider range |
  | Curve | Linear, Soft (square root), Hard (square), Gate (on above a threshold) |
  | Polarity | Up (0 to amount) or Centered (−½ to +½ of amount) |
  | Attack, Release | ms |

  Below the table: a **Depth** slider (0–100%, scales everything), **Bypass** (shown as "Modulation on"), + (a copy of the selected row, if any) / −, Restore Defaults (a small starter set), **Export… / Import…**. As built (9.4): actions are a Target choice (an "Actions" group in the Target menu), not a separate column; the Threshold column applies to the Gate curve and to actions on continuous sources; Attack doesn't apply to hits (a pulse starts at once). Starting rows: Bass → Line Width +30%, Kick → Zoom +8% (release 250 ms), Hit → Random Phase (off).
- **Actions** (trigger targets): Random Phase, Rotate Hue, next / previous playlist patch, next / previous snapshot, Clear. Actions that change the document (Rotate Hue moves the Hue value) mark it Edited, as they do from the menu; that's documented.
- **Menus and remote control:**
  - **Window > Modulation…** opens the window;
  - **Image > Audio Modulation** (on / off) gets **⌘8**, which is free and sits between the image toggles and Random Phase;
  - **OSC:** `/w/mod/on` and `/w/mod/depth` to start with. MIDI targets for them would add new tags to the playlist's mapping section; check first that Windows ignores unknown targets before adding them.
- **Storage:**
  - Routing: UserDefaults `Modulation_v1`, JSON — `{ "version": 1, "depth": 1, "bypass": false, "rows": [ { "id", "on", "source", "target" (mapping tag, as the key map stores it), "prop", "amount", "curve", "polarity", "attackMs", "releaseMs", "options": {…} } ] }`.
  - Audio and Link settings go in their own keys (`Audio_sInputUID`, `Audio_fGain`, `Link_bEnabled`, …), because a device belongs to a machine.
  - **Export / Import** writes and reads the routing JSON (`Whorld Modulation.json`), like the key map; Import checks the version and skips unknown sources and targets with a notice.

### Beat tracker (added in 9.5, 2026-11-13)

Hit detection alone misses kicks in dense mixes. On a 124 BPM house track (checked offline, frame by frame, against the track's beat grid), the Kick detector found every kick in the intro but only about 6 in 16 once the bassline came in. The off-beat bassline (70–117 Hz) shares the kick's band and raises its threshold. Lower thresholds, narrower bands, broadband attacks and a time-domain detector all traded misses for false kicks.

`BeatTracker` (portable C++, fed by the analyzer every hop) keeps a steady beat instead. It produces the **Beat** source (a trigger) and shows the tempo in the meter.

- **Tempo:** autocorrelation of the last 8 s of onsets (bass + overall flux), every 0.33 s, over 70–180 BPM, with the echo at twice the period and a gentle preference for 120 BPM against half and double tempo. A different tempo must be seen 3 times running.
- **Phase:** a comb over the last 8 beats of the same onsets steers a running beat clock (corrections up to 0.15 beat, smoothly). A bigger error must persist 16 beats, and the sub-bass onsets (20–60 Hz: the kick, 3–6× stronger on the beat than off it on that track) must back the new phase 3 to 1, before the clock jumps. So the beat rides through breakdowns where only off-beat sounds are left; with 8 beats or a smaller margin, that track's kickless breakdown (with an off-beat sub bassline) pulled it half a beat over.
- **Beats** come when the clock, shifted by the onsets' own delay (1.5 hops), crosses a whole beat. They continue for 8 beats after the beat is lost or the music falls silent (level below −50 dB), then stop until it locks again (only once the comb has forgotten the old beat).
- **Results:**
  - on the track: 839 of 848 beats within 70 ms of the grid, none off it (the 9 missed are the first 4.3 s, while it locks), about 13 ms early;
  - in `test_audio` on synthetic music: locks in under 5 s with median timing 0 ms, fills a third of kicks missing, prefers the kick to louder off-beat hats at the right tempo, follows 120 → 130 BPM, rides through a 12 s breakdown, stops 9 beats into silence;
  - the analyzer still costs about 40 µs a hop.
- **Bars and phrases** (added at the user's request): **Bar**, **4-Bar**, **8-Bar**, **16-Bar** and **32-Bar** fire on the first beat of every 1, 4, 8, 16 or 32 bars of 4 beats. Beats are numbered from the first after locking (the one, until told otherwise; again after the beat is lost and found). **Mark Downbeat** makes the beat nearest the press the one (the last beat if less than half a beat ago, and the spans fire at once; else the next): a button by the meter's Beat light, Image > Mark Downbeat (⌥⌘8), OSC `/w/mod/downbeat`. The meter shows "bar 5 · beat 2" (bars 1 to 32). With Link, bars will come from Link. A MIDI action for Mark Downbeat: the `MarkDownbeat` mapping target (2026-11-14), on a press only; it's saved in playlists' `[MacMapping]` section, since Windows reads unknown targets as Ring Growth (PORT_PLAN "Mac-only mapping targets").
- **Offset** (per row, −300 to +300 ms, at the user's request): the tracker publishes its beat position (beats since the one, continuous) and tempo in `ModSources`, and the render thread carries the position on to the frame's moment. A beat-based row (Beat, Bar … 32-Bar) fires when *position − offset × tempo / 60* enters a new span, so it can fire early as well as late; a jump landing near a span's start (Mark Downbeat a little late) fires at once. Hit rows can only be delayed (a queue per row); negative offsets do nothing for them. Link will supply the same position, so the column works unchanged.
- **Later, with Link:** a Beat Phase source (exact from Link, or from the tracker).

### Latency

Sound reaches the picture after the input buffer (≈5–10 ms), the analysis hop (≈10 ms), at most one frame (8–17 ms) and the display (≈1 frame): about 20–40 ms. That's fine for most music. Visuals can't run ahead of live audio. For Link (which knows the future beat times), a **latency offset** setting aims the beat phase at the moment the frame appears on screen, plus or minus the user's offset, so beats can line up exactly with what you hear.

## Ableton Link (after analysis)

- **Dependency:**
  - Ableton's `link` repository as a git submodule at `mac/third_party/link`, pinned to a release tag (check the newest at the time). Its `asio-standalone` submodule comes too, so CI checks out with `submodules: recursive`.
  - Header-only: include `link/include` and `modules/asio-standalone/asio/include`, define `LINK_PLATFORM_MACOSX=1`, and compile it in one file (`WHLink.mm`) to keep asio's heavy headers out of everything else.
- **License notices:**
  - Link's license ships in the DMG, as Syphon's does (`make_dmg.sh`);
  - Help and About credit Ableton Link (GPLv2+);
  - the README notes the GPL basis.
- **Network:** Link uses UDP multicast on the local network. Info.plist already has `NSLocalNetworkUsageDescription` (for OSC); widen its wording to mention Link. Turning Link on triggers the macOS Local Network prompt.
- **Settings > Link:**
  - enable (off by default), with the number of peers and the session tempo shown;
  - beats per bar (Link's "quantum", default 4);
  - Start/Stop sync;
  - the latency offset (shared with Audio).
- **Clock:**
  - Each frame, the render thread captures Link's app session state (allowed off the audio thread) and computes the beat at the frame's expected display time (the display link's target timestamp, converted to Link's clock), plus the offset.
  - `LinkState` holds tempo, beat (a continuous count), the phase in the bar, playing, and beat and bar counters (for triggers).
- **Sources:**
  - **Beat LFO:** a row option picks a division (1/16 … 8 bars) and a shape (saw, ramp down, triangle, sine, square), phase-locked to the session.
  - **Beat pulse** and **Bar pulse:** triggers, also usable as decaying pulses.
  - **Tempo:** the BPM mapped over a range.
- **Tempo follow:** while Link is on, the engine's Tempo (it drives Origin Random's timing) can follow the session's, render-only, so the patch's own Tempo isn't changed.
- **Beat-locked oscillators** (the second half of the Link work):
  - In the Modulation window, a "Sync" list: a parameter and a division. While Link is on, that parameter's oscillator clock is set from the beat each frame, instead of running free. The patch's waveform, amplitude and pulse width are kept; only its timing follows the beat.
  - New engine call: `SetOscillatorSync(iParam, beatsPerCycle)`, applied where `TimerHook` advances the clocks.
  - Stored with the modulation settings, not in the patch.
- **Testing:** with Ableton Live, or LinkHut (Link's own example app, built from the submodule), check phase alignment with logs and by eye. Check tempo changes, start/stop, peers joining and leaving, and Wi-Fi off.

### Ableton Link as built (9.6)

- Link 4.1.1 (the latest stable release), `mac/third_party/link`, compiled into `WHLink.mm` alone (with `LINK_PLATFORM_MACOSX`).
- **Driving the beat:** while enabled with peers, the render thread's sources get Link's beat position (at the moment of the frame, quantum 4) and tempo in place of the beat tracker's, so every beat-based row and its Offset work unchanged. With no peers, the tracker takes over again. The per-row Offset replaced the planned global latency offset.
- **Phrases:** Link aligns apps within a bar but not their bar counts, so phrases start at Mark Downbeat's beat, or, with Start/Stop sync, at the beat where the session started playing.
- **Not built:** the planned Beat Phase source (the Beat LFO's Ramp Up is the same, as a row).
- **Beat LFO** (built 2026-11-14): a source, `BeatLFO`, whose value is a wave at the beat's position, shifted by the row's Offset (early or late): `ModRow` has its length (`fLfoBeats`, the Oscillators on the Beat divisions, 1/16 note to 32 bars), shape (`nLfoShape`: Sine, Triangle, Ramp Up, Ramp Down, Square, as `Oscillator::GetVal` scaled to 0–1) and phase (`fLfoPhase`). Not smoothed (Attack and Release would put it behind the beat). Without a beat it carries on at the last tempo, as the beat-locked oscillators do; never locked, 0. In the window, a menu beside the Source picker (the Table has its 10 columns); in the settings file, `lfoBeats`, `lfoShape` and `lfoPhaseDeg`, read by `whorld-render --mod` too. Tests: `BeatLfoShapesAreWhorldsWaveforms`, `BeatLfoFollowsTheBeatAndCarriesOn`, `ModulationFileReadsTheBeatLfo`; checked offline (a square LFO firing Clear at 120 BPM clears at 2 s and 4 s, at 1, 3 and 5 s with phase 180°) and in the window.

### Beat-locked oscillators as built (9.7)

- A second table in the Modulation window, **Oscillators on the Beat** (a tab beside Routing), not in Settings: each row is a parameter, a cycle (1/16 note, 1/8, 1 beat, 2 beats, 1 bar, 2, 4, 8, 16, 32 bars), a phase (degrees: where the one falls in the cycle) and an offset (±300 ms, as the routing rows'). Stored as `syncs` in the modulation file (export/import).
- **Engine:** the modulator turns each row into a frequency and a place in the cycle as the frame ends (`ModOutput::aOscFreq`, `aOscCycle`); `WhorldEngine::LockOscillators` sets that oscillator's frequency and clock just before `TimerHook` advances it, in place of the planned `SetOscillatorSync`. The waveform, amplitude and pulse width are the patch's.
- **Any beat:** it follows the beat tracker as well as Link. Without a beat, a locked oscillator carries on at the last tempo; turned off (or Modulation off), it returns to the patch's frequency from its current phase.

## Capturing another app's audio (after Link)

Core Audio process taps (`AudioHardwareCreateProcessTap` with an aggregate device) can capture an app's output (Ableton's, a browser's) or the whole system mix, with no loopback driver.

- Sources disagree on the minimum: macOS 14.2 or 14.4. Whorld supports 14.0, so this goes behind `#available` and is hidden on older systems.
- There's a permission prompt, and the exact Info.plist key needs checking (see insidegui's AudioCap sample).
- There are reports of taps delivering silence when permission is missing; detect that and say so.
- In Settings > Audio it would be another choice of input: "Audio from app…".

### As built (9.8)

- macOS 14.2 (`AudioHardwareCreateProcessTap`), hidden before. Input uids `tap:all` and `tap:app:<bundle ID>`, in the Input menu's "Sound from apps" section.
- The tap (unmuted, private) goes into a private aggregate device with only the tap in it, and the existing input unit reads that device, so the analysis path is unchanged. The aggregate is left out of the device list.
- Apps: Core Audio's process objects, grouped under their regular app (a helper whose bundle ID starts with an app's counts as that app). The process list is watched; a tapped app that restarts is tapped again.
- Permission: `NSAudioCaptureUsageDescription`; macOS asks when the tap starts. Refused, the tap delivers zeros, and there's no public way to ask, so after three seconds of digital silence the status line says where to allow it.
- Ad-hoc signing: each new build is a new app to macOS, so it asks again.

## Offline render (later; designed for now)

**File > Export Audio-Reactive Video…** (and `whorld-render --audio`): pick an audio file, a size, fps and codec. Whorld renders the current patch frame by frame at a fixed dt, feeds the analyzer the audio at each frame's time, and writes the video **with the audio track** (AVAssetWriter, as Export Video does).

- It's frame-exact and repeatable, and it can even look a little ahead, so hits land on the frame.
- Link sources are simulated from a BPM and first-downbeat time you enter, so beat-locked modulation works offline too.

As built (9.9): File > Export Audio-Reactive Video… and `whorld-render --audio` (`renderer/AudioVideoExport.mm`).

- A fresh engine runs the document's patch (antialiased, as exports draw; zoomed to frame it as the view does). Optionally, it runs for a pre-roll first, so the picture is full when the video starts; by default (the user's choice) the video starts at the patch's first frame.
- The beat, found ahead (`BeatMap`): a first pass runs the tracker over the whole range (analysis only: about 4 s for a 6-minute track). The beat at a moment is the tracker's estimate 16 s later, once settled, carried back at the rate its positions advanced; where the tracker's own estimate at that moment has the same phase, its (locally more exact) position is used, renumbered. Live, the tracker locks a few seconds in and can lock on an ambient intro first (a synthetic pad locked at 117 BPM, then retuned to the music's 124 after about 9 s); the settled beat avoids both.
- The music's first beat: the first kick on that grid with kicks on at least 3 of the 4 beats after it (any hit, if there are no kicks). Beat-driven rows start there (known 0.35 s before, so rows set to fire early still fire on it), and it's the one unless a downbeat is marked. With a set tempo, beats start at the marked downbeat. Kicks are counted about 21 ms after their onset; with that, they land within 10 ms of the grid. The random sequence is seeded, so a render is the same every time.
- Each frame: the audio is decoded and analyzed up to the frame's moment plus half an analysis window (the lookahead that puts hits on their frame); the beat position is moved back to the frame's moment; the Modulator steps 1/fps; actions run on the export's engine (Next/Previous Patch from the playlist; snapshot actions are skipped).
- The beat comes from the tracker, or from a set tempo; a downbeat time marks the one (Mark Downbeat at that moment, with the tracker).
- The decoded audio is the movie's sound track (AAC, 48 kHz stereo). The writer interleaves sound and picture and waits for sound ahead of each frame, so decoding stays 2 s ahead, and the track is marked finished when the audio ends.

What this needed from the live design, which is why it was planned early:

- the analyzer takes samples from any source;
- the modulator's step is pure and takes dt;
- `LinkState` can be made up;
- the engine accepts offsets from any caller.

All of this is already in the design above.

## Performance

- **Costs:**
  - analysis: about 0.2% of one core, on its own thread;
  - the modulator: microseconds a frame;
  - Link: one capture a frame;
  - none of these add any drawing.
- **The real risk is what the music drives.** Offsets on Ring Spacing (down), Rings, Line Width, Copies or Canvas (up) make more or heavier geometry, like moving those sliders. They're bounded by the clamp and the Rings limit, but a loud passage can still push a heavy patch into missed frames. The plan:
  - measure with `WHORLD_STATS=1` (missed frames, draw and GPU ms) on heavy sample patches, with worst-case rows at full depth, at 60 and 120 Hz;
  - compare against the same patches without audio;
  - document what to avoid (Help), or add a per-row limit, if the numbers say so.
- **Real-time safety:** the audio callback doesn't allocate, lock or call Objective-C or Swift; the analysis thread doesn't touch the engine; the render thread reads the features with a sequence lock (retrying if a write was in progress).

## Testing

- **ctest (portable):**
  - FFT against a naive DFT;
  - band levels from sine tones;
  - hits from synthetic clicks (within one hop of the click), no hits on steady tones;
  - the smoothing math at different dt;
  - modulator: sums, clamping, depth, bypass, polarity, curves, triggers firing once per counter step;
  - engine: with zero offsets, frames identical to before (the golden images);
  - offsets never change `OnGetPatch`;
  - beat-locked phase math.
- **App:**
  - real input (an interface, the built-in mic, BlackHole), device unplugged while running;
  - permission denied (a clear message, no crash);
  - export / import round trip;
  - missed-frame measurements as above.
- **Link:** with Live or LinkHut, as above.

## Open questions (decide while building)

- A small set of starter rows for Restore Defaults: for example Bass → Ring Growth, Hit → Random Phase, Treble → Line Width. Tune these by ear with the user.
- Whether the panels should show modulation, for example a faint second marker on a slider at the modulated value.
- MIDI targets for Depth and Bypass (checked: Windows reads unknown targets as Ring Growth, so they'd go in `[MacMapping]`, as Mark Downbeat does).
