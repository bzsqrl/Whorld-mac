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

/// The menu bar's refresh (the user's report, 2026-11-20: an open submenu
/// closed by itself, after a while). SwiftUI rebuilds the menus whenever
/// what they read changes, and a rebuild closes an open submenu; a patch
/// playing (auto-advance, MIDI, OSC) or any other change did it. The menus
/// read only this counter, bumped after the changes they show, but in the
/// run loop's default mode: while a menu is open (event tracking) the bump
/// waits, and comes as soon as the menu closes. A closed menu bar is
/// refreshed at once, so a menu always opens up to date.
@MainActor
@Observable
final class MenuRefresh {
	static let shared = MenuRefresh()
	private(set) var n = 0
	@ObservationIgnored private var scheduled = false
	@ObservationIgnored private var modelWatch: AnyCancellable?

	/// Follows the model's published values and its menu-related change
	/// counters (once, at launch)
	func install(_ model: AppModel) {
		guard modelWatch == nil else { return }
		modelWatch = model.objectWillChange.sink { [weak self] _ in self?.request() }
		watch(model.changes)
	}

	private func watch(_ c: Changes) {
		withObservationTracking {
			_ = (c.menus.n, c.main.n, c.media.n, c.playlist.n)
		} onChange: { [weak self] in
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					self?.request()
					self?.watch(c)	// observation fires once: again
				}
			}
		}
	}

	func request() {
		guard !scheduled else { return }
		scheduled = true
		RunLoop.main.perform(inModes: [.default]) { [weak self] in	// not while a menu tracks
			MainActor.assumeIsolated {
				guard let self else { return }
				self.scheduled = false
				self.n &+= 1
			}
		}
	}
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

/// App state shared by the windows, menus and app delegate. All document
/// edits go through here so they're undoable, as in CWhorldDoc.
@MainActor
final class AppModel: ObservableObject {
	static let shared = AppModel()
	static let logStats = ProcessInfo.processInfo.environment["WHORLD_STATS"] == "1"

	let engine = WHEngine()
	let undoManager = UndoManager()
	@Published var title = "Untitled"
	/// View > Show Perform Bar (was Show Stats): the strip below the
	/// picture (ContentView.swift), kept between runs
	/// On at first (the default layout shows it, with its Properties row:
	/// the user's request, 2026-11-24)
	@Published var showStats: Bool = UserDefaults.standard.object(forKey: "View_bShowStats") as? Bool ?? true {
		didSet { UserDefaults.standard.set(showStats, forKey: "View_bShowStats") }
	}
	/// View > Show Properties in Perform Bar (the user's choice, 2026-11-24):
	/// the Properties' live chips as a row of the Perform Bar
	/// (PropertiesStrip), with the bar; kept between runs and per layout
	/// View > Show Info Overlay (InfoOverlay): off at launch, and turned off
	/// on entering full screen (the user's request, 2026-11-25)
	@Published var showInfoOverlay = false {
		didSet { InfoOverlay.shared.refresh() }
	}
	@Published var showPropsBar: Bool = UserDefaults.standard.object(forKey: "View_bShowPropsBar") as? Bool ?? true {
		didSet { UserDefaults.standard.set(showPropsBar, forKey: "View_bShowPropsBar") }
	}
	/// Settings > Performance > Render quality (renderScale) and Upscaling (Mac addition): the
	/// picture is drawn at this fraction of the display's pixels and scaled up
	@Published var renderScale: Double = {
		Preferences.register()
		return UserDefaults.standard.double(forKey: "Render_fScale")
	}() {
		didSet {
			UserDefaults.standard.set(renderScale, forKey: "Render_fScale")
			fullScreen.setRender(scale: renderScale, smooth: smoothUpscaling)
			engine.userRenderScale = renderScale
		}
	}
	@Published var smoothUpscaling: Bool = {
		Preferences.register()
		return UserDefaults.standard.bool(forKey: "Render_bSmoothUpscale")
	}() {
		didSet {
			UserDefaults.standard.set(smoothUpscaling, forKey: "Render_bSmoothUpscale")
			fullScreen.setRender(scale: renderScale, smooth: smoothUpscaling)
		}
	}
	/// Settings > Display > Automatic quality (until 2026-11-19; now View > Automatic Quality) (Mac addition): steps curve
	/// quality, then render scale, down when frames are missed (WHEngine)
	@Published var autoQuality: Bool = {
		Preferences.register()
		return UserDefaults.standard.bool(forKey: "Render_bAutoQuality")
	}() {
		didSet {
			UserDefaults.standard.set(autoQuality, forKey: "Render_bAutoQuality")
			engine.autoQuality = autoQuality
		}
	}
	/// Settings > Performance > Curve quality (Mac addition), 0 (Low) to 1
	/// (High): the live view's curve flattening tolerance, 1 px to 0.1 px
	@Published var curveQuality: Double = {
		Preferences.register()
		return UserDefaults.standard.double(forKey: "Render_fCurveQuality")
	}() {
		didSet {
			UserDefaults.standard.set(curveQuality, forKey: "Render_fCurveQuality")
			engine.curveTolerance = Self.curveTolerance(curveQuality)
		}
	}
	/// High (1) is 0.1 px, as exports and the golden tests draw; each step
	/// down is a factor of 10 over the slider's length (0.5: about 0.32 px)
	static func curveTolerance(_ quality: Double) -> Float {
		Float(0.1 * pow(10, 1 - min(max(quality, 0), 1)))
	}
	/// the choices, in the View menu and Settings
	static let renderScales: [(value: Double, name: String)] = [
		(1, "100% (full resolution)"), (0.75, "75%"), (0.5, "50%"), (1.0 / 3, "33%"),
	]
	/// the workspace's panels and the output's place (Workspace.swift)
	let layout = LayoutModel()
	let outputWindow = OutputWindowController()	// (TitleBarClicks asks for its window)
	private var layoutWatch: AnyCancellable?
	var didFitWorkspace = false
	/// What changed (see Changes). changed() means anything may have.
	let changes = Changes()
	/// the draw mode as last known, to tell which switch a change flipped
	/// (MIDI's change arrives done; showDrawMode)
	private var knownDrawMode: UInt32?
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
			guard self.showStats || Self.logStats || osc else { return }
			let gpu = e.gpuMilliseconds > 0 ? String(format: " · gpu %.1f ms", e.gpuMilliseconds) : ""
			let auto = e.autoQualityStatus.isEmpty ? "" : " · " + e.autoQualityStatus
			let text = String(format: "%.0f fps · draw %.1f ms%@ · %d Hz · %ld missed · %ld rings · %@%@",
				e.framesPerSecond, e.renderMilliseconds, gpu, e.refreshRate, e.missedFrames, e.ringCount,
				e.rendererName, auto)
			// the strip: fps, missed, draw and GPU times, rings, automatic
			// quality (StripFeed, not published: a change to AppModel rebuilds
			// every open panel, about 100 ms with four open, a stutter)
			if self.showStats {
				StripFeed.shared.setSyphon(self.syphonState)
				var detail = String(format: "%.0f frames a second\n%ld display refreshes missed in the last second\nDraw time: %.1f ms on the CPU",
					e.framesPerSecond, e.missedFrames, e.renderMilliseconds)
				if e.gpuMilliseconds > 0 { detail += String(format: ", %.1f ms on the GPU", e.gpuMilliseconds) }
				detail += "\n\(e.ringCount) rings\n\(e.refreshRate) Hz display · \(e.rendererName)"
				if self.autoQuality {
					detail += "\nAutomatic quality: " + (e.autoQualityStatus.isEmpty ? "nothing lowered" : e.autoQualityStatus)
				}
				StripFeed.shared.setStats(fps: String(format: "%.0f fps", e.framesPerSecond),
					warn: e.missedFrames > 0, detail: detail)
				StripFeed.shared.setAuto(Self.autoTag(e.autoQualityStatus),
					percent: Int((self.renderScale * (self.autoQuality ? e.autoScaleFactor : 1) * 100).rounded()))
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
		MenuRefresh.shared.install(self)	// the menu bar follows the model, but not while a menu is open
		// a display connected or removed: View > Enter Full Screen on Other
		// Display is there only with more than one
		screensWatch = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
			object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.changes.menus.bump() }
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
		engine.curveTolerance = Self.curveTolerance(curveQuality)	// Curve quality (Mac addition)
		engine.userRenderScale = renderScale	// and automatic quality, which steps below them
		engine.autoQuality = autoQuality
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
		engine.autoAdvanceHandler = { [weak self] in self?.autoAdvanceNext() }
	}

	// MARK: MIDI and mappings

	// MARK: Phase 6 state (see Media.swift)
	/// Snapshots loaded with Load Snapshot (CMainFrame::m_aSnapshotPath).
	@Published var snapshotPaths: [URL] = []
	@Published var currentSnapshot = 0
	/// Index of the playing playlist patch (CPlaylistBar::m_iPlayingPatch).
	@Published var playingPatch = -1
	/// the cue (AppModel+Cue.swift): the entry Go plays, -1 for none
	@Published var cuedPatch = -1
	/// a Go waiting for the beat: the entry it plays, -1 for none
	@Published var pendingLaunch = -1
	/// the pads' bank (MIDI's Pad 1 to 16 play bank × size + n), and
	/// whether one has been used (the Playlist and the overlay show it then)
	@Published var cueBank = 0
	@Published var bankShown = false
	/// the beat count when that Go was pressed (it plays on a later one)
	var launchFrom = 0
	/// the number being typed after Option-Command-G, and the cue before it
	var cueEntry: String?
	var cueBeforeEntry = -1
	/// the patch file playing or open, for the Patches panel's marker
	@Published var playingFile: URL?
	/// Counts patches played from the playlist (the Playlist panel scrolls
	/// to the playing one on each, even the same one again)
	@Published var patchPlays = 0
	@Published var playlistSelection = Set<Int>()
	@Published var movieExportProgress: (done: Int64, total: Int64)? = nil

	/// Mapping rows selected in the MIDI Mapping window, for learn.
	@Published var mappingSelection = Set<Int>()
	/// True while the MIDI Mapping window is the key window (learn needs it).
	var mappingWindowIsKey = false
	@Published var playlistTitle = "Untitled Playlist"
	@Published var playlistModified = false
	var playlistURL: URL?
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
		case 7:	// the Geometry Mode target (engine.geometryMode is already set)
			changes.playlist.bump()
			changes.menus.bump()
		case 8:	// the Auto Advance target: 0 stop, 1 start, 2 the other way
			setAutoAdvance(value == 2 ? !engine.autoAdvancing : value != 0)
		case 10:	// the Random Phase target (the engine has done it): the readout
			showRandomPhase()
		case 11:	// the Rotate Hue target, done: its chips flash
			ActionFlash.shared.fire(.rotateHue)
		case 12:	// the Clear target, done: its chips flash
			ActionFlash.shared.fire(.clear)
		case 13:	// cue, then go's targets (Go, Cue Next, Bank Up, Pad n, ...)
			cueCommand(Int(value))
		case 9:	// the Blackout target: 0 back, 1 to black, 2 the other way
			setBlackout(value == 2 ? !engine.blackout : value != 0)
		case 5:	// a parameter, from a mapping
			let iParam = Int(value & 0xff)
			midiPending.params.insert(iParam)
			scheduleMidiRefresh()
			if let prop = WHParamProperty(rawValue: Int(value >> 8)) { showParam(iParam, prop) }
		case 6:	// a master property
			midiPending.master.insert(Int(value))
			scheduleMidiRefresh()
			showMaster(Int(value))
		default:	// 0: main properties or draw mode; 1: pause
			midiPending.main = true
			scheduleMidiRefresh()
			if kind == 0, value > 0, let prop = MainProp(rawValue: Int(value) - 1) {
				if prop == .drawMode { showDrawMode(from: knownDrawMode) } else { showMain(prop) }
			}
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
			if p.main {
				self.noteOriginMotion()
				self.changes.main.bump()
			}
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

	// The playlist and auto-advance: in AppModel+Playlist.swift
	/// Anything may have changed (a patch opened, undo, ...): refresh everything.
	func changed() {
		noteOriginMotion()
		changes.all()
		noteEdit()
		knownDrawMode = engine.drawMode
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
		noteOriginMotion()
		changes.main.bump()
		noteEdit()
		knownDrawMode = engine.drawMode
	}

	/// The origin has moved away from the patch's origin (Drag, Random or a
	/// press on the picture) and hasn't been centered since: parked, the
	/// Properties panel says Park, not Center, though the patch's origin,
	/// which Drag and Random don't change, is still the middle (2026-11-20).
	var originMoved = false

	private func noteOriginMotion() {
		if engine.originMotion == .drag || engine.originMotion == .random {
			originMoved = true
		}
	}

	/// Parked in the middle: what Image > Origin Center leaves
	var originAtCenter: Bool {
		engine.originMotion == .park && !originMoved && engine.origin == CGPoint(x: 0.5, y: 0.5)
	}

	/// A patch loaded (New, Open, played): its own origin, unless Geometry
	/// mode kept the one before
	func originFromPatch() {
		if !engine.geometryMode { originMoved = false }
	}

	/// After an edit: refresh the title if it went from saved to edited, and
	/// the menu bar if the Undo or Redo item changed (coalesced edits of one
	/// control don't change it).
	func noteEdit() {
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
	/// What the list edits (the playlist's patches, the Patches panel's
	/// removals) are registered on, apart from the patch's edits: playing
	/// or opening a patch clears the patch's undo (as Windows does), not
	/// theirs (the user's report, 2026-11-25: a click in the Patches panel
	/// plays the patch, and lost the removals' undo)
	final class ListUndo {}
	let listUndo = ListUndo()

	/// Undo for a setting kept as a whole (the Key Map, the Modulation rows;
	/// the user's request, 2026-11-25): each change that `note()` sees is
	/// recorded against the state before it, as a list edit (kept when a
	/// patch plays). Changes to the same thing within a second of each other
	/// (a slider's drag, typing) are one step. `batch` makes several changes
	/// one titled step; `quietly` changes that aren't steps on their own
	/// (a Key Map row made for a key badge, until the key lands).
	@MainActor
	final class SnapshotUndo<State: Equatable> {
		private var last: State?
		private var batching = 0, quiet = 0
		private var gesture = 0, lastTime = Date.distantPast
		private let read: () -> State
		private let write: (State) -> Void
		private let describe: (State, State) -> (key: String, title: String)

		init(read: @escaping () -> State, write: @escaping (State) -> Void,
			describe: @escaping (State, State) -> (key: String, title: String)) {
			self.read = read
			self.write = write
			self.describe = describe
		}

		/// the state as it starts (before any change is noted)
		func start() { last = read() }

		func note() {
			guard batching == 0, quiet == 0, let old = last else { return }
			let now = read()
			guard now != old else { return }
			last = now
			let (key, title) = describe(old, now)
			let t = Date()
			if t.timeIntervalSince(lastTime) > 1 { gesture += 1 }
			lastTime = t
			record(old, key: key + " \(gesture)", title: title)
		}

		func batch(_ title: String, _ body: () -> Void) {
			batching += 1
			body()
			batching -= 1
			guard let old = last else { return }
			let now = read()
			guard now != old else { return }
			last = now
			record(old, key: "\(title) \(UUID())", title: title)
		}

		func quietly(_ body: () -> Void) {
			quiet += 1
			body()
			quiet -= 1
		}

		/// a change that's no step (remote control, live): taken as the
		/// state from now on
		func unrecorded(_ body: () -> Void) {
			batching += 1
			body()
			batching -= 1
			if last != nil { last = read() }
		}

		private func record(_ old: State, key: String, title: String) {
			AppModel.shared.recordUndo(key: key, title: title, list: true) { [weak self] in
				guard let self else { return }
				let undone = self.read()
				self.batching += 1
				self.write(old)
				self.batching -= 1
				self.last = old
				self.record(undone, key: "\(title) \(UUID())", title: title)	// the redo
			}
		}
	}

	func recordUndo(key: String, title: String, list: Bool = false, restore: @escaping () -> Void) {
		let replaying = undoManager.isUndoing || undoManager.isRedoing
		if !replaying && key == coalesceKey && undoManager.canUndo {
			return
		}
		if list {
			undoManager.registerUndo(withTarget: listUndo) { _ in restore() }
		} else {
			undoManager.registerUndo(withTarget: self) { _ in restore() }
		}
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

	/// a patch played, opened or new: its edits' undo is let go, the
	/// lists' kept (ListUndo); `lists` too: a playlist new or opened
	func resetUndo(lists: Bool = false) {
		if lists {
			undoManager.removeAllActions()
		} else {
			undoManager.removeAllActions(withTarget: self)
		}
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
		showParam(iParam, prop)
	}

	// MARK: The stats strip's readout

	/// a parameter column's name, short, for the stats strip's readout:
	/// Ring Growth Amp, Freq, PW, Glob, Wave (the user's request, 2026-11-19)
	static func shortParamTitle(_ iParam: Int, _ prop: WHParamProperty) -> String {
		let base = WHControls.paramName(iParam)
		switch prop {
		case .amp: return base + " Amp"
		case .freq: return base + " Freq"
		case .PW: return base + " PW"
		case .global: return base + " Glob"
		case .wave: return base + " Wave"
		default: return base
		}
	}

	/// The last control changed by hand, MIDI or OSC (not by modulation or
	/// a patch loading), with its new value, in the stats strip (View > Show
	/// Stats; the user's request, 2026-11-19).
	func showParam(_ iParam: Int, _ prop: WHParamProperty) {
		let v = engine.paramValue(iParam, property: prop)
		let shown: String
		switch prop {
		case .wave: shown = WHControls.waveformName(Int(v))
		case .global: shown = paramText(v, WHControls.globalControl(iParam))	// as the edit boxes show it
		default:
			let column = prop == .amp ? 1 : prop == .freq ? 2 : prop == .PW ? 3 : 0
			shown = paramText(v, WHControls.paramControl(iParam, column: column))
		}
		StripFeed.shared.setReadout(Self.shortParamTitle(iParam, prop) + "  " + shown, full: Self.paramTitle(iParam, prop) + "  " + shown)
	}

	func showMaster(_ iProp: Int) {
		StripFeed.shared.setReadout(WHControls.masterName(iProp) + "  "
			+ masterText(iProp, engine.masterValue(iProp)))
	}

	func showMain(_ prop: MainProp) {
		let shown: String
		switch prop {
		case .origin:
			let o = engine.liveOrigin
			shown = String(format: "%.3f, %.3f", o.x, o.y)
		case .drawMode:
			let m = engine.drawMode
			let parts = (m & Self.drawModeFill != 0 ? ["Fill"] : []) + (m & Self.drawModeOutline != 0 ? ["Outline"] : [])
				+ (m & Self.drawModeXRay != 0 ? ["XRay"] : [])
			shown = parts.isEmpty ? "Lines" : parts.joined(separator: " + ")
		case .orgMotion:
			switch engine.originMotion {
			case .drag: shown = "Drag"
			case .random: shown = "Random"
			default: shown = "Park"
			}
		case .hue:
			shown = hueText(engine.hue) + "°"
		default:
			shown = isOn(prop) ? "On" : "Off"
		}
		// the draw mode by what's on, never "Draw Mode" (the user's request,
		// 2026-11-25): "Fill + Outline", or "Lines"
		StripFeed.shared.setReadout(prop == .drawMode ? shown : WHControls.mainName(prop.rawValue) + "  " + shown)
	}

	func setMaster(_ iProp: Int, _ value: Double) {
		let old = engine.masterValue(iProp)
		guard old != value else { return }
		recordUndo(key: "master \(iProp)", title: WHControls.masterName(iProp)) { [weak self] in
			self?.setMaster(iProp, old)
		}
		engine.setMasterValue(value, prop: iProp)
		masterChanged(iProp)
		showMaster(iProp)
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
		showMaster(MasterProp.zoom.rawValue)
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
		showMain(.origin)
	}

	func setHue(_ hue: Double) {
		let old = engine.hue
		guard old != hue else { return }
		recordUndo(key: "main \(MainProp.hue.rawValue)", title: WHControls.mainName(MainProp.hue.rawValue)) { [weak self] in
			self?.setHue(old)
		}
		engine.hue = hue
		mainChanged()
		showMain(.hue)
	}

	/// Image > Rotate Hue (V1's, F3): existing rings turn 90 degrees and
	/// Hue goes up 90 so new rings follow. Undo restores Hue; colors already
	/// given to existing rings stay, as in V1.
	/// `readout` false: modulation's, which never takes the readout (the
	/// user's report, 2026-11-25: its Rotate Hue showed there, and on the
	/// info overlay, as if changed by hand)
	func rotateHue(readout: Bool = true) {
		let old = engine.hue
		recordUndo(key: "rotate hue", title: "Rotate Hue") { [weak self] in
			self?.setHue(old)
		}
		engine.rotateHue()
		mainChanged()
		if readout { showMain(.hue) }
		ActionFlash.shared.fire(.rotateHue)	// its chips flash
	}

	func setDrawMode(_ mode: UInt32) {
		let old = engine.drawMode
		guard old != mode else { return }
		// titled by the switch ("Undo Fill"), never "Draw Mode" (the user's request, 2026-11-25)
		let one: [UInt32: String] = [Self.drawModeFill: "Fill", Self.drawModeOutline: "Outline", Self.drawModeXRay: "XRay"]
		recordUndo(key: "main \(MainProp.drawMode.rawValue)", title: one[old ^ mode] ?? "Fill and Outline") { [weak self] in
			self?.setDrawMode(old)
		}
		engine.setDrawMode(mode)
		mainChanged()
		showDrawMode(from: old)
	}

	/// The readout for a draw mode change: one switch flipped says just that
	/// ("Fill  On", "Outline  Off", "XRay  On", as the other switches; the
	/// user's requests, 2026-11-24 and 25); several at once (undo, a patch)
	/// the draw mode ("Draw Mode  Fill + Outline")
	func showDrawMode(from old: UInt32?) {
		let new = engine.drawMode
		knownDrawMode = new
		let names: [(UInt32, String)] = [(Self.drawModeFill, "Fill"), (Self.drawModeOutline, "Outline"), (Self.drawModeXRay, "XRay")]
		if let old, let (bit, name) = names.first(where: { $0.0 == old ^ new }) {
			StripFeed.shared.setReadout(name + "  " + (new & bit != 0 ? "On" : "Off"))
		} else {
			showMain(.drawMode)
		}
	}

	/// Image > Random Phase (F9), by hand, MIDI or OSC, shown in the
	/// Perform Bar's readout (the user's request, 2026-11-24); modulation
	/// calls the engine directly, so it doesn't show, as with the controls
	func randomPhase() {
		engine.randomPhase()
		showRandomPhase()
	}

	func showRandomPhase() {
		StripFeed.shared.setReadout("Random Phase")
		ActionFlash.shared.fire(.randomPhase)	// its chips flash
	}

	/// Image > Clear (Delete), by hand: its chips flash
	func clear() {
		engine.clear()
		ActionFlash.shared.fire(.clear)
	}

	func setOriginMotion(_ motion: WHOriginMotion) {
		let old = engine.originMotion
		guard old != motion else { return }
		recordUndo(key: "main \(MainProp.orgMotion.rawValue)", title: WHControls.mainName(MainProp.orgMotion.rawValue)) { [weak self] in
			self?.setOriginMotion(old)
		}
		engine.setOriginMotion(motion)
		mainChanged()
		showMain(.orgMotion)
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
		showMain(prop)
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
	static let drawModeXRay: UInt32 = 0x04		// DM_XRAY: XOR mode, V1's X-Ray (V2 ignores it)

	/// Pause, from the keyboard or the Properties' chip: the chip redraws
	func togglePause() {
		engine.togglePause()
		changes.main.bump()
	}

	func toggleFill() { setDrawMode(engine.drawMode ^ Self.drawModeFill) }
	func toggleOutline() { setDrawMode(engine.drawMode ^ Self.drawModeOutline) }
	func toggleXRay() { setDrawMode(engine.drawMode ^ Self.drawModeXRay) }

	// CWhorldDoc::OnImageOriginCenter
	func originCenter() {
		originMoved = false
		setOriginMotion(.park)
		setOrigin(CGPoint(x: 0.5, y: 0.5))
	}

	func toggleOriginDrag() { setOriginMotion(engine.originMotion == .drag ? .park : .drag) }
	func toggleOriginRandom() { setOriginMotion(engine.originMotion == .random ? .park : .random) }

	// CWhorldDoc::OnMouseWheel: zoom (Windows: damping with Shift), in
	// normalized slider space (CWhorldDoc::OffsetMasterProp). Mac addition:
	// with a key held over the picture (OutputKeys), that key's control
	// instead. Shift no longer means Damping (the user's request, 2026-11-24:
	// it's the coarse modifier, with a key held or not, as everywhere; D in
	// the Key Map moves Damping). `shift` is the views' concern: a mouse
	// wheel turned with Shift scrolls sideways.
	func wheel(notches: Double, shift: Bool, momentum: Bool = false, inverted: Bool = false, trackpad: Bool = false) {
		// a mouse wheel: Wheel sensitivity; a trackpad swipe: Trackpad
		// sensitivity times the wheel's default (the user's request,
		// 2026-11-19; swipes followed Wheel sensitivity before)
		let delta = notches * (trackpad ? Preferences.defaultWheelSense * Preferences.swipeSense : Preferences.wheelSense) / 100
		if momentum && (outputKeys.held != nil || outputKeys.lastWheelWasKeyed) {
			return	// no coasting after a key swipe, nor turning into zoom when the key lifts
		}
		if let target = outputKeys.heldTarget {
			outputKeys.lastWheelWasKeyed = true
			// finer or coarser with the modifiers, as on the panels (ModifierLadder)
			let d = delta * ModifierLadder.factor(NSEvent.modifierFlags)
			adjust(target, by: inverted ? -d : d)	// fingers or wheel up: more, whatever the scrolling direction
			return
		}
		if !momentum {
			outputKeys.lastWheelWasKeyed = false
		}
		let iProp = MasterProp.zoom.rawValue
		let old = engine.masterValue(iProp)
		// finer or coarser with the modifiers, as a key's control (ModifierLadder)
		var norm = WHControls.masterNorm01(iProp, value: old) + delta * ModifierLadder.factor(NSEvent.modifierFlags)
		norm = min(max(norm, 0), 1)
		let value = WHControls.masterDenorm01(iProp, value: norm)
		guard value != old else { return }
		setZoom(value)
	}

	let outputKeys = OutputKeys()

	/// The stats strip's tag beside Auto: what Automatic quality has lowered
	/// ("curves 1.0 px, 75%"), from WHEngine's status ("auto: curves 1.0 px,
	/// scale 75%"); nothing when it's off or everything is as set.
	static func autoTag(_ status: String) -> String {
		guard status.hasPrefix("auto:"), status != "auto: as set" else { return "" }
		return status.dropFirst("auto:".count).trimmingCharacters(in: .whitespaces)
			.replacingOccurrences(of: "scale ", with: "")
	}

	/// A key's control, moved by `delta` (in the units of a slider's travel,
	/// 0 to 1) times the key's speed; with the readout on, shows the result.
	/// `apply` false only shows the control and its value, changing nothing.
	/// ↑ or ↓ with a Key Map key held over the picture (the user's request,
	/// 2026-11-25): its control steps as a focused number box's does, by
	/// the normal step (1% of a slider's range, or an increment) scaled by
	/// the modifiers (KeyStep, Settings > Input > Modifier steps), or to an
	/// end with Shift-Command; times the key's speed, as a swipe
	func keyStep(_ b: KeyBinding, up: Bool, _ k: KeyStep) {
		switch k {
		case .end: adjust(b, by: up ? 1 : -1, scaled: false)
		case .by(let f): adjust(b, by: (up ? 1 : -1) * 0.01 * f)
		}
	}

	private func adjust(_ b: KeyBinding, by delta: Double, apply: Bool = true, scaled: Bool = true) {
		guard let t = b.targetIndex else { return }
		let d = delta * (scaled ? b.speed : 1)
		let nParams = WHMappingInfo.paramTargetCount, nMaster = WHMappingInfo.masterTargetCount
		var shown = ""
		if t < nParams {
			shown = adjustParam(t, WHParamProperty(rawValue: b.prop) ?? .val, d, apply: apply)
		} else if t < nParams + nMaster {
			let i = t - nParams
			let old = engine.masterValue(i)
			let value = WHControls.masterDenorm01(i, value: min(max(WHControls.masterNorm01(i, value: old) + d, 0), 1))
			if apply, value != old {
				if i == MasterProp.zoom.rawValue {
					setZoom(value)	// damped, as the wheel's zoom
				} else {
					setMaster(i, value)
				}
			}
			shown = masterText(i, engine.masterValue(i))
		} else {
			switch b.target {
			case "Hue":	// degrees, 0 to 360
				if apply { setHue(min(max(engine.hue + d * 360, 0), 360)) }
				shown = hueText(engine.hue) + "°"
			case "OriginX", "OriginY":	// normalized, 0 to 1
				var p = engine.liveOrigin
				if b.target == "OriginX" {
					p.x = min(max(p.x + d, 0), 1)
				} else {
					p.y = min(max(p.y + d, 0), 1)
				}
				if apply { setOrigin(p) }
				shown = String(format: "%.3f", b.target == "OriginX" ? p.x : p.y)
			default:
				return
			}
		}
		let short = t < nParams ? Self.shortParamTitle(t, WHParamProperty(rawValue: b.prop) ?? .val) : b.displayName
		StripFeed.shared.setReadout(short + "  " + shown, full: b.displayName + "  " + shown, key: b.keyLabel)
	}

	/// A two-finger tap (a secondary click) over the picture while a key in
	/// the key map is held: that key's control goes back to its value in the
	/// patch as loaded (opened, played from the playlist, or new) or last saved.
	/// With no key held, what a swipe there moves (wheel) goes back the same
	/// way: Zoom (Damping with Shift until 2026-11-24; the user's requests, 2026-11-21).
	/// Returns false with another modifier held, so the click goes on as usual.
	func resetHeldKeyControl() -> Bool {
		guard let b = outputKeys.heldTarget, let t = b.targetIndex else {
			switch NSEvent.modifierFlags.intersection([.shift, .command, .control, .option]) {
			case [], .shift:	// what a swipe there moves: Zoom (Shift was Damping until 2026-11-24)
				setZoom(engine.loadedMasterValue(MasterProp.zoom.rawValue))
			default:
				return false
			}
			return true
		}
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
		adjust(b, by: 0, apply: false)	// the readout
		return true
	}

	/// A key in the key map, pressed over the picture: the Perform Bar's
	/// readout names its control and value before anything moves, so a wrong
	/// key can be let go unused (the user's request, 2026-11-21)
	func showKeyControl(_ b: KeyBinding) {
		adjust(b, by: 0, apply: false)
	}

	/// A parameter column, moved: Value and Global along their sliders; the
	/// oscillator columns (number boxes only) within the box's limits, or by
	/// its stepper increments (one per hundredth of travel) if it has none.
	/// Returns the new value as the panel shows it.
	private func adjustParam(_ i: Int, _ prop: WHParamProperty, _ d: Double, apply: Bool = true) -> String {
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
		if apply, value != old {
			setParam(i, prop, value)
		}
		return paramText(engine.paramValue(i, property: prop), ci)	// as the edit boxes show it
	}

	// Patch files: open, save, the title: in AppModel+Files.swift (its state stays here)
	/// The name of the patch last played from the playlist, while the
	/// document is that patch. As on Windows (CWhorldDoc::SetPatch), playing
	/// a playlist patch detaches the document from its file, so Save asks
	/// where; the title shows the patch's name, not "Untitled" (Mac port).
	var playedName: String?
	var authorCache: [String: (date: Date?, author: String)] = [:]
	// Full screen, other displays, and presses on the picture: in AppModel+Display.swift (its state stays here)
	let fullScreen = FullScreenController()
	var screensWatch: NSObjectProtocol?
	/// Where the output was before full screen, put back when it ends: docked,
	/// or detached in its window's frame (the user's request, 2026-11-21)
	struct FullScreenOrigin {
		var detached: Bool
		var frame: NSRect?		// the detached window's
		var savedFrame: String?	// docked: the detached window's remembered frame
	}
	var fullScreenOrigin: FullScreenOrigin?
	/// Where a press on the full-screen picture started: the origin motion and
	/// origin to restore on undo. Nil when no press is moving the origin.
	var pressDrag: (motion: WHOriginMotion, origin: CGPoint)?
	var pressCount = 0
	var lastPress: (motion: WHOriginMotion, origin: CGPoint, time: TimeInterval)?
	// MARK: OSC

	/// Why OSC isn't running (a port in use, a bad host), or nil.
	@Published private(set) var oscError: String?
	private var oscTimer: Timer?

	/// Starts (or stops) OSC remote control as Settings > Input > OSC says. Whorld
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

	/// Syphon output is on (View > Syphon and the stats strip)
	@Published private(set) var syphonEnabled = false
	/// the fixed size Syphon sends, or nil for the output's own
	@Published private(set) var syphonSize: (width: Int, height: Int)?

	/// Starts, stops or resizes Syphon output as the settings say (View >
	/// Syphon and the stats strip; in Settings > Output until 2026-11-19).
	func applySyphon() {
		let s = Preferences.syphon
		syphonEnabled = s.enabled
		syphonSize = s.fixedSize
		engine.setSyphonEnabled(s.enabled, width: s.fixedSize?.width ?? 0, height: s.fixedSize?.height ?? 0)
		StripFeed.shared.setSyphon(syphonState)
	}

	/// for the stats strip's dot: 0 off, 1 publishing with no app receiving,
	/// 2 an app receiving
	var syphonState: Int {
		!engine.syphonRunning ? 0 : engine.syphonHasClients ? 2 : 1
	}

	/// View > Syphon's sizes: nil is the output's own size
	func setSyphonSize(_ size: (width: Int, height: Int)?) {
		let d = UserDefaults.standard
		d.set(size != nil, forKey: "Syphon_bFixedSize")
		if let size {
			d.set(size.width, forKey: "Syphon_nWidth")
			d.set(size.height, forKey: "Syphon_nHeight")
		}
		applySyphon()
	}

	static let syphonPresets: [(width: Int, height: Int)] = [(1280, 720), (1920, 1080), (3840, 2160)]

	/// View > Syphon > Custom Size…: a width and height in pixels
	func askSyphonSize() {
		let cur = syphonSize ?? (Preferences.syphonStoredSize)
		let a = NSAlert()
		a.messageText = "Syphon Size"
		a.informativeText = "Each frame is drawn again at this size in pixels for Syphon, the picture scaled to fit, with more of the pattern on the longer side."
		let fmt = NumberFormatter()
		fmt.allowsFloats = false
		fmt.minimum = 16
		fmt.maximum = 16384
		func field(_ v: Int) -> NSTextField {
			let f = NSTextField(string: String(v))
			f.formatter = fmt
			f.alignment = .right
			f.frame.size.width = 70
			return f
		}
		let w = field(cur.width), h = field(cur.height)
		let times = NSTextField(labelWithString: "×")
		let row = NSStackView(views: [w, times, h])
		row.spacing = 6
		w.widthAnchor.constraint(equalToConstant: 70).isActive = true
		h.widthAnchor.constraint(equalToConstant: 70).isActive = true
		row.frame = NSRect(x: 0, y: 0, width: 170, height: 24)
		a.accessoryView = row
		a.addButton(withTitle: "OK")
		a.addButton(withTitle: "Cancel")
		a.window.initialFirstResponder = w
		guard a.runModal() == .alertFirstButtonReturn else { return }
		let width = min(max(w.integerValue, 16), 16384), height = min(max(h.integerValue, 16), 16384)
		setSyphonSize((width, height))
	}

	func setSyphonEnabled(_ on: Bool) {
		UserDefaults.standard.set(on, forKey: "Syphon_bEnabled")
		applySyphon()
	}

	// The workspace: Detach, Show All Panels, layouts: in AppModel+Workspace.swift (its state stays here)
	var pendingLayout: LayoutFile?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	private var secondKeysMonitor: Any?

	func applicationDidFinishLaunching(_ notification: Notification) {
		StandardViewMenu.removeWhenAdded()
		MainActor.assumeIsolated {
			WhorldFolders.makeOnce()
			WhorldFolders.installSamples()
		}
		NumberBoxSelect.install()
		TitleBarClicks.install()
		ClickAway.install()
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
	// not observed here: the scenes' views observe it themselves, and the
	// menu bar refreshes through MenuRefresh (a change here rebuilt it)
	private let model = AppModel.shared

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

		// Modulation (audio modulation; Modulation.swift), floating: a panel
		// since 2026-11-18, its window's id as before, so its place is kept
		Window("Modulation", id: "modulation") {
			FloatingPanel(id: .modulation).environmentObject(model)
		}
		.commandsRemoved()
		.defaultSize(width: 1280, height: 760)	// the two-column layout

		// View > Key Map (keys held over the picture; KeyMap.swift): a panel
		// since 2026-11-18, floating here (the window's id is its PanelID)
		Window("Patches", id: PanelID.patches.rawValue) {
			FloatingPanel(id: .patches).environmentObject(model)
		}
		.commandsRemoved()
		.defaultSize(width: 320, height: 520)

		Window("Key Map", id: PanelID.keymap.rawValue) {
			FloatingPanel(id: .keymap).environmentObject(model)
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
		// a new install: the sample playlist, playing its first patch, so
		// there's a patch to see and a playlist to step through (the user's
		// request, 2026-11-23); not over a file opened at launch
		if WhorldFolders.isFirstLaunch, !openedPlaylist, !openedPatch,
			let dir = WhorldFolders.existing(.playlists) {
			let url = dir.appendingPathComponent(WhorldFolders.samplePlaylistName)
			if FileManager.default.fileExists(atPath: url.path) {
				model.openPlaylist(url)
				if model.playlistURL == url, !model.engine.playlistPatches.isEmpty {
					model.playPatch(0)
				}
				return
			}
		}
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
