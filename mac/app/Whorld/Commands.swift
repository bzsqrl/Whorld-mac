// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

import AppKit
import SwiftUI

/// Menus with the Windows Whorld shortcuts (Whorld.rc IDR_MAINFRAME
/// accelerators), with Ctrl mapped to Command except where macOS reserves
/// the key. See mac/app/README.md for the full table.
struct WhorldCommands: Commands {
	@ObservedObject var model: AppModel

	private func fkey(_ code: Int) -> KeyEquivalent {
		KeyEquivalent(Character(UnicodeScalar(UInt32(code))!))
	}

	/// A menu item with a standard check mark, reading its state from the
	/// engine's document and toggling it through the given action.
	private func toggle(_ title: String, _ isOn: Bool, _ action: @escaping () -> Void) -> some View {
		Toggle(title, isOn: Binding(
			get: { isOn },
			set: { _ in
				action()
				model.changed()
			}))
	}

	var body: some Commands {
		let e = model.engine
		let _ = model.revision	// refresh check marks after changes

		CommandGroup(replacing: .newItem) {
			Button("New") { model.newPatch() }
				.keyboardShortcut("n")
			Button("Open…") { model.showOpenPanel() }
				.keyboardShortcut("o")
		}

		CommandMenu("Image") {
			toggle("Fill", e.fill) { e.toggleFill() }
				.keyboardShortcut(fkey(NSF6FunctionKey), modifiers: [])
			toggle("Outline", e.outline) { e.toggleOutline() }
				.keyboardShortcut(fkey(NSF7FunctionKey), modifiers: [])
			toggle("Mirror", e.mirror) { e.toggleMirror() }
				.keyboardShortcut(fkey(NSF5FunctionKey), modifiers: [])
			Divider()
			toggle("Reverse", e.reverse) { e.toggleReverse() }
				.keyboardShortcut(.delete, modifiers: .command)
			toggle("Convex", e.convex) { e.toggleConvex() }
				.keyboardShortcut(.tab, modifiers: .control)
			toggle("Loop Hue", e.loopHue) { e.toggleLoopHue() }
				.keyboardShortcut(fkey(NSF2FunctionKey), modifiers: [])
			toggle("Zoom Center", e.zoomCenter) { e.toggleZoomCenter() }
				.keyboardShortcut("w", modifiers: .shift)
			toggle("Antialiasing", e.antialiasing) { e.toggleAntialiasing() }
				.keyboardShortcut("a", modifiers: [.command, .option])
			Divider()
			Button("Origin Center") { e.originCenter(); model.changed() }
				.keyboardShortcut("0")
			toggle("Origin Drag", e.originMotion == .drag) { e.toggleOriginDrag() }
				.keyboardShortcut("d")
			toggle("Origin Random", e.originMotion == .random) { e.toggleOriginRandom() }
				.keyboardShortcut("r")
			Divider()
			Button("Random Phase") { e.randomPhase() }
				.keyboardShortcut(fkey(NSF9FunctionKey), modifiers: [])
		}

		CommandGroup(after: .toolbar) {
			Toggle("Full Resolution", isOn: $model.fullResolution)
			Toggle("Show Frame Rate", isOn: $model.showFrameRate)
				.keyboardShortcut("f", modifiers: [.command, .shift])
			Divider()
		}

		CommandGroup(before: .windowSize) {
			toggle("Pause", e.paused) { e.togglePause() }
				.keyboardShortcut(.space, modifiers: [])
			Button("Step") { e.singleStep() }
				.keyboardShortcut(.space, modifiers: .shift)
			Button("Clear") { e.clear() }
				.keyboardShortcut(.deleteForward, modifiers: .command)
			Button("Full Screen") { model.toggleFullScreen() }
				.keyboardShortcut(fkey(NSF11FunctionKey), modifiers: [])
			Divider()
		}
	}
}
