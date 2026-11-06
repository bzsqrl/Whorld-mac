# Whorld macOS Port Plan

Status: **Phase 7 done (unnotarized ad-hoc build)** · Upstream baseline: `victimofleisure/Whorld` commit `5b5de69` (2026-10-26, V2 2.0.20)

## Goal

A native macOS app that plays Whorld V2 patches and looks the same as the Windows version, with full-screen VJ use, parameter and oscillator controls, MIDI, playlists and export. Patch, playlist and snapshot files stay compatible with Windows Whorld, so people can share them across platforms.

## What we're starting from

Whorld V2 is about 20,000 lines of C++ in `trunk/Whorld/` (82 `.cpp`, 111 `.h`), built with Visual Studio (`Whorld.sln`, toolset v110) against MFC and Direct2D.

| Layer | Approx. size | Windows dependency | Mac plan |
|---|---|---|---|
| UI: frame, docking panes, dialogs, grids, playlist and mapping bars | ~80% of code; 120+ files touch MFC | MFC | **Rebuild** in SwiftUI/AppKit |
| Rendering engine: ring generation, oscillators, color, geometry | ~3,000 lines | Direct2D for drawing; `CString`/`CList` in places | **Port** to portable C++17 |
| Render thread and device setup | ~800 lines | DXGI swap chain, `AfxBeginThread`, window messages | **Replace** with display-link-driven rendering |
| MIDI input | 4 files | WinMM `midiIn*` | **Replace** with CoreMIDI; port the mapping logic |
| Settings | 14 files | Registry via MFC profile calls | **Replace** with `UserDefaults` |
| Image export | 2 files | WIC | **Replace** with ImageIO |

Direct2D usage in `WhorldDraw.cpp` is narrow: path geometries, solid-color brushes, `FillGeometry`, `DrawGeometry`, `FillRectangle`, and bitmaps (`CreateBitmap`/`DrawBitmap`, used for quad mirroring and capture), with antialiasing on or off. Each has a direct Core Graphics equivalent.

### Initial file classification

Confirm each file when reading it; some UI files (especially `MainFrm.cpp`, 1,577 lines, and `WhorldThread.cpp`) contain app logic that belongs in the engine.

- **Engine (port):** `WhorldBase`, `WhorldDraw`, `WhorldThread` (non-UI parts), `Oscillator`, `Patch`, `Snapshot`, `SnapshotV1`, `SnapMovie`, `Playlist` (data parts), `Mapping`, `Options` (data parts), `hls`, `DPoint`, `RandList`, `FormatIO`, `IniFile`, and the X-macro definition headers `WhorldDef.h`, `MappingDef.h`, `MidiCtrlrDef.h`, `OptionsDef.h`.
- **Windows platform (replace):** `D2DDevCtx`, `D2DHelper.h`, `RenderThread`, `RenderWnd`, `MidiWrap`, `MidiDevices`, `MidiManager`, `Persist`, `PathStr`, `StdioFileEx`, `SubFileFind`, `FolderDialog`, `VersionInfo`, `Win32Console`, `WinAppCK`.
- **UI (rebuild, use as a spec):** `Whorld`, `MainFrm`, `WhorldDoc`, `WhorldView`, `AuxiliaryDoc`, all `*Bar`, `*Dlg`, `*Ctrl`, `Row*`, `Popup*`, `Num*`, `GridCtrl`, `PropertiesGrid`, `ListCtrlExSel`, `MyDockablePane`, `FocusEdit`, `Undo*`.
- **Tests and tools (reference):** `UndoTest`, `PatchUndoTest`, `MappingUndoTest`, `Benchmark`, `Statistics`.

### File formats

- `.whp` patch — tab-separated text: a header line, then one line per parameter (`tag, value, waveform, amplitude, frequency, pulse width, global`), then master and main properties. Easy to keep compatible.
- `.whl` playlist — INI-style text listing patches.
- `.whs` snapshot — binary: a draw-state header plus a variable-length array of ring structs. Has a V1 legacy variant.
- `.whm` movie — binary sequence of snapshots with a frame index; written with Windows overlapped (async) I/O.

The binary formats are raw MSVC struct dumps, so they must be decoded field by field (see `CLAUDE.md`).

## Target architecture

```
SwiftUI / AppKit app (mac/app)
   │  controls, windows, full screen, file dialogs, preferences, menus
   ▼
Objective-C++ bridge (WhorldEngineBridge.mm)
   │
   ├──► Engine (mac/engine, portable C++17)
   │       Patch + oscillators → per-frame Tick(dt) → ring list
   │       Render(IRenderer&) issues abstract draw calls
   │       File I/O for .whp/.whl/.whs/.whm, MIDI mapping model
   │
   ├──► CoreGraphicsRenderer (mac/renderer) implements IRenderer
   │
   └──► CoreMIDI input → engine mapping model
```

Frames are driven by the display (`NSView.displayLink` / `CADisplayLink`, macOS 14+) instead of the Windows render thread and swap chain. Engine updates run on a dedicated render thread; the UI sends commands through a lock-free or mutex-protected queue, mirroring the original `PushCommand` design in `RenderThread.h`.

The `IRenderer` interface keeps the backend swappable. Core Graphics comes first because it maps one-to-one onto the Direct2D calls. If it can't hold 60 fps at the maximum ring count, a Metal backend can be added later without touching the engine.

## Phases

Each phase ends with something that runs. Check items off as they're done.

### Phase 0 — Setup
- [x] Fork upstream on GitHub; clone; create branch `mac-port`. (Fork is `bzsqrl/Whorld`; `master` tracks upstream `5b5de69`.)
- [x] Create `mac/engine`, `mac/renderer`, `mac/app`, `mac/testdata`; add `CMakeLists.txt` for the engine and tests. (Tests use a small built-in harness, `mac/engine/tests/TestHarness.h`, so there's no third-party dependency.)
- [x] Add GitHub Actions CI on a macOS runner: build the engine, run tests, build the app. (`.github/workflows/mac.yml`: engine on macOS (`macos-latest`) and Linux; the app build step is skipped until the Xcode project exists. First green run: 42100966306.)
- [x] Collect test data into `mac/testdata`: the demo `.whp` patches from the Windows release (the repo doesn't include them), a few `.whs` snapshots, and PNGs exported from Windows Whorld of those same snapshots. If no Windows machine or VM is available, ask the user — the golden-image tests depend on these. (Exported by the user from Windows Whorld 2.0.20: 86 patches, 2 playlists, 8 snapshots with golden PNGs, 1 movie. See `mac/testdata/README.md`.)

**Done when:** an empty engine library and test target build locally and in CI.

### Phase 1 — Portable engine
- [x] Port the definition headers and core types (`WhorldDef.h` X-macros, `PARAM_VALS`, `RING`, `DRAW_STATE`, `GLOB_RING`) with engine-native point/color/size structs. (`include/whorld/{WhorldDef,WhorldBase,RenderCmd,Types,Round,Random}.h`)
- [x] Port `Oscillator`, `hls`, `DPoint`, `RandList`, `FormatIO`.
- [x] Port `Patch` read/write; test round-trip against the sample `.whp` files. (All 86 samples parse. In the 14 version-4 files, 616 lines are reproduced byte for byte; 19 hand-edited lines, with empty fields or typos, are only required to parse.)
- [x] Define `IRenderer` (begin/end frame, clear, set antialiasing, build path, fill path, stroke path with width, fill rect, offscreen bitmap create/draw for mirroring). (`include/whorld/IRenderer.h`. The host brackets frames itself, as the Windows render thread does. Mirroring is `BeginQuadMirror` / `EndQuadMirror`, since it's a pixel operation the backend does. The contract records the Direct2D defaults a backend must match: even-odd fill and miter joins with limit 10.)
- [x] Port `CWhorldDraw` as `WhorldEngine`: `TimerHook` → `Tick()`, `AddRing`, `DrawRing`, `DrawOutline`, origin/zoom/hue/globals updates, quad mirroring — drawing only through `IRenderer`. Separate it from the thread and device classes it inherits from on Windows. (`WhorldEngine::Draw` is `OnDraw` and calls `TimerHook` unless paused, as the original does. The `CWhorldThread` command handlers and `OnRenderCommand` are ported too. Movie commands wait for Phase 6. Bitmap capture is split: the engine draws (`DrawCapture`), and the host owns the offscreen target and the image file.)
- [x] Port `Snapshot` (including `SnapshotV1`) with explicit binary decoding. (All 8 sample snapshots decode and re-encode byte for byte. The V1 reader is tested only with synthetic files, because no real V1 snapshot is available.)
- [x] Unit tests: oscillator waveforms, patch round-trip, snapshot parsing, a recording `IRenderer` that checks the draw calls for a fixed seed. (8 test executables. They also pass under AddressSanitizer and UndefinedBehaviorSanitizer. The draw-call tests check structure and hand-computed geometry within tolerances rather than a hash, because `sin` and `cos` differ in the last bit between macOS and glibc.)

**Done when:** the engine builds with no Windows or Apple headers and tests pass.

### Phase 2 — Core Graphics renderer and headless renderer tool
- [x] Implement `CoreGraphicsRenderer` with `CGContext` and `CGPath` (y-flip and backing scale handled here). (`mac/renderer/CGRenderer.{h,mm}`, `CGBitmapRenderer`: draws into its own BGRA premultiplied bitmap, like the Direct2D swap chain, and mirrors by copying pixels. 12 unit tests.)
- [x] Build a command-line tool: `whorld-render <patch.whp> --frames N --size WxH --out frame.png`, and `whorld-render <snapshot.whs> --out frame.png`. (`mac/tools/whorld-render.mm`. Also supports `--scale`, `--fit`, `--use-view-size`, `--no-letterbox`, and `--compare a.png b.png [--diff d.png] [--region X,Y,W,H]`.)
- [x] Golden-image tests: render each `.whs` and compare to the Windows PNG within a tolerance (antialiasing differs slightly between Direct2D and Core Graphics; use a perceptual or per-pixel threshold, not exact match). (`test_golden`: every image must have mean difference ≤ 1.5 and at most 1% of pixels with an RGB difference over 32. Worst today: bloom at 0.70% and mean 0.72; the rest are under 0.4%. Mirrored snapshots compare only the upper-left quadrant; see Upstream notes.)

**Done when:** snapshots render visibly identical to Windows output and the golden tests pass.

### Phase 3 — Minimum viable app
- [x] Xcode project, SwiftUI app shell, Objective-C++ bridge. (`mac/app`: `WHEngine.{h,mm}` bridge, SwiftUI menus and window.)
- [x] Render view driven by the display link, with the engine on a render thread. (`WHRenderView`: the display link requests frames; the render thread drains the command queue, draws into an IOSurface pool, and the layer shows the surface without copying. The engine's frame rate is the display's refresh rate, as on Windows.)
- [x] Open a `.whp` patch (menu and drag-and-drop), play/pause, full screen, the main keyboard shortcuts from the Windows version. (Shortcut table in `mac/app/README.md`. Checked in the running app: opening patches, Mirror, Fill, check marks, Pause, Step, full screen. Drag-and-drop is untested because it can't be scripted.)
- [x] Measure frame rate at high ring counts on Apple Silicon. Record results here. If below 60 fps, raise the Metal backend decision with the user. (Results below. Decision, 2026-11-05: the user chose to stay on Core Graphics for now and revisit Metal before release, after testing on a base-model Mac.)

**Done when:** a user can open a demo patch and watch it full screen at a steady frame rate. **Good moment to show upstream.**

#### Video export (Mac only)

Movie > Export Video… encodes the playing `.whm` movie to a QuickTime `.mov` (`mac/renderer/VideoWriter.{h,mm}`, AVFoundation). It renders offline, frame by frame, like image-sequence export, at the movie's own frame rate, with the same frame size, scaling and range options. Formats are H.264, HEVC, ProRes 422 and ProRes 4444. The renderer draws straight into the encoder's pixel buffers.
- **Color:** tagged with Rec. 709 primaries and matrix and the **sRGB transfer function**, because Whorld draws sRGB values. Tagging the Rec. 709 transfer curve made decoded gray 128 come back as 117. With the sRGB tag, flat colors decode within about 2 levels.
- **Fidelity** (`test_video`, 512×384, frame 130 of the sample movie, compared with a direct render): in flat areas, every format is within 0.2–1.4 levels. At edges, H.264 and HEVC (4:2:0) average about 5.4 and ProRes 422 (4:2:2) about 4.8. These formats store color at reduced resolution, which blurs Whorld's saturated hard edges. **ProRes 4444** keeps full color resolution: mean difference 1.6, with no pixel off by more than 32. The dialog recommends it for fine lines. Lossy quality depends on the machine's encoder: on the GitHub CI runner, H.264 averaged 8.0 and ProRes 4444 0.01. So the test checks flat-area color tightly, while lossy formats get only a loose overall bound.
- **Speed:** the full sample movie (1118 frames, 1056×1234) exports to H.264 in about 6 s on an M1 Max.
- **Sizes:** odd dimensions are rounded down to even, because H.264 and HEVC need even sizes. A canceled export deletes the partial file. `whorld-render <movie.whm> --video out.mov [--codec h264|hevc|prores|prores4444]` does the same from the command line.

#### Performance results (2026-11-05, M1 Max, 120 Hz ProMotion display, Release build)

The renderer went through three steps, all measured with `bloom_cvx` (100 filled, curved, thickly outlined rings) in the app:

| Renderer | bloom, window (about 1890×1380 px) |
|---|---|
| Core Graphics, direct | 26 fps (37 ms draw) |
| + deferred: stroke outlines built in parallel, rasterized in 32 parallel bands | 55 fps (13 ms) |
| + IOSurface delivery, no copy per frame | 95 fps (10.5 ms) |

Full screen (3024×1964 px): `saturn_cvx` holds 120 fps (3.9 ms draw); `bloom_cvx` runs at about 75 fps (13 ms).

All 86 sample patches timed with `whorld-render --deferred` at 3024×1964, 400 frames each; the tool runs about 1.8× faster than the app, which also delivers frames to the display:
- mean 3.15 ms per frame; 71 of 86 patches under 4.6 ms (about 120 fps in the app);
- the slowest are `boomer_cvx` 27.6 ms, `typhoon_cvx` 9.3 ms, then `bloom`, `gallop`, `fish eye`, `fireworks` at about 7.5 ms;
- drawing at 1× instead of 2× (View > Full Resolution off) saves little (`boomer` 22.5 → 16.6 ms), because the cost is stroke geometry and rasterizing, not pixels.

So on this machine nearly every sample holds 60 fps full screen and most hold 120. The exceptions are `boomer_cvx` (about 20 fps; its even curve is modulated with amplitude 20, giving huge self-overlapping rings) and `typhoon_cvx` (borderline at 60). Two things tried and rejected: flattening curves into lines (faster only at tolerances that fail the golden test) and plain render-thread QoS (no change).

Two notes on accuracy:
- When drawing falls behind the display, the engine ticks less often than its configured rate, so animation slows down, exactly as on Windows when a frame misses vsync.
- At 120 Hz each tick is 1/120 s, so ring growth per second is twice that of a 60 Hz display, again as on Windows.


### Phase 4 — Controls
- [x] Parameters panel: value, waveform, amplitude, frequency, pulse width, global for each parameter (spec: `ParamsBar`, `ParamsRowDlg`). (`Panels.swift` `ParamsPanel`. The global column is in the Globals panel, as on Windows.)
- [x] Master and globals panels (`MasterBar`, `GlobalsBar`), main properties (`PropertiesGrid`). (Separate windows, so they can sit on a laptop screen while the render window is full screen on a projector. The slider and edit math is the engine's `Controls`.)
- [x] Save patch; native undo/redo via `UndoManager`. (Save writes the live origin, as `CWhorldDoc::OnSaveDocument` does. Undo coalesces consecutive edits of the same thing and uses the Windows undo titles (`CWhorldDoc::GetUndoTitle`). The app asks to save changes on New, Open and Quit. Mouse-wheel zoom, and Shift+wheel damping (`CWhorldDoc::OnMouseWheel`), are undoable too.)
- [x] Preferences window (spec: `OptionsDef.h`, `OptionsDlg`), stored in `UserDefaults`. (Keys use the Windows names, for example `Export_nImageWidth`. Wheel sensitivity and letterbox take effect now; the export options are stored for Phase 6. The MIDI device comes in Phase 5. The recent-files count is left to macOS.)

### Phase 5 — MIDI
- [x] CoreMIDI input with device selection (replaces `MidiWrap`, `MidiDevices`, `MidiManager`). (`WHEngine.mm`: a CoreMIDI client and input port using the MIDI 1.0 protocol. Channel voice packets are repacked as WinMM short messages for the ported `MidiManager::OnMidiEvent`. The device is chosen in Preferences and stored by name (`Midi_sInputDevice`), and it reconnects when the device comes back. Tested end to end with a virtual CoreMIDI source.)
- [x] Port the mapping model (`Mapping`, `MappingDef.h`, `MidiCtrlrDef.h`) and build the mapping UI (spec: `MappingBar`). (Engine: `Mapping`, `MidiManager`, `IniFile`, `Playlist`, with tests in `test_midi`. App: the MIDI Mapping window (`Mapping.swift`) with insert, delete and undo; cut, copy, paste, move and sort aren't ported yet. As on Windows, MIDI changes go straight to the render thread, and the document is updated with undo disabled.)
- [x] MIDI learn; mapping files compatible with Windows. (Learn follows `CMappingBar::OnMidiEvent`: it needs the Mapping window in front and a selection, strips the data from the message, and coalesces repeats into one undo step. Mappings live in the playlist (`.whl`), as on Windows; both sample playlists round-trip byte for byte, and a playlist saved after a learn differs only in the learned lines.)

### Phase 6 — Playlists, snapshots, movies, export
- [x] Playlists (`.whl`) and patch crossfading (spec: `Playlist`, `PlaylistBar`). (Playlist window: name and folder columns, playing indicator, insert, delete, move up and down, play with Return or double-click, and undo. Missing patches (Windows paths) resolve by file name next to the playlist, or by searching a chosen folder (`CMissingFilesDlg`). **Crossfading isn't in V2**: the only trace in `PlaylistBar.cpp` is a 2005 revision note from V1. Porting it would mean inventing a feature, so it's left out.)
- [x] Save/load snapshots. (Take Snapshot, Load Snapshot (multiple files), First/Previous/Next/Last, Info and Export All, with snapshot mode as in `CWhorldApp::SetSnapshotMode`: pause, back up the document, restore it on unpause. Checked in the app: Export All of `yin yang_cvx.whs` matches the Windows golden image (0.02% of pixels over 32).)
- [x] Movie record and playback (`.whm`); replace overlapped I/O with a background writer. (`SnapMovie`: the sample movie rewrites byte for byte, and the tests pass under ThreadSanitizer. In the app: Record and Play (⌘M and ⇧⌘M) and a movie bar with play/pause, seek slider and time. The Windows sample movie plays.)
- [x] Image and image-sequence export via ImageIO; consider video export via AVFoundation (new feature — ask first). (Image export (⌘E) and movie export to `img000000.png`… are done, with the Windows options and unique timestamped names (`MakeUniqueExportPath`). Movie export moves the folder's existing PNG files to the Trash after confirming; Windows deletes them. **Video export**, approved by the user on 2026-11-05, is a Mac-only feature, described below.)

### Phase 7 — Release
- [x] App icon, About box with GPLv3 notice and credit to Chris Korda, help docs (adapt `docs/Help`).
  - Icon: `mac/packaging/make_icon.swift` redraws `res/Whorld.ico` (three nested pentagons) as vectors on the macOS icon grid and builds `mac/app/Whorld/AppIcon.icns`.
  - About: the standard About panel with credits (Chris Korda, upstream baseline version, GPLv3 notice, source links).
  - Help: `mac/app/Help/index.html` covers what differs from Windows, the shortcuts and the first-launch note. `docs/Help` (the V1 manual) is bundled unchanged as `Help/V1` by the Copy Help build phase, with `frames.html` as its frameset. Help > Whorld Help and Whorld Manual open them in the default browser.
- [x] Universal binary (Apple Silicon + Intel), code signing, DMG packaging. Notarization skipped: it needs an Apple Developer ID, which we don't have yet.
  - `sh mac/packaging/make_dmg.sh` builds Release for arm64 and x86_64, signs ad hoc, checks the signature and `lipo -archs`, and writes `build/dist/Whorld-<version>.dmg` (app, Applications link, license, read-me with the Gatekeeper steps). CI builds it and uploads it as an artifact.
  - Verified: the DMG mounts with the expected contents; `codesign` reports an ad-hoc universal bundle; `spctl` rejects it, as expected without notarization. The packaged app runs natively (about 106 fps windowed) and as x86_64 under Rosetta (about 90 fps). All 14 tests also pass when built as x86_64 and run under Rosetta.
  - To do with a Developer ID: sign with it, enable the hardened runtime, notarize with `notarytool`, and staple the DMG.
- [x] README section for the Mac build.
- [ ] Before a public release: measure performance on a base-model Mac (decision from Phase 3).

## Decisions (confirmed with the user 2026-11-05)

| Decision | Recommendation | Why |
|---|---|---|
| Rendering backend | Core Graphics first, Metal only if needed | Closest match to Direct2D; fastest path to correct visuals |
| UI toolkit | SwiftUI, dropping to AppKit where needed (render view, full screen) | Modern, quick to build panels |
| Engine ↔ Swift bridge | Objective-C++ wrapper | Mature and simple; Swift's C++ interop is an option later |
| Minimum macOS | 14 (Sonoma) | `NSView.displayLink`, current SwiftUI |
| Scope of v1 | Phases 0–4, then MIDI | A usable visualizer before VJ features |

## Risks

- **Visual fidelity.** Subtle differences in antialiasing, line joins or color math. Mitigated by golden-image tests from real Windows snapshots.
- **Performance.** Core Graphics is CPU-based; high ring counts with large line widths may drop frames. Mitigated by measuring in Phase 3 and keeping `IRenderer` swappable.
- **Logic hidden in UI files.** MFC apps often put behavior in frame and view classes. Read `MainFrm.cpp`, `WhorldView.cpp` and `WhorldThread.cpp` closely in Phase 1 and move any non-UI behavior into the engine.
- **Upstream keeps moving.** V2 is under active development (quad mirroring was added Oct 2026). Pin to the baseline commit above; periodically diff `trunk/Whorld` against upstream and port relevant engine changes.

## Upstream notes

Record here anything worth telling the upstream author: suspected bugs found while porting, small changes that would make the shared code easier to keep portable, and the overall port once Phase 3 works.

- **`FormatIO.cpp` `CFormatIO::StrToVal`:** the `FIO_BYTE` case (also used for `bool`) has no `break`, so it falls through to `default` and returns `FALSE` even though the value was stored. Harmless today because `CPatch::Read` ignores the return value. The port keeps this behavior.
- **`Oscillator.cpp` `COscillator::SetPhaseFromVal`:** for `TRIANGLE`, `r = (fVal + 1) / 2 + 10.5` lands on the phase where `GetVal()` returns `-fVal`, not `fVal`. The other waveforms invert correctly. Nothing calls `SetPhaseFromVal`, so there's no visible effect. The port keeps this behavior.
- **`Oscillator.h` `CTriggerOscillator()`:** the default constructor leaves `m_bIsHigh` uninitialized. The port initializes it to `false`. This is latent only: the one user, `CWhorldDraw::m_oscOrigin`, uses the two-argument constructor.
- **`SnapshotV1.cpp` `CSnapshotV1::CvtRing`:** `ptShiftDelta` is copied from the V1 ring's `Shift` rather than its `ShiftDelta`. This might be intentional. The port keeps it.
- **Patch loading ignores waveforms and pulse widths (visible).** `CWhorldThread::OnSetPatch` copies the patch into the render thread but never calls `COscillator::SetWaveform` or `SetPulseWidth`; only `OnSetWaveform` and `OnSetPulseWidth` (from editing a parameter) do. Opening a patch sends only `RC_SET_PATCH` (`CWhorldView::OnUpdate`, `HINT_NONE`), so each oscillator keeps its previous waveform (`TRIANGLE` at startup) and pulse width (0.5). A loaded patch with sine or square modulation therefore animates with the previous waveform until that row is edited. The port keeps this behavior, and `test_engine` documents it. This is worth reporting upstream; the fix would be to set each oscillator's waveform and pulse width in `OnSetPatch`. The user decided (2026-11-05) to keep the bug in the port for now. It's hard to see on their patches.
- **`WhorldThread.cpp` `OnRenderCommand` `RC_MOVIE_SEEK`:** passes `cmd.m_prop.intVal`, so frame indices above 2^31 are truncated, even though `MovieSeek` takes a `LONGLONG`. Harmless in practice. Noted for the Phase 6 port.
- **Exporting while mirroring uses a stale mirror bitmap (visible in exports).** `CWhorldDraw::InitMirroring` creates `m_pMirrorBitmap` lazily at the live window's quadrant size, and only `OnResize` releases it. `CaptureBitmap` recomputes `m_szMirQuad` for the export bitmap but reuses the window-sized bitmap. `FinishMirroring` then copies only the export's quadrant into the bitmap's corner, and `DrawBitmap` with no source rectangle squeezes the whole bitmap, stale content included, into each mirrored quadrant. Confirmed with `pinwheel_cvx-mirrored`: a 528×617 stale bitmap (half the 1056×1234 view) reproduces the Windows output with 99.7% of pixels matching. Live mirroring in the window is unaffected. The port mirrors exports correctly, by the user's decision (2026-11-05); the golden test compares only the upper-left quadrant. The fix upstream would be to release `m_pMirrorBitmap` when the capture target is set, or to pass a source rectangle to `DrawBitmap`.

- **`MAIN_InvertColor` is unused.** The Invert Color main property is defined, saved and loaded, but nothing in the Windows code reads it. The Mac port shows it in the Properties panel and saves it, but, as on Windows, it has no effect.

## Port notes

- **Frame pacing (2026-11-05).** Frames used to be handed to the layer whenever the render thread finished them. At a 6–8 ms draw on a 120 Hz display, most landed right at the compositor's deadline (median 7.6 ms after the vsync), so frames were shown late or repeated at random, and the animation hitched. Frames are now pipelined one refresh deep, like a vsync'd DXGI swap chain: each display-link fire first shows the frame finished since the last one (`WHEngine presentFrame`), then requests the next. This adds one refresh of latency. The stats line counts refreshes with no new frame as "missed"; those now happen only when a frame takes longer than a refresh to draw (a heavy patch in a large Retina window).

Decisions made while porting that preserve Windows behavior in non-obvious ways.

- **Rounding.** On x64, `Round()` and `Trunc()` (`Round.h`) use SSE `cvtsd2si` / `cvttsd2si`. Halves round to even (`Round(2.5) == 2`), and NaN or out-of-range input returns `INT_MIN`. `whorld::Round` and `whorld::Trunc` reproduce both, so don't replace them with `std::round` or `lround`.
- **Random numbers.** MSVC's `rand()` is a per-thread LCG (`RAND_MAX` 32767) seeded with 1 on each thread, and Whorld never calls `srand`, so Windows Whorld produces the same random sequence on every run. `whorld::rand()` (`Random.h`) reproduces that generator exactly, so random waveforms and random origins match Windows and are the same on macOS and Linux. Ported code uses `whorld::rand()` and `whorld::kRandMax` instead of `rand()` and `RAND_MAX`.
- **Number formatting.** Windows Whorld is built with toolset v110, whose C runtime (msvcr110) prints at least three exponent digits (`7.22068e-005`). C99 runtimes print two. `src/MsvcFormat.h` pads exponents so `.whp` output matches Windows byte for byte; reading accepts both forms. The sample patches confirm the three-digit form.
- **Line endings.** `CStdioFile` text mode writes CRLF, so `Patch::Write` writes CRLF; `Patch::Read` accepts CRLF or LF.
- **Errors.** The engine reports errors with `bool` results and an optional `std::string*` message, in place of MFC exceptions and message boxes. Use this everywhere in the engine.
- **Binary layouts.** `.whs` structs are decoded at the MSVC x64 offsets listed in `Snapshot.cpp`: `DRAW_STATE` 40 bytes, `GLOB_RING` 104, `RING` 192, none with padding. V1 snapshots use the 32-bit MSVC offsets listed in `SnapshotV1.cpp`. Each struct is copied into a zeroed image of its full size before decoding, which reproduces the original's behavior of reading `min(size, sizeof)` bytes into a zeroed struct for files with older, smaller structs.
- **Legacy snapshot size.** `CSnapshotV1` gets the frame size from the options (`GetLegacySnapshotSize`); the port takes it as a parameter, defaulting to 800×600 like the Windows option.
- **Argument evaluation order.** `DPoint ptRand(RandDouble(), RandDouble())` (random origin) evaluates its arguments in an unspecified order. MSVC typically goes right to left and clang left to right. The port draws y first, then x, matching MSVC. Confirmed on Windows (2026-11-05): after launch, the first random origin jumps almost straight up, which matches the y-first prediction (x ≈ 0.56, y ≈ 0.001). x-first would jump to the left edge.
- **Overlapping copy.** `CWhorldDraw::OnDraw` copies the previous ring's points with `memcpy` into a range that overlaps when the current ring has fewer points. MSVC's `memcpy` handles overlap like `memmove`, so the port uses `memmove`.
- **Frame timing.** As on Windows, the engine advances one tick per displayed frame, and the oscillators use the display rate as their clock (`SetFrameRate`). Ring growth is per tick, so a 120 Hz display grows rings twice as fast as 60 Hz, exactly as a 120 Hz monitor does on Windows. Phase 3 should pass the real display rate.
- **Cursor and options.** `OM_DRAG` reads the cursor through `SetCursorPosition` (normalized) instead of `GetCursorPos`. The snapshot letterbox option is `SetSnapshotLetterbox`.
- **Renderer: Direct2D stroke semantics.** Found against the golden images:
  - A negative stroke width is drawn as its absolute value. Oscillators can push line width below zero; `fish eye_cvx` showed it.
  - Direct2D's default join is `D2D1_LINE_JOIN_MITER` with limit 10. Past the limit Direct2D **clips** the miter, while Core Graphics bevels it, so `CGBitmapRenderer::StrokePath` adds the clipped-miter polygons itself. Both measure the limit as 1 / sin(θ/2), so the Core Graphics miter limit is also 10. Curved rings with negative shear turn back on themselves at vertices, and their long miters are a visible part of patches like `bloom_cvx`.
  - A zero-width stroke is skipped. Core Graphics would draw a hairline; Direct2D's behavior at exactly zero is unverified.
- **Renderer: color.** The bitmap and every fill color use the same sRGB color space, so values are written without conversion, as Direct2D does. PNG export writes the premultiplied bytes labeled as straight alpha, as `WriteCapturedBitmap` does through WIC; this only differs for translucent backgrounds.
- **Export scale.** Windows captures into a bitmap at 96 DPI, so exports are 1 DIP = 1 pixel whatever the display scaling. The 125% scaling the goldens were exported at doesn't affect them. `RenderSnapshotExport` reproduces Export All: snapshot mode, then `DrawCapture`.
- **Deferred, banded rendering.** The app uses `CGBitmapRenderer::SetDeferred(true)`: calls are recorded, stroke outlines are built in parallel (`CGPathCreateCopyByStrokingPath`), and the frame is replayed into 32 horizontal bands in parallel. Strokes thinner than 2 device pixels are stroked directly in each band, because Core Graphics renders thin lines differently from their prebuilt outlines, and its direct rendering is closer to Direct2D (fish eye: 0.95% → 0.37% of pixels off). The golden test checks both modes.
- **Performance (early measurement, Phase 2).** Release build, M1 Max, CPU only, 3024×1964 pixels (full-screen Retina): `saturn_cvx` about 6 ms per frame; `bloom_cvx` (100 filled curved rings with thick outlines) about 41 ms per frame, roughly 24 fps. Phase 3 should measure in the app and raise the Metal decision if heavy patches can't hold 60 fps. Rendering at 1× and scaling up is a cheaper fallback to evaluate first.
- **Pane control math.** The slider mappings, log curves, display scaling and edit ranges from `ParamsRowDlg`, `GlobalsRowDlg`, `MasterRowDlg`, `EditSliderCtrl` and `NumEdit` are ported to the engine as `Controls`, with tests. The master slider table stores scales as `float`, as the original does, so typed values carry the same rounding.
- **Playlists ahead of Phase 6.** Mappings are stored in playlists, so the playlist file format (`Playlist`, `IniFile`) is ported in Phase 5. The Playlist menu opens and saves `.whl` files with their mappings and patch paths. The MIDI Patch target plays playlist entry *n*. A Windows path that doesn't exist on the Mac is tried by file name next to the playlist; proper missing-file handling (`CMissingFilesDlg`) comes in Phase 6.
- **One undo history.** Windows keeps separate undo stacks for the patch and the mapping pane. The Mac app uses one `UndoManager`, so mapping edits and patch edits share Edit > Undo, and opening a playlist clears the whole history.
- **Display names.** These come from the `Whorld.rc` string table and are compiled in (`src/WhorldStrings.h`), replacing `LoadString` and `InitWhorldBase`.
- **Anonymous structs in unions.** `PARAM_VALS` and `MASTER_PROPS` keep the original's union of named members and an array. This is a compiler extension that MSVC, clang and gcc all support. The warning is silenced only around those declarations, and `static_assert`s check that the members overlay the array exactly.
