# Whorld for macOS

This repository, [bzsqrl/Whorld-mac](https://github.com/bzsqrl/Whorld-mac) (branch `main`), is derived from [victimofleisure/Whorld](https://github.com/victimofleisure/Whorld) (Chris Korda's sacred-geometry visualizer, V2) and keeps its full history; it's a standalone repository, not a GitHub fork. The goal is a native macOS port. Remotes: `origin` is Whorld-mac, `upstream` is victimofleisure/Whorld, and the local `master` branch is the upstream baseline the port started from. The full plan, with phases and status, is in `PORT_PLAN.md`. Read it before starting work, and update its status checkboxes when a task is finished. The design for audio reactivity and Ableton Link (Phase 9) is in `AUDIO_PLAN.md`.

License: GPLv3. Every new file gets a GPLv3 header and keeps the original copyright notice where code is derived from Whorld. Under the copyright line (`Copyright 2026 Jeff Matson.`) goes the credit line `Written with Claude (Anthropic).`; it's a credit, not a copyright notice.

## Repository layout

- `trunk/Whorld/` — the original Windows source (C++, MFC, Direct2D). **Reference only.** Do not edit it, except for small changes that could be sent upstream, and only when the user asks.
- `mac/engine/` — portable C++17 engine extracted from the Windows source. No Windows headers, no MFC, no Apple headers.
- `mac/engine/tests/` — engine unit tests and golden-image tests.
- `mac/renderer/` — the drawing backends (Objective-C++, `.mm`), implementing the engine's renderer interface: Core Graphics (`CGRenderer`, CPU) and Metal (`MetalRenderer`, GPU, coverage mode on Apple GPUs; its portable geometry is in `mac/renderer/gpu/`). The app's live view uses Metal by default; exports use Metal wherever `MetalRenderer::CanDrawCoverage`, else Core Graphics. Core Graphics' antialiased rasterizer isn't repeatable on several threads at once, so don't parallelize antialiased Core Graphics drawing (PORT_PLAN Phase 8).
- `mac/tools/` — command-line tools: `whorld-render` renders a patch or snapshot to PNG and compares images.
- `mac/app/` — the macOS app (Swift / SwiftUI, Xcode project), talking to the engine through a thin Objective-C++ bridge.
- `mac/third_party/Syphon-Framework` — git submodule (BSD), built from source and embedded by the app's Build Syphon and Embed Syphon phases. Don't edit it; update it by moving the submodule to a tested commit.
- `mac/third_party/link` — git submodule: Ableton Link (GPLv2 or later), with its own `asio-standalone` submodule, header-only, compiled into `WHLink.mm` alone. Pinned to a release tag. Clone with `git submodule update --init --recursive`.
- `mac/testdata/` — sample `.whp` patches, `.whs` snapshots and reference PNGs exported from Windows Whorld.

## Build and test

These commands are created in Phase 0 of the plan. Keep this section accurate as the build changes.

- Engine + tests: `cmake -S mac -B build && cmake --build build && ctest --test-dir build --output-on-failure` (`build/` defaults to Debug)
- Timing: use an optimized tree, `cmake -S mac -B build-release -DCMAKE_BUILD_TYPE=Release && cmake --build build-release`; Debug CPU code runs about 10× slower. Metal timings: `build-release/renderer/tests/spike_metal --samples 0 --no-golden --patches name1,name2` (full screen; `--aa 1` forces antialiasing; see PORT_PLAN Phase 8)
- Metal tests: `test_metal` checks the Windows golden images and every sample patch against Core Graphics (every third patch in a Debug build); it skips where there's no Apple GPU; `WHORLD_NO_METAL=1` (tests or app) acts as if there were none, to try the Intel fallback
- Render a frame: `build/tools/whorld-render <file.whp|file.whs> --out frame.png` (run with no arguments for options)
- Compare images: `build/tools/whorld-render --compare a.png b.png --diff diff.png`
- Movie to video: `build/tools/whorld-render movie.whm --video out.mov --codec prores4444` (or `--frame N --out f.png` for one frame)
- Audio-reactive video: `build/tools/whorld-render patch.whp --audio music.mp3 --video out.mov --mod modulation.json` (the Modulation window's export; run with no arguments for the other options)
- App: `xcodebuild -project mac/app/Whorld.xcodeproj -scheme Whorld build` (needs the submodule: `git submodule update --init`) (run the built app with `WHORLD_STATS=1` to print frame-rate stats)
- Release DMG: `sh mac/packaging/make_dmg.sh` (universal, ad-hoc signed, not notarized; writes `build/dist/Whorld-<version>.dmg`)
- Making a release: in `mac/app/Whorld/Info.plist` set `WhorldReleaseVersion` to the new tag without the `v` (e.g. `0.1.0-beta.3`; the update checker, `Updates.swift`, compares it with the release tags) and raise `CFBundleVersion`, also `CURRENT_PROJECT_VERSION` in the Xcode project and `mac/app/generate_project.py`; then test, build the DMG, tag `v<WhorldReleaseVersion>`, and publish the GitHub release (`--prerelease` for betas) with the DMG and its SHA-256
- App icon: `xcrun swiftc mac/packaging/make_icon.swift -o /tmp/make_icon && /tmp/make_icon mac/app/Whorld/AppIcon.icns`

On macOS, CMake also builds the Core Graphics and Metal renderers, the tools and the golden-image tests; on Linux it builds only the engine, the GPU renderer's portable geometry (`mac/renderer/gpu`) and their tests.

Run the engine tests after every engine change. Build the app after every change to the bridge, renderer or app.

## Rules for porting

- **Preserve behavior.** The point is that a patch looks the same on the Mac as on Windows. Port the math line by line; don't "improve" or simplify formulas, timing, or the order of operations while porting. If something looks like a bug in the original, keep the original behavior and note it in `PORT_PLAN.md` under "Upstream notes".
- **Cite the source.** When a function is ported, add a comment naming the original, e.g. `// ported from WhorldDraw.cpp CWhorldDraw::AddRing`.
- **Keep the engine portable.** `mac/engine` must compile with plain clang on macOS and Linux. Replace MFC and Win32 types as follows:
  - `CString`, `TCHAR`, `_T()`, `LPCTSTR` → `std::string` (UTF-8)
  - `CArray` / `CList` / `POSITION` → `std::vector` / `std::list` / iterators
  - `D2D_POINT_2F`, `D2D1_COLOR_F`, `CD2DSizeF` → small engine structs (`PointF`, `ColorF`, `SizeF`)
  - `CComPtr<ID2D1...>` objects → calls on the engine's `IRenderer` interface
  - `AfxBeginThread`, `CRITICAL_SECTION`, `Interlocked*` → `std::thread`, `std::mutex`, `std::atomic`
  - `PostMessage` to the main window → a callback the app supplies (the app hops to the main queue)
  - `HRESULT` / `CHECK()` → `bool` results or exceptions, decided once and used consistently
  - `__forceinline` → `inline`
- **Keep file formats compatible.** `.whp` patches and `.whl` playlists are tab-separated text and must round-trip with Windows Whorld. `.whs` snapshots and `.whm` movies are raw binary struct dumps: read them with explicit field-by-field little-endian decoding, never by `memcpy` into a struct, because type sizes and padding differ between MSVC and clang.
- **Coordinate systems.** Direct2D uses a top-left origin with y pointing down, in device-independent pixels (DIPs). Core Graphics in an `NSView` has y pointing up and needs the Retina backing scale. Handle both in the renderer, not in the engine math.
- **Ask before** adding a third-party dependency, changing a file format, or changing the plan's architecture.

## Verifying work

A task isn't done until it is checked: engine changes pass `ctest`; rendering changes match the golden images in `mac/testdata` within tolerance; app changes are checked by building and running the app and looking at the result. For UI or visual work, describe what was checked.

## Commits

Small commits, one task per commit, with messages that say which original files were ported.
