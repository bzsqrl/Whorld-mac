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
- **`AudioAnalyzer`** (new, `Audio.h/.cpp`). Input is mono float samples at any rate. Its parameters:
  - Hann window of 2048 samples, hop 512 (about 94 analyses a second at 48 kHz);
  - its own radix-2 real FFT (portable and deterministic; about 20 µs, so roughly 0.2% of one core).

  It produces `Features`; all values are 0–1 unless stated:
  - **Level:** RMS in dBFS mapped over a range (default −60 to 0 dB), after input gain; optional slow auto-level.
  - **Bands:** Bass 20–150 Hz, Low Mid 150–600 Hz, High Mid 600 Hz–4 kHz, Treble 4–16 kHz, as energy in dB mapped like Level.
  - **Brightness:** spectral centroid on a log scale.
  - **Onsets:** spectral flux (the positive change in magnitude) overall, bass only ("kick") and treble only ("hats"). A hit is flux above an adaptive threshold (recent median × sensitivity), with a refractory time (default 80 ms). Each kind keeps a hit **counter**, so the render thread can't miss a hit that falls between frames.
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
- **Render command** `SET_MODULATION` (the `pData` pattern, like a patch) installs a new routing table, built by the app from Settings. Features and Link state are handed to the engine each frame by the render loop (`WHEngine.mm`), not through the command queue.

### App (Swift / Objective-C++)

- **Audio input** (`WHAudioInput.mm`).
  - `AVAudioEngine`'s input node, with the device chosen by setting the input unit's current device (`kAudioOutputUnitProperty_CurrentDevice`). Channels are mixed to mono, or one channel or a pair is chosen.
  - It follows device changes and disconnection (it falls back to none and says so).
  - **Permission:** `NSMicrophoneUsageDescription` in Info.plist (macOS asks for any input device, not just microphones). Hardened runtime is off, so no entitlement is needed; if it's ever turned on, add `com.apple.security.device.audio-input`.
- **Settings > Audio** (a new pane):
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

  Below the table: a **Depth** slider (0–100%, scales everything), **Bypass**, + / − / Duplicate, Restore Defaults (a small starter set), **Export… / Import…**.
- **Actions** (trigger targets): Random Phase, Rotate Hue, next / previous playlist patch, next / previous snapshot, Clear. Actions that change the document (Rotate Hue moves the Hue value) mark it Edited, as they do from the menu; that's documented.
- **Menus and remote control:**
  - **Window > Modulation…** opens the window;
  - **Image > Audio Modulation** (on / off) gets **⌘8**, which is free and sits between the image toggles and Random Phase;
  - **OSC:** `/w/mod/on` and `/w/mod/depth` to start with. MIDI targets for them would add new tags to the playlist's mapping section; check first that Windows ignores unknown targets before adding them.
- **Storage:**
  - Routing: UserDefaults `Modulation_v1`, JSON — `{ "version": 1, "depth": 1, "bypass": false, "rows": [ { "id", "on", "source", "target" (mapping tag, as the key map stores it), "prop", "amount", "curve", "polarity", "attackMs", "releaseMs", "options": {…} } ] }`.
  - Audio and Link settings go in their own keys (`Audio_sInputUID`, `Audio_fGain`, `Link_bEnabled`, …), because a device belongs to a machine.
  - **Export / Import** writes and reads the routing JSON (`Whorld Modulation.json`), like the key map; Import checks the version and skips unknown sources and targets with a notice.

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

## Capturing another app's audio (after Link)

Core Audio process taps (`AudioHardwareCreateProcessTap` with an aggregate device) can capture an app's output (Ableton's, a browser's) or the whole system mix, with no loopback driver.

- Sources disagree on the minimum: macOS 14.2 or 14.4. Whorld supports 14.0, so this goes behind `#available` and is hidden on older systems.
- There's a permission prompt, and the exact Info.plist key needs checking (see insidegui's AudioCap sample).
- There are reports of taps delivering silence when permission is missing; detect that and say so.
- In Settings > Audio it would be another choice of input: "Audio from app…".

## Offline render (later; designed for now)

**File > Export Audio-Reactive Video…** (and `whorld-render --audio`): pick an audio file, a size, fps and codec. Whorld renders the current patch frame by frame at a fixed dt, feeds the analyzer the audio at each frame's time, and writes the video **with the audio track** (AVAssetWriter, as Export Video does).

- It's frame-exact and repeatable, and it can even look a little ahead, so hits land on the frame.
- Link sources are simulated from a BPM and first-downbeat time you enter, so beat-locked modulation works offline too.

What this needs from the live design, which is why it's planned now:

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
- MIDI targets for Depth and Bypass (checking Windows' handling of unknown mapping targets first).
