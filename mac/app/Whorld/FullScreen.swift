// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyleft 2025 Chris Korda (original Whorld); port Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

import AppKit

/// Whorld's own full screen, after CWhorldApp::SetFullScreen, which detaches
/// the render window into a full-screen window and hides the main menu. The
/// picture moves to a borderless window covering the main window's display,
/// and the menu bar and Dock are hidden outright. macOS's own full screen
/// can't do that: it shows the menu bar if System Settings says to, whatever
/// the app asks. On a display with a camera housing, the picture stays below
/// it and the strip beside it is black.
@MainActor
final class FullScreenController {
	private var window: FullScreenWindow?
	private weak var mainWindow: NSWindow?
	private weak var previousLayer: CALayer?

	var isFullScreen: Bool { window != nil }

	func enter(from main: NSWindow?, engine: WHEngine, fullResolution: Bool, onExit: @escaping () -> Void) {
		guard window == nil, let screen = main?.screen ?? NSScreen.main else { return }
		let frame = screen.frame
		let w = FullScreenWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
		w.isReleasedWhenClosed = false
		w.backgroundColor = .black
		w.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
		w.onExit = onExit
		let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
		container.wantsLayer = true
		container.layer?.backgroundColor = NSColor.black.cgColor
		let top = screen.safeAreaInsets.top	// the camera housing's strip, if any
		let view = WHRenderView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height - top))
		view.autoresizingMask = [.width, .height]
		view.fullResolution = fullResolution
		view.wheelHandler = { notches, shift in
			Task { @MainActor in AppModel.shared.wheel(notches: notches, shift: shift) }
		}
		container.addSubview(view)
		w.contentView = container
		previousLayer = engine.attachedLayer
		view.engine = engine	// frames now go to this view's layer
		NSApp.presentationOptions = [.hideDock, .hideMenuBar]
		w.setFrame(frame, display: true)
		w.makeKeyAndOrderFront(nil)
		w.makeFirstResponder(view)
		main?.orderOut(nil)
		mainWindow = main
		window = w
	}

	func exit(engine: WHEngine) {
		guard let w = window else { return }
		window = nil
		NSApp.presentationOptions = []
		if let layer = previousLayer {
			engine.attach(layer)	// back to the main window's view
		}
		mainWindow?.makeKeyAndOrderFront(nil)
		w.orderOut(nil)
		w.contentView = nil
	}
}

/// A borderless window that can take the keyboard (borderless windows can't
/// by default), so menu shortcuts and Esc reach the app.
final class FullScreenWindow: NSWindow {
	var onExit: (() -> Void)?

	override var canBecomeKey: Bool { true }
	override var canBecomeMain: Bool { true }

	// Esc leaves full screen, as in macOS's own (Windows Whorld uses F11 only)
	override func cancelOperation(_ sender: Any?) { onExit?() }
	override func keyDown(with event: NSEvent) {
		if event.keyCode == 53 {	// Esc
			onExit?()
		} else {
			super.keyDown(with: event)
		}
	}
}
