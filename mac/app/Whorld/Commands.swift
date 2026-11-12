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
	@ObservedObject var model: AppModel
	@Environment(\.openWindow) private var openWindow

	private func fkey(_ code: Int) -> KeyEquivalent {
		KeyEquivalent(Character(UnicodeScalar(UInt32(code))!))
	}

	/// A recent file's name, with its folder if another recent file has the same name.
	static func recentTitle(_ url: URL, in all: [URL]) -> String {
		let name = url.lastPathComponent
		let same = all.filter { $0.lastPathComponent == name }.count > 1
		return same ? "\(name) — \(url.deletingLastPathComponent().lastPathComponent)" : name
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
		// refresh check marks, titles and enabled states after changes
		let _ = (model.changes.menus.n, model.changes.main.n, model.changes.media.n, model.changes.playlist.n)

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
			Button("Patch Author…") { model.editPatchAuthor() }
			Divider()
			Button("Take Snapshot…") { model.takeSnapshot() }
				.keyboardShortcut("t")
			Button("Load Snapshot…") { model.loadSnapshots() }
				.keyboardShortcut("l")
			Button("Export…") { model.exportImage() }
				.keyboardShortcut("e")
		}

		CommandMenu("Snapshot") {
			Button("First") { model.snapshotFirst() }
				.keyboardShortcut(.home, modifiers: [])
				.disabled(!model.hasSnapshots)
			Button("Previous") { model.snapshotPrev() }
				.keyboardShortcut(.pageUp, modifiers: [])
				.disabled(!model.hasSnapshots)
			Button("Next") { model.snapshotNext() }
				.keyboardShortcut(.pageDown, modifiers: [])
				.disabled(!model.hasSnapshots)
			Button("Last") { model.snapshotLast() }
				.keyboardShortcut(.end, modifiers: [])
				.disabled(!model.hasSnapshots)
			Divider()
			Button("Export All…") { model.exportAllSnapshots() }
				.disabled(!model.hasSnapshots)
			Button("Info…") { model.snapshotInfo() }
				.disabled(!model.isCurrentSnapshotValid)
		}

		CommandMenu("Movie") {
			let ms = model.engine.movieState
			Button(ms.io == .writing ? "Stop Recording" : "Record…") { model.toggleRecordMovie() }
				.keyboardShortcut("m")
				.disabled(ms.io == .reading)
			Button(ms.io == .reading ? "Stop Playing" : "Play…") { model.togglePlayMovie() }
				// Windows' Ctrl+Shift+M would be Shift-Cmd-M, the Master panel's
				.keyboardShortcut("m", modifiers: [.control, .command])
				.disabled(ms.io == .writing)
			Button("Rewind") { model.rewindMovie() }
				.keyboardShortcut(.home, modifiers: .command)
				.disabled(ms.io != .reading)
			Divider()
			Button("Export Image Sequence…") { model.exportMovie() }
				.disabled(ms.io != .reading || model.movieExportProgress != nil)
			Button("Export Video…") { model.exportMovieVideo() }
				.disabled(ms.io != .reading || model.movieExportProgress != nil)
		}

		CommandGroup(replacing: .undoRedo) {
			Button(model.undoManager.canUndo ? model.undoManager.undoMenuItemTitle : "Undo") { model.undo() }
				.keyboardShortcut("z")
				.disabled(!model.undoManager.canUndo)
			Button(model.undoManager.canRedo ? model.undoManager.redoMenuItemTitle : "Redo") { model.redo() }
				.keyboardShortcut("z", modifiers: [.command, .shift])
				.disabled(!model.undoManager.canRedo)
		}

		CommandMenu("Playlist") {
			Button("New Playlist") { model.newPlaylist() }
				.keyboardShortcut("n", modifiers: [.command, .shift])
			Button("Open Playlist…") { model.openPlaylist() }
				.keyboardShortcut("o", modifiers: [.command, .shift])
			Button("Save Playlist") { model.savePlaylist() }
				.keyboardShortcut("s", modifiers: [.command, .option])
			Button("Save Playlist As…") { model.savePlaylistAs() }
			Divider()
			Toggle("MIDI Learn", isOn: Binding(get: { model.midiLearn }, set: { model.midiLearn = $0 }))
				.keyboardShortcut("l", modifiers: [.command, .shift])
		}

		CommandMenu("Image") {
			toggle("Fill", e.fill) { model.toggleFill() }
				.keyboardShortcut(fkey(NSF6FunctionKey), modifiers: [])
			toggle("Outline", e.outline) { model.toggleOutline() }
				.keyboardShortcut(fkey(NSF7FunctionKey), modifiers: [])
			toggle("Mirror", e.mirror) { model.toggle(.mirror) }
				.keyboardShortcut(fkey(NSF5FunctionKey), modifiers: [])
			Divider()
			toggle("Reverse", e.reverse) { model.toggle(.reverse) }
				.keyboardShortcut(.delete, modifiers: .command)
			toggle("Convex", e.convex) { model.toggle(.convex) }
				.keyboardShortcut(.tab, modifiers: .control)
			toggle("Loop Hue", e.loopHue) { model.toggle(.loopHue) }
				.keyboardShortcut(fkey(NSF2FunctionKey), modifiers: [])
			Button("Rotate Hue") { model.rotateHue() }	// V1's (Mac addition)
				.keyboardShortcut(fkey(NSF3FunctionKey), modifiers: [])
			toggle("Zoom Center", e.zoomCenter) { model.toggle(.zoomCenter) }
				.keyboardShortcut("w", modifiers: .shift)
			toggle("Antialiasing", e.antialiasing) { model.toggle(.antialiasing) }
				.keyboardShortcut("a", modifiers: [.command, .option])
			// not on Windows' Image menu (its Properties grid only); here the
			// Properties panel mirrors this menu, so it's in both
			toggle("Invert Color", e.invertColor) { model.toggle(.invertColor) }
				.keyboardShortcut(fkey(NSF4FunctionKey), modifiers: [])	// V1's
			Divider()
			Button("Origin Center") { model.originCenter() }
				.keyboardShortcut("0")
			toggle("Origin Drag", e.originMotion == .drag) { model.toggleOriginDrag() }
				.keyboardShortcut("d")
			toggle("Origin Random", e.originMotion == .random) { model.toggleOriginRandom() }
				.keyboardShortcut("r")
			Divider()
			Button("Random Phase") { e.randomPhase() }
				.keyboardShortcut(fkey(NSF9FunctionKey), modifiers: [])
		}

		CommandGroup(after: .toolbar) {
			// Whorld's own full screen (FullScreen.swift), on Shift-Cmd-F (the
			// user's choice; Ctrl-Cmd-F, macOS's usual one, is Show Frame Rate).
			// It replaces AppKit's automatic Enter Full Screen item,
			// which drives macOS's full screen (turned off; see AppDelegate).
			// F11, the Windows shortcut, is on the Window menu's item; on most
			// Mac keyboards it doesn't reach apps (a media key, or fn-F11 for
			// Show Desktop).
			Button(model.isFullScreen ? "Exit Full Screen" : "Enter Full Screen") { model.toggleFullScreen() }
				.keyboardShortcut("f", modifiers: [.command, .shift])
			Divider()
			// CMainFrame's ID_VIEW_BAR_ commands: show or hide a panel
			ForEach(PanelID.allCases) { id in
				Toggle(id.title, isOn: Binding(
					get: { model.layout.isShown(id) },
					set: { model.layout.setShown(id, $0) }))
					.keyboardShortcut(id.shortcut, modifiers: [.command, .shift])
			}
			Divider()
			Toggle("Full Resolution", isOn: $model.fullResolution)
			Toggle("Show Frame Rate", isOn: $model.showFrameRate)
				.keyboardShortcut("f", modifiers: [.control, .command])
			Toggle("Syphon Output", isOn: Binding(get: { model.syphonEnabled }, set: { model.setSyphonEnabled($0) }))
			Divider()
		}

		CommandGroup(before: .windowSize) {
			toggle("Pause", e.paused) {
				// Space pressed while a Properties row has focus toggles the row
				let ev = NSApp.currentEvent
				if ev?.type == .keyDown, ev?.charactersIgnoringModifiers == " ",
					let take = model.keyboardSpaceAction, take() {
					return
				}
				e.togglePause()
			}
				.keyboardShortcut(.space, modifiers: [])
			Button("Step") { e.singleStep() }
				.keyboardShortcut(.space, modifiers: .shift)
			Button("Clear") { e.clear() }
				.keyboardShortcut(.deleteForward, modifiers: .command)
			// CMainFrame::OnWindowDetach
			Toggle("Detach", isOn: Binding(get: { model.isDetached }, set: { _ in model.toggleDetach() }))
				.keyboardShortcut("d", modifiers: [.command, .shift])	// Windows: Ctrl+F12
				.disabled(model.isFullScreen)
			Divider()
			Button("Show All Panels") { model.showAllPanels() }
				.keyboardShortcut("p", modifiers: [.command, .option])
			Button("Reset Layout…") { model.resetLayout() }
			Button("Save Layout…") { model.saveLayout() }
			Button("Open Layout…") { model.openLayout() }
			Button("Key Map…") { openWindow(id: "keymap") }	// keys held over the picture
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
			</div>
			"""
		let credits = NSMutableAttributedString(html: Data(html.utf8), documentAttributes: nil) ?? NSMutableAttributedString()
		credits.addAttribute(.foregroundColor, value: NSColor.labelColor,
			range: NSRange(location: 0, length: credits.length))
		NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
		NSApp.activate(ignoringOtherApps: true)
	}
}
