// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
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
	let model: AppModel	// not observed: MenuRefresh says when to refresh
	@Environment(\.openWindow) private var openWindow
	@AppStorage(AudioSettings.linkKey) private var linkEnabled = false	// Audio > Ableton Link
	@AppStorage(LaunchTiming.key) private var launchTiming = 0	// Image > Cue > Launch Timing
	@AppStorage(KeyBadge.defaultsKey) private var keyBadges = false	// View > Show Key Map in Panels
	@AppStorage(HoverTips.key) private var hoverTips = true	// View > Show Tips on Hover

	/// A recent file's name, with its folder if another recent file has the same name.
	static func recentTitle(_ url: URL, in all: [URL]) -> String {
		let name = url.lastPathComponent
		let same = all.filter { $0.lastPathComponent == name }.count > 1
		return same ? "\(name) — \(url.deletingLastPathComponent().lastPathComponent)" : name
	}

	/// Command-Down or Command-Up as a menu command (Next and Previous
	/// Patch), except in a text area of several lines, where they keep
	/// their usual meaning: to the end or the start, and in a focused number
	/// box, which takes them as its finest step (the modifier ladder's
	/// Command; the user's request, 2026-11-24: a box no longer stays
	/// focused once you click elsewhere, ClickAway).
	static func arrowOrStep(down: Bool, _ step: () -> Void) {
		guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable else {
			step()
			return
		}
		if !text.isFieldEditor {
			text.doCommand(by: down ? #selector(NSResponder.moveToEndOfDocument(_:))
				: #selector(NSResponder.moveToBeginningOfDocument(_:)))
		} else if let box = (text.delegate as AnyObject?) as? KeyTextField.Field, let swipe = box.onSwipeStep {	// via AnyObject: Swift takes the cast from the delegate protocol to fail
			swipe(down ? -1 : 1, KeyStep(.command) ?? .by(ModifierLadder.finest))	// an arrow key's ⌘ step
		} else {
			step()
		}
	}

	/// A menu item with a standard check mark, reading its state from the
	/// engine's document and toggling it through the given action.
	private func toggle(_ title: String, _ isOn: Bool, _ action: @escaping () -> Void) -> some View {
		Toggle(title, isOn: Binding(
			get: { isOn },
			set: { _ in
				action()
				model.mainChanged()
			}))
	}

	var body: some Commands {
		let e = model.engine
		// refresh check marks, titles and enabled states after changes, but
		// not while a menu is open (MenuRefresh)
		let _ = MenuRefresh.shared.n

		CommandGroup(replacing: .newItem) {
			Button("New") { model.newPatch() }
				.keyboardShortcut("n")
			Button("Open…") { model.showOpenPanel() }
				.keyboardShortcut("o")
			// CWinApp's recent file list (Windows' File menu MRU)
			Menu("Open Recent") {
				let recent = NSDocumentController.shared.recentDocumentURLs
				ForEach(recent, id: \.self) { url in
					Button(Self.recentTitle(url, in: recent)) { model.openFile(url) }
				}
				Divider()
				Button("Clear Menu") {
					NSDocumentController.shared.clearRecentDocuments(nil)
					model.changes.menus.bump()
				}
				.disabled(recent.isEmpty)
			}
		}

		CommandGroup(replacing: .saveItem) {
			Button("Save") { model.save() }
				.keyboardShortcut("s")
			Button("Save As…") { model.saveAs() }
				.keyboardShortcut("s", modifiers: [.command, .shift])
			// Patch Author… is gone: the Save As dialog has the Author field
			// (the user's request, 2026-11-19)
			Divider()
			// the playlist's files, from the Playlist menu (Windows' File >
			// Playlist; the user's menu audit, 2026-11-18), in a submenu of
			// their own (the user's request, 2026-11-19); same keys
			Menu("Playlist") {
				Button("New Playlist") { model.newPlaylist() }
					.keyboardShortcut("n", modifiers: [.command, .shift])
				Button("Open Playlist…") { model.openPlaylist() }
					.keyboardShortcut("o", modifiers: [.command, .shift])
				Button("Save Playlist") { model.savePlaylist() }
					.keyboardShortcut("s", modifiers: [.command, .option])
				Button("Save Playlist As…") { model.savePlaylistAs() }
					.keyboardShortcut("s", modifiers: [.command, .option, .shift])
			}
			// snapshots and movies, folded into File (they were menus of
			// their own; the user's menu audit, 2026-11-18): important, not
			// for a live set; their keys work from the submenus as before
			Menu("Snapshots") {
				Button("Take Snapshot…") { model.takeSnapshot() }
					.keyboardShortcut("t")
				Button("Load Snapshot…") { model.loadSnapshots() }
					.keyboardShortcut("l")
				Divider()
				// no keys (the user's shortcut review, 2026-11-24): Windows'
				// Home, Page Up, Page Down and End, unmodified, took the lists'
				// own scrolling keys, and most Mac laptops lack them; Command-
				// Left and Right step the snapshots over the picture (OutputKeys)
				Button("First") { model.snapshotFirst() }
					.disabled(!model.hasSnapshots)
				Button("Previous") { model.snapshotPrev() }
					.disabled(!model.hasSnapshots)
				Button("Next") { model.snapshotNext() }
					.disabled(!model.hasSnapshots)
				Button("Last") { model.snapshotLast() }
					.disabled(!model.hasSnapshots)
				Divider()
				Button("Info…") { model.snapshotInfo() }
					.disabled(!model.isCurrentSnapshotValid)
			}
			Menu("Movie") {
				let ms = model.engine.movieState
				// Windows' Ctrl+M, Command-M here, was the Modulation panel's, and
				// is Minimize since 2026-11-18; Record is Command-R (2026-11-22)
				// "Movie" named in each item (the user's request, 2026-11-22): a
				// movie is Whorld's own replayable recording (.whm); a video is
				// what Export makes of it
				Button(ms.io == .writing ? "Stop Recording" : "Record Movie…") { model.toggleRecordMovie() }
					.keyboardShortcut("r")	// R for Record, free since Origin Random left it (2026-11-21); the user's request, 2026-11-22, in place of a Perform Bar button
					.disabled(ms.io == .reading)
				Button(ms.io == .reading ? "Stop Playing" : "Play Movie…") { model.togglePlayMovie() }
					.keyboardShortcut("r", modifiers: [.command, .shift])	// beside Record's Command-R (the user's shortcut review, 2026-11-24)
					.disabled(ms.io == .writing)
				Button("Rewind") { model.rewindMovie() }
					.keyboardShortcut(.home, modifiers: .command)
					.disabled(ms.io != .reading)
			}
			// every export in one place (the user's menu audit, 2026-11-18:
			// they were in File, Snapshot and Movie)
			Menu("Export") {
				Button("Image…") { model.exportImage() }	// Windows' File > Export
					.keyboardShortcut("e")
				Button("All Snapshots…") { model.exportAllSnapshots() }	// Windows' Snapshot > Export All
					.disabled(!model.hasSnapshots)
				Divider()
				let ms = model.engine.movieState
				Button("Movie as Video…") { model.exportMovieVideo() }	// (Mac addition)
					.disabled(ms.io != .reading || model.movieExportProgress != nil)
				Button("Movie as Image Sequence…") { model.exportMovie() }	// Windows' Movie > Export
					.disabled(ms.io != .reading || model.movieExportProgress != nil)
				Divider()
				Button("Audio-Reactive Video…") { model.exportAudioVideo() }
					.disabled(model.movieExportProgress != nil)
			}
			Divider()
			// the key map's files (they were buttons in the Key Map panel;
			// the user's request, 2026-11-18)
			Menu("Key Map") {
				Button("Restore Defaults") { KeyMap.shared.restoreDefaults() }
				Divider()
				Button("Import…") { KeyMap.shared.importMap() }
				Button("Export…") { KeyMap.shared.export() }
			}
		}

		CommandGroup(replacing: .undoRedo) {
			Button(model.undoManager.canUndo ? model.undoManager.undoMenuItemTitle : "Undo") { model.undo() }
				.keyboardShortcut("z")
				.disabled(!model.undoManager.canUndo)
			Button(model.undoManager.canRedo ? model.undoManager.redoMenuItemTitle : "Redo") { model.redo() }
				.keyboardShortcut("z", modifiers: [.command, .shift])
				.disabled(!model.undoManager.canRedo)
		}

		// The function keys are Windows Whorld's; on a Mac keyboard they need
		// fn (plain, they're brightness, Mission Control, media...), so the
		// menu shows Command-digit keys and the F-keys work too (SecondKeys,
		// in WhorldApp.swift).
		CommandMenu("Image") {
			// the live controls first (the user's menu audit, 2026-11-18):
			// Pause, Step and Clear were in the Window menu, as on Windows
			toggle("Pause", e.paused) { e.togglePause() }
				.keyboardShortcut(.space, modifiers: [])
			Button("Step") { e.singleStep() }
				.keyboardShortcut(.space, modifiers: .shift)
			// Shift-Delete (the user's choice, 2026-11-25; plain Delete
			// from 11-21, Cmd-K before): OutputKeys takes it first, leaving
			// it to text being edited. Cmd-Forward Delete (Windows'
			// Ctrl+Delete) works too.
			Button("Clear") { model.clear() }
				.keyboardShortcut(.delete, modifiers: .shift)
			Divider()
			// the playlist's next and previous patch, wrapping at the ends
			// (were Command-Down and Command-Up over the picture only);
			// a focused number box takes them instead (arrowOrStep)
			Button("Next Patch") { Self.arrowOrStep(down: true) { model.stepPatch(1) } }
				.keyboardShortcut(.downArrow, modifiers: .command)
				.disabled(model.playlistPatches.isEmpty)
			Button("Previous Patch") { Self.arrowOrStep(down: false) { model.stepPatch(-1) } }
				.keyboardShortcut(.upArrow, modifiers: .command)
				.disabled(model.playlistPatches.isEmpty)
			// Command plays, Option cues (the user's paradigm, 2026-11-25)
			Button("Random Patch") { model.playRandomPatch() }
				.keyboardShortcut("/")
				.disabled(model.playlistPatches.count < 2)
			// play through the playlist (the Playlist panel's Play button;
			// the user's request, 2026-11-20)
			Toggle("Auto Advance", isOn: Binding(get: { e.autoAdvancing }, set: { model.setAutoAdvance($0) }))
				.keyboardShortcut("l", modifiers: [.command, .option])
				.disabled(model.playlistPatches.isEmpty && !e.autoAdvancing)
			// V1's Edit > Patch Mode (Mac addition), one toggle: on, playing a
			// patch changes only its geometry; off, everything (Full). Was a
			// submenu on Shift-F and Shift-G, letters the key map uses (the
			// user's menu audit, 2026-11-18)
			toggle("Geometry Only", e.geometryMode) { model.setGeometryMode(!e.geometryMode) }
				.keyboardShortcut("g")	// was Option-Command-G (the user's request, 2026-11-24; Whorld has no Find to need Find Next's ⌘G)
			// the picture faded to black and back (the Perform Bar; the
			// user's request, 2026-11-20)
			toggle("Blackout", e.blackout) { model.setBlackout(!e.blackout) }
				.keyboardShortcut("b")
			// cue, then go (AppModel+Cue.swift; the user's design,
			// 2026-11-25); their keys are OutputKeys', shown in the titles
			// (a menu key would take Return and the arrows from text boxes)
			Menu("Cue") {
				Button("Go (Return)") { model.go() }
				Button("Go Now (⌘Return)") { model.go(now: true) }
				Divider()
				Button("Cue Next (⌥↓)") { model.cueStep(1) }
				Button("Cue Previous (⌥↑)") { model.cueStep(-1) }
				Button("Cue 10 Down (⌥⇧↓)") { model.cueStep(10) }
				Button("Cue 10 Up (⌥⇧↑)") { model.cueStep(-10) }
				Button("Cue First (⇧⌥⌘↑)") { model.cue(0) }
				Button("Cue Last (⇧⌥⌘↓)") { model.cue(model.playlistPatches.count - 1) }
				Button("Cue Random (⌥/)") { model.cueRandom() }
				Divider()
				Button("Pads: Next Bank") { model.bankStep(1) }
				Button("Pads: Previous Bank") { model.bankStep(-1) }
				Divider()
				Picker("Launch Timing", selection: $launchTiming) {
					ForEach(LaunchTiming.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
				}
			}
			.disabled(model.playlistPatches.isEmpty)
			Divider()
			// Cmd-1 to Cmd-9, then Cmd-0, in the Properties' order (the
			// user's request, 2026-11-24; before: Fill, Outline, Mirror,
			// Convex, Reverse, Invert Color, Rotate Hue, XOR on 1 to 8, Loop
			// Hue Shift-Cmd-7, Random Phase 9). The F-keys stay as they were.
			toggle("Fill", e.fill) { model.toggleFill() }
				.keyboardShortcut("1")	// and F6
			toggle("Outline", e.outline) { model.toggleOutline() }
				.keyboardShortcut("2")	// and F7
			// Whorld V1's X-Ray, the draw mode's XOR bit, which V2 keeps but
			// ignores (the user's request, 2026-11-23)
			toggle("XRay", e.xray) { model.toggleXRay() }
				.keyboardShortcut("3")	// and F8, V1's X-Ray key
			toggle("Mirror", e.mirror) { model.toggle(.mirror) }
				.keyboardShortcut("4")	// and F5
			toggle("Convex", e.convex) { model.toggle(.convex) }
				.keyboardShortcut("5")	// Windows' Ctrl+Tab dropped (the user's request, 2026-11-21): on the Mac it moves keyboard focus
			toggle("Reverse", e.reverse) { model.toggle(.reverse) }
				.keyboardShortcut("6")	// Windows' Ctrl+Backspace
			// not on Windows' Image menu (its Properties grid only); here the
			// Properties panel mirrors this menu, so it's in both
			toggle("Invert Color", e.invertColor) { model.toggle(.invertColor) }
				.keyboardShortcut("7")	// and F4, V1's
			Button("Rotate Hue") { model.rotateHue() }	// V1's (Mac addition)
				.keyboardShortcut("8")	// and F3
			toggle("Loop Hue", e.loopHue) { model.toggle(.loopHue) }
				.keyboardShortcut("9")	// and F2
			Button("Random Phase") { model.randomPhase() }
				.keyboardShortcut("0")	// and F9
			Divider()
			// the origin on Minus and Equals, Shift for the second of each
			// pair (the user's request, 2026-11-24; before: Center Cmd-0,
			// Drag Cmd-Minus, Random Cmd-Equals, Park Option-Cmd-0)
			Button("Origin Center") { model.originCenter() }
				.keyboardShortcut("-")
			// Mac addition (the user's request, 2026-11-20): the origin stays
			// where it is. Drag and Random, toggled off, park it too.
			Button("Origin Park") { model.setOriginMotion(.park) }
				.keyboardShortcut("-", modifiers: [.command, .shift])
			toggle("Origin Drag", e.originMotion == .drag) { model.toggleOriginDrag() }
				.keyboardShortcut("=")	// Windows' Ctrl+D, Cmd-D, dropped (the user's request, 2026-11-21)
			toggle("Origin Random", e.originMotion == .random) { model.toggleOriginRandom() }
				.keyboardShortcut("=", modifiers: [.command, .shift])	// Windows' Ctrl+R, Cmd-R, dropped (2026-11-21)
			Divider()
			toggle("Zoom Center", e.zoomCenter) { model.toggle(.zoomCenter) }
				// Windows' Shift+W until the user's menu audit (2026-11-18):
				// W is a key-map letter, so Shift then W over the picture
				// toggled this instead
				.keyboardShortcut("z", modifiers: [.command, .option])
			// Windows' Ctrl+Alt+A, Option-Command-A; in the Properties grid on
			// Windows. Out of the menu in the 2026-11-18 audit, back at the
			// user's request (2026-11-21) so its shortcut can be found.
			toggle("Antialiasing", e.antialiasing) { model.toggle(.antialiasing) }
				.keyboardShortcut("a", modifiers: [.command, .option])
		}

		// Audio response in a menu of its own, apart from the picture (the
		// user's menu audit, 2026-11-18; these were at the end of Image):
		// the rows on or off, keeping the rows' phrases with the music's,
		// where the beat comes from
		CommandMenu("Audio") {
			// Mac addition (AUDIO_PLAN.md): the Modulation panel's rows on or off
			toggle("Audio Modulation", !ModMap.shared.bypass) { ModMap.shared.bypass.toggle() }
				.keyboardShortcut("'")	// with the beat keys, Command [ ] \ (the user's request, 2026-11-19; was Command-8)
			Divider()
			// the count, to keep the rows' phrases with the music's (the
			// Modulation panel's beat buttons; Reset Bar Count, the nearest
			// bar is bar 1, is a MIDI target and /w/mod/bars only, since 2026-11-18)
			// two-key chords, the brackets and backslash side by side (the
			// user's menu audit, 2026-11-18; were Option-Command, with Shift
			// for bars): the beat with Command, the bar or the half beat
			// with Shift-Command
			Button("Reset to 1.1") { ModMap.markDownbeat() }	// the beat nearest now is the one
				.keyboardShortcut("\\", modifiers: .command)
			Button("Beat Back") { ModMap.nudge(beats: -1) }
				.keyboardShortcut("[", modifiers: .command)
			Button("Beat Forward") { ModMap.nudge(beats: 1) }
				.keyboardShortcut("]", modifiers: .command)
			Button("Bar Back") { ModMap.nudge(beats: -4) }
				.keyboardShortcut("[", modifiers: [.command, .shift])
			Button("Bar Forward") { ModMap.nudge(beats: 4) }
				.keyboardShortcut("]", modifiers: [.command, .shift])
			// half a beat, with Option-Command (the user's request, 2026-11-19;
			// was one Shift Half Beat toggle, which MIDI and OSC keep); they
			// do nothing while Ableton Link drives the beat
			Button("Half Beat Back") { ModMap.shiftHalfBeats(-1) }
				.keyboardShortcut("[", modifiers: [.command, .option])
			Button("Half Beat Forward") { ModMap.shiftHalfBeats(1) }
				.keyboardShortcut("]", modifiers: [.command, .option])
			Divider()
			// the Modulation panel's switches, kept in step with them: the
			// setting is Link_bEnabled (the panel's AppStorage)
			Toggle("Ableton Link", isOn: Binding(get: { linkEnabled }, set: {
				linkEnabled = $0
				WHLink.shared.enabled = $0
			}))
			Toggle("Tempo Follows the Beat", isOn: Binding(get: { ModMap.shared.followTempo },
				set: { ModMap.shared.followTempo = $0 }))
			// the Modulation panel is View > Modulation (⌥⌘7), with the
			// others (here too until 2026-11-19, the user's request)
		}

		// The View menu, after Audio and before Window (the user's choice,
		// 2026-11-18): Whorld's own menu, since the standard one is fixed
		// after Edit; its standard groups are emptied, so it doesn't show
		CommandGroup(replacing: .toolbar) {}
		CommandGroup(replacing: .sidebar) {}
		CommandMenu("View") {
			// Whorld's own full screen (FullScreen.swift), on Cmd-F (the user's
			// choice, 2026-11-21; Shift-Cmd-F before). It replaces AppKit's
			// automatic Enter Full Screen item, which drives macOS's full
			// screen (turned off; see AppDelegate). Ctrl-Cmd-F, macOS's usual
			// one, and F11, the Windows one, work too (SecondKeys); on most Mac
			// keyboards F11 doesn't reach apps (a media key, or fn-F11 for Show
			// Desktop).
			Button(model.isFullScreen ? "Exit Full Screen" : "Enter Full Screen") { model.toggleFullScreen() }
				.keyboardShortcut("f", modifiers: .command)
			// Full screen on another display, and while full screen on to the
			// next, through them all (Mac addition, the user's request,
			// 2026-11-21): only with more than one display
			Button(model.isFullScreen ? "Move Full Screen to Next Display" : "Enter Full Screen on Other Display") {
				model.fullScreenNextDisplay()
			}
			.keyboardShortcut("f", modifiers: [.command, .shift])
			.disabled(!model.hasOtherDisplay)
			// CMainFrame::OnWindowDetach (Windows' Window menu): beside Full
			// Screen, the other way to show the picture (the user's menu
			// audit, 2026-11-18)
			Toggle("Detach", isOn: Binding(get: { model.isDetached }, set: { _ in model.toggleDetach() }))
				.keyboardShortcut("d")	// Windows: Ctrl+F12; ⌘D beside Full Screen's ⌘F (the user's request, 2026-11-22; was ⇧⌘D)
				.disabled(model.isFullScreen)
			// Detach onto another display, and while detached on to the next
			// (Mac addition, the user's request, 2026-11-22), as Shift-Cmd-F
			Button(model.isDetached ? "Move to Next Display" : "Detach to Other Display") {
				model.detachNextDisplay()
			}
			.keyboardShortcut("d", modifiers: [.command, .shift])
			.disabled(!model.hasOtherDisplay || model.isFullScreen)
			Divider()
			// CMainFrame's ID_VIEW_BAR_ commands: show or hide a panel
			ForEach(PanelID.allCases) { id in
				Toggle(id.title, isOn: Binding(
					get: { model.layout.isShown(id) },
					set: { model.layout.setShown(id, $0) }))
					// Option-Command 1 to 9, in this order (PanelID.shortcut)
					.optionalShortcut(id.shortcut, modifiers: id.shortcutModifiers)
			}
			Divider()
			// Render Scale's submenu is gone: the stats strip has it, with
			// Automatic Quality (the user's request, 2026-11-19)
			// the stats strip became the Perform Bar (the user's request, 2026-11-20)
			Toggle("Show Perform Bar", isOn: Binding(get: { model.showStats }, set: { model.showStats = $0 }))
				.keyboardShortcut("b", modifiers: [.command, .shift])	// "Bar", beside Blackout's Command-B (2026-11-22: Option-Command-9 went to the panels, Patches joining them)
			// the Properties' chips as a row of the bar (the user's choice,
			// 2026-11-24)
			Toggle("Show Properties in Perform Bar", isOn: Binding(get: { model.showPropsBar }, set: { model.showPropsBar = $0 }))
				.keyboardShortcut("b", modifiers: [.command, .option, .shift])	// beside the bar's Shift-Command-B (the user's shortcut review, 2026-11-24)
				.disabled(!model.showStats)
			// the Perform Bar's information over the picture (InfoOverlay; the
			// user's request, 2026-11-25): ⌥⌘`, on the cheat sheet's key
			// (⌘` is macOS's next-window key)
			Toggle("Show Info Overlay", isOn: Binding(get: { model.showInfoOverlay }, set: { model.showInfoOverlay = $0 }))
				.keyboardShortcut("`", modifiers: [.command, .option])
			// the panels' key boxes (KeyBadge; the Key Map panel's Show in
			// Panels too) and tips on hover, here only since 2026-11-25 (out of
			// Settings > General and the Help menu; the user's request)
			// ⌥⌘K "keys", ⌥⌘I "info" (the user's choice, 2026-11-25; tips
			// were ⌥⌘/, now the playlist's random keys' family)
			Toggle("Show Key Map in Panels", isOn: $keyBadges)
				.keyboardShortcut("k", modifiers: [.command, .option])
			Toggle("Show Tips on Hover", isOn: Binding(get: { hoverTips }, set: {
				hoverTips = $0
				if !$0 { InfoPopover.shared.close() }	// a title's ⓘ it came from may be gone
				NotificationCenter.default.post(name: HoverTips.changed, object: nil)
			}))
				.keyboardShortcut("i", modifiers: [.command, .option])
			// the strip's Auto; beside Audio Modulation's Command-' (the
			// user's request, 2026-11-19; out of Settings > Display)
			Toggle("Automatic Quality", isOn: Binding(get: { model.autoQuality }, set: { model.autoQuality = $0 }))
				.keyboardShortcut(";")
			// on and off, and the size (out of Settings > Output, and in the
			// stats strip too; the user's request, 2026-11-19)
			Menu("Syphon") {
				Toggle("Syphon Output", isOn: Binding(get: { model.syphonEnabled }, set: { model.setSyphonEnabled($0) }))
					.keyboardShortcut("y", modifiers: [.command, .shift])	// "sYphon" (the user's shortcut review, 2026-11-24)
				Divider()
				Toggle("Match the Output", isOn: Binding(get: { model.syphonSize == nil }, set: { _ in model.setSyphonSize(nil) }))
				ForEach(AppModel.syphonPresets.indices, id: \.self) { i in
					let p = AppModel.syphonPresets[i]
					let title = "\(p.width) × \(p.height)"	// a String, not localized: no thousands separators
					Toggle(title, isOn: Binding(
						get: { model.syphonSize.map { $0 == p } ?? false },
						set: { _ in model.setSyphonSize(p) }))
				}
				let custom: (width: Int, height: Int)? = model.syphonSize.flatMap { s in AppModel.syphonPresets.contains { $0 == s } ? nil : s }
				let customTitle: String = custom.map { "Custom Size (\($0.width) × \($0.height))…" } ?? "Custom Size…"
				Toggle(customTitle, isOn: Binding(
					get: { custom != nil }, set: { _ in model.askSyphonSize() }))
			}
		}

		CommandGroup(before: .windowSize) {
			// Named layouts (Mac addition, the user's request, 2026-11-22):
			// Edit, Perform and the user's own on Control-Command-1 to 9,
			// each remembering how it was left (NamedLayouts.swift)
			let named = NamedLayouts.shared
			ForEach(Array(named.items.enumerated()), id: \.element.id) { i, item in
				Toggle(item.name, isOn: Binding(get: { named.active == item.id }, set: { _ in named.switchTo(item.id) }))
					.optionalShortcut(NamedLayouts.shortcut(i), modifiers: [.command, .control])
			}
			Divider()
			Button("Save Layout As…") { named.saveCurrentAs() }
			Button("Reset Layout…") { model.resetLayout() }
			if named.current?.isBuiltIn == false {
				Button("Rename Layout…") { named.renameCurrent() }
				Button("Delete Layout…") { named.deleteCurrent() }
			}
			Button("Import Layout…") { model.importLayout() }
			Button("Export Layout…") { model.exportLayout() }
			Divider()
			Button("Show All Panels") { model.showAllPanels() }
				.keyboardShortcut("p", modifiers: [.command, .option])
			Divider()
		}
	}
}

/// The About box and Help menu (kept apart: a Commands body holds at most
/// ten groups).
struct HelpCommands: Commands {
	var body: some Commands {
		CommandGroup(replacing: .appInfo) {
			Button("About Whorld") { Self.showAbout() }
			Button("Check for Updates…") { UpdateChecker.shared.checkNow() }
		}

		CommandGroup(replacing: .help) {
			Button("Whorld Help") { Self.openHelp("index.html") }
				.keyboardShortcut("?")
			Button("Tips and Gestures") { Self.openHelp("tips.html") }
			Button("Whorld Manual") { Self.openHelp("frames.html") }
			Divider()
			Button("Report a Bug…") { Self.openIssueForm("bug_report.yml") }
			Button("Request a Feature…") { Self.openIssueForm("feature_request.yml") }
			Divider()
			Button("Whorld for Mac on GitHub") { NSWorkspace.shared.open(Self.sourceURL) }
			Button("Original Whorld Website") { NSWorkspace.shared.open(URL(string: "https://whorld.org")!) }
		}
	}

	static let sourceURL = URL(string: "https://github.com/bzsqrl/Whorld-mac")!

	/// Opens one of the repository's issue forms (.github/ISSUE_TEMPLATE) in
	/// the browser, with the Whorld version, macOS version and Mac filled in
	/// (a form's fields take their values from URL parameters named by id).
	static func openIssueForm(_ template: String) {
		let info = Bundle.main.infoDictionary ?? [:]
		let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
		let os = ProcessInfo.processInfo.operatingSystemVersion
		let macos = os.patchVersion > 0
			? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)" : "\(os.majorVersion).\(os.minorVersion)"
		var c = URLComponents(url: sourceURL.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
		c.queryItems = [
			URLQueryItem(name: "template", value: template),
			URLQueryItem(name: "version", value: version),
			URLQueryItem(name: "macos", value: macos),
			URLQueryItem(name: "mac", value: chipName()),
		]
		if let url = c.url {
			NSWorkspace.shared.open(url)
		}
	}

	/// The processor, such as "Apple M1 Max" or "Intel(R) Core(TM) i7-…".
	private static func chipName() -> String {
		var size = 0
		guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
		var buf = [CChar](repeating: 0, count: size)
		guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else { return "" }
		return String(cString: buf)
	}

	/// Opens a page of the bundled help (Contents/Resources/Help, copied by
	/// the Copy Help build phase) in the default browser.
	static func openHelp(_ page: String) {
		guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Help") else { return }
		NSWorkspace.shared.open(dir.appendingPathComponent(page))
	}

	/// The standard About panel with the credits and license notice
	/// (the Windows About dialog, IDD_ABOUTBOX, credits Chris Korda).
	static func showAbout() {
		let html = """
			<meta charset="utf-8"><div style="font: 11px -apple-system; text-align: center">
			<p>Whorld by Chris Korda<br>macOS port by Jeff Matson and Claude<br>
			Based on Whorld V2 \(WHControls.upstreamBaseline())</p>
			<p>Whorld is free software: you can redistribute it and/or modify it under the terms of the
			<a href="https://www.gnu.org/licenses/gpl-3.0.html">GNU General Public License</a>
			version 3 or later. It comes with ABSOLUTELY NO WARRANTY.</p>
			<p><a href="\(sourceURL.absoluteString)">Source code</a> ·
			<a href="https://github.com/victimofleisure/Whorld">Original Whorld</a></p>
			<p>Syphon output uses Syphon.framework, copyright 2010 bangnoise (Tom Butterworth)
			&amp; vade (Anton Marini), under its
			<a href="https://github.com/Syphon/Syphon-Framework/blob/main/License.txt">BSD license</a>.</p>
			<p>Ableton Link support uses Ableton's Link library, copyright 2016 Ableton AG, Berlin, under the
			<a href="https://github.com/Ableton/link/blob/master/LICENSE.md">GNU General Public License</a>
			version 2 or later.</p>
			</div>
			"""
		let credits = NSMutableAttributedString(html: Data(html.utf8), documentAttributes: nil) ?? NSMutableAttributedString()
		credits.addAttribute(.foregroundColor, value: NSColor.labelColor,
			range: NSRange(location: 0, length: credits.length))
		NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
		NSApp.activate(ignoringOtherApps: true)
	}
}

extension View {
	/// a keyboard shortcut, or none for a nil key
	@ViewBuilder func optionalShortcut(_ key: KeyEquivalent?, modifiers: EventModifiers) -> some View {
		if let key {
			keyboardShortcut(key, modifiers: modifiers)
		} else {
			self
		}
	}
}
