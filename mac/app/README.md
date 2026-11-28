# macOS app

SwiftUI/AppKit app (`Whorld.xcodeproj`, macOS 14+, Xcode 16.2 or later). It compiles the engine (`mac/engine/src`) and the renderers (`mac/renderer`: Core Graphics and Metal) directly.

- `Whorld/WHEngine.{h,mm}`: the Objective-C++ bridge. `WHEngine` owns the engine, a render thread and a command queue; it keeps the current patch as the document, as `CWhorldDoc` does. `WHRenderView` is the AppKit view: its display link (`NSView.displayLink`) requests one frame per display refresh, and the render thread draws it straight into an IOSurface that the view's layer displays without copying.
- `Whorld/WhorldApp.swift`: `AppModel`, which holds the app state and makes every document edit undoable (coalescing as `CUndoManager` does), plus the scenes.
- `Whorld/Panels.swift`: the Parameters, Master, Globals and Properties panels (`ParamsBar`, `MasterBar`, `GlobalsBar`, main properties). Their slider and edit-box math is `whorld::Controls` in the engine.
- `Whorld/Media.swift`: snapshots, image and movie export, the movie bar and the Playlist window.
- `Whorld/Mapping.swift`: the MIDI Mapping window (`MappingBar`) and MIDI learn.
- `Whorld/Preferences.swift`: the Preferences window (`OptionsDef.h`), stored in `UserDefaults` under the Windows option names.
- `Whorld/ContentView.swift`, `Commands.swift`: the render window, menus and shortcuts.
- `generate_project.py`: regenerates `Whorld.xcodeproj`. Add new source files to its lists.

Build: `xcodebuild -project mac/app/Whorld.xcodeproj -scheme Whorld build`. Set `WHORLD_STATS=1` in the environment to print the frame-rate line (View > Show Perform Bar, ⌥⌘B, shows the same figures) to stderr once a second.

## Keyboard shortcuts

The list is in Help (`Help/index.html`, "Keyboard shortcuts"), the one place it's kept, with the Windows key beside each Mac one. They come from the Windows accelerator table (`Whorld.rc`, `IDR_MAINFRAME`), with Ctrl mapped to Command except where macOS reserves the key; the menus' are in `Commands.swift`, and the keys taken before the menus (Space, Shift-Delete, the cue, the Key Map's holds) in `OutputKeys.swift`.

The scroll wheel or a two-finger swipe over the picture zooms (`CWhorldDoc::OnMouseWheel`), scaled by Settings > Input > Wheel and Trackpad sensitivity; with a Key Map key held it moves that key's control. Unlike Windows, Shift doesn't switch the wheel to Damping: it's the coarse modifier, as everywhere (D in the Key Map moves Damping).

Function keys need fn on keyboards set to media keys. F11 is also macOS's Show Desktop shortcut by default, so the system takes it unless that shortcut is turned off in System Settings > Keyboard > Keyboard Shortcuts; ⌘F always works.
