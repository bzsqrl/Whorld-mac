// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyleft 2025 Chris Korda (original Whorld); port Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

import AppKit

/// Whorld's own full screen, after CWhorldApp::SetFullScreen, which detaches
/// the render window into a full-screen window and hides the main menu. The
/// picture moves to a borderless window covering the display the main
/// window is on. macOS's own full screen can't do this: it shows the menu bar
/// if System Settings says to, whatever the app asks. On a display with a
/// camera housing, the picture stays below it and the strip beside it is black.
///
/// On the primary display (the one with the menu bar and usually the Dock)
/// the menu bar and Dock are hidden. On another display, such as a
/// projector, they stay put, so Whorld's other windows remain usable on the
/// primary display (as on Windows, which hides its menus only with a single
/// monitor); the picture instead sits above that display's own menu bar and
/// the Dock, and on every Space of that display. If the display is
/// disconnected, full screen ends; if its resolution changes, the picture
/// follows.
@MainActor
final class FullScreenController {
	private var window: FullScreenWindow?
	private weak var mainWindow: NSWindow?
	private weak var previousLayer: CALayer?
	private var view: WHRenderView?
	private var displayID: CGDirectDisplayID = 0
	private var onPrimary = true
	private var screenObserver: NSObjectProtocol?
	private var onExit: (() -> Void)?

	var isFullScreen: Bool { window != nil }

	private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
		(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
	}

	/// The picture's frame within the window: below the camera housing, if any.
	private static func pictureFrame(_ screen: NSScreen) -> NSRect {
		NSRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height - screen.safeAreaInsets.top)
	}

	func enter(from main: NSWindow?, engine: WHEngine, fullResolution: Bool, onExit: @escaping () -> Void) {
		guard window == nil, let screen = main?.screen ?? NSScreen.main else { return }
		let frame = screen.frame
		let w = FullScreenWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
		w.isReleasedWhenClosed = false
		w.backgroundColor = .black
		onPrimary = screen == NSScreen.screens.first
		if onPrimary {
			w.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
		} else {	// above that display's menu bar and the Dock, on all its Spaces
			w.level = .statusBar
			w.collectionBehavior = [.fullScreenNone, .canJoinAllSpaces]
		}
		w.onExit = onExit
		self.onExit = onExit
		displayID = Self.displayID(of: screen)
		let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
		container.wantsLayer = true
		container.layer?.backgroundColor = NSColor.black.cgColor
		let view = WHRenderView(frame: Self.pictureFrame(screen))
		view.autoresizingMask = [.width, .height]
		view.fullResolution = fullResolution
		view.fullScreenOutput = true	// no cursor over the picture; the mouse followed for Origin Drag
		view.mouseButtonHandler = { down in	// while pressed, the origin follows the mouse
			MainActor.assumeIsolated { AppModel.shared.outputMouse(down: down) }	// in order: no Task
		}
		view.wheelHandler = { notches, shift in
			Task { @MainActor in AppModel.shared.wheel(notches: notches, shift: shift) }
		}
		container.addSubview(view)
		w.contentView = container
		previousLayer = engine.attachedLayer
		view.engine = engine	// frames now go to this view's layer
		self.view = view
		if onPrimary {
			NSApp.presentationOptions = [.hideDock, .hideMenuBar]
		}
		screenObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.screensChanged() }
		}
		w.setFrame(frame, display: true)
		w.makeKeyAndOrderFront(nil)
		w.makeFirstResponder(view)
		main?.orderOut(nil)
		mainWindow = main
		window = w
	}

	/// A display was added, removed or reconfigured.
	private func screensChanged() {
		guard let w = window else { return }
		guard let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == displayID }) else {
			onExit?()	// our display is gone: back to the window
			return
		}
		w.setFrame(screen.frame, display: true)
		view?.frame = Self.pictureFrame(screen)
	}

	func exit(engine: WHEngine) {
		guard let w = window else { return }
		window = nil
		view = nil
		onExit = nil
		if let o = screenObserver {
			NotificationCenter.default.removeObserver(o)
			screenObserver = nil
		}
		if onPrimary {
			NSApp.presentationOptions = []
		}
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
