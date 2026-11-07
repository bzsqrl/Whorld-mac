## Whorld for macOS

A native macOS port of [Whorld](https://github.com/victimofleisure/Whorld) V2, the free sacred-geometry visualizer by Chris Korda. This is an unofficial port, made with Chris's blessing; the official Whorld, for Windows, is at [victimofleisure/Whorld](https://github.com/victimofleisure/Whorld). This repository keeps Whorld's full history, and the original Windows source in `trunk/Whorld` is unchanged.

Whorld for macOS runs on macOS 14 (Sonoma) or later, on Apple silicon and Intel Macs, and draws patches the same way the Windows version does. Patches, playlists, snapshots and movies are the same files on both, so you can share them across platforms. The Mac version adds video export (H.264, HEVC and ProRes) and takes MIDI input through Core MIDI.

### Install

Download `Whorld-<version>.dmg` from [Releases](https://github.com/bzsqrl/Whorld-mac/releases), open it and drag Whorld to Applications. Releases marked *pre-release* are betas.

The app is signed ad hoc but not notarized by Apple, so the first time you open it macOS says it can't check it for malicious software. Control-click Whorld in Applications, choose **Open**, then **Open** again. On macOS 15 and later, if there is no Open button, go to **System Settings > Privacy & Security** and click **Open Anyway**. You only need to do this once.

Help > Whorld Help explains what differs from Windows and lists the keyboard shortcuts. Please report bugs and suggestions in [Issues](https://github.com/bzsqrl/Whorld-mac/issues), not on the original Whorld's repository.

### Build from source

You need Xcode 16.2 or later and CMake 3.20 or later.

```sh
# engine, Core Graphics renderer, tools and tests
cmake -S mac -B build && cmake --build build && ctest --test-dir build --output-on-failure

# the app (Debug)
xcodebuild -project mac/app/Whorld.xcodeproj -scheme Whorld build

# a universal Release app, signed ad hoc, in build/dist/Whorld-<version>.dmg
sh mac/packaging/make_dmg.sh
```

`build/tools/whorld-render` renders patches, snapshots and movies from the command line (run it with no arguments for help). The source layout and the porting notes are in [CLAUDE.md](CLAUDE.md) and [PORT_PLAN.md](PORT_PLAN.md). The Windows source in `trunk/Whorld` is unchanged.

The port is free software under the GNU GPL version 3 or later ([LICENSE](LICENSE)); the original Whorld source is GPL version 2 or later. Whorld is copyleft Chris Korda; the macOS port is by Jeff Matson and Claude. Each ported file names the original it comes from and keeps its copyright notice.

---

*The original Whorld README follows.*

## Version 2 of [Whorld](https://victimofleisure.github.io/Whorld/) is available! See below.

Whorld is a free, open-source visualizer for sacred geometry. It uses math to create a seamless animation of mesmerizing psychedelic images. You can VJ with it, make unique digital artwork with it, or sit back and watch it like a screensaver.

Whorld's visualization is controlled via parameters which can be adjusted manually, or modulated by oscillators. A given setting of the parameters and their oscillators form a patch. You can use the demo patches, or create your own.

Patches can be grouped together in a playlist. You can play patches manually, or via MIDI.

Whorld is optimized for VJing. All of its functions are available in full-screen mode, via shortcut keys, mouse or trackball, and MIDI controllers.

**Whorld V2 is a major update**

It has been nearly **twenty years** since the last release. The main design goals of Whorld V2 are listed below.

1. Improve *rendering throughput* by leveraging Direct2D’s hardware acceleration. [done]
2. Implement *anti-aliasing* (line smoothing), which is a core feature of Direct2D.  [done]
3. Improve *accuracy* by drawing in floating-point coordinates, another Direct2D feature.  [done]
4. Modernize the user interface via *dockable panes* and similar enhancements. [done]
5. Move rendering to a worker thread, to avoid glitches and tearing. [done]
6. Redo the MIDI mapping, to improve usability and flexibility. [done] 
7. Streamline the application, preserving what’s valuable and discarding what isn’t. [done]
8. Add transparency (alpha). [done]
9. Implement quad mirroring [done] and other visual effects.

**Requirements:**

* PC running Windows 10 or 11 with DirectX 12 (or higher)
* Whorld could conceivably run on Windows 8 or even Windows 7 if the necessary service packs are applied, but performance will likely suffer. Direct2D 1.1 is **required**.
* Whorld may work satisfactorily on a Mac via virtualization software such VMWare or Parallels, but this is unproven. Note that virtualizer-induced misbehaviors will be considered _features_, not bugs.

V2 has its own issues list, [HERE](https://victimofleisure.github.io/Whorld/Whorld2-issues.html). V2 does not necessarily agree with the V1 documentation, and this will be addressed though not immediately.
