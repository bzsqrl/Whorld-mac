// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

import AppKit
import Combine
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
	// Whorld patch (.whp), declared in Info.plist
	static let whorldPatch = UTType(importedAs: "io.github.bzsqrl.whorld.patch", conformingTo: .data)
	// Whorld playlist (.whl), declared in Info.plist
	static let whorldPlaylist = UTType(importedAs: "io.github.bzsqrl.whorld.playlist", conformingTo: .data)
	// Whorld panel layout (.whlayout, Mac only), declared in Info.plist
	static let whorldLayout = UTType(exportedAs: "io.github.bzsqrl.whorld.layout", conformingTo: .json)
}

/// Main property indices (WhorldBase MAIN_*)
enum MainProp: Int {
	case origin, drawMode, orgMotion, hue, mirror, reverse, convex, invertColor, loopHue, zoomCenter, antialiasing
}

/// Master property indices (WhorldBase MASTER_*)
enum MasterProp: Int {
	case speed, zoom, damping, trail, rings, tempo, hueSpan, canvasScale, copies, spread, fade
}

/// A change counter a view depends on by reading `n`: SwiftUI's Observation
/// redraws that view when it's bumped, and not for other changes.
@Observable
final class Tick {
	private(set) var n = 0
	func bump() { n &+= 1 }
}

/// What changed, by area, so an edit redraws only the views showing it.
/// Moving one slider used to redraw every panel, the menu bar and the
/// window title and lay out the whole window: about 30 changes a second
/// (a MIDI knob sends more) kept the main thread 90% busy.
@MainActor
final class Changes {
	let params = (0..<WHControls.paramCount).map { _ in Tick() }	// a Parameters and Globals row
	let master = (0..<WHControls.masterCount).map { _ in Tick() }	// a Master row
	let main = Tick()		// main properties and pause: Properties, the Image and Window menus
	let menus = Tick()		// undo titles, files, layout and the rest of the menu bar
	let document = Tick()	// the window title (name, edited)
	let playlist = Tick()
	let mapping = Tick()
	let media = Tick()		// snapshots and movies
	let midi = Tick()		// MIDI sources

	func all() {
		for t in params { t.bump() }
		for t in master { t.bump() }
		for t in [main, menus, document, playlist, mapping, media, midi] { t.bump() }
	}
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
	/// What changed (see Changes). changed() means anything may have.
	let changes = Changes()
	private var shownModified = false
	private var shownUndo = ""

	/// Undo coalescing key of the edit on top of the undo stack
	/// (CUndoManager::NotifyUndoableEdit with UE_COALESCE).
	var coalesceKey: String?

	private init() {
		engine.statsHandler = { [weak self] in
			guard let self else { return }
			let e = self.engine
			let osc = e.oscClientCount > 0	// OSC monitoring: /w/stat/...
			guard self.showFrameRate || Self.logStats || osc else { return }
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
			if osc {
				e.oscSendStats(text)
			}
		}
		undoManager.levelsOfUndo = 100
		// menus show the layout (they observe AppModel)
		layoutWatch = layout.objectWillChange.sink { [weak self] _ in
			DispatchQueue.main.async { self?.changes.menus.bump() }
		}
		outputWindow.onClose = { [weak self] in	// closing the output window docks it
			guard let self, self.layout.layout.detached else { return }
			self.outputWindow.hide()
			self.layout.layout.detached = false
		}
		engine.setSnapshotLetterbox(Preferences.snapshotLetterbox)
		engine.preferMetal = Preferences.preferMetal
		engine.maxFrameRate = Preferences.maxFrameRate
		engine.setRingFadeEased(Preferences.ringFadeEased)
		engine.setHueFromPatch(Preferences.hueFromPatch)
		restartOSC()
		applySyphon()
		_ = AudioInputWatch.shared	// sees the audio input's changes from the start
		AudioSettings.apply()	// the audio input chosen last time
		ModMap.shared.attach(engine)	// the modulation rows
		engine.modulationActionHandler = { [weak self] actions in
			guard let self else { return }
			ModMap.shared.perform(actions, self)
		}
		engine.modulationOscHandler = { kind, value in ModMap.shared.osc(kind: kind, value: value) }
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
		set { engine.midiLearn = newValue; changes.menus.bump(); changes.mapping.bump() }
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
		changes.mapping.bump()
		changes.menus.bump()
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
		case 4:	// MIDI sources changed
			changes.midi.bump()
		case 5:	// a parameter, from a mapping
			midiPending.params.insert(Int(value))
			scheduleMidiRefresh()
		case 6:	// a master property
			midiPending.master.insert(Int(value))
			scheduleMidiRefresh()
		default:	// 0: main properties or draw mode; 1: pause
			midiPending.main = true
			scheduleMidiRefresh()
		}
	}

	/// Rows changed by MIDI and not yet redrawn. A knob can send hundreds of
	/// messages a second; redrawing a row costs about 5 ms of the main
	/// thread, so the panels catch up at most 30 times a second (the picture
	/// follows every message regardless, on the render thread).
	private var midiPending = (params: Set<Int>(), master: Set<Int>(), main: false, scheduled: false)

	private func scheduleMidiRefresh() {
		guard !midiPending.scheduled else { return }
		midiPending.scheduled = true
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
			guard let self else { return }
			let p = self.midiPending
			self.midiPending = (params: [], master: [], main: false, scheduled: false)
			for i in p.params { self.changes.params[i].bump() }
			for i in p.master { self.changes.master[i].bump() }
			if p.main { self.changes.main.bump() }
			self.noteEdit()
		}
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
			if Preferences.applyPlaylistLayouts, let line = engine.playlistLayout, let f = LayoutFile(line: line) {
				applyLayout(f)
			}
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
		// the panel layout goes in the playlist if this is checked (remembered)
		let include = NSButton(checkboxWithTitle: "Include the panel layout", target: nil, action: nil)
		include.state = Preferences.playlistSavesLayout ? .on : .off
		include.toolTip = "Saves the panels' arrangement with the playlist, to restore when it's opened (Whorld for Mac only; Windows Whorld ignores it)."
		let row = NSStackView(views: [include])
		row.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
		panel.accessoryView = row
		guard panel.runModal() == .OK, let url = panel.url else { return false }
		let on = include.state == .on
		UserDefaults.standard.set(on, forKey: "Playlist_bSaveLayout")
		engine.playlistLayout = on ? currentLayoutFile().line : nil
		return writePlaylist(to: url)
	}

	private func writePlaylist(to url: URL) -> Bool {
		if engine.playlistLayout != nil {	// a playlist with a layout keeps it current
			engine.playlistLayout = currentLayoutFile().line
		}
		do {
			try engine.savePlaylist(toPath: url.path)
			NSDocumentController.shared.noteNewRecentDocumentURL(url)
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

	// CPlaylistBar::Play (also from the MIDI and OSC Patch target). Unlike
	// Windows, which asks to save an edited patch first (except in full
	// screen), this never asks: playing through a playlist live shouldn't
	// be interrupted, and unsaved edits are simply let go (the user's choice,
	// 2026-11-09). File > New, Open and Quit still ask.
	func playPatch(_ index: Int) {
		let paths = engine.playlistPatches
		guard index >= 0, index < paths.count, let url = resolvePatchPath(paths[index]) else { return }
		if engine.playPatch(atPath: url.path) {
			playedName = url.deletingPathExtension().lastPathComponent
			playingPatch = index
			resetUndo()
			updateTitle()
			changed()
		}
	}

	/// The playlist's next (+1) or previous (-1) patch, wrapping around at
	/// the ends; with none playing, the first or last. (A Mac addition:
	/// Command-Down and Command-Up over the picture or in full screen.)
	func stepPatch(_ step: Int) {
		let n = engine.playlistPatches.count
		guard n > 0 else { return }
		let i = playingPatch >= 0 && playingPatch < n ? (playingPatch + step + n) % n : (step > 0 ? 0 : n - 1)
		playPatch(i)
	}

	/// Anything may have changed (a patch opened, undo, ...): refresh everything.
	func changed() {
		changes.all()
		noteEdit()
	}

	/// An edit to parameter row iParam (any column, including Global).
	func paramChanged(_ iParam: Int) {
		changes.params[iParam].bump()
		noteEdit()
	}

	func masterChanged(_ iProp: Int) {
		changes.master[iProp].bump()
		noteEdit()
	}

	/// main properties or pause
	func mainChanged() {
		changes.main.bump()
		noteEdit()
	}

	/// After an edit: refresh the title if it went from saved to edited, and
	/// the menu bar if the Undo or Redo item changed (coalesced edits of one
	/// control don't change it).
	private func noteEdit() {
		if engine.modified != shownModified {
			shownModified = engine.modified
			changes.document.bump()
		}
		let u = undoManager
		let undo = "\(u.canUndo) \(u.undoActionName) \(u.canRedo) \(u.redoActionName)"
		if undo != shownUndo {
			shownUndo = undo
			changes.menus.bump()
		}
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
		paramChanged(iParam)
	}

	func setMaster(_ iProp: Int, _ value: Double) {
		let old = engine.masterValue(iProp)
		guard old != value else { return }
		recordUndo(key: "master \(iProp)", title: WHControls.masterName(iProp)) { [weak self] in
			self?.setMaster(iProp, old)
		}
		engine.setMasterValue(value, prop: iProp)
		masterChanged(iProp)
	}

	// CWhorldDoc::SetZoom
	func setZoom(_ zoom: Double, damping: Bool = true) {
		let old = engine.masterValue(MasterProp.zoom.rawValue)
		guard old != zoom else { return }
		recordUndo(key: "zoom", title: WHControls.masterName(MasterProp.zoom.rawValue)) { [weak self] in
			self?.setZoom(old, damping: false)
		}
		engine.setZoom(zoom, damping: damping)
		masterChanged(MasterProp.zoom.rawValue)
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
		mainChanged()
	}

	func setHue(_ hue: Double) {
		let old = engine.hue
		guard old != hue else { return }
		recordUndo(key: "main \(MainProp.hue.rawValue)", title: WHControls.mainName(MainProp.hue.rawValue)) { [weak self] in
			self?.setHue(old)
		}
		engine.hue = hue
		mainChanged()
	}

	/// Image > Rotate Hue (V1's, F3): existing rings turn 90 degrees and
	/// Hue goes up 90 so new rings follow. Undo restores Hue; colors already
	/// given to existing rings stay, as in V1.
	func rotateHue() {
		let old = engine.hue
		recordUndo(key: "rotate hue", title: "Rotate Hue") { [weak self] in
			self?.setHue(old)
		}
		engine.rotateHue()
		mainChanged()
	}

	func setDrawMode(_ mode: UInt32) {
		let old = engine.drawMode
		guard old != mode else { return }
		recordUndo(key: "main \(MainProp.drawMode.rawValue)", title: WHControls.mainName(MainProp.drawMode.rawValue)) { [weak self] in
			self?.setDrawMode(old)
		}
		engine.setDrawMode(mode)
		mainChanged()
	}

	func setOriginMotion(_ motion: WHOriginMotion) {
		let old = engine.originMotion
		guard old != motion else { return }
		recordUndo(key: "main \(MainProp.orgMotion.rawValue)", title: WHControls.mainName(MainProp.orgMotion.rawValue)) { [weak self] in
			self?.setOriginMotion(old)
		}
		engine.setOriginMotion(motion)
		mainChanged()
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
		mainChanged()
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
	// slider space (CWhorldDoc::OffsetMasterProp). Mac addition: with a key
	// held over the picture (OutputKeys), that key's control instead.
	func wheel(notches: Double, shift: Bool, momentum: Bool = false, inverted: Bool = false) {
		let delta = notches * Preferences.wheelSense / 100
		if momentum && (outputKeys.held != nil || outputKeys.lastWheelWasKeyed) {
			return	// no coasting after a key swipe, nor turning into zoom when the key lifts
		}
		if let target = outputKeys.heldTarget {
			outputKeys.lastWheelWasKeyed = true
			adjust(target, by: inverted ? -delta : delta)	// fingers or wheel up: more, whatever the scrolling direction
			return
		}
		if !momentum {
			outputKeys.lastWheelWasKeyed = false
		}
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

	let outputKeys = OutputKeys()

	/// A key's control, moved by `delta` (in the units of a slider's travel,
	/// 0 to 1) times the key's speed; with the readout on, shows the result.
	private func adjust(_ b: KeyBinding, by delta: Double) {
		guard let t = b.targetIndex else { return }
		let d = delta * b.speed
		let nParams = WHMappingInfo.paramTargetCount, nMaster = WHMappingInfo.masterTargetCount
		var shown = ""
		if t < nParams {
			shown = adjustParam(t, WHParamProperty(rawValue: b.prop) ?? .val, d)
		} else if t < nParams + nMaster {
			let i = t - nParams
			let old = engine.masterValue(i)
			let value = WHControls.masterDenorm01(i, value: min(max(WHControls.masterNorm01(i, value: old) + d, 0), 1))
			if value != old {
				if i == MasterProp.zoom.rawValue {
					setZoom(value)	// damped, as the wheel's zoom
				} else {
					setMaster(i, value)
				}
			}
			shown = WHControls.formatMaster(i, value: engine.masterValue(i))
		} else {
			switch b.target {
			case "Hue":	// degrees, 0 to 360
				setHue(min(max(engine.hue + d * 360, 0), 360))
				shown = String(format: "%.1f°", engine.hue)
			case "OriginX", "OriginY":	// normalized, 0 to 1
				var p = engine.liveOrigin
				if b.target == "OriginX" {
					p.x = min(max(p.x + d, 0), 1)
				} else {
					p.y = min(max(p.y + d, 0), 1)
				}
				setOrigin(p)
				shown = String(format: "%.3f", b.target == "OriginX" ? p.x : p.y)
			default:
				return
			}
		}
		KeyReadout.show(b.displayName + "  " + shown)
	}

	/// A two-finger tap (a secondary click) over the picture while a key in
	/// the key map is held: that key's control goes back to its value in the
	/// patch as loaded (opened, played from the playlist, or new) or last saved.
	/// Returns false with no such key held, so the click goes on as usual.
	func resetHeldKeyControl() -> Bool {
		guard let b = outputKeys.heldTarget, let t = b.targetIndex else { return false }
		let nParams = WHMappingInfo.paramTargetCount, nMaster = WHMappingInfo.masterTargetCount
		if t < nParams {
			let prop = WHParamProperty(rawValue: b.prop) ?? .val
			guard prop != .wave else { return false }
			setParam(t, prop, engine.loadedParamValue(t, property: prop))
		} else if t < nParams + nMaster {
			let i = t - nParams
			let value = engine.loadedMasterValue(i)
			if i == MasterProp.zoom.rawValue {
				setZoom(value)
			} else {
				setMaster(i, value)
			}
		} else {
			let o = engine.loadedOrigin
			switch b.target {
			case "Hue": setHue(engine.loadedHue)
			case "OriginX": setOrigin(CGPoint(x: o.x, y: engine.liveOrigin.y))
			case "OriginY": setOrigin(CGPoint(x: engine.liveOrigin.x, y: o.y))
			default: return false
			}
		}
		adjust(b, by: 0)	// the readout, if on
		return true
	}

	/// A parameter column, moved: Value and Global along their sliders; the
	/// oscillator columns (number boxes only) within the box's limits, or by
	/// its stepper increments (one per hundredth of travel) if it has none.
	/// Returns the new value as the panel shows it.
	private func adjustParam(_ i: Int, _ prop: WHParamProperty, _ d: Double) -> String {
		let old = engine.paramValue(i, property: prop)
		var value = old
		let ci: WHControlInfo
		switch prop {
		case .val, .global:
			ci = prop == .val ? WHControls.paramControl(i, column: 0) : WHControls.globalControl(i)
			let lo = Double(ci.rangeMin), hi = Double(ci.rangeMax)
			guard hi > lo else { return "" }
			let pos = prop == .val ? WHControls.paramPosition(i, value: old) : WHControls.globalPosition(i, value: old)
			let newPos = lo + min(max((pos - lo) / (hi - lo) + d, 0), 1) * (hi - lo)
			value = prop == .val ? WHControls.paramValue(i, position: newPos) : WHControls.globalValue(i, position: newPos)
		case .amp, .freq, .PW:
			ci = WHControls.paramControl(i, column: prop == .amp ? 1 : prop == .freq ? 2 : 3)
			if ci.editClamp.boolValue && ci.editMax > ci.editMin {
				value = old + d * (ci.editMax - ci.editMin)
			} else {
				value = old + d * 100 * (ci.spinDelta > 0 ? ci.spinDelta : 0.01)
			}
			if ci.editClamp.boolValue {
				value = min(max(value, ci.editMin), ci.editMax)
			}
		default:
			return ""	// waveforms aren't continuous
		}
		if value != old {
			setParam(i, prop, value)
		}
		return WHControls.format(engine.paramValue(i, property: prop), control: ci)
	}

	// MARK: Files

	/// The name of the patch last played from the playlist, while the
	/// document is that patch. As on Windows (CWhorldDoc::SetPatch), playing
	/// a playlist patch detaches the document from its file, so Save asks
	/// where; the title shows the patch's name, not "Untitled" (Mac port).
	private var playedName: String?

	func updateTitle() {
		if let path = engine.patchPath {
			title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
		} else {
			title = playedName ?? "Untitled"
		}
	}


	var windowTitle: String {
		_ = changes.document.n	// the name is @Published; edited comes from the engine
		return engine.modified ? title + " — Edited" : title
	}

	/// Under the title: the patch's author, if the patch names one
	var windowSubtitle: String {
		_ = changes.document.n
		let author = engine.patchAuthor
		return author.isEmpty ? "" : "by " + author
	}

	/// A playlist patch's author, for the Playlist's Author column: read from
	/// the file, and read again only when the file changes
	func patchAuthor(_ stored: String) -> String {
		guard let url = resolvePatchPath(stored) else { return "" }
		let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
		if let cached = authorCache[url.path], cached.date == date {
			return cached.author
		}
		let author = WHEngine.authorOfPatch(atPath: url.path) ?? ""
		authorCache[url.path] = (date, author)
		return author
	}
	private var authorCache: [String: (date: Date?, author: String)] = [:]

	func newPatch() {
		guard confirmDiscard() else { return }
		playedName = nil
		engine.newPatch()
		resetUndo()
		updateTitle()
		changed()
	}

	func open(_ url: URL) {
		guard confirmDiscard() else { return }
		do {
			try engine.openPatch(atPath: url.path)
			playedName = nil
			resetUndo()
			NSDocumentController.shared.noteNewRecentDocumentURL(url)
		} catch {
			NSAlert(error: error).runModal()
		}
		updateTitle()
		changed()
	}

	/// Opens any Whorld file by its kind: from the Finder, or File > Open Recent.
	func openFile(_ url: URL) {
		switch url.pathExtension.lowercased() {
		case "whl":
			if confirmDiscardPlaylist() {
				openPlaylist(url)
			}
		case "whlayout": openLayout(url)
		case "whs": loadSnapshots([url])
		case "whm": playMovie(url)
		default: open(url)
		}
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
		// the patch's author, or for a patch without one Settings > Your name
		let author = NSTextField(string: authorToSuggest)
		author.placeholderString = "who made this patch (optional)"
		author.widthAnchor.constraint(equalToConstant: 280).isActive = true
		let row = NSStackView(views: [NSTextField(labelWithString: "Author:"), author])
		row.spacing = 8
		row.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
		panel.accessoryView = row
		guard panel.runModal() == .OK, let url = panel.url else { return false }
		setPatchAuthor(author.stringValue)
		return write(to: url)
	}

	/// What the Author fields start with: the patch's author, or if it has
	/// none, Settings > General > Your name
	private var authorToSuggest: String {
		let a = engine.patchAuthor
		return a.isEmpty ? Preferences.authorName : a
	}

	/// Sets the patch's author: an edit, undoable like any other
	func setPatchAuthor(_ author: String) {
		let old = engine.patchAuthor
		engine.patchAuthor = author
		guard engine.patchAuthor != old else { return }
		recordUndo(key: "author", title: "Author") { [weak self] in
			self?.setPatchAuthor(old)
		}
		changes.document.bump()	// the title's subtitle
		noteEdit()
	}

	/// File > Patch Author...: names the patch's author; Save (or Save As)
	/// then writes it
	func editPatchAuthor() {
		let field = NSTextField(string: authorToSuggest)
		field.placeholderString = "who made this patch"
		field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
		let a = NSAlert()
		a.messageText = "Author of \"\(title)\""
		a.informativeText = "Saved with the patch, and shown in the title bar and the Playlist's Author column. Leave empty for none."
		a.accessoryView = field
		a.addButton(withTitle: "OK")
		a.addButton(withTitle: "Cancel")
		a.window.initialFirstResponder = field
		guard a.runModal() == .alertFirstButtonReturn else { return }
		setPatchAuthor(field.stringValue)
	}

	private func write(to url: URL) -> Bool {
		do {
			try engine.savePatch(toPath: url.path)
			NSDocumentController.shared.noteNewRecentDocumentURL(url)
			updateTitle()
			changed()
			changes.playlist.bump()	// its Author column, if the playlist has this patch
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
			defer { UpdateChecker.shared.showPending() }	// an update found while full screen
			// The origin stays where it is, as on Windows: a patch's own
			// origin is kept (until 2026-11-12, leaving full screen ran
			// Origin Center; removed at the user's request)
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

	// MARK: OSC

	/// Why OSC isn't running (a port in use, a bad host), or nil.
	@Published private(set) var oscError: String?
	private var oscTimer: Timer?

	/// Starts (or stops) OSC remote control as Settings > OSC says. Whorld
	/// sends what changed about 10 times a second, but only while some
	/// device is listening (WHEngine oscSendState returns at once otherwise).
	func restartOSC() {
		oscTimer?.invalidate()
		oscTimer = nil
		engine.stopOSC()
		oscError = nil
		let o = Preferences.osc
		guard o.enabled else { return }
		do {
			try engine.startOSC(onPort: o.receivePort, sendPort: o.sendPort, host: o.host)
		} catch {
			oscError = error.localizedDescription
			return
		}
		let t = Timer(timeInterval: 0.1, repeats: true) { _ in
			MainActor.assumeIsolated { AppModel.shared.oscTick() }
		}
		RunLoop.main.add(t, forMode: .common)
		oscTimer = t
	}

	private func oscTick() {
		engine.oscSendState(withPatch: playingPatch, patchName: title, playlistName: playlistTitle,
			fullScreen: isFullScreen)
	}

	// MARK: Syphon

	/// Syphon output is on (View > Syphon Output and Settings > Syphon)
	@Published private(set) var syphonEnabled = false

	/// Starts, stops or resizes Syphon output as Settings > Syphon says.
	func applySyphon() {
		let s = Preferences.syphon
		syphonEnabled = s.enabled
		engine.setSyphonEnabled(s.enabled, width: s.fixedSize?.width ?? 0, height: s.fixedSize?.height ?? 0)
	}

	func setSyphonEnabled(_ on: Bool) {
		UserDefaults.standard.set(on, forKey: "Syphon_bEnabled")
		applySyphon()
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
		alert.informativeText = "The panels go back to their standard places and sizes, as when Whorld is first opened."
		alert.addButton(withTitle: "Reset")
		alert.addButton(withTitle: "Cancel")
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		layout.reset()
		fitWorkspace()
	}

	// MARK: Layouts (Mac addition)

	/// The workspace as it is now: panels, divider proportions, windows
	func currentLayoutFile() -> LayoutFile {
		var f = LayoutFile(layout: layout.layout)
		if let w = mainWindow {
			if let v = w.contentView {
				f.splits = SplitShares.capture(in: v)
			}
			if let area = w.screen?.visibleFrame {
				f.window = UnitRect(w.frame, in: area)
			}
		}
		if layout.layout.detached, let w = outputWindow.window, let area = w.screen?.visibleFrame {
			f.output = UnitRect(w.frame, in: area)
		}
		for id in layout.layout.floating {
			if let w = panelWindow(id), let area = w.screen?.visibleFrame {
				f.floating[id.rawValue] = UnitRect(w.frame, in: area)
			}
		}
		return f
	}

	/// Arranges the workspace as a saved layout says. Before the Whorld
	/// window is up (a playlist reopened at launch), it waits for it.
	func applyLayout(_ f: LayoutFile) {
		guard let main = mainWindow else {
			pendingLayout = f
			return
		}
		for id in layout.layout.floating where !f.layout.floating.contains(id) {
			layout.closeFloating?(id)
		}
		layout.forgetSplitPositions()
		SplitShares.current = Layout.standardSplits.merging(f.splits) { $1 }
		let wasDetached = layout.layout.detached
		layout.layout = f.layout
		if let r = f.window, let area = (main.screen ?? NSScreen.main)?.visibleFrame {
			main.setFrame(r.rect(in: area), display: true)
		}
		if f.layout.detached && !wasDetached {
			outputWindow.show(model: self, near: main.frame)
		} else if !f.layout.detached && wasDetached {
			outputWindow.hide()
		}
		if let r = f.output, let w = outputWindow.window, let area = (w.screen ?? NSScreen.main)?.visibleFrame {
			w.setFrame(r.rect(in: area), display: true)
		}
		for id in f.layout.floating {
			layout.openFloating?(id)
		}
		DispatchQueue.main.async {	// the floating windows are up now
			for (raw, r) in f.floating {
				if let id = PanelID(rawValue: raw), let w = self.panelWindow(id),
					let area = (w.screen ?? NSScreen.main)?.visibleFrame {
					w.setFrame(r.rect(in: area), display: true)
				}
			}
		}
		layout.arrangeGeneration += 1
		changes.menus.bump()
	}
	private var pendingLayout: LayoutFile?

	private func panelWindow(_ id: PanelID) -> NSWindow? {
		NSApp.windows.first {
			guard let s = $0.identifier?.rawValue else { return false }
			return s == id.rawValue || s.hasPrefix(id.rawValue + "-")
		}
	}

	/// Window > Save Layout...
	func saveLayout() {
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.whorldLayout]
		panel.nameFieldStringValue = "Layout.whlayout"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		let e = JSONEncoder()
		e.outputFormatting = [.prettyPrinted, .sortedKeys]
		do {
			try e.encode(currentLayoutFile()).write(to: url, options: .atomic)
		} catch {
			NSAlert(error: error).runModal()
		}
	}

	/// Window > Open Layout...
	func openLayout() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.whorldLayout]
		guard panel.runModal() == .OK, let url = panel.url else { return }
		openLayout(url)
	}

	func openLayout(_ url: URL) {
		do {
			applyLayout(try JSONDecoder().decode(LayoutFile.self, from: Data(contentsOf: url)))
		} catch {
			let a = NSAlert()
			a.messageText = "Can't open the layout \"\(url.lastPathComponent)\"."
			a.informativeText = "It isn't a Whorld layout file, or it's damaged."
			a.runModal()
		}
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
		if let f = pendingLayout {	// a playlist's, from before the window was up
			pendingLayout = nil
			DispatchQueue.main.async { self.applyLayout(f) }
		}
	}

	var mainWindow: NSWindow? {
		NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
			?? NSApp.mainWindow
	}
}

/// Keys held over the picture (Mac addition): while a key in the key map
/// (KeyMap.swift) is held with the pointer over the output (docked,
/// detached or full screen), a trackpad swipe up or down, or the mouse
/// wheel, moves that key's control instead of zooming. Plain keys only:
/// with Shift, Command, Control or Option they're shortcuts (Shift-W is
/// Zoom Center, Command-S Save...), and with the pointer elsewhere they
/// type as usual.
@MainActor
final class OutputKeys {

	private(set) var held: String?
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
			let take = MainActor.assumeIsolated {
				AppModel.shared.outputKeys.takes(key: key, code: code, up: up, modifiers: mods)
			}
			return take ? nil : e
		}
		resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
			object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.held = nil }	// its key-up goes to another app
		}
	}

	/// true: the key event is this feature's (not passed on)
	func takes(key: String?, code: CGKeyCode, up: Bool, modifiers: UInt) -> Bool {
		guard let key else { return false }
		// Command-Up and Command-Down: the playlist's previous and next patch,
		// in full screen or with the pointer over the picture
		if !up, code == 126 || code == 125, modifiers == NSEvent.ModifierFlags.command.rawValue,
			AppModel.shared.isFullScreen || Self.pointerOverOutput() {
			AppModel.shared.stepPatch(code == 125 ? 1 : -1)
			return true
		}
		// Command-Left and Command-Right: the previous and next snapshot
		// (Snapshot > Previous and Next, Page Up and Page Down), likewise
		if !up, code == 123 || code == 124, modifiers == NSEvent.ModifierFlags.command.rawValue,
			AppModel.shared.hasSnapshots, AppModel.shared.isFullScreen || Self.pointerOverOutput() {
			if code == 124 { AppModel.shared.snapshotNext() } else { AppModel.shared.snapshotPrev() }
			return true
		}
		if up {
			if key == held {
				held = nil
				return true
			}
			return false
		}
		guard modifiers == 0, KeyMap.shared.binding(for: key) != nil else { return false }
		if key == held {
			return true	// key repeat
		}
		guard Self.pointerOverOutput() else { return false }
		held = key
		heldCode = code
		return true
	}

	/// the pointer is over a picture (WHRenderView) in the topmost window under it
	private static func pointerOverOutput() -> Bool {
		let p = NSEvent.mouseLocation
		let n = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
		guard let w = NSApp.window(withWindowNumber: n), let content = w.contentView else { return false }
		var v = content.hitTest(w.convertPoint(fromScreen: p))	// hitTest takes its superview's (the window's) coordinates
		while let view = v {
			if view is WHRenderView { return true }
			v = view.superview
		}
		return false
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
	private static let ctrl = Mods.control.rawValue

	/// true: the key was one of these, and its command ran
	static func perform(code: UInt16, modifiers: UInt) -> Bool {
		guard NSApp.modalWindow == nil else { return false }	// a dialog is up
		let m = AppModel.shared
		let e = m.engine
		switch (code, modifiers) {
		case (103, none): m.toggleFullScreen()	// F11, Windows' full screen
		case (3, ctrlCmd): m.toggleFullScreen()	// Ctrl-Cmd-F, macOS's (Shift-Cmd-F in the menu)
		case (117, cmd): e.clear()	// Cmd-Forward Delete, Windows' Ctrl+Delete (Cmd-K in the menu)
		case (97, none): m.toggleFill()	// F6 (Cmd-1)
		case (98, none): m.toggleOutline()	// F7 (Cmd-2)
		case (96, none): m.toggle(.mirror)	// F5 (Cmd-3)
		case (48, ctrl): m.toggle(.convex)	// Ctrl-Tab (Cmd-4)
		case (120, none): m.toggle(.loopHue)	// F2 (Cmd-5)
		case (99, none): m.rotateHue()	// F3 (Cmd-6)
		case (118, none): m.toggle(.invertColor)	// F4 (Cmd-7)
		case (2, cmd): m.toggleOriginDrag()	// Cmd-D, Windows' Ctrl+D (Cmd-Minus)
		case (15, cmd): m.toggleOriginRandom()	// Cmd-R, Windows' Ctrl+R (Cmd-Equals)
		case (101, none): e.randomPhase()	// F9 (Cmd-9)
		default: return false
		}
		return true
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	private var secondKeysMonitor: Any?

	func applicationDidFinishLaunching(_ notification: Notification) {
		// second shortcuts for menu commands (a menu item has only one)
		secondKeysMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
			let code = event.keyCode
			let mods = event.modifierFlags.intersection([.shift, .command, .control, .option]).rawValue
			let taken = MainActor.assumeIsolated { SecondKeys.perform(code: code, modifiers: mods) }
			return taken ? nil : event
		}
		MainActor.assumeIsolated { AppModel.shared.outputKeys.install() }
		UpdateChecker.shared.checkAtLaunch()
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
			Task { @MainActor in AppModel.shared.openFile(url) }
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

		// Window > Modulation... (audio modulation; Modulation.swift)
		Window("Modulation", id: "modulation") {
			ModulationView()
		}
		.commandsRemoved()
		.defaultSize(width: 1140, height: 760)

		// Window > Key Map... (keys held over the picture; KeyMap.swift)
		Window("Key Map", id: "keymap") {
			KeyMapView()
		}
		.commandsRemoved()
		.defaultSize(width: 560, height: 620)

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
