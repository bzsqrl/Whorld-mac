// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Keys taken before the menus and controls: the Key Map keys held over
// the picture, Space, Delete, the cheat sheet key (OutputKeys), number-box
// selection, the View menu tidy-up and the second keys (split out of
// WhorldApp.swift on 2026-11-22; no change in behavior).

import AppKit
import SwiftUI

/// Keys held over the picture (Mac addition): while a key in the key map
/// (KeyMap.swift) is held with the pointer over the output (docked,
/// detached or full screen), a trackpad swipe up or down, or the mouse
/// wheel, moves that key's control instead of zooming. Plain keys only:
/// with Shift, Command, Control or Option they're shortcuts (Shift-Space
/// is Step, Command-S Save...), and with the pointer elsewhere they
/// type as usual.
@MainActor
final class OutputKeys {

	private(set) var held: String?
	/// the cheat sheet's key went down here, so its repeats and key-up are taken too
	private var sheetKeyTaken = false
	private var heldCode: CGKeyCode = 0
	/// the held key's control, if the key is still down (a key-up can be
	/// missed, e.g. released while a menu tracks: then ask the keyboard)
	var heldTarget: KeyBinding? {
		guard let held else { return nil }
		if !CGEventSource.keyState(.combinedSessionState, key: heldCode) {
			self.held = nil
			return nil
		}
		return KeyMap.shared.binding(for: held)
	}
	/// the last wheel event moved a key's control (so its coasting is ignored)
	var lastWheelWasKeyed = false
	private var monitor: Any?
	private var resign: Any?

	func install() {
		guard monitor == nil else { return }
		monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
			// plain values across to the main actor (we're on the main thread)
			let key = e.charactersIgnoringModifiers?.lowercased()
			let code = e.keyCode
			let up = e.type == .keyUp
			let mods = e.modifierFlags.intersection([.shift, .command, .control, .option]).rawValue
			let isRepeat = e.type == .keyDown && e.isARepeat
			let take = MainActor.assumeIsolated {
				AppModel.shared.outputKeys.takes(key: key, code: code, up: up, modifiers: mods, isRepeat: isRepeat)
			}
			return take ? nil : e
		}
		resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
			object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.held = nil }	// its key-up goes to another app (the cheat sheet stays, hidden with the app)
		}
	}

	/// true: the key event is this feature's (not passed on)
	func takes(key: String?, code: CGKeyCode, up: Bool, modifiers: UInt, isRepeat: Bool = false) -> Bool {
		guard let key else { return false }
		// Space and Shift-Space: Pause and Step (Image menu), taken before
		// the focused control, which could otherwise swallow them (a number
		// box, focused when the window opens, or the playlist; the user's
		// menu audit, 2026-11-18). Held, Space pauses once; Shift-Space
		// keeps stepping.
		if !up, code == 49, modifiers == 0 || modifiers == NSEvent.ModifierFlags.shift.rawValue, Self.takesSpace() {
			let m = AppModel.shared
			if modifiers == 0 {
				if !isRepeat {
					m.togglePause()	// (the Properties' Pause chip redraws)
				}
			} else {
				m.engine.singleStep()
			}
			return true
		}
		// Delete: Image > Clear (the user's request, 2026-11-21), taken
		// before the menu and the panels' buttons, except where Delete has a
		// job of its own: editing text, or a list with focus (MIDI Mapping's
		// Delete removes its selected rows). Held, it clears once.
		if !up, code == 51, modifiers == 0, Self.takesDelete() {
			if !isRepeat { AppModel.shared.clear() }
			return true
		}
		// Command-Left and Command-Right: the previous and next snapshot
		// (File > Snapshots > Previous and Next, without keys of their own), in full
		// screen or with the pointer over the picture
		if !up, code == 123 || code == 124, modifiers == NSEvent.ModifierFlags.command.rawValue,
			AppModel.shared.hasSnapshots, AppModel.shared.isFullScreen || Self.pointerOverOutput() {
			if code == 124 { AppModel.shared.snapshotNext() } else { AppModel.shared.snapshotPrev() }
			return true
		}
		// the Key Map cheat sheet (KeyCheatSheet; the user's requests,
		// 2026-11-22): the key left of 1, over the picture, shows it; pressed
		// again (anywhere), or Esc, hides it
		let sheet = KeyCheatSheet.shared
		if KeyCheatSheet.keyCodes.contains(code), KeyMap.shared.capturing == nil {
			if up || isRepeat { return sheetKeyTaken }
			sheetKeyTaken = false
			guard modifiers == 0 else { return false }
			if sheet.isShown {
				sheet.hide()
			} else if let view = Self.outputViewUnderPointer() {
				sheet.show(over: view)
			} else {
				return false
			}
			sheetKeyTaken = true
			return true
		}
		if !up, code == 53, modifiers == 0, sheet.isShown, NSApp.modalWindow == nil {	// Esc
			sheet.hide()
			return true
		}
		if up {
			if held != nil, key == held || code == heldCode {
				held = nil
				return true
			}
			return false
		}
		// the held key's repeats, whatever the modifiers: they now scale the
		// swipe (ModifierLadder), and Command plus the repeat mustn't reach
		// the menus (Command-W)
		if held != nil, code == heldCode {	// by key code: Shift turns [ into {
			return true	// key repeat
		}
		// not while the Key Map waits for a key (docked beside the picture,
		// the pointer may be over it): the key is the new one, not a hold
		guard modifiers == 0, KeyMap.shared.capturing == nil, KeyMap.shared.binding(for: key) != nil else { return false }
		guard Self.pointerOverOutput() else { return false }
		held = key
		heldCode = code
		if let b = KeyMap.shared.binding(for: key) {
			AppModel.shared.showKeyControl(b)	// named on the press, before any swipe
		}
		return true
	}

	/// Whether Space is Pause's here: not in a dialog, nor while the Key Map
	/// waits for a key, nor where a space is typed (a text field other than
	/// a number box, which takes no spaces) or presses something (a focused
	/// button or menu, with Full Keyboard Access).
	private static func takesSpace() -> Bool {
		guard NSApp.modalWindow == nil, KeyMap.shared.capturing == nil,
			let w = NSApp.keyWindow, w.attachedSheet == nil, !w.isSheet else { return false }
		switch w.firstResponder {
		case let text as NSTextView:
			return text.isFieldEditor && (text.delegate as AnyObject?) is KeyTextField.Field	// via AnyObject: Swift takes the cast from the delegate protocol to fail
		case is NSTableView, is NSSlider:
			return true
		case is NSButton, is NSSegmentedControl, is NSTextField:
			return false
		default:
			return true
		}
	}

	/// Delete clears the picture: not in a dialog, a sheet or the Key Map's
	/// key capture, nor while text is edited or a list has focus
	private static func takesDelete() -> Bool {
		guard NSApp.modalWindow == nil, KeyMap.shared.capturing == nil,
			let w = NSApp.keyWindow, w.attachedSheet == nil, !w.isSheet else { return false }
		switch w.firstResponder {
		case is NSTextView, is NSTextField, is NSTableView, is NSOutlineView:
			return false
		default:
			return true
		}
	}

	/// the pointer is over a picture (WHRenderView), or the swipe pad standing
	/// for it, in the topmost window under it
	private static func pointerOverOutput() -> Bool { outputViewUnderPointer() != nil }

	/// that picture or swipe pad
	static func outputViewUnderPointer() -> NSView? {
		let p = NSEvent.mouseLocation
		var n = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
		if let sheet = KeyCheatSheet.shared.windowNumber, n == sheet {	// the cheat sheet lets the pointer through
			n = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: sheet)
		}
		guard let w = NSApp.window(withWindowNumber: n), let content = w.contentView else { return nil }
		var v = content.hitTest(w.convertPoint(fromScreen: p))	// hitTest takes its superview's (the window's) coordinates
		while let view = v {
			if view is WHRenderView || view is SwipePadView { return view }
			v = view.superview
		}
		return nil
	}
}

/// A click into a number box selects its number, ready to type over (the
/// user's request, 2026-11-18): the panels' boxes and the dialogs' and
/// Settings' number fields alike. Only the click that starts editing: a
/// click in a box already being edited places the caret, to change part
/// of it. A field holding text that isn't a number (a name) is left alone.
@MainActor
enum NumberBoxSelect {
	private static var monitor: Any?

	static func install() {
		guard monitor == nil else { return }
		monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
			let before = MainActor.assumeIsolated { editedField(in: e.window) }
			let window = e.window
			// after the click's own handling: the text field tracks the mouse
			// until it's up, then places the caret, so not while tracking
			// (the main queue would run there), only back in the default mode
			RunLoop.main.perform(inModes: [.default]) {
				MainActor.assumeIsolated {
					guard let field = editedField(in: window), field !== before,
						let editor = field.currentEditor(), isNumber(field.stringValue) else { return }
					editor.selectAll(nil)
				}
			}
			return e
		}
	}

	/// the text field the window is editing now, if any
	private static func editedField(in window: NSWindow?) -> NSTextField? {
		guard let text = window?.firstResponder as? NSTextView, text.isFieldEditor else { return nil }
		return text.delegate as? NSTextField
	}

	private static func isNumber(_ s: String) -> Bool {
		let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
		return !t.isEmpty && (Double(t) != nil || NumberField.fraction(t) != nil)
	}
}

/// A click on something that isn't a control (a panel's background, a
/// label, the picture) takes the focus away from the control that had it,
/// leaving none (the user's request, 2026-11-24); AppKit leaves it where it
/// was. Checked when the button comes up, once the click has been handled:
/// a click that gave something focus (another box, a slider, a Properties
/// row), or landed in the focused control or on any AppKit control (a
/// button or stepper beside a box), leaves the focus alone.
@MainActor
enum ClickAway {
	private static var monitor: Any?
	private static var pending: (window: NSWindow, before: NSResponder, point: NSPoint, onControl: Bool)?
	/// set by SwiftUI views that take focus with a tap gesture (the
	/// Properties rows), which the responder chain doesn't show
	static var claimed = false

	static func install() {
		guard monitor == nil else { return }
		monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
			MainActor.assumeIsolated {
				if e.type == .leftMouseDown { down(e) } else { up() }
			}
			return e
		}
	}

	private static func down(_ e: NSEvent) {
		pending = nil
		claimed = false
		guard let w = e.window, let before = w.firstResponder, before !== w,
			let content = w.contentView?.superview else { return }
		let p = e.locationInWindow
		pending = (w, before, p, isControl(content.hitTest(content.convert(p, from: nil))))
	}

	private static func up() {
		guard let c = pending else { return }
		pending = nil
		// after SwiftUI's tap gestures, which end on this mouse-up
		DispatchQueue.main.async {
			MainActor.assumeIsolated {
				guard !claimed, !c.onControl, c.window.firstResponder === c.before else { return }
				if let v = focusedView(c.before), !isSwiftUI(v),
					v.convert(v.bounds, to: nil).contains(c.point) { return }	// in the focused control
				c.window.makeFirstResponder(nil)
			}
		}
	}

	/// the view that shows the focus: a text field for its field editor
	private static func focusedView(_ r: NSResponder) -> NSView? {
		if let t = r as? NSTextView, t.isFieldEditor { return t.delegate as? NSView ?? t }
		return r as? NSView
	}

	/// SwiftUI's own views (a hosting view and what's inside it), which
	/// take clicks for gestures as well as controls
	private static func isSwiftUI(_ v: NSView) -> Bool {
		let name = NSStringFromClass(type(of: v))
		return name.contains("SwiftUI") || name.contains("Hosting")
	}

	/// an AppKit control, text, table or other view that takes focus, at
	/// the click or around it (not a plain label)
	private static func isControl(_ hit: NSView?) -> Bool {
		var v = hit
		while let view = v {
			if let field = view as? NSTextField, !field.isEditable, !field.isSelectable {
				// a label: not a control
			} else if view is NSControl || view is NSText || view is NSTableView || view is NSScroller {
				return true
			} else if !isSwiftUI(view), view.acceptsFirstResponder {
				return true
			}
			v = view.superview
		}
		return false
	}
}

/// The View menu is Whorld's own, after Audio (WhorldCommands, the user's
/// choice, 2026-11-18); SwiftUI keeps the standard one after Edit even with
/// its groups emptied (it holds a separator), so that one is taken out of
/// the menu bar whenever SwiftUI builds or rebuilds it.
@MainActor
enum StandardViewMenu {
	private static var observer: Any?

	static func removeWhenAdded() {
		remove()
		guard observer == nil, let bar = NSApp.mainMenu else { return }
		observer = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification,
			object: bar, queue: .main) { _ in
			MainActor.assumeIsolated { remove() }
		}
	}

	/// a View menu with nothing in it but separators
	private static func remove() {
		guard let bar = NSApp.mainMenu else { return }
		for item in bar.items where item.title == "View" {
			if let sub = item.submenu, sub.items.allSatisfy(\.isSeparatorItem) {
				bar.removeItem(item)
			}
		}
	}
}

/// Keys that do what a menu item does, besides the item's own shortcut: the
/// Windows Whorld keys where the menu shows a Mac one (the F-keys need fn
/// on a Mac keyboard; laptops have no Forward Delete), and macOS's usual
/// full-screen key. Not shown in the menus; listed in Help.
@MainActor
enum SecondKeys {
	private typealias Mods = NSEvent.ModifierFlags
	private static let none: UInt = 0
	private static let cmd = Mods.command.rawValue
	private static let ctrlCmd = Mods([.control, .command]).rawValue

	/// true: the key was one of these, and its command ran
	static func perform(code: UInt16, modifiers: UInt) -> Bool {
		guard NSApp.modalWindow == nil else { return false }	// a dialog is up
		let m = AppModel.shared
		let e = m.engine
		switch (code, modifiers) {
		case (103, none): m.toggleFullScreen()	// F11, Windows' full screen
		case (3, ctrlCmd): m.toggleFullScreen()	// Ctrl-Cmd-F, macOS's (Cmd-F in the menu)
		case (117, cmd): m.clear()	// Cmd-Forward Delete, Windows' Ctrl+Delete (Delete in the menu)
		case (97, none): m.toggleFill()	// F6 (Cmd-1)
		case (98, none): m.toggleOutline()	// F7 (Cmd-2)
		case (96, none): m.toggle(.mirror)	// F5 (Cmd-4)
		case (120, none): m.toggle(.loopHue)	// F2 (Cmd-9)
		case (99, none): m.rotateHue()	// F3 (Cmd-8)
		case (118, none): m.toggle(.invertColor)	// F4 (Cmd-7)
		case (101, none): m.randomPhase()	// F9 (Cmd-0)
		case (100, none): m.toggleXRay()	// F8 (Cmd-3), Whorld V1's X-Ray key
		default: return false
		}
		return true
	}
}
