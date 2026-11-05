# Whorld macOS Port Plan

Status: **Phase 1 in progress** (Phase 0 done) · Upstream baseline: `victimofleisure/Whorld` commit `5b5de69` (2026-10-26, V2 2.0.20)

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
- [x] Add GitHub Actions CI on a macOS runner: build the engine, run tests, build the app. (`.github/workflows/mac.yml`: engine on macOS 15 and Linux; the app build step is skipped until the Xcode project exists. First green run: 42100966306.)
- [x] Collect test data into `mac/testdata`: the demo `.whp` patches from the Windows release (the repo doesn't include them), a few `.whs` snapshots, and PNGs exported from Windows Whorld of those same snapshots. If no Windows machine or VM is available, ask the user — the golden-image tests depend on these. (Exported by the user from Windows Whorld 2.0.20: 86 patches, 2 playlists, 8 snapshots with golden PNGs, 1 movie. See `mac/testdata/README.md`.)

**Done when:** an empty engine library and test target build locally and in CI.

### Phase 1 — Portable engine
- [x] Port the definition headers and core types (`WhorldDef.h` X-macros, `PARAM_VALS`, `RING`, `DRAW_STATE`, `GLOB_RING`) with engine-native point/color/size structs. (`include/whorld/{WhorldDef,WhorldBase,RenderCmd,Types,Round,Random}.h`)
- [x] Port `Oscillator`, `hls`, `DPoint`, `RandList`, `FormatIO`.
- [x] Port `Patch` read/write; test round-trip against the sample `.whp` files. (All 86 samples parse. In the 14 version-4 files, 616 lines are reproduced byte for byte; 19 hand-edited lines, with empty fields or typos, are only required to parse.)
- [ ] Define `IRenderer` (begin/end frame, clear, set antialiasing, build path, fill path, stroke path with width, fill rect, offscreen bitmap create/draw for mirroring).
- [ ] Port `CWhorldDraw` as `WhorldEngine`: `TimerHook` → `Tick()`, `AddRing`, `DrawRing`, `DrawOutline`, origin/zoom/hue/globals updates, quad mirroring — drawing only through `IRenderer`. Separate it from the thread and device classes it inherits from on Windows.
- [x] Port `Snapshot` (including `SnapshotV1`) with explicit binary decoding. (All 8 sample snapshots decode and re-encode byte for byte. The V1 reader is tested only with synthetic files, because no real V1 snapshot is available.)
- [ ] Unit tests: oscillator waveforms, patch round-trip, snapshot parsing, a recording `IRenderer` that checks the draw calls for a fixed seed.

**Done when:** the engine builds with no Windows or Apple headers and tests pass.

### Phase 2 — Core Graphics renderer and headless renderer tool
- [ ] Implement `CoreGraphicsRenderer` with `CGContext` and `CGPath` (y-flip and backing scale handled here).
- [ ] Build a command-line tool: `whorld-render <patch.whp> --frames N --size WxH --out frame.png`, and `whorld-render <snapshot.whs> --out frame.png`.
- [ ] Golden-image tests: render each `.whs` and compare to the Windows PNG within a tolerance (antialiasing differs slightly between Direct2D and Core Graphics; use a perceptual or per-pixel threshold, not exact match).

**Done when:** snapshots render visibly identical to Windows output and the golden tests pass.

### Phase 3 — Minimum viable app
- [ ] Xcode project, SwiftUI app shell, Objective-C++ bridge.
- [ ] Render view driven by the display link, with the engine on a render thread.
- [ ] Open a `.whp` patch (menu and drag-and-drop), play/pause, full screen, the main keyboard shortcuts from the Windows version.
- [ ] Measure frame rate at high ring counts on Apple Silicon. Record results here. If below 60 fps, raise the Metal backend decision with the user.

**Done when:** a user can open a demo patch and watch it full screen at a steady frame rate. **Good moment to show upstream.**

### Phase 4 — Controls
- [ ] Parameters panel: value, waveform, amplitude, frequency, pulse width, global for each parameter (spec: `ParamsBar`, `ParamsRowDlg`).
- [ ] Master and globals panels (`MasterBar`, `GlobalsBar`), main properties (`PropertiesGrid`).
- [ ] Save patch; native undo/redo via `UndoManager`.
- [ ] Preferences window (spec: `OptionsDef.h`, `OptionsDlg`), stored in `UserDefaults`.

### Phase 5 — MIDI
- [ ] CoreMIDI input with device selection (replaces `MidiWrap`, `MidiDevices`, `MidiManager`).
- [ ] Port the mapping model (`Mapping`, `MappingDef.h`, `MidiCtrlrDef.h`) and build the mapping UI (spec: `MappingBar`).
- [ ] MIDI learn; mapping files compatible with Windows.

### Phase 6 — Playlists, snapshots, movies, export
- [ ] Playlists (`.whl`) and patch crossfading (spec: `Playlist`, `PlaylistBar`).
- [ ] Save/load snapshots.
- [ ] Movie record and playback (`.whm`); replace overlapped I/O with a background writer.
- [ ] Image and image-sequence export via ImageIO; consider video export via AVFoundation (new feature — ask first).

### Phase 7 — Release
- [ ] App icon, About box with GPLv3 notice and credit to Chris Korda, help docs (adapt `docs/Help`).
- [ ] Universal binary (Apple Silicon + Intel), code signing, notarization, DMG packaging.
- [ ] README section for the Mac build.

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

## Port notes

Decisions made while porting that preserve Windows behavior in non-obvious ways.

- **Rounding.** On x64, `Round()` and `Trunc()` (`Round.h`) use SSE `cvtsd2si` / `cvttsd2si`. Halves round to even (`Round(2.5) == 2`), and NaN or out-of-range input returns `INT_MIN`. `whorld::Round` and `whorld::Trunc` reproduce both, so don't replace them with `std::round` or `lround`.
- **Random numbers.** MSVC's `rand()` is a per-thread LCG (`RAND_MAX` 32767) seeded with 1 on each thread, and Whorld never calls `srand`, so Windows Whorld produces the same random sequence on every run. `whorld::rand()` (`Random.h`) reproduces that generator exactly, so random waveforms and random origins match Windows and are the same on macOS and Linux. Ported code uses `whorld::rand()` and `whorld::kRandMax` instead of `rand()` and `RAND_MAX`.
- **Number formatting.** Windows Whorld is built with toolset v110, whose C runtime (msvcr110) prints at least three exponent digits (`7.22068e-005`). C99 runtimes print two. `src/MsvcFormat.h` pads exponents so `.whp` output matches Windows byte for byte; reading accepts both forms. The sample patches confirm the three-digit form.
- **Line endings.** `CStdioFile` text mode writes CRLF, so `Patch::Write` writes CRLF; `Patch::Read` accepts CRLF or LF.
- **Errors.** The engine reports errors with `bool` results and an optional `std::string*` message, in place of MFC exceptions and message boxes. Use this everywhere in the engine.
- **Binary layouts.** `.whs` structs are decoded at the MSVC x64 offsets listed in `Snapshot.cpp`: `DRAW_STATE` 40 bytes, `GLOB_RING` 104, `RING` 192, none with padding. V1 snapshots use the 32-bit MSVC offsets listed in `SnapshotV1.cpp`. Each struct is copied into a zeroed image of its full size before decoding, which reproduces the original's behavior of reading `min(size, sizeof)` bytes into a zeroed struct for files with older, smaller structs.
- **Legacy snapshot size.** `CSnapshotV1` gets the frame size from the options (`GetLegacySnapshotSize`); the port takes it as a parameter, defaulting to 800×600 like the Windows option.
- **Display names.** These come from the `Whorld.rc` string table and are compiled in (`src/WhorldStrings.h`), replacing `LoadString` and `InitWhorldBase`.
- **Anonymous structs in unions.** `PARAM_VALS` and `MASTER_PROPS` keep the original's union of named members and an array. This is a compiler extension that MSVC, clang and gcc all support. The warning is silenced only around those declarations, and `static_assert`s check that the members overlay the array exactly.
