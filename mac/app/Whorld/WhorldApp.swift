// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
	// Whorld patch (.whp), declared in Info.plist
	static let whorldPatch = UTType(importedAs: "io.github.bzsqrl.whorld.patch", conformingTo: .data)
	// Whorld playlist (.whl), declared in Info.plist
	static let whorldPlaylist = UTType(importedAs: "io.github.bzsqrl.whorld.playlist", conformingTo: .data)
}

/// Main property indices (WhorldBase MAIN_*)
enum MainProp: Int {
	case origin, drawMode, orgMotion, hue, mirror, reverse, convex, invertColor, loopHue, zoomCenter, antialiasing
}

/// Master property indices (WhorldBase MASTER_*)
enum MasterProp: Int {
	case speed, zoom, damping, trail, rings, tempo, hueSpan, canvasScale, copies, spread
}

/// The frame-rate overlay's text (see AppModel.stats).
@MainActor
final class StatsModel: ObservableObject {
	@Published var text = ""
}

/// App state shared by the windows, menus and app delegate. All document
/// edits go through here so they're undoable, as in CWhorldDoc.
@MainActor
final class AppModel: ObservableObject {
	static let shared = AppModel()
	static let logStats = ProcessInfo.processInfo.environment["WHORLD_STATS"] == "1"

	let engine = WHEngine()
	let undoManager = UndoManager()
	@Published private(set) var title = "Untitled"
	@Published var showFrameRate = false
	@Published var fullResolution = true
	/// Frame statistics, published on their own: a change to AppModel
	/// rebuilds every open panel, which with Parameters, Master, Globals and
	/// Properties open blocked the main thread for about 100 ms. Done once a
	/// second, that cost several display refreshes each time (a stutter).
	let stats = StatsModel()
	/// Set while a Properties row has focus: Space (the Pause shortcut,
	/// which menus see before any view) goes to the row instead. Returns
	/// false if it didn't take it (its window isn't the key window).
	var keyboardSpaceAction: (() -> Bool)?
	/// the workspace's panels and the output's place (Workspace.swift)
	let layout = LayoutModel()
	private let outputWindow = OutputWindowController()
	private var layoutWatch: AnyCancellable?
	private var didFitWorkspace = false
	/// Bumped after every change so views and menus refresh.
	@Published private(set) var revision = 0

	/// Undo coalescing key of the edit on top of the undo stack
	/// (CUndoManager::NotifyUndoableEdit with UE_COALESCE).
	var coalesceKey: String?

	private init() {
		engine.statsHandler = { [weak self] in
			guard let self else { return }
			let e = self.engine
			guard self.showFrameRate || Self.logStats else { return }
			let gpu = e.gpuMilliseconds > 0 ? String(format: " · gpu %.1f ms", e.gpuMilliseconds) : ""
			let text = String(format: "%.0f fps · draw %.1f ms%@ · %d Hz · %ld missed · %ld rings · %@",
				e.framesPerSecond, e.renderMilliseconds, gpu, e.refreshRate, e.missedFrames, e.ringCount,
				e.rendererName)
			if self.showFrameRate {
				self.stats.text = text
			}
			if Self.logStats {	// WHORLD_STATS=1: also print, for measuring
				FileHandle.standardError.write(Data((text + "\n").utf8))
			}
		}
		undoManager.levelsOfUndo = 100
		// menus show the layout (they observe AppModel)
		layoutWatch = layout.objectWillChange.sink { [weak self] _ in
			DispatchQueue.main.async { self?.changed() }
		}
		outputWindow.onClose = { [weak self] in	// closing the output window docks it
			guard let self, self.layout.layout.detached else { return }
			self.outputWindow.hide()
			self.layout.layout.detached = false
		}
		engine.setSnapshotLetterbox(Preferences.snapshotLetterbox)
		engine.preferMetal = Preferences.preferMetal
		engine.midiInputName = Preferences.midiInputName
		engine.movieErrorHandler = { message in
			let alert = NSAlert()
			alert.messageText = "Movie error"
			alert.informativeText = message
			alert.runModal()
		}
		engine.movieStateHandler = { [weak self] in self?.changed() }	// the movie bar
		engine.midiHandler = { [weak self] kind, value in
			self?.onMidi(kind: kind, value: value)
		}
	}

	// MARK: MIDI and mappings

	// MARK: Phase 6 state (see Media.swift)
	/// Snapshots loaded with Load Snapshot (CMainFrame::m_aSnapshotPath).
	@Published var snapshotPaths: [URL] = []
	@Published var currentSnapshot = 0
	/// Index of the playing playlist patch (CPlaylistBar::m_iPlayingPatch).
	@Published var playingPatch = -1
	@Published var playlistSelection = Set<Int>()
	@Published var movieExportProgress: (done: Int64, total: Int64)? = nil

	/// Mapping rows selected in the MIDI Mapping window, for learn.
	@Published var mappingSelection = Set<Int>()
	/// True while the MIDI Mapping window is the key window (learn needs it).
	var mappingWindowIsKey = false
	@Published private(set) var playlistTitle = "Untitled Playlist"
	@Published var playlistModified = false
	private(set) var playlistURL: URL?
	private var learnSelection = Set<Int>()

	var midiLearn: Bool {
		get { engine.midiLearn }
		set { engine.midiLearn = newValue; changed() }
	}

	var mappings: [WHMappingData] {
		(0..<engine.mappingCount()).map { engine.mapping(at: $0) }
	}

	/// Replaces all mappings, undoably. Consecutive edits with the same key
	/// coalesce, as CMappingBar's undo does for repeated property edits.
	func setMappings(_ new: [WHMappingData], key: String, title: String) {
		let old = mappings
		recordUndo(key: "mapping " + key, title: title) { [weak self] in
			self?.setMappings(old, key: key, title: title)
		}
		new.withUnsafeBufferPointer { engine.setMappings($0.baseAddress, count: $0.count) }
		playlistModified = true
		changed()
	}

	func setMapping(_ index: Int, _ m: WHMappingData, column: String) {
		var arr = mappings
		guard index < arr.count else { return }
		arr[index] = m
		setMappings(arr, key: "\(index) \(column)", title: "Mapping " + column)
	}

	func insertMapping() {
		var arr = mappings
		let at = (mappingSelection.max() ?? arr.count - 1) + 1
		arr.insert(WHMappingInfo.defaultMapping(), at: min(at, arr.count))
		setMappings(arr, key: "insert \(arr.count)", title: "Insert Mapping")
		mappingSelection = [min(at, arr.count - 1)]
	}

	func deleteMappings() {
		guard !mappingSelection.isEmpty else { return }
		let arr = mappings.enumerated().filter { !mappingSelection.contains($0.offset) }.map { $0.element }
		setMappings(arr, key: "delete \(arr.count)", title: "Delete Mapping")
		mappingSelection = []
	}

	private func onMidi(kind: Int, value: UInt32) {
		switch kind {
		case 2:	// play patch (Patch target)
			playPatch(Int(value))
		case 3:	// learn (CMappingBar::OnMidiEvent)
			learn(value)
		default:
			break
		}
		changed()
	}

	private func learn(_ message: UInt32) {
		guard engine.midiLearn, mappingWindowIsKey, !mappingSelection.isEmpty else { return }
		var arr = mappings
		var changedAny = false
		for i in mappingSelection where i < arr.count {
			var m = arr[i]
			if WHMappingInfo.learn(message, into: &m) {
				changedAny = changedAny || m.event != arr[i].event || m.channel != arr[i].channel
					|| m.control != arr[i].control
				arr[i] = m
			}
		}
		guard changedAny else { return }
		// a new selection starts a new undo step; the same selection coalesces
		if mappingSelection != learnSelection {
			learnSelection = mappingSelection
			coalesceKey = nil
		}
		let sel = mappingSelection.sorted().map(String.init).joined(separator: ",")
		setMappings(arr, key: "learn " + sel, title: mappingSelection.count > 1 ? "Learn Multiple" : "Learn")
	}

	// MARK: Playlist

	func newPlaylist() {
		guard confirmDiscardPlaylist() else { return }
		engine.newPlaylist()
		playlistURL = nil
		playingPatch = -1
		playlistTitle = "Untitled Playlist"
		playlistModified = false
		mappingSelection = []
		resetUndo()
		changed()
	}

	func openPlaylist() {
		guard confirmDiscardPlaylist() else { return }
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.whorldPlaylist]
		guard panel.runModal() == .OK, let url = panel.url else { return }
		openPlaylist(url)
	}

	func openPlaylist(_ url: URL) {
		do {
			try engine.openPlaylist(atPath: url.path)
			playlistURL = url
			playingPatch = -1
			checkMissingPatches()
			playlistTitle = url.deletingPathExtension().lastPathComponent
			playlistModified = false
			mappingSelection = []
			resetUndo()
			NSDocumentController.shared.noteNewRecentDocumentURL(url)
		} catch {
			NSAlert(error: error).runModal()
		}
		changed()
	}

	@discardableResult
	func savePlaylist() -> Bool {
		if let url = playlistURL {
			return writePlaylist(to: url)
		}
		return savePlaylistAs()
	}

	@discardableResult
	func savePlaylistAs() -> Bool {
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.whorldPlaylist]
		panel.nameFieldStringValue = playlistTitle + ".whl"
		guard panel.runModal() == .OK, let url = panel.url else { return false }
		return writePlaylist(to: url)
	}

	private func writePlaylist(to url: URL) -> Bool {
		do {
			try engine.savePlaylist(toPath: url.path)
			playlistURL = url
			playlistTitle = url.deletingPathExtension().lastPathComponent
			playlistModified = false
			changed()
			return true
		} catch {
			NSAlert(error: error).runModal()
			return false
		}
	}

	func confirmDiscardPlaylist() -> Bool {
		guard playlistModified else { return true }
		let alert = NSAlert()
		alert.messageText = "Do you want to save the changes you made to the playlist \"\(playlistTitle)\"?"
		alert.informativeText = "This includes its MIDI mappings."
		alert.addButton(withTitle: "Save")
		alert.addButton(withTitle: "Cancel")
		alert.addButton(withTitle: "Don't Save")
		switch alert.runModal() {
		case .alertFirstButtonReturn: return savePlaylist()
		case .alertThirdButtonReturn: return true
		default: return false
		}
	}

	/// Resolves a playlist's patch path. Windows playlists store Windows
	/// paths; if the path doesn't exist here, look for the same file name
	/// next to the playlist (full missing-file handling is Phase 6).
	func resolvePatchPath(_ stored: String) -> URL? {
		let fm = FileManager.default
		if fm.fileExists(atPath: stored) {
			return URL(fileURLWithPath: stored)
		}
		let name = stored.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? stored
		if let dir = playlistURL?.deletingLastPathComponent() {
			let candidate = dir.appendingPathComponent(name)
			if fm.fileExists(atPath: candidate.path) {
				return candidate
			}
		}
		return nil
	}

	// CPlaylistBar::Play (from the MIDI Patch target)
	func playPatch(_ index: Int) {
		let paths = engine.playlistPatches
		guard index >= 0, index < paths.count, let url = resolvePatchPath(paths[index]) else { return }
		// read first; then the save prompt, unless full screen
		if !isFullScreen && !confirmDiscard() {
			return
		}
		if engine.playPatch(atPath: url.path) {
			playingPatch = index
			resetUndo()
			updateTitle()
			changed()
		}
	}

	func changed() {
		revision &+= 1
	}

	// MARK: Undo

	/// Registers an undo step unless it coalesces with the previous one:
	/// consecutive edits of the same thing are one step, as on Windows.
	func recordUndo(key: String, title: String, restore: @escaping () -> Void) {
		let replaying = undoManager.isUndoing || undoManager.isRedoing
		if !replaying && key == coalesceKey && undoManager.canUndo {
			return
		}
		undoManager.registerUndo(withTarget: self) { _ in restore() }
		undoManager.setActionName(title)
		coalesceKey = replaying ? nil : key
	}

	func undo() {
		coalesceKey = nil
		undoManager.undo()
		changed()
	}

	func redo() {
		coalesceKey = nil
		undoManager.redo()
		changed()
	}

	func resetUndo() {
		undoManager.removeAllActions()
		coalesceKey = nil
	}

	// CWhorldDoc::GetUndoTitle
	static func paramTitle(_ iParam: Int, _ prop: WHParamProperty) -> String {
		var t = WHControls.paramName(iParam)
		if prop != .val {
			t += " " + WHControls.paramPropertyName(prop.rawValue)
		}
		return t
	}

	// MARK: Document edits

	func setParam(_ iParam: Int, _ prop: WHParamProperty, _ value: Double) {
		let old = engine.paramValue(iParam, property: prop)
		guard old != value else { return }
		recordUndo(key: "param \(iParam) \(prop.rawValue)", title: Self.paramTitle(iParam, prop)) { [weak self] in
			self?.setParam(iParam, prop, old)
		}
		engine.setParamValue(value, param: iParam, property: prop)
		changed()
	}

	func setMaster(_ iProp: Int, _ value: Double) {
		let old = engine.masterValue(iProp)
		guard old != value else { return }
		recordUndo(key: "master \(iProp)", title: WHControls.masterName(iProp)) { [weak self] in
			self?.setMaster(iProp, old)
		}
		engine.setMasterValue(value, prop: iProp)
		changed()
	}

	// CWhorldDoc::SetZoom
	func setZoom(_ zoom: Double, damping: Bool = true) {
		let old = engine.masterValue(MasterProp.zoom.rawValue)
		guard old != zoom else { return }
		recordUndo(key: "zoom", title: WHControls.masterName(MasterProp.zoom.rawValue)) { [weak self] in
			self?.setZoom(old, damping: false)
		}
		engine.setZoom(zoom, damping: damping)
		changed()
	}

	// CWhorldDoc::SetOrigin: always sent, as on Windows. The document's
	// origin doesn't follow Drag or Random, so an equality test against it
	// skipped Origin Center after dragging; undo restores the live origin.
	func setOrigin(_ pt: CGPoint) {
		let old = engine.liveOrigin
		recordUndo(key: "main \(MainProp.origin.rawValue)", title: WHControls.mainName(MainProp.origin.rawValue)) { [weak self] in
			self?.setOrigin(old)
		}
		engine.origin = pt
		changed()
	}

	func setHue(_ hue: Double) {
		let old = engine.hue
		guard old != hue else { return }
		recordUndo(key: "main \(MainProp.hue.rawValue)", title: WHControls.mainName(MainProp.hue.rawValue)) { [weak self] in
			self?.setHue(old)
		}
		engine.hue = hue
		changed()
	}

	func setDrawMode(_ mode: UInt32) {
		let old = engine.drawMode
		guard old != mode else { return }
		recordUndo(key: "main \(MainProp.drawMode.rawValue)", title: WHControls.mainName(MainProp.drawMode.rawValue)) { [weak self] in
			self?.setDrawMode(old)
		}
		engine.setDrawMode(mode)
		changed()
	}

	func setOriginMotion(_ motion: WHOriginMotion) {
		let old = engine.originMotion
		guard old != motion else { return }
		recordUndo(key: "main \(MainProp.orgMotion.rawValue)", title: WHControls.mainName(MainProp.orgMotion.rawValue)) { [weak self] in
			self?.setOriginMotion(old)
		}
		engine.setOriginMotion(motion)
		changed()
	}

	/// Toggles a boolean main property; undo toggles it back.
	func toggle(_ prop: MainProp) {
		recordUndo(key: "main \(prop.rawValue)", title: WHControls.mainName(prop.rawValue)) { [weak self] in
			self?.toggle(prop)
		}
		switch prop {
		case .mirror: engine.toggleMirror()
		case .reverse: engine.toggleReverse()
		case .convex: engine.toggleConvex()
		case .invertColor: engine.invertColor.toggle()
		case .loopHue: engine.toggleLoopHue()
		case .zoomCenter: engine.toggleZoomCenter()
		case .antialiasing: engine.toggleAntialiasing()
		default: assertionFailure("not a boolean main property")
		}
		changed()
	}

	func isOn(_ prop: MainProp) -> Bool {
		switch prop {
		case .mirror: return engine.mirror
		case .reverse: return engine.reverse
		case .convex: return engine.convex
		case .invertColor: return engine.invertColor
		case .loopHue: return engine.loopHue
		case .zoomCenter: return engine.zoomCenter
		case .antialiasing: return engine.antialiasing
		default: return false
		}
	}

	static let drawModeFill: UInt32 = 0x01		// DM_FILL
	static let drawModeOutline: UInt32 = 0x02	// DM_OUTLINE

	func toggleFill() { setDrawMode(engine.drawMode ^ Self.drawModeFill) }
	func toggleOutline() { setDrawMode(engine.drawMode ^ Self.drawModeOutline) }

	// CWhorldDoc::OnImageOriginCenter
	func originCenter() {
		setOriginMotion(.park)
		setOrigin(CGPoint(x: 0.5, y: 0.5))
	}

	func toggleOriginDrag() { setOriginMotion(engine.originMotion == .drag ? .park : .drag) }
	func toggleOriginRandom() { setOriginMotion(engine.originMotion == .random ? .park : .random) }

	// CWhorldDoc::OnMouseWheel: zoom, or damping with Shift, in normalized
	// slider space (CWhorldDoc::OffsetMasterProp)
	func wheel(notches: Double, shift: Bool) {
		let delta = notches * Preferences.wheelSense / 100
		let iProp = (shift ? MasterProp.damping : MasterProp.zoom).rawValue
		let old = engine.masterValue(iProp)
		var norm = WHControls.masterNorm01(iProp, value: old) + delta
		norm = min(max(norm, 0), 1)
		let value = WHControls.masterDenorm01(iProp, value: norm)
		guard value != old else { return }
		if shift {
			setMaster(iProp, value)
		} else {
			setZoom(value)
		}
	}

	// MARK: Files

	func updateTitle() {
		if let path = engine.patchPath {
			title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
		} else {
			title = "Untitled"
		}
	}

	var windowTitle: String {
		_ = revision
		return engine.modified ? title + " — Edited" : title
	}

	func newPatch() {
		guard confirmDiscard() else { return }
		engine.newPatch()
		resetUndo()
		updateTitle()
		changed()
	}

	func open(_ url: URL) {
		guard confirmDiscard() else { return }
		do {
			try engine.openPatch(atPath: url.path)
			resetUndo()
			NSDocumentController.shared.noteNewRecentDocumentURL(url)
		} catch {
			NSAlert(error: error).runModal()
		}
		updateTitle()
		changed()
	}

	func showOpenPanel() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.whorldPatch]
		panel.allowsMultipleSelection = false
		if panel.runModal() == .OK, let url = panel.url {
			open(url)
		}
	}

	@discardableResult
	func save() -> Bool {
		if let path = engine.patchPath {
			return write(to: URL(fileURLWithPath: path))
		}
		return saveAs()
	}

	@discardableResult
	func saveAs() -> Bool {
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.whorldPatch]
		panel.nameFieldStringValue = title + ".whp"
		guard panel.runModal() == .OK, let url = panel.url else { return false }
		return write(to: url)
	}

	private func write(to url: URL) -> Bool {
		do {
			try engine.savePatch(toPath: url.path)
			NSDocumentController.shared.noteNewRecentDocumentURL(url)
			updateTitle()
			changed()
			return true
		} catch {
			NSAlert(error: error).runModal()
			return false
		}
	}

	/// Asks to save unsaved changes. Returns false if the user cancels.
	func confirmDiscard() -> Bool {
		guard engine.modified else { return true }
		let alert = NSAlert()
		alert.messageText = "Do you want to save the changes you made to \"\(title)\"?"
		alert.informativeText = "Your changes will be lost if you don't save them."
		alert.addButton(withTitle: "Save")
		alert.addButton(withTitle: "Cancel")
		alert.addButton(withTitle: "Don't Save")
		switch alert.runModal() {
		case .alertFirstButtonReturn: return save()
		case .alertThirdButtonReturn: return true
		default: return false
		}
	}

	// CMainFrame::OnWindowFullscreen: full screen on the display of the
	// window that shows the output (the workspace, or the detached window)
	private let fullScreen = FullScreenController()
	var isFullScreen: Bool { fullScreen.isFullScreen }

	func toggleFullScreen() {
		if fullScreen.isFullScreen {
			fullScreen.exit(engine: engine)
			pressDrag = nil
			// Each time full screen ends (however: Esc, the shortcut, the
			// display going away), the origin goes back to the middle and
			// stays there (Image > Origin Center).
			originCenter()
		} else {
			let from = layout.layout.detached ? outputWindow.window : mainWindow
			fullScreen.enter(from: from, engine: engine, fullResolution: fullResolution) { [weak self] in
				self?.toggleFullScreen()
			}
		}
		changed()
	}

	/// Where a press on the full-screen picture started: the origin motion and
	/// origin to restore on undo. Nil when no press is moving the origin.
	private var pressDrag: (motion: WHOriginMotion, origin: CGPoint)?
	private var pressCount = 0

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
			engine.setOriginMotion(.drag)
		} else if let p = pressDrag {
			pressDrag = nil
			engine.setOriginMotion(.park)
			pressCount += 1
			recordUndo(key: "origin press \(pressCount)", title: WHControls.mainName(MainProp.origin.rawValue)) { [weak self] in
				self?.setOriginMotion(p.motion)
				self?.setOrigin(p.origin)
			}
			changed()
		}
	}

	// MARK: Workspace

	var isDetached: Bool { layout.layout.detached }

	/// Window > Detach (CMainFrame::OnWindowDetach): the output to a window of
	/// its own, or back to the workspace. Not while full screen, as on Windows.
	func toggleDetach() {
		guard !isFullScreen else { return }
		if layout.layout.detached {
			outputWindow.hide()
			layout.layout.detached = false
		} else {
			layout.layout.detached = true
			outputWindow.show(model: self, near: mainWindow?.frame)
		}
	}

	/// Window > Show All Panels: every panel in the workspace, and the
	/// workspace filling its display. A detached output stays where it is.
	func showAllPanels() {
		layout.showAll()
		fitWorkspace()
	}

	/// Window > Reset Layout (CMainFrame::OnWindowResetLayout, which asks
	/// first, as this does).
	func resetLayout() {
		let alert = NSAlert()
		alert.messageText = "Reset the layout?"
		alert.informativeText = "All panels go back to their standard places and sizes."
		alert.addButton(withTitle: "Reset")
		alert.addButton(withTitle: "Cancel")
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		layout.reset()
		fitWorkspace()
	}

	/// The workspace fills its display's visible area, the panes at their
	/// starting sizes.
	private func fitWorkspace() {
		guard let w = mainWindow, let screen = w.screen ?? NSScreen.main else { return }
		w.setFrame(screen.visibleFrame, display: true, animate: true)
		layout.arrangeGeneration += 1
	}

	/// The workspace window is up: restore a detached output, and on the
	/// first launch with a workspace, fit it to its display.
	func workspaceWindowAppeared(_ w: NSWindow) {
		guard !didFitWorkspace else { return }
		didFitWorkspace = true
		if layout.layout.detached {
			outputWindow.show(model: self, near: w.frame)
		}
		if layout.isFirstRun {
			DispatchQueue.main.async { self.fitWorkspace() }
		}
	}

	var mainWindow: NSWindow? {
		NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
			?? NSApp.mainWindow
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		// the playlist and patch from last time, after any files opened at
		// launch (application(_:open:) comes first)
		DispatchQueue.main.async {
			MainActor.assumeIsolated { Session.restore(AppModel.shared) }
		}
		// One full screen, Whorld's own (FullScreen.swift): the green button
		// zooms instead of entering macOS's full screen.
		DispatchQueue.main.async {
			MainActor.assumeIsolated {
				_ = AppModel.shared.mainWindow?.collectionBehavior.insert(.fullScreenNone)
			}
		}
		// WHORLD_SCREEN=<display ID>: start on that display (for measuring there)
		if let sID = ProcessInfo.processInfo.environment["WHORLD_SCREEN"], let id = UInt32(sID) {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
				MainActor.assumeIsolated {
					let key = NSDeviceDescriptionKey("NSScreenNumber")
					if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }),
						let w = AppModel.shared.mainWindow {
						let f = screen.visibleFrame
						w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2))
					}
				}
			}
		}
		// WHORLD_FULLSCREEN=1: start in full screen (for measuring there)
		if ProcessInfo.processInfo.environment["WHORLD_FULLSCREEN"] == "1" {
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
				MainActor.assumeIsolated { AppModel.shared.toggleFullScreen() }
			}
		}
	}

	func application(_ application: NSApplication, open urls: [URL]) {
		MainActor.assumeIsolated {
			for url in urls {
				switch url.pathExtension.lowercased() {
				case "whl": Session.openedPlaylist = true
				case "whs", "whm": break
				default: Session.openedPatch = true
				}
			}
		}
		for url in urls {
			Task { @MainActor in
				switch url.pathExtension.lowercased() {
				case "whl":
					if AppModel.shared.confirmDiscardPlaylist() {
						AppModel.shared.openPlaylist(url)
					}
				case "whs": AppModel.shared.loadSnapshots([url])
				case "whm": AppModel.shared.playMovie(url)
				default: AppModel.shared.open(url)
				}
			}
		}
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		MainActor.assumeIsolated {
			guard AppModel.shared.confirmDiscard() && AppModel.shared.confirmDiscardPlaylist() else {
				return .terminateCancel
			}
			Session.save(AppModel.shared)
			return .terminateNow
		}
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}
}

@main
struct WhorldApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@StateObject private var model = AppModel.shared

	init() {
		// No automatic Enter Full Screen item (it drives macOS's full screen,
		// which Whorld doesn't use): the View menu has Whorld's own. AppKit
		// reads this before the app delegate runs.
		UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
	}

	var body: some Scene {
		Window("Whorld", id: "main") {
			ContentView()
				.environmentObject(model)
				.navigationTitle(model.windowTitle)
		}
		.defaultSize(width: 1024, height: 768)
		.commands {
			WhorldCommands(model: model)
			HelpCommands()
		}

		// Floating panels (a docked panel's menu > Float in a Window). The
		// View menu shows and hides panels, so these add no menu items.
		Window("Parameters", id: "params") {
			FloatingPanel(id: .params).environmentObject(model)
		}
		.commandsRemoved()
		.defaultPosition(.topTrailing)

		Window("Master", id: "master") {
			FloatingPanel(id: .master).environmentObject(model)
		}
		.commandsRemoved()
		.windowResizability(.contentSize)

		Window("Globals", id: "globals") {
			FloatingPanel(id: .globals).environmentObject(model)
		}
		.commandsRemoved()
		.windowResizability(.contentSize)

		Window("Properties", id: "properties") {
			FloatingPanel(id: .properties).environmentObject(model)
		}
		.commandsRemoved()
		.windowResizability(.contentSize)

		Window("Playlist", id: "playlist") {
			FloatingPanel(id: .playlist).environmentObject(model)
		}
		.commandsRemoved()
		.defaultSize(width: 520, height: 420)

		Window("MIDI Mapping", id: "mapping") {
			FloatingPanel(id: .mapping).environmentObject(model)
		}
		.commandsRemoved()
		.defaultSize(width: 760, height: 420)

		Settings {
			PreferencesView().environmentObject(model)
		}
	}
}

// MARK: Session

/// Whorld reopens the playlist and patch it had when it quit (a Mac
/// addition: Windows Whorld starts with an untitled patch). They're kept as
/// bookmarks, so a file that was moved or renamed is still found; one that
/// can't be found is skipped without a word. The patch is a patch file, or
/// the playlist entry that was playing; an untitled patch isn't kept, nor a
/// playlist that was never saved. A file opened at launch (from the Finder)
/// takes the place of the remembered one of its kind. Settings > General
/// can turn this off.
@MainActor
enum Session {
	private static let playlistKey = "LastPlaylist"	// bookmark data
	private static let patchKey = "LastPatch"	// bookmark data
	private static let entryKey = "LastPlaylistEntry"	// [index, stored path]

	/// Set when a file of that kind was opened at launch.
	static var openedPlaylist = false
	static var openedPatch = false

	private static func bookmark(_ url: URL) -> Data? {
		try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
	}

	private static func resolve(_ data: Data?) -> URL? {
		guard let data else { return nil }
		var stale = false
		guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
			FileManager.default.fileExists(atPath: url.path) else { return nil }
		return url
	}

	/// At quit, after the save prompts.
	static func save(_ model: AppModel) {
		let d = UserDefaults.standard
		d.set(model.playlistURL.flatMap(bookmark), forKey: playlistKey)
		let patches = model.engine.playlistPatches
		if let path = model.engine.patchPath {
			d.set(bookmark(URL(fileURLWithPath: path)), forKey: patchKey)
			d.removeObject(forKey: entryKey)
		} else if model.playlistURL != nil, model.playingPatch >= 0, model.playingPatch < patches.count {
			d.removeObject(forKey: patchKey)
			d.set([model.playingPatch, patches[model.playingPatch]] as [Any], forKey: entryKey)
		} else {
			d.removeObject(forKey: patchKey)
			d.removeObject(forKey: entryKey)
		}
	}

	/// At launch, if Settings > General says to. (What was open is kept
	/// either way, so turning the setting on reopens the last files.)
	static func restore(_ model: AppModel) {
		guard Preferences.reopenLast else { return }
		let d = UserDefaults.standard
		var playlistOpen = false
		if !openedPlaylist, let url = resolve(d.data(forKey: playlistKey)) {
			model.openPlaylist(url)
			playlistOpen = model.playlistURL == url
		}
		guard !openedPatch, !model.engine.modified else { return }
		if let url = resolve(d.data(forKey: patchKey)) {
			model.open(url)
		} else if playlistOpen, let entry = d.array(forKey: entryKey), entry.count == 2,
			let index = entry[0] as? Int, let stored = entry[1] as? String {
			let patches = model.engine.playlistPatches
			if index >= 0, index < patches.count, patches[index] == stored {	// the same entry
				model.playPatch(index)
			}
		}
	}
}
