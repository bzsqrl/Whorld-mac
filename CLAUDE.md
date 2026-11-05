# Whorld for macOS

This repository is a fork of [victimofleisure/Whorld](https://github.com/victimofleisure/Whorld) (Chris Korda's sacred-geometry visualizer, V2). The goal is a native macOS port. The full plan, with phases and status, is in `PORT_PLAN.md`. Read it before starting work, and update its status checkboxes when a task is finished.

License: GPLv3. Every new file gets a GPLv3 header and keeps the original copyright notice where code is derived from Whorld.

## Repository layout

- `trunk/Whorld/` — the original Windows source (C++, MFC, Direct2D). **Reference only.** Do not edit it, except for small changes that could be sent upstream, and only when the user asks.
- `mac/engine/` — portable C++17 engine extracted from the Windows source. No Windows headers, no MFC, no Apple headers.
- `mac/engine/tests/` — engine unit tests and golden-image tests.
- `mac/renderer/` — the Core Graphics drawing backend (Objective-C++, `.mm`), implementing the engine's renderer interface.
- `mac/tools/` — command-line tools: `whorld-render` renders a patch or snapshot to PNG and compares images.
- `mac/app/` — the macOS app (Swift / SwiftUI, Xcode project), talking to the engine through a thin Objective-C++ bridge.
- `mac/testdata/` — sample `.whp` patches, `.whs` snapshots and reference PNGs exported from Windows Whorld.

## Build and test

These commands are created in Phase 0 of the plan. Keep this section accurate as the build changes.

- Engine + tests: `cmake -S mac -B build && cmake --build build && ctest --test-dir build --output-on-failure`
- Render a frame: `build/tools/whorld-render <file.whp|file.whs> --out frame.png` (run with no arguments for options)
- Compare images: `build/tools/whorld-render --compare a.png b.png --diff diff.png`
- App: `xcodebuild -project mac/app/Whorld.xcodeproj -scheme Whorld build` (run the built app with `WHORLD_STATS=1` to print frame-rate stats)

On macOS, CMake also builds the Core Graphics renderer, the tools and the golden-image tests; on Linux it builds only the engine and its tests.

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
