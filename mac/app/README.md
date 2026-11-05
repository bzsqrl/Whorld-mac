# macOS app

SwiftUI/AppKit app (`Whorld.xcodeproj`, macOS 14+, Xcode 16.2 or later). It compiles the engine (`mac/engine/src`) and the Core Graphics renderer (`mac/renderer/CGRenderer.mm`) directly.

- `Whorld/WHEngine.{h,mm}`: the Objective-C++ bridge. `WHEngine` owns the engine, a render thread and a command queue; it keeps the current patch as the document, as `CWhorldDoc` does. `WHRenderView` is the AppKit view: its display link (`NSView.displayLink`) requests one frame per display refresh, and the render thread draws it straight into an IOSurface that the view's layer displays without copying.
- `Whorld/WhorldApp.swift`, `ContentView.swift`, `Commands.swift`: the SwiftUI shell, menus and shortcuts.

Build: `xcodebuild -project mac/app/Whorld.xcodeproj -scheme Whorld build`. Set `WHORLD_STATS=1` in the environment to print the frame-rate line (also shown with View > Show Frame Rate) to stderr once a second.

## Keyboard shortcuts

From the Windows accelerator table (`Whorld.rc`, `IDR_MAINFRAME`), with Ctrl mapped to Command except where macOS reserves the key.

| Command | Windows | macOS |
|---|---|---|
| New patch | Ctrl+N | ⌘N |
| Open patch | Ctrl+O | ⌘O |
| Fill | F6 | F6 |
| Outline | F7 | F7 |
| Mirror | F5 | F5 |
| Reverse | Ctrl+Backspace | ⌘Delete |
| Convex | Ctrl+Tab | ⌃Tab (⌘Tab switches apps) |
| Loop Hue | F2 | F2 |
| Zoom Center | Shift+W | ⇧W |
| Antialiasing | Ctrl+Alt+A | ⌥⌘A |
| Origin Center | Ctrl+0 | ⌘0 |
| Origin Drag | Ctrl+D | ⌘D |
| Origin Random | Ctrl+R | ⌘R |
| Random Phase | F9 | F9 |
| Pause | Ctrl+Space | Space (⌃Space switches input sources) |
| Step | Shift+Space | ⇧Space |
| Clear | Ctrl+Delete | ⌘⌦ (forward delete; fn+Delete on laptops) |
| Full screen | F11 | F11, or ⌃⌘F |

Function keys need fn on keyboards set to media keys. F11 is also macOS's Show Desktop shortcut by default, so the system takes it unless that shortcut is turned off in System Settings > Keyboard > Keyboard Shortcuts; ⌃⌘F always works.
