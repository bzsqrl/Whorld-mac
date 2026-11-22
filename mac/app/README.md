# macOS app

SwiftUI/AppKit app (`Whorld.xcodeproj`, macOS 14+, Xcode 16.2 or later). It compiles the engine (`mac/engine/src`) and the Core Graphics renderer (`mac/renderer/CGRenderer.mm`) directly.

- `Whorld/WHEngine.{h,mm}`: the Objective-C++ bridge. `WHEngine` owns the engine, a render thread and a command queue; it keeps the current patch as the document, as `CWhorldDoc` does. `WHRenderView` is the AppKit view: its display link (`NSView.displayLink`) requests one frame per display refresh, and the render thread draws it straight into an IOSurface that the view's layer displays without copying.
- `Whorld/WhorldApp.swift`: `AppModel`, which holds the app state and makes every document edit undoable (coalescing as `CUndoManager` does), plus the scenes.
- `Whorld/Panels.swift`: the Parameters, Master, Globals and Properties panels (`ParamsBar`, `MasterBar`, `GlobalsBar`, main properties). Their slider and edit-box math is `whorld::Controls` in the engine.
- `Whorld/Media.swift`: snapshots, image and movie export, the movie bar and the Playlist window.
- `Whorld/Mapping.swift`: the MIDI Mapping window (`MappingBar`) and MIDI learn.
- `Whorld/Preferences.swift`: the Preferences window (`OptionsDef.h`), stored in `UserDefaults` under the Windows option names.
- `Whorld/ContentView.swift`, `Commands.swift`: the render window, menus and shortcuts.
- `generate_project.py`: regenerates `Whorld.xcodeproj`. Add new source files to its lists.

Build: `xcodebuild -project mac/app/Whorld.xcodeproj -scheme Whorld build`. Set `WHORLD_STATS=1` in the environment to print the frame-rate line (View > Show Perform Bar, ⇧⌘B, shows the same figures) to stderr once a second.

## Keyboard shortcuts

From the Windows accelerator table (`Whorld.rc`, `IDR_MAINFRAME`), with Ctrl mapped to Command except where macOS reserves the key, and the same as the table in Help (`Help/index.html`).

| Command | Windows | macOS |
|---|---|---|
| New patch | Ctrl+N | ⌘N |
| Save | Ctrl+S | ⌘S |
| Save As | — | ⇧⌘S |
| Undo | Ctrl+Z | ⌘Z |
| Redo | Ctrl+Y | ⇧⌘Z |
| Parameters panel | Shift+P | ⌥⌘1 |
| Master panel | Shift+M | ⌥⌘2 |
| Globals panel | Shift+G | ⌥⌘3 |
| Properties panel | — | ⌥⌘4 |
| Show all panels | — | ⌥⌘P |
| Move the panel under the pointer a step (Mac) | — | ⌥⌘← ⌥⌘→ ⌥⌘↑ ⌥⌘↓ |
| Move it all the way (Mac) | — | ⇧⌥⌘ and an arrow |
| Preferences | Shift+O | ⌘, |
| Playlist panel | Shift+A | ⌥⌘5 |
| Take Snapshot | Ctrl+T | ⌘T |
| Load Snapshot | Ctrl+L | ⌘L |
| Export image | Ctrl+E | ⌘E |
| First / Previous / Next / Last snapshot | Home / Page Up / Page Down / End | same (fn‑← / fn‑↑ / fn‑↓ / fn‑→ on laptops); also ⌘← / ⌘→ for previous / next, in full screen or with the pointer over the picture |
| Record movie, Play movie | Ctrl+M, Ctrl+Shift+M | none (File > Movie) |
| Patches panel (Mac) | — | ⌥⌘6 |
| Modulation panel (Mac) | — | ⌥⌘7 |
| Key Map panel (Mac) | — | ⌥⌘9 |
| Rewind movie | Ctrl+Home | ⌘Home (fn‑⌘‑← on laptops) |
| MIDI Mapping panel | Shift+I | ⌥⌘8 |
| MIDI Learn | Shift+L | none (the MIDI Mapping panel's Learn switch) |
| New Playlist | Ctrl+Shift+N | ⇧⌘N |
| Open Playlist | Ctrl+Shift+O | ⇧⌘O |
| Save Playlist | Ctrl+Shift+S | ⌥⌘S (⇧⌘S is Save As) |
| Save Playlist As | — | ⌥⇧⌘S |
| Next / previous playlist patch (Image menu) | none | ⌘↓ / ⌘↑ |
| Auto Advance through the playlist, on or off (Mac) | — | ⌥⌘L |
| Blackout, fade to black or back (Mac) | — | ⌘B |
| Open patch | Ctrl+O | ⌘O |
| Fill | F6 | ⌘1, or F6 |
| Outline | F7 | ⌘2, or F7 |
| Mirror | F5 | ⌘3, or F5 |
| Convex | Ctrl+Tab | ⌘4 |
| Reverse | Ctrl+Backspace | ⌘5 |
| Invert Color (Mac, as in Whorld 1) | — | ⌘6, or F4 |
| Rotate Hue (Mac, as in Whorld 1) | — | ⌘7, or F3 |
| Loop Hue | F2 | ⌘8, or F2 |
| Zoom Center | Shift+W | ⌥⌘Z |
| Geometry Only, on or off (Mac, Whorld 1's patch mode) | — | ⌥⌘G |
| Antialiasing (Image > Antialiasing, or the Properties panel) | Ctrl+Alt+A | ⌥⌘A |
| Origin Center | Ctrl+0 | ⌘0 |
| Origin Drag, on or off (off parks the origin) | Ctrl+D | ⌘− (minus) |
| Origin Random, on or off (off parks the origin) | Ctrl+R | ⌘= |
| Origin Park (Mac) | — | ⌥⌘0 |
| Random Phase | F9 | ⌘9, or F9 |
| Audio Modulation on or off (Mac) | — | ⌘' |
| Automatic Quality on or off (Mac) | — | ⌘; |
| Reset to 1.1 (Mac) | — | ⌘\ |
| Beat Back, Beat Forward (Mac) | — | ⌘[, ⌘] |
| Bar Back, Bar Forward (Mac) | — | ⇧⌘[, ⇧⌘] |
| Half Beat Back, Half Beat Forward (Mac) | — | ⌥⌘[, ⌥⌘] |
| Pause | Ctrl+Space | Space (⌃Space switches input sources) |
| Step | Shift+Space | ⇧Space |
| Clear | Ctrl+Delete | Delete (⌫), except while you type in a box or a list has focus, where Delete does its usual job; or ⌘⌦ (forward delete: fn‑⌘‑Delete on laptops) |
| Full screen | F11 | ⌘F (View > Enter Full Screen), or ⌃⌘F as in other Mac apps, or F11 if your keyboard sends it; Esc also leaves |
| Full screen on another display | — | ⇧⌘F (View > Enter Full Screen on Other Display), with more than one display; while full screen, the next display |
| Detach | Ctrl+F12 | ⇧⌘D |
| Show Perform Bar | — | ⇧⌘B |

Panels use ⌥⌘ and a digit, not Windows' Shift+letter, which would fire while typing a capital letter in a panel's text field. Space (Pause) is safe: a focused text field takes it first.

The scroll wheel over the render window zooms, and Shift+wheel changes damping (`CWhorldDoc::OnMouseWheel`), scaled by Settings > Control > Wheel sensitivity.

Function keys need fn on keyboards set to media keys. F11 is also macOS's Show Desktop shortcut by default, so the system takes it unless that shortcut is turned off in System Settings > Keyboard > Keyboard Shortcuts; ⌘F always works.
