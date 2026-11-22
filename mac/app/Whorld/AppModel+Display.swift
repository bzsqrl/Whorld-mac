// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Full screen, other displays, and presses on the picture (AppModel, split out of WhorldApp.swift on 2026-11-22;
// no change in behavior).

import AppKit
import SwiftUI

extension AppModel {
	// CMainFrame::OnWindowFullscreen: full screen on the display of the
	// window that shows the output (the workspace, or the detached window)
	var isFullScreen: Bool { fullScreen.isFullScreen }

	static let outputFrameKey = "NSWindow Frame WhorldOutputWindow"

	/// The displays, left to right as arranged in System Settings > Displays
	/// (then bottom to top): the order Shift-Cmd-F goes through them in
	static var displaysInOrder: [NSScreen] {
		NSScreen.screens.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
	}
	/// More than one display: Shift-Cmd-F has somewhere to go
	var hasOtherDisplay: Bool { NSScreen.screens.count > 1 }

	/// The display after this one, wrapping around
	static func display(after screen: NSScreen?) -> NSScreen? {
		let all = displaysInOrder
		guard all.count > 1 else { return nil }
		guard let screen, let i = all.firstIndex(of: screen) else { return all.first }
		return all[(i + 1) % all.count]
	}

	/// The display the output is on: its detached window's, or the Whorld window's
	var outputScreen: NSScreen? {
		(layout.layout.detached ? outputWindow.window?.screen : mainWindow?.screen) ?? NSScreen.main
	}

	/// View > Enter Full Screen (Cmd-F, Ctrl-Cmd-F, F11, the Perform Bar's
	/// button): full screen on the display the output is on
	/// (CMainFrame::OnWindowFullscreen), and again to leave. It never moves
	/// the output to another display.
	func toggleFullScreen() {
		KeyCheatSheet.shared.hide()	// never over a full-screen picture, and its view may move
		if isFullScreen {
			exitFullScreen()
			return
		}
		saveFullScreenOrigin()
		let from = layout.layout.detached ? outputWindow.window : mainWindow
		enterFullScreen(from: from, on: from?.screen ?? NSScreen.main)
	}

	/// View > Enter Full Screen on Other Display / Move Full Screen to Next
	/// Display (Shift-Cmd-F, Option-click on the Perform Bar's button; a Mac
	/// addition, the user's request, 2026-11-21): out of full screen, full
	/// screen on the next display from the output's; in it, the picture
	/// moves on to the next display, through all of them in turn. With one
	/// display, nothing. As if by hand: the output detached (if it isn't),
	/// its window moved onto that display, then full screen, so a Whorld
	/// window elsewhere stays in view with the swipe pad.
	func fullScreenNextDisplay() {
		KeyCheatSheet.shared.hide()
		let target: NSScreen?
		if isFullScreen {
			target = Self.display(after: FullScreenController.coveredScreen)
			guard target != nil else { return }
			fullScreen.exit(engine: engine)	// and on again, there
		} else {
			target = Self.display(after: outputScreen)
			guard target != nil else { return }
			saveFullScreenOrigin()
		}
		guard let screen = target else { return }
		if !layout.layout.detached {
			layout.layout.detached = true
			outputWindow.show(model: self, near: mainWindow?.frame)
		}
		guard let w = outputWindow.window else { return }
		if w.screen != screen {
			Self.center(w, on: screen)
		}
		w.contentView?.layoutSubtreeIfNeeded()
		// the next turn: a window just shown has its picture view (and the
		// engine drawing to it) once SwiftUI has built it
		DispatchQueue.main.async { [weak self] in
			guard let self, !self.fullScreen.isFullScreen, let w = self.outputWindow.window else { return }
			self.enterFullScreen(from: w, on: screen)
		}
	}

	/// View > Detach to Other Display / Move to Next Display (Shift-Cmd-D,
	/// Option-click on the Perform Bar's Detach button; a Mac addition, the
	/// user's request, 2026-11-22), as Shift-Cmd-F without the full screen:
	/// docked, the output detaches onto the next display from the Whorld
	/// window's; detached, its window moves on to the next display, through
	/// them all in turn (Cmd-D docks it). Its remembered size where that
	/// fits, centered. With one display, or full screen, nothing.
	func detachNextDisplay() {
		guard !isFullScreen, let screen = Self.display(after: outputScreen) else { return }
		KeyCheatSheet.shared.hide()	// its picture moves
		if !layout.layout.detached {
			layout.layout.detached = true
			outputWindow.show(model: self, near: mainWindow?.frame)
		}
		guard let w = outputWindow.window else { return }
		if w.screen != screen {
			Self.center(w, on: screen)
		}
	}

	/// Centered on the display, kept within it
	static func center(_ w: NSWindow, on screen: NSScreen) {
		let area = screen.visibleFrame
		var f = w.frame
		f.size.width = min(f.width, area.width)
		f.size.height = min(f.height, area.height)
		f.origin = NSPoint(x: area.midX - f.width / 2, y: area.midY - f.height / 2)
		w.setFrame(f, display: true)
	}

	func enterFullScreen(from: NSWindow?, on screen: NSScreen?) {
		fullScreen.enter(from: from, on: screen, engine: engine, renderScale: renderScale,
			smoothUpscaling: smoothUpscaling) { [weak self] in
			self?.exitFullScreen()	// Esc, or the display disconnected
		}
		changed()
	}

	/// Full screen ends; the output goes back where it was before it began
	/// (the user's request, 2026-11-21)
	func exitFullScreen() {
		guard isFullScreen else { return }
		fullScreen.exit(engine: engine)
		pressDrag = nil
		restoreFullScreenOrigin()
		fullScreenOrigin = nil
		UpdateChecker.shared.showPending()	// an update found while full screen
		// The origin stays where it is, as on Windows: a patch's own
		// origin is kept (until 2026-11-12, leaving full screen ran
		// Origin Center; removed at the user's request)
		changed()
	}

	func saveFullScreenOrigin() {
		let detached = layout.layout.detached
		fullScreenOrigin = FullScreenOrigin(detached: detached,
			frame: detached ? outputWindow.window?.frame : nil,
			savedFrame: detached ? nil : UserDefaults.standard.string(forKey: Self.outputFrameKey))
	}

	func restoreFullScreenOrigin() {
		guard let o = fullScreenOrigin else { return }
		if o.detached {
			if !layout.layout.detached {
				layout.layout.detached = true
				outputWindow.show(model: self, near: mainWindow?.frame)
			}
			// its frame; its display gone, the Whorld window's display
			if let f = o.frame, let w = outputWindow.window {
				w.setFrame(f, display: true)
				if !NSScreen.screens.contains(where: { $0.frame.intersects(f) }), let home = mainWindow?.screen ?? NSScreen.main {
					Self.center(w, on: home)
				}
			}
		} else if layout.layout.detached {
			outputWindow.hide()
			layout.layout.detached = false
			if let saved = o.savedFrame {	// the window's own place for next time, not where full screen put it
				UserDefaults.standard.set(saved, forKey: Self.outputFrameKey)
			}
		}
	}


	/// A double-click on the swipe pad (the detached output's place): the
	/// output docks again. Its first click pressed the origin to the pointer;
	/// that's undone, so docking doesn't move the picture.
	func outputDoubleClick() {
		if let p = lastPress, ProcessInfo.processInfo.systemUptime - p.time < NSEvent.doubleClickInterval + 0.2 {
			engine.setOriginMotion(p.motion)
			engine.origin = p.origin
			mainChanged()
		}
		lastPress = nil
		toggleDetach()
	}

	/// The mouse button went down or up on the full-screen picture. While it's
	/// down, the origin follows the mouse (the engine's Origin Drag, damped as
	/// usual); when it's released, Origin Motion is Park, so the origin
	/// settles where the mouse was let go. One undo puts back the origin and
	/// motion from before the press. If Origin Drag was already chosen, the
	/// origin follows the mouse anyway, and a press changes nothing.
	func outputMouse(down: Bool) {
		if down {
			guard pressDrag == nil, engine.originMotion != .drag else { return }
			pressDrag = (engine.originMotion, engine.liveOrigin)
			originMoved = true
			engine.setOriginMotion(.drag)
		} else if let p = pressDrag {
			pressDrag = nil
			lastPress = (p.motion, p.origin, ProcessInfo.processInfo.systemUptime)
			engine.setOriginMotion(.park)
			pressCount += 1
			recordUndo(key: "origin press \(pressCount)", title: WHControls.mainName(MainProp.origin.rawValue)) { [weak self] in
				self?.setOriginMotion(p.motion)
				self?.setOrigin(p.origin)
			}
			changed()
		}
	}
}
