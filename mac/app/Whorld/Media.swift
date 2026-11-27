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
import UniformTypeIdentifiers

// Snapshots, image export, movies and the playlist window (Phase 6).
// Specs: CMainFrame (OnFileTakeSnapshot, OnFileLoadSnapshot, OnSnapshot*,
// OnFileExport, OnSnapshotExportAll, OnMovie*), CExportDlg,
// CMovieExportDlg, CMovieBar, CPlaylistBar, CMissingFilesDlg.

extension UTType {
	static let whorldSnapshot = UTType(filenameExtension: "whs") ?? .data
	static let whorldMovie = UTType(filenameExtension: "whm") ?? .data
}

/// Export options shown before an export (CExportDlg), stored in Preferences.
struct ExportOptions {
	var useViewSize: Bool
	var width: Int
	var height: Int
	var scaleToFit: Int	// 0 none, 1 width, 2 height, 3 both (SCALETOFITDEF)

	static func load() -> ExportOptions {
		Preferences.register()
		let d = Preferences.defaults
		return ExportOptions(useViewSize: d.bool(forKey: "Export_bUseViewSize"),
			width: d.integer(forKey: "Export_nImageWidth"), height: d.integer(forKey: "Export_nImageHeight"),
			scaleToFit: d.integer(forKey: "Export_nScaleToFit"))
	}

	func save() {
		let d = Preferences.defaults
		d.set(useViewSize, forKey: "Export_bUseViewSize")
		d.set(width, forKey: "Export_nImageWidth")
		d.set(height, forKey: "Export_nImageHeight")
		d.set(scaleToFit, forKey: "Export_nScaleToFit")
	}

	// COptions::GetExportFlags
	var flags: WHExportFlags {
		var f: WHExportFlags = []
		if useViewSize { f.insert(.useViewSize) }
		switch scaleToFit {
		case 1: f.insert(.fitWidth)
		case 2: f.insert(.fitHeight)
		case 3: f.formUnion([.fitWidth, .fitHeight])
		default: break
		}
		return f
	}
}

extension AppModel {

	// MARK: Export helpers

	var exportFolder: URL {
		Preferences.register()
		let path = Preferences.defaults.string(forKey: "Export_sImageFolder") ?? ""
		if !path.isEmpty {
			return URL(fileURLWithPath: path)
		}
		// none chosen: Documents/Whorld/Exports (the user's request,
		// 2026-11-22), or Pictures, as Windows, if it's gone
		if let exports = WhorldFolders.existing(.exports) { return exports }
		return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory())	// SetDefaultExportImageFolder: Pictures
	}

	/// CMainFrame::PromptingForExport: prompt unless full screen on the only screen.
	var promptingForExport: Bool {
		Preferences.register()
		let fullScreenSingle = isFullScreen && NSScreen.screens.count == 1
		return Preferences.defaults.bool(forKey: "Export_bPromptUser") && !fullScreenSingle
	}

	/// CMainFrame::MakeUniqueExportPath with CWhorldApp::GetTimestampFileName
	/// (UTC, like GetSystemTime): Whorld-YYYY-MM-DD-hh-mm-ss-mmm.ext
	func makeUniqueExportPath(_ ext: String, in folder: URL? = nil) -> URL? {
		let folder = folder ?? exportFolder
		var isDir: ObjCBool = false
		guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
			alert("The export folder doesn't exist.", folder.path)
			return nil
		}
		var cal = Calendar(identifier: .gregorian)
		cal.timeZone = TimeZone(identifier: "UTC")!
		let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: Date())
		let base = String(format: "Whorld-%04d-%02d-%02d-%02d-%02d-%02d-%03d", c.year!, c.month!, c.day!,
			c.hour!, c.minute!, c.second!, c.nanosecond! / 1_000_000)
		var url = folder.appendingPathComponent(base + "." + ext)
		var retries = 0
		while FileManager.default.fileExists(atPath: url.path) {
			retries += 1
			url = folder.appendingPathComponent(base + "(\(retries))." + ext)
		}
		return url
	}

	func alert(_ message: String, _ info: String = "") {
		let a = NSAlert()
		a.messageText = message
		a.informativeText = info
		a.runModal()
	}

	private func savePanel(_ type: UTType, title: String, name: String, in folder: URL? = nil) -> URL? {
		let panel = NSSavePanel()
		panel.title = title
		if let folder { panel.directoryURL = folder }
		panel.allowedContentTypes = [type]
		panel.nameFieldStringValue = name
		return panel.runModal() == .OK ? panel.url : nil
	}

	/// The export options dialog (CExportDlg). Returns nil if canceled.
	func runExportOptions() -> ExportOptions? {
		var opts = ExportOptions.load()
		let viewSize = engine.viewSize
		let host = NSHostingView(rootView: AccessoryState(opts, onChange: { opts = $0 }) {
			ExportOptionsView(options: $0, viewSize: viewSize)
		})
		host.frame = NSRect(x: 0, y: 0, width: 440, height: 130)
		let a = NSAlert()
		a.messageText = "Export Options"
		a.accessoryView = host
		a.addButton(withTitle: "Export")
		a.addButton(withTitle: "Cancel")
		guard a.runModal() == .alertFirstButtonReturn else { return nil }
		opts.save()
		return opts
	}

	// MARK: Snapshots

	// CMainFrame::OnFileTakeSnapshot and WriteSnapshot. Into
	// Documents/Whorld/Snapshots, not the export folder, where it's there
	// (the user's request, 2026-11-22); the dialog starts where the last
	// snapshot went.
	func takeSnapshot() {
		let url: URL?
		if promptingForExport {
			url = savePanel(.whorldSnapshot, title: "Snapshot Save As", name: "Untitled.whs",
				in: WhorldFolders.start(.snapshots))
			if let url { WhorldFolders.used(.snapshots, url) }
		} else {
			url = makeUniqueExportPath("whs", in: WhorldFolders.existing(.snapshots))
		}
		guard let url else { return }
		engine.takeSnapshot(toPath: url.path) { [weak self] error in
			if let error { self?.alert("Can't save the snapshot.", error) }
		}
	}

	// CMainFrame::OnFileLoadSnapshot
	func loadSnapshots() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.whorldSnapshot]
		panel.allowsMultipleSelection = true
		panel.directoryURL = WhorldFolders.start(.snapshots)
		guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
		WhorldFolders.used(.snapshots, panel.urls[0])
		loadSnapshots(panel.urls)
	}

	func loadSnapshots(_ urls: [URL]) {
		snapshotPaths = urls
		currentSnapshot = 0	// reset current snapshot index
		loadSnapshot(0)	// load the first snapshot
	}

	@discardableResult
	func loadSnapshot(_ index: Int) -> Bool {
		guard index >= 0, index < snapshotPaths.count else { return false }
		do {
			try engine.loadSnapshot(atPath: snapshotPaths[index].path)
			currentSnapshot = index
			changed()
			return true
		} catch {
			NSAlert(error: error).runModal()
			return false
		}
	}

	var hasSnapshots: Bool { !snapshotPaths.isEmpty }

	func snapshotFirst() { if currentSnapshot > 0 { loadSnapshot(0) } }
	func snapshotLast() { if currentSnapshot < snapshotPaths.count - 1 { loadSnapshot(snapshotPaths.count - 1) } }
	func snapshotNext() { if currentSnapshot < snapshotPaths.count - 1 { loadSnapshot(currentSnapshot + 1) } }
	func snapshotPrev() { if currentSnapshot > 0 { loadSnapshot(currentSnapshot - 1) } }

	var isCurrentSnapshotValid: Bool {
		currentSnapshot >= 0 && currentSnapshot < snapshotPaths.count
	}

	// CMainFrame::OnSnapshotInfo
	func snapshotInfo() {
		guard isCurrentSnapshotValid, let info = WHEngine.snapshotInfo(atPath: snapshotPaths[currentSnapshot].path) else { return }
		alert("Snapshot", info)
	}

	// MARK: Image export

	// CMainFrame::OnFileExport
	func exportImage() {
		var url: URL?
		var opts = ExportOptions.load()
		if promptingForExport {
			var name = "Untitled"
			if engine.snapshotMode {
				if isCurrentSnapshotValid {
					name = snapshotPaths[currentSnapshot].deletingPathExtension().lastPathComponent
				}
			} else if engine.patchPath != nil {
				name = title
			}
			guard let picked = savePanel(.png, title: "Export Save As", name: name + ".png") else { return }
			guard let o = runExportOptions() else { return }
			url = picked
			opts = o
		} else {
			url = makeUniqueExportPath("png")
		}
		guard let url else { return }
		engine.exportImage(toPath: url.path, flags: opts.flags, width: Int32(opts.width), height: Int32(opts.height)) { [weak self] error in
			if let error { self?.alert("Can't export the image.", error) }
		}
	}

	// CMainFrame::OnSnapshotExportAll
	func exportAllSnapshots() {
		guard hasSnapshots else { return }
		var folder = exportFolder
		var opts = ExportOptions.load()
		if promptingForExport {
			let panel = NSOpenPanel()
			panel.title = "Export All Snapshots"
			panel.canChooseDirectories = true
			panel.canChooseFiles = false
			panel.canCreateDirectories = true
			panel.directoryURL = folder
			guard panel.runModal() == .OK, let picked = panel.url else { return }
			guard let o = runExportOptions() else { return }
			folder = picked
			opts = o
		}
		guard FileManager.default.fileExists(atPath: folder.path) else {
			alert("The export folder doesn't exist.", folder.path)
			return
		}
		var failures: [String] = []
		let total = snapshotPaths.count
		var done = 0
		for (i, snap) in snapshotPaths.enumerated() {
			guard loadSnapshot(i) else { continue }	// load snapshot in render thread
			let out = folder.appendingPathComponent(snap.deletingPathExtension().lastPathComponent + ".png")
			engine.exportImage(toPath: out.path, flags: opts.flags, width: Int32(opts.width), height: Int32(opts.height)) { [weak self] error in
				done += 1
				if let error { failures.append(out.lastPathComponent + ": " + error) }
				if done == total, !failures.isEmpty {
					self?.alert("Some snapshots couldn't be exported.", failures.joined(separator: "\n"))
				}
			}
		}
	}

	// MARK: Movies

	var movieState: WHMovieState { engine.movieState }

	// CMainFrame::OnMovieRecord
	func toggleRecordMovie() {
		if movieState.io != .closed {	// if movie is open
			if movieState.io == .writing { engine.recordMovie(toPath: nil) }	// stop recording
			changed()
			return
		}
		// into Documents/Whorld/Movies, where it's there (the user's request,
		// 2026-11-22), as snapshots
		let url: URL?
		if promptingForExport {
			url = savePanel(.whorldMovie, title: "Movie Save As", name: "Untitled.whm", in: WhorldFolders.start(.movies))
			if let url { WhorldFolders.used(.movies, url) }
		} else {
			url = makeUniqueExportPath("whm", in: WhorldFolders.existing(.movies))
		}
		guard let url else { return }
		engine.recordMovie(toPath: url.path)	// start recording
		changed()
	}

	// CMainFrame::OnMoviePlay
	func togglePlayMovie() {
		if movieState.io != .closed {	// if movie is open
			if movieState.io == .reading {
				engine.playMovie(atPath: nil, paused: false)	// stop playback
			}
			changed()
			return
		}
		let panel = NSOpenPanel()
		panel.title = "Movie Open"
		panel.allowedContentTypes = [.whorldMovie]
		panel.directoryURL = WhorldFolders.start(.movies)
		guard panel.runModal() == .OK, let url = panel.url else { return }
		WhorldFolders.used(.movies, url)
		playMovie(url)
	}

	func playMovie(_ url: URL) {
		if movieState.io == .reading {
			engine.playMovie(atPath: nil, paused: false)
		}
		snapshotPaths = []	// can't display snapshots while playing movie
		engine.playMovie(atPath: url.path, paused: false)	// start playback
		changed()
	}

	func rewindMovie() {
		engine.seekMovie(0)	// CMainFrame::OnMovieRewind
	}

	// CMainFrame::OnMovieExport
	func exportMovie() {
		let ms = movieState
		guard ms.io == .reading, ms.frameCount > 0 else { return }
		let panel = NSOpenPanel()
		panel.title = "Export Movie"
		panel.message = "Choose a folder for the image sequence."
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.canCreateDirectories = true
		panel.directoryURL = exportFolder
		guard panel.runModal() == .OK, let folder = panel.url else { return }
		// options (CMovieExportDlg)
		var opts = MovieExportOptions(frameCount: ms.frameCount, frameRate: ms.frameRate, movieSize: ms.frameSize)
		let viewSize = engine.viewSize
		let host = NSHostingView(rootView: AccessoryState(opts, onChange: { opts = $0 }) {
			MovieExportOptionsView(options: $0, viewSize: viewSize)
		})
		host.frame = NSRect(x: 0, y: 0, width: 440, height: 190)
		let a = NSAlert()
		a.messageText = "Export Movie"
		a.accessoryView = host
		a.addButton(withTitle: "Export")
		a.addButton(withTitle: "Cancel")
		guard a.runModal() == .alertFirstButtonReturn else { return }
		Preferences.defaults.set(folder.path, forKey: "Export_sImageFolder")	// movie and image export share the folder
		// check for a pre-existing image sequence; the original deletes all
		// .png files in the folder after confirming; here they go to the Trash
		let fm = FileManager.default
		let pngs = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
			.filter { $0.pathExtension.lowercased() == "png" }
		if fm.fileExists(atPath: folder.appendingPathComponent("img000000.png").path) {
			let w = NSAlert()
			w.alertStyle = .warning
			w.messageText = "The folder already contains an image sequence."
			w.informativeText = "Exporting moves the \(pngs.count) PNG files in this folder to the Trash. Continue?"
			w.addButton(withTitle: "Cancel")
			w.addButton(withTitle: "Move to Trash and Export")
			guard w.runModal() == .alertSecondButtonReturn else { return }
		}
		for url in pngs {
			try? fm.trashItem(at: url, resultingItemURL: nil)
		}
		let (start, end) = opts.range
		let total = end - start + 1
		movieExportProgress = (0, total)
		engine.exportMovie(toFolder: folder.path, start: start, end: end, flags: opts.flags,
			width: Int32(opts.size.width), height: Int32(opts.size.height),
			progress: { [weak self] done in self?.movieExportProgress = (done, total) },
			completion: { [weak self] error in
				self?.movieExportProgress = nil
				if let error { self?.alert("The movie export stopped.", error) }
			})
	}

	// Video export (new in the Mac port): the playing movie to a .mov
	func exportMovieVideo() {
		let ms = movieState
		guard ms.io == .reading, ms.frameCount > 0 else { return }
		let name = "Untitled.mov"
		guard let url = savePanel(.quickTimeMovie, title: "Export Video", name: name) else { return }
		var opts = MovieExportOptions(frameCount: ms.frameCount, frameRate: ms.frameRate, movieSize: ms.frameSize)
		opts.showsCodec = true
		opts.codec = Preferences.defaults.integer(forKey: "Video_iCodec")
		let viewSize = engine.viewSize
		let host = NSHostingView(rootView: AccessoryState(opts, onChange: { opts = $0 }) {
			MovieExportOptionsView(options: $0, viewSize: viewSize)
		})
		host.frame = NSRect(x: 0, y: 0, width: 440, height: 220)
		let a = NSAlert()
		a.messageText = "Export Video"
		a.informativeText = String(format: "Frames are encoded at the movie's rate, %g fps.", ms.frameRate)
		a.accessoryView = host
		a.addButton(withTitle: "Export")
		a.addButton(withTitle: "Cancel")
		guard a.runModal() == .alertFirstButtonReturn else { return }
		Preferences.defaults.set(opts.codec, forKey: "Video_iCodec")
		let (start, end) = opts.range
		let total = end - start + 1
		movieExportProgress = (0, total)
		engine.exportMovieVideo(toPath: url.path, codec: opts.codec, start: start, end: end, flags: opts.flags,
			width: Int32(opts.size.width), height: Int32(opts.size.height),
			progress: { [weak self] done in self?.movieExportProgress = (done, total) },
			completion: { [weak self] error in
				self?.movieExportProgress = nil
				if let error, error != "Canceled." { self?.alert("The video export stopped.", error) }
			})
	}

	// Audio-reactive video (9.9): the patch, moved by an audio file through
	// the Modulation window's rows, with the audio as its sound
	func exportAudioVideo() {
		let open = NSOpenPanel()
		open.title = "Choose the Music"
		open.allowedContentTypes = [.audio]
		guard open.runModal() == .OK, let audio = open.url else { return }
		var opts = AudioVideoExportOptions.load()
		let viewSize = engine.viewSize
		let host = NSHostingView(rootView: AccessoryState(opts, onChange: { opts = $0 }) {
			AudioVideoExportView(options: $0, viewSize: viewSize)
		})
		host.frame = NSRect(x: 0, y: 0, width: 440, height: 280)
		let a = NSAlert()
		a.messageText = "Export Audio-Reactive Video"
		a.informativeText = "\(audio.lastPathComponent) moves the patch through the rows in Window > Modulation, as the music would live, and becomes the video's sound."
		a.accessoryView = host
		a.addButton(withTitle: "Continue…")
		a.addButton(withTitle: "Cancel")
		guard a.runModal() == .alertFirstButtonReturn else { return }
		opts.save()
		let name = audio.deletingPathExtension().lastPathComponent + ".mov"
		guard let url = savePanel(.quickTimeMovie, title: "Export Audio-Reactive Video", name: name) else { return }
		let map = ModMap.shared
		let d = UserDefaults.standard
		AudioSettings.register()
		let o = WHAudioVideoOptions()
		o.codec = opts.codec
		o.width = Int32(opts.width)
		o.height = Int32(opts.height)
		o.frameRate = Double(opts.frameRate)
		o.start = opts.wholeFile ? 0 : opts.start
		o.duration = opts.wholeFile ? -1 : opts.length
		o.preroll = opts.runFirst ? max(opts.preroll, 0) : 0
		o.tempo = opts.setTempo ? opts.tempo : 0
		o.downbeat = opts.markDownbeat ? opts.downbeat : -1
		o.gainDb = d.double(forKey: AudioSettings.gainKey)
		o.rangeDb = d.double(forKey: AudioSettings.rangeKey)
		o.autoLevel = d.bool(forKey: AudioSettings.autoLevelKey)
		o.hitThreshold = d.double(forKey: AudioSettings.hitThresholdKey)
		o.rows = map.bypass ? [] : map.rows.map { $0.engineRow() }
		o.syncs = []	// the rows' Frequency targets become syncs in the engine
		o.depth = map.depth
		o.followTempo = map.followTempo
		o.playlistIndex = playingPatch
		movieExportProgress = (0, 1)
		engine.exportAudioVideo(toPath: url.path, audio: audio.path, options: o,
			progress: { [weak self] done, total in self?.movieExportProgress = (done, total) },
			completion: { [weak self] error in
				self?.movieExportProgress = nil
				if let error, error != "Canceled." { self?.alert("The video export stopped.", error) }
			})
	}

	// MARK: Playlist

	var playlistPatches: [String] { engine.playlistPatches }

	/// Undoable, every edit its own step (the user's request, 2026-11-25:
	/// two drags or deletes in a row coalesced, so one undo took back
	/// both), and undo puts back the selection and the playing patch too
	func setPlaylistPatches(_ paths: [String], title: String) {
		let old = playlistPatches
		let oldSelection = playlistSelection, oldPlaying = playingPatch
		recordUndo(key: "playlist \(UUID())", title: title, list: true) { [weak self] in
			guard let self else { return }
			self.setPlaylistPatches(old, title: title)
			self.playlistSelection = oldSelection
			self.playingPatch = oldPlaying
		}
		engine.setPlaylistPatches(paths)
		playlistModified = true
		if cuedPatch >= paths.count { cuedPatch = -1 }
		if pendingLaunch >= paths.count { cancelLaunch() }
		changed()
	}

	// CPlaylistBar::Insert
	func insertPatches() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.whorldPatch]
		panel.allowsMultipleSelection = true
		panel.directoryURL = WhorldFolders.start(.patches)
		guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
		WhorldFolders.used(.patches, panel.urls[0])
		var paths = playlistPatches
		let at = min((playlistSelection.max() ?? paths.count - 1) + 1, paths.count)
		paths.insert(contentsOf: panel.urls.map { $0.path }, at: at)
		setPlaylistPatches(paths, title: "Insert Patches")
		playlistSelection = Set(at..<(at + panel.urls.count))
	}

	// CPlaylistBar::Delete
	func deletePatches() {
		guard !playlistSelection.isEmpty else { return }
		let paths = playlistPatches.enumerated().filter { !playlistSelection.contains($0.offset) }.map { $0.element }
		setPlaylistPatches(paths, title: playlistSelection.count == 1 ? "Remove Patch" : "Remove Patches")
		// the playing patch keeps its marker, unless it was removed
		let p = playingPatch
		playingPatch = p < 0 || playlistSelection.contains(p) ? -1 : p - playlistSelection.filter { $0 < p }.count
		playlistSelection = []
	}

	// CPlaylistBar::Move
	func movePatches(from source: IndexSet, to destination: Int) {
		var paths = playlistPatches
		var order = Array(paths.indices)	// where each patch goes (Mac: the
		order.move(fromOffsets: source, toOffset: destination)	// playing one and the selection follow)
		guard order != Array(paths.indices) else { return }
		paths.move(fromOffsets: source, toOffset: destination)
		setPlaylistPatches(paths, title: source.count == 1 ? "Move Patch" : "Move Patches")
		if playingPatch >= 0, let i = order.firstIndex(of: playingPatch) {
			playingPatch = i
		}
		playlistSelection = Set(source.compactMap { order.firstIndex(of: $0) })
	}

	// CPlaylist::CheckPatchPaths and CMissingFilesDlg: offer to search a
	// folder for patches that can't be found
	/// the playlist entries whose patch can't be found
	var missingPatchIndices: [Int] {
		let paths = playlistPatches
		return paths.indices.filter { !paths[$0].isEmpty && resolvePatchPath(paths[$0]) == nil }
	}

	/// After a playlist opens (CPlaylist::CheckPatchPaths): if patches are
	/// missing, offers to search a folder for them by file name. Patches
	/// beside the playlist or in Documents/Whorld/Patches are found without
	/// asking (resolvePatchPath). Left missing, they show dimmed, and the
	/// Playlist's right-click menu can locate them later.
	func checkMissingPatches() {
		let missing = missingPatchIndices
		guard !missing.isEmpty else { return }
		let a = NSAlert()
		a.messageText = "\(missing.count) of the playlist's \(playlistPatches.count) patches can't be found."
		a.informativeText = "Whorld can search a folder and its subfolders for them by file name. Patches still missing are dimmed in the Playlist; right-click one to locate it."
		a.addButton(withTitle: "Search Folder…")
		a.addButton(withTitle: "Not Now")
		guard a.runModal() == .alertFirstButtonReturn else { return }
		findMissingPatches()
	}

	/// Asks for a folder and relinks the missing patches found in it
	/// (CFileSearchDlg), saying how many
	func findMissingPatches() {
		let missing = missingPatchIndices
		guard !missing.isEmpty else {
			alert("No patches are missing.")
			return
		}
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.directoryURL = WhorldFolders.start(.patches)
		panel.message = "Choose a folder to search for the \(missing.count) missing patches, including its subfolders."
		panel.prompt = "Search"
		guard panel.runModal() == .OK, let root = panel.url else { return }
		let found = relinkMissing(in: root)
		alert("Found \(found) of \(missing.count) missing patches.",
			found < missing.count ? "The rest stay dimmed in the Playlist; right-click one to locate it." : "")
	}

	/// The Playlist's Locate…: picks the file for one missing entry, then
	/// looks in that file's folder (and below) for the other missing ones
	func locatePatch(_ index: Int) {
		let paths = playlistPatches
		guard index >= 0, index < paths.count else { return }
		let name = paths[index].split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? paths[index]
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.whorldPatch]
		panel.directoryURL = WhorldFolders.start(.patches)
		panel.message = "Where is \(name)?"
		panel.prompt = "Locate"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		var all = paths
		all[index] = url.path
		setPlaylistPatches(all, title: "Locate Patch")
		let others = missingPatchIndices.count
		if others > 0 {
			let found = relinkMissing(in: url.deletingLastPathComponent())
			if found > 0 {
				alert("Also found \(found) of the other \(others) missing patches in that folder.")
			}
		}
	}

	/// Relinks the missing entries whose file name is under `root` (the first
	/// found, as CFileSearchDlg); one undo step. Returns how many.
	@discardableResult
	private func relinkMissing(in root: URL) -> Int {
		var byName: [String: String] = [:]
		if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
			for case let url as URL in e where url.pathExtension.lowercased() == "whp" {
				let key = url.lastPathComponent.lowercased()
				if byName[key] == nil { byName[key] = url.path }
			}
		}
		var paths = playlistPatches
		var found = 0
		for i in missingPatchIndices {
			let name = paths[i].split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? paths[i]
			if let hit = byName[name.lowercased()] {
				paths[i] = hit
				found += 1
			}
		}
		if found > 0 {
			setPlaylistPatches(paths, title: "Find Missing Patches")	// marks the playlist edited, as Windows does
		}
		return found
	}
}

// MARK: Views

/// Turns off a patch list's type-select, macOS's jump to the first row
/// starting with a typed letter (the user's report, 2026-11-24: in the
/// Patches panel that played the patch, from a stray key press; plain keys
/// shouldn't change the picture). Finds the table near it with a Patch
/// column (SwiftUI's Table is an NSTableView).
///
/// `onDelete`: what Delete (or Forward Delete) does while the table has
/// focus, taken before Image > Clear (the user's request, 2026-11-25: in
/// the Patches and Playlist panels it removes the selected patches from
/// the list, never the files)
struct NoTypeSelect: NSViewRepresentable {
	var onDelete: (() -> Void)? = nil

	/// the tables' Delete actions (OutputKeys asks)
	@MainActor private static let deleteActions = NSMapTable<NSTableView, DeleteAction>.weakToStrongObjects()
	private final class DeleteAction {
		let run: () -> Void
		init(_ run: @escaping () -> Void) { self.run = run }
	}

	/// the focused table's Delete action, if it has one
	@MainActor static func deleteAction(for responder: NSResponder?) -> (() -> Void)? {
		guard let t = responder as? NSTableView else { return nil }
		return deleteActions.object(forKey: t)?.run
	}

	func makeNSView(context: Context) -> NSView { NSView() }

	func updateNSView(_ view: NSView, context: Context) {
		let onDelete = onDelete
		DispatchQueue.main.async {	// once the table is in the window
			var v: NSView? = view.superview
			while let ancestor = v {
				if let t = Self.table(in: ancestor) {
					if t.allowsTypeSelect { t.allowsTypeSelect = false }
					if let onDelete { Self.deleteActions.setObject(DeleteAction(onDelete), forKey: t) }
					return
				}
				v = ancestor.superview
			}
		}
	}

	private static func table(in view: NSView) -> NSTableView? {
		if let t = view as? NSTableView, t.tableColumns.contains(where: { $0.title == "Patch" }) { return t }
		for sub in view.subviews {
			if let t = table(in: sub) { return t }
		}
		return nil
	}
}

/// A table's column choices (which show, their widths and order), kept in
/// the settings under `key`: right-click a table's header to choose
enum StoredColumns {
	static func load<Row>(_ key: String) -> TableColumnCustomization<Row>? {
		guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
		return try? JSONDecoder().decode(TableColumnCustomization<Row>.self, from: data)
	}

	static func save<Row>(_ c: TableColumnCustomization<Row>, _ key: String) {
		if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: key) }
	}
}

/// An image or frame size, the same wherever one is chosen (Settings >
/// Export and the export dialogs; the user's requests, 2026-11-24): a menu
/// of the special sizes (the view, the movie), common sizes, and Custom,
/// with the width and height beside it on one line. They always show the
/// size chosen, greyed unless Custom, and can always be clicked: typing a
/// size that differs makes it Custom, or the common size it matches; a size
/// left as it was keeps the choice. Nothing appears or disappears.
struct FrameSizePicker: View {
	let title: String
	/// the special sizes' titles and sizes, before the common ones
	let specials: [(title: String, size: CGSize)]
	/// which special size is chosen, or nil for a width and height
	@Binding var special: Int?
	@Binding var width: Int
	@Binding var height: Int
	/// Custom chosen from the menu though the size is a common one: stays
	/// Custom until the size is typed
	@State private var custom = false
	@FocusState private var focused: Int?	// 0 the width, 1 the height

	static let presets: [(String, Int, Int)] = [
		("720p", 1280, 720), ("1080p", 1920, 1080), ("1440p", 2560, 1440), ("4K", 3840, 2160),
		("Square", 1080, 1080), ("Vertical", 1080, 1920)]	// names only: the fields beside show the size

	enum Choice: Hashable { case special(Int), preset(Int), custom }

	private var choice: Choice {
		if let s = special, s < specials.count { return .special(s) }
		if !custom, let j = Self.presets.firstIndex(where: { $0.1 == width && $0.2 == height }) { return .preset(j) }
		return .custom
	}

	/// the size shown: a special size as it is now, or the width and height
	private var shownSize: (Int, Int) {
		if let s = special, s < specials.count {
			return (Int(specials[s].size.width), Int(specials[s].size.height))
		}
		return (width, height)
	}

	private func pick(_ c: Choice) {
		switch c {
		case .special(let s):
			custom = false
			special = s
		case .preset(let j):
			custom = false
			special = nil
			(width, height) = (Self.presets[j].1, Self.presets[j].2)
		case .custom:	// from the size shown, ready to type
			(width, height) = shownSize
			custom = true
			special = nil
		}
	}

	/// a typed width or height: unchanged keeps the choice; otherwise the
	/// size becomes the width and height, Custom or the common size it is
	private func typed(_ value: Int, isWidth: Bool) {
		let (w, h) = shownSize
		guard value != (isWidth ? w : h), value > 0 else { return }
		(width, height) = isWidth ? (value, h) : (w, value)
		special = nil
		custom = false	// the menu follows the size (a common one, or Custom)
	}

	/// the menu's width, fixed, so the fields beside it never move
	static let menuWidth: CGFloat = 170

	var body: some View {
		LabeledContent(title) {
			HStack(spacing: 8) {
				Picker(title, selection: Binding(get: { choice }, set: { pick($0) })) {
					ForEach(specials.indices, id: \.self) { i in
						Text(specials[i].title).tag(Choice.special(i))
					}
					if !specials.isEmpty { Divider() }
					ForEach(Self.presets.indices, id: \.self) { j in
						Text(Self.presets[j].0).tag(Choice.preset(j))
					}
					Divider()
					Text("Custom").tag(Choice.custom)
				}
				.labelsHidden()
				.frame(width: Self.menuWidth)
				// width × height, close about the ×: the width right-aligned,
				// the height left-aligned; greyed unless Custom or being typed in
				let dim = choice != .custom && focused == nil
				HStack(spacing: 4) {
					sizeField(Binding(get: { shownSize.0 }, set: { typed($0, isWidth: true) }), .trailing)
						.focused($focused, equals: 0)
					Text("×")
					sizeField(Binding(get: { shownSize.1 }, set: { typed($0, isWidth: false) }), .leading)
						.focused($focused, equals: 1)
				}
				.foregroundStyle(dim ? .secondary : .primary)
			}
		}
	}

	private func sizeField(_ value: Binding<Int>, _ alignment: TextAlignment) -> some View {
		TextField("", value: value, format: .number.grouping(.never))
			.labelsHidden()
			.multilineTextAlignment(alignment)
			.frame(width: 46)
	}
}

struct ExportOptionsView: View {
	@Binding var options: ExportOptions
	let viewSize: CGSize

	var body: some View {
		Form {
			FrameSizePicker(title: "Image size", specials: [("Same as the view", viewSize)],
				special: Binding(get: { options.useViewSize ? 0 : nil }, set: { options.useViewSize = $0 == 0 }),
				width: $options.width, height: $options.height)
			Picker("Scale to fit", selection: $options.scaleToFit) {
				Text("None").tag(0)
				Text("Width").tag(1)
				Text("Height").tag(2)
				Text("Both").tag(3)
			}
		}
		.padding(4)
	}
}

/// An alert's options view, with the options in SwiftUI state so the view
/// redraws as they change (a binding to a plain variable doesn't), each
/// change passed back to the caller
struct AccessoryState<Value, Content: View>: View {
	@State private var value: Value
	private let onChange: (Value) -> Void
	private let content: (Binding<Value>) -> Content

	init(_ initial: Value, onChange: @escaping (Value) -> Void, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
		_value = State(initialValue: initial)
		self.onChange = onChange
		self.content = content
	}

	var body: some View {
		content(Binding(get: { value }, set: { value = $0; onChange($0) }))
	}
}

/// Audio-reactive video export options, kept between exports
struct AudioVideoExportOptions: Codable {
	var preset = 1			// 0 the view; otherwise width and height (FrameSizePicker; was 1 to 3 its sizes, 4 custom)
	var width = 1920
	var height = 1080
	var frameRate = 60
	var codec = 0			// VideoWriter::Codec
	var wholeFile = true
	var start = 0.0			// seconds
	var length = 60.0
	var runFirst = false	// run the patch before the video starts (pre-roll), to fill the picture
	var preroll = 10.0
	var setTempo = false	// a set tempo instead of the beat tracker's
	var tempo = 120.0
	var markDownbeat = false
	var downbeat = 0.0		// seconds into the audio

	init() {}

	init(from decoder: Decoder) throws {	// missing fields (from an older Whorld) read as defaults
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = AudioVideoExportOptions()
		preset = (try? c.decodeIfPresent(Int.self, forKey: .preset)) ?? d.preset
		width = (try? c.decodeIfPresent(Int.self, forKey: .width)) ?? d.width
		height = (try? c.decodeIfPresent(Int.self, forKey: .height)) ?? d.height
		frameRate = (try? c.decodeIfPresent(Int.self, forKey: .frameRate)) ?? d.frameRate
		codec = (try? c.decodeIfPresent(Int.self, forKey: .codec)) ?? d.codec
		wholeFile = (try? c.decodeIfPresent(Bool.self, forKey: .wholeFile)) ?? d.wholeFile
		start = (try? c.decodeIfPresent(Double.self, forKey: .start)) ?? d.start
		length = (try? c.decodeIfPresent(Double.self, forKey: .length)) ?? d.length
		runFirst = (try? c.decodeIfPresent(Bool.self, forKey: .runFirst)) ?? d.runFirst
		preroll = (try? c.decodeIfPresent(Double.self, forKey: .preroll)) ?? d.preroll
		setTempo = (try? c.decodeIfPresent(Bool.self, forKey: .setTempo)) ?? d.setTempo
		tempo = (try? c.decodeIfPresent(Double.self, forKey: .tempo)) ?? d.tempo
		markDownbeat = (try? c.decodeIfPresent(Bool.self, forKey: .markDownbeat)) ?? d.markDownbeat
		downbeat = (try? c.decodeIfPresent(Double.self, forKey: .downbeat)) ?? d.downbeat
	}

	private static let key = "AudioVideo_Options"

	static func load() -> AudioVideoExportOptions {
		guard let data = Preferences.defaults.data(forKey: key),
			let o = try? JSONDecoder().decode(AudioVideoExportOptions.self, from: data) else {
			var o = AudioVideoExportOptions()
			o.preset = 2
			return o
		}
		return o
	}

	func save() {
		if let data = try? JSONEncoder().encode(self) {
			Preferences.defaults.set(data, forKey: Self.key)
		}
	}
}

struct AudioVideoExportView: View {
	@Binding var options: AudioVideoExportOptions
	let viewSize: CGSize

	var body: some View {
		Form {
			FrameSizePicker(title: "Frame size", specials: [("Same as the view", viewPixels)],
				special: Binding(get: { options.preset == 0 ? 0 : nil }, set: { setPreset($0 == 0 ? 0 : 1) }),
				width: $options.width, height: $options.height)
			Picker("Frame rate", selection: $options.frameRate) {
				ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
			}
			.hoverTip("Whorld moves one step a frame, as on a display of that rate: 60 looks like a 60 Hz display.")
			Picker("Format", selection: $options.codec) {
				Text("H.264").tag(0)
				Text("HEVC").tag(1)
				Text("ProRes 422").tag(2)
				Text("ProRes 4444 (best for fine lines)").tag(3)
			}
			Toggle("The whole file", isOn: $options.wholeFile)
			if !options.wholeFile {
				HStack {
					TextField("From (s)", value: $options.start, format: .number)
					TextField("Length (s)", value: $options.length, format: .number)
				}
			}
			Toggle("Run the patch first", isOn: $options.runFirst)
				.hoverTip("Off: the video starts with the patch's first frame, reacting to the music at once. On: the patch runs this long before the video starts, so the picture is already full of rings.")
			if options.runFirst {
				TextField("For (s)", value: $options.preroll, format: .number)
			}
			Toggle("Set the tempo (instead of finding the beat)", isOn: $options.setTempo)
			if options.setTempo {
				TextField("Tempo (BPM)", value: $options.tempo, format: .number)
			}
			Toggle("Mark the downbeat", isOn: $options.markDownbeat)
				.hoverTip("Where \"the one\" is, for Bar ... 32-Bar and the oscillators on the beat, as Mark Downbeat would.")
			if options.markDownbeat {
				TextField(options.setTempo ? "A downbeat at (s)" : "Near a downbeat at (s)", value: $options.downbeat, format: .number)
			}
		}
		.padding(4)
	}

	/// the view, in pixels, even (a video's frame size)
	private var viewPixels: CGSize {
		let scale = NSScreen.main?.backingScaleFactor ?? 2
		return CGSize(width: Int(viewSize.width * scale) & ~1, height: Int(viewSize.height * scale) & ~1)
	}

	/// 0: the view's size, kept in width and height; otherwise width and height as set
	private func setPreset(_ i: Int) {
		options.preset = i
		if i == 0 {
			options.width = Int(viewPixels.width)
			options.height = Int(viewPixels.height)
		}
	}
}

/// CMovieExportDlg options
struct MovieExportOptions {
	enum FrameSize: Int { case movie, view, custom }	// FSP_*
	var frameSize = FrameSize.movie
	var width = 1920
	var height = 1080
	var scaleToFit = 0
	var allFrames = true
	var showsCodec = false
	var codec = 0	// VideoWriter::Codec
	var start: Int64 = 0
	var end: Int64
	let frameCount: Int64
	let frameRate: Float
	let movieSize: CGSize

	init(frameCount: Int64, frameRate: Float, movieSize: CGSize) {
		self.frameCount = frameCount
		self.frameRate = frameRate
		self.movieSize = movieSize
		end = max(frameCount - 1, 0)
	}

	// CMovieExportDlg::UpdateFrameSize: the movie preset uses the movie's
	// frame size; the view preset uses the view (EF_USE_VIEW_SIZE)
	var size: (width: Int, height: Int) {
		switch frameSize {
		case .movie: return (Int(movieSize.width.rounded()), Int(movieSize.height.rounded()))
		default: return (width, height)
		}
	}

	var range: (Int64, Int64) {
		if allFrames { return (0, max(frameCount - 1, 0)) }
		let s = min(max(start, 0), max(frameCount - 1, 0))
		return (s, min(max(end, s), max(frameCount - 1, 0)))
	}

	// CMovieExportDlg::GetExportFlags: use the view size for the view preset
	var flags: WHExportFlags {
		ExportOptions(useViewSize: frameSize == .view, width: width, height: height, scaleToFit: scaleToFit).flags
	}
}

struct MovieExportOptionsView: View {
	@Binding var options: MovieExportOptions
	let viewSize: CGSize

	// CMovieExportDlg::FrameToTimeString
	private func time(_ frame: Int64) -> String {
		guard options.frameRate > 0 else { return "" }
		let t = Int64((Double(frame) / Double(options.frameRate)).rounded())
		return String(format: "%02lld:%02lld:%02lld", t / 3600, t / 60 % 60, t % 60)
	}

	var body: some View {
		Form {
			FrameSizePicker(title: "Frame size",
				specials: [("Same as the movie", options.movieSize), ("Same as the view", viewSize)],
				special: Binding(get: { options.frameSize == .movie ? 0 : options.frameSize == .view ? 1 : nil },
					set: { options.frameSize = $0 == 0 ? .movie : $0 == 1 ? .view : .custom }),
				width: $options.width, height: $options.height)
			Picker("Scale to fit", selection: $options.scaleToFit) {
				Text("None").tag(0)
				Text("Width").tag(1)
				Text("Height").tag(2)
				Text("Both").tag(3)
			}
			if options.showsCodec {
				Picker("Format", selection: $options.codec) {
					Text("H.264").tag(0)
					Text("HEVC").tag(1)
					Text("ProRes 422").tag(2)
					Text("ProRes 4444 (best for fine lines)").tag(3)
				}
			}
			Toggle("All \(options.frameCount) frames (\(time(options.frameCount)))", isOn: $options.allFrames)
			if !options.allFrames {
				HStack {
					TextField("Start frame", value: $options.start, format: .number.grouping(.never))
					Text("to")
					TextField("End frame", value: $options.end, format: .number.grouping(.never))
				}
			}
		}
		.padding(4)
	}
}

/// The movie bar (CMovieBar): shown on the render window while a movie is
/// open. Seek slider and time while playing; a record indicator while
/// recording; export progress.
struct MovieBar: View {
	@EnvironmentObject private var model: AppModel
	@State private var scrub: Double? = nil

	// The bar polls the movie ten times a second, but only while one is open:
	// each tick lays out the window, and the workspace's panels make that
	// expensive (an idle timer kept the main thread busy all the time).
	var body: some View {
		let _ = model.changes.media.n	// movie commands call changed()
		if isActive(model.movieState) {
			TimelineView(.periodic(from: .now, by: 0.1)) { _ in
				let ms = model.movieState
				if isActive(ms) {
					bar(ms)
				} else {	// the movie closed by itself (at its end, or an error): stop polling
					Color.clear.frame(width: 0, height: 0)
						.onAppear { model.changes.media.bump(); model.changes.menus.bump() }
				}
			}
		}
	}

	private func isActive(_ ms: WHMovieState) -> Bool {
		ms.io != .closed || model.movieExportProgress != nil
	}

	private func bar(_ ms: WHMovieState) -> some View {
				HStack(spacing: 10) {
					if let p = model.movieExportProgress {
						Text("Exporting \(p.done) of \(p.total)")
						ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
							.frame(width: 200)
						Button("Cancel") { model.engine.cancelMovieExport() }
					} else if ms.io == .writing {
						Circle().fill(.red).frame(width: 10, height: 10)
						Text("Recording · \(ms.frame) frames")
						Button("Stop") { model.toggleRecordMovie() }
					} else {
						Button {
							model.engine.pauseMovie(!ms.paused.boolValue)
						} label: {
							Image(systemName: ms.paused.boolValue ? "play.fill" : "pause.fill")
						}
						.buttonStyle(.borderless)
						Slider(value: Binding(
							get: { scrub ?? Double(max(ms.frame - 1, 0)) },
							set: { v in
								scrub = v
								model.engine.seekMovie(Int64(v.rounded()))
							}),
							in: 0...Double(max(ms.frameCount - 1, 1)),
							onEditingChanged: { editing in if !editing { scrub = nil } })
							.frame(minWidth: 200)
						Text(timeText(ms))
							.monospacedDigit()
						Button("Close") { model.togglePlayMovie() }
					}
				}
				.font(.caption)
				.foregroundStyle(.white)
				.padding(.horizontal, 10)
				.padding(.vertical, 6)
				.background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
				.padding(10)
	}

	// CMovieBar::UpdateTime
	private func timeText(_ ms: WHMovieState) -> String {
		let f = max(ms.frame - 1, 0)
		guard ms.frameRate > 0 else { return "\(f)" }
		let t = Double(f) / Double(ms.frameRate)
		return String(format: "%d:%02d.%02d  %lld / %lld", Int(t) / 60, Int(t) % 60, Int(t * 100) % 100, f, ms.frameCount)
	}
}

/// The playlist window (CPlaylistBar): patch name, author (Mac addition)
/// and folder, playing indicator; double-click or Return plays.
/// When Go plays the cued patch (LaunchTiming; an app setting): a small
/// menu in the Playlist's bottom bar
struct LaunchTimingMenu: View {
	@AppStorage(LaunchTiming.key) private var timing = 0
	@AppStorage(PadSettings.sizeKey) private var bankSize = 16
	@AppStorage(PadSettings.cuesKey) private var padsCue = false

	var body: some View {
		Menu {
			Picker("Go", selection: $timing) {
				ForEach(LaunchTiming.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
			}
			.pickerStyle(.inline)
			// MIDI pads (part 2 of cue, then go; 2026-11-25)
			Picker("MIDI Pads: Bank Size", selection: $bankSize) {
				ForEach(PadSettings.sizes, id: \.self) { Text("\($0) Pads").tag($0) }
			}
			.pickerStyle(.inline)
			Picker("A Pad Press", selection: $padsCue) {
				Text("Plays Its Patch").tag(false)
				Text("Only Cues It").tag(true)
			}
			.pickerStyle(.inline)
		} label: {
			Text("Go: " + (LaunchTiming(rawValue: timing) ?? .now).title)
				.font(.caption)
		}
		.menuStyle(.borderlessButton)
		.fixedSize()
		.hoverTip("When Return plays the cued patch: now, or on the next beat, bar or 4 bars (at once without a beat). Option-Up and Option-Down move the cue; Command-Return plays it now.")
	}
}

struct PlaylistPanel: View {
	@EnvironmentObject private var model: AppModel

	private struct Row: Identifiable {
		let id: Int
		let path: String
		var name: String {
			let last = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
			return (last as NSString).deletingPathExtension
		}
		var folder: String {
			guard let i = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) else { return "" }
			return String(path[..<i])
		}
	}

	/// which columns show (right-click the header), kept in the settings;
	/// Folder hidden at first (the user's choice, 2026-11-24: it repeated
	/// itself for most playlists; a name's tooltip has its path)
	@State private var columns = TableColumnCustomization<Row>()
	private static let columnsKey = "Playlist_columns"

	var body: some View {
		let _ = model.changes.playlist.n
		let rows = model.playlistPatches.enumerated().map { Row(id: $0.offset, path: $0.element) }
		VStack(spacing: 0) {
			header(count: rows.count)
			Divider()
			Table(of: Row.self, selection: $model.playlistSelection, columnCustomization: $columns) {
				TableColumn("Patch") { row in
					HStack(spacing: 4) {
						// playing, or else cued (AppModel+Cue.swift): an
						// outlined arrow, filled in while a Go waits for the beat
						ZStack {
							Image(systemName: "play.fill")
								.foregroundStyle(.green)
								.opacity(row.id == model.playingPatch ? 1 : 0)
							if row.id == model.cuedPatch && row.id != model.playingPatch {
								Image(systemName: row.id == model.pendingLaunch ? "arrowtriangle.right.fill" : "arrowtriangle.right")
									.foregroundStyle(Color.accentColor)
									.hoverTip(row.id == model.pendingLaunch ? "Cued; plays on the beat" : "Cued: Return plays it")
							}
						}
						let missing = model.resolvePatchPath(row.path) == nil
						Text(row.name)
							.foregroundStyle(missing ? .secondary : .primary)
							.hoverTip(missing ? "Can't be found: \(row.path). Right-click to locate it." : row.path)
					}
					.background(model.inBank(row.id) ? Color.accentColor.opacity(0.1) : Color.clear)	// the pads' bank
				}
				.width(min: 120, ideal: 180)
				.customizationID("patch")
				.disabledCustomizationBehavior(.visibility)	// always shown
				TableColumn("Author") { row in
					Text(model.patchAuthor(row.path))
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.tail)
				}
				.width(min: 60, ideal: 110)
				.customizationID("author")
				TableColumn("Folder") { row in
					Text(row.folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
				}
				.customizationID("folder")
				.defaultVisibility(.hidden)
			} rows: {
				// drag rows to reorder (the user's choice, 2026-11-20, for the
				// Move Up and Move Down buttons): a selected row takes the
				// whole selection with it
				ForEach(rows) { row in
					TableRow(row).itemProvider {
						NSItemProvider(object: PlaylistRowDrag.payload(row.id, model.playlistSelection) as NSString)
					}
				}
				.onInsert(of: [.plainText]) { offset, providers in
					dropRows(providers, at: offset)
				}
			}
			.onAppear { columns = StoredColumns.load(Self.columnsKey) ?? columns }
			.onChange(of: columns) { _, c in StoredColumns.save(c, Self.columnsKey) }
			.contextMenu(forSelectionType: Int.self) { sel in
				Button("Play") { playSelected() }
				Button("Remove from Playlist") { model.deletePatches() }	// the files stay
				// missing patches (dimmed): locate one, or search a folder
				// for all of them (the user's request, 2026-11-22)
				let missing = model.missingPatchIndices
				if sel.count == 1, let i = sel.first, missing.contains(i) {
					Divider()
					Button("Locate…") { model.locatePatch(i) }
				}
				if !missing.isEmpty {
					if !(sel.count == 1 && missing.contains(sel.first!)) { Divider() }
					Button("Find Missing Patches…") { model.findMissingPatches() }
				}
			} primaryAction: { sel in
				if let i = sel.first { model.playPatch(i) }
			}
			.onKeyPress(.return) {
				playSelected()
				return .handled
			}
			.background(PlayingRowScroller(row: model.playingPatch, plays: model.patchPlays))
			// a letter doesn't jump to a patch; Delete removes the selected
			// ones from the playlist (not Image > Clear)
			.background(NoTypeSelect(onDelete: { model.deletePatches() }))
			// an empty table has no rows to drop between: while it's empty, the
			// whole list takes patches dragged from the Patches panel
			.overlay {
				if rows.isEmpty {
					Text("Drag patches here from the Patches panel, or click +")
						.font(.callout).foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
						.padding()
						.frame(maxWidth: .infinity, maxHeight: .infinity)
						.contentShape(Rectangle())
						.onDrop(of: [.plainText], isTargeted: nil) { providers in
							dropRows(providers, at: 0)
							return true
						}
				}
			}
			Divider()
			// the bottom bar, as much of it as fits: everything, then without
			// the playlist's name, then without the patch mode button; never
			// wider than the pane (a wider bar pushed the panel's title bar
			// out of place)
			ViewThatFits(in: .horizontal) {
				bottomBar(mode: true)
				bottomBar(mode: false)
			}
			.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
			.clipped()
		}
	}

	/// the playlist's file bar, as the Patches panel's folder bar (the
	/// user's request, 2026-11-25): File > Playlist's commands in a menu,
	/// the playlist's name (it was in the bottom bar), and its patch count
	private func header(count: Int) -> some View {
		HStack(spacing: 6) {
			Menu {
				Button("New Playlist") { model.newPlaylist() }
				Button("Open Playlist…") { model.openPlaylist() }
				Divider()
				Button("Save Playlist") { model.savePlaylist() }
				Button("Save Playlist As…") { model.savePlaylistAs() }
				Divider()
				Button("Show in Finder") {
					if let url = model.playlistURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
				}
				.disabled(model.playlistURL == nil)
				Button("Show Playlists Folder") {
					NSWorkspace.shared.activateFileViewerSelecting([WhorldFolders.folder(.playlists)])
				}
			} label: {
				Label("Playlist file", systemImage: "doc")
					.labelStyle(.iconOnly)
			}
			.menuStyle(.borderlessButton)
			.fixedSize()
			.hoverTip("New, Open, Save and Save As for the playlist (as File > Playlist: ⇧⌘N, ⇧⌘O, ⌥⌘S, ⌥⇧⌘S)")
			Text(model.playlistTitle)
				.lineLimit(1)
				.truncationMode(.middle)
				.hoverTip(model.playlistURL?.path ?? "Not saved yet")
			if model.playlistModified {
				Text("Edited")
					.font(.caption).foregroundStyle(.secondary)
					.fixedSize()
			}
			Spacer(minLength: 0)
			Text("\(count)")
				.font(.caption).foregroundStyle(.secondary)
				.monospacedDigit()
				.hoverTip("Patches in the playlist")
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 5)
		.frame(minHeight: 30)	// as tall as the Patches panel's bar, with its search box
	}

	private func bottomBar(mode: Bool) -> some View {
		HStack {
			Button { model.insertPatches() } label: { Image(systemName: "plus") }
				.hoverTip("Insert patches")
			Button { model.deletePatches() } label: { Image(systemName: "minus") }
				.hoverTip("Remove the selected patches from the playlist (Delete); the files stay")
				.disabled(model.playlistSelection.isEmpty)
			AutoAdvanceControls()
				.padding(.leading, 6)
			LaunchTimingMenu()
			Spacer(minLength: 0)
			if mode {
				// the patch mode, named as it is now (the user's request,
				// 2026-11-18): Geom or Full; click for the other
				let geometry = model.engine.geometryMode
				Button(geometry ? "Geom" : "Full") { model.setGeometryMode(!geometry) }
					.controlSize(.small)
					.fixedSize()
					.hoverTip(geometry
						? "Geometry mode: playing a patch changes only its shape and motion, keeping colors, Hue, Master, Properties and Global values. Click for Full mode, where everything changes. Saved with the playlist (Image > Geometry Only, ⌘G)."
						: "Full mode: playing a patch changes everything. Click for Geometry mode, where only its shape and motion change, keeping colors, Hue, Master, Properties and Global values. Saved with the playlist (Image > Geometry Only, ⌘G).")
			}
		}
		.padding(8)
	}

	/// rows dragged within the list: moved to `offset` (their text says which)
	private func dropRows(_ providers: [NSItemProvider], at offset: Int) {
		guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
		_ = p.loadObject(ofClass: NSString.self) { obj, _ in
			guard let text = obj as? String else { return }
			if let files = PatchFileDrag.paths(text) {	// from the Patches panel
				DispatchQueue.main.async { model.addPatchesToPlaylist(files, at: offset) }
				return
			}
			guard let moved = PlaylistRowDrag.rows(text) else { return }
			DispatchQueue.main.async {
				let valid = moved.filter { $0 >= 0 && $0 < model.playlistPatches.count }
				guard !valid.isEmpty else { return }
				model.movePatches(from: IndexSet(valid), to: offset)
			}
		}
	}

	private func playSelected() {
		if let i = model.playlistSelection.min() { model.playPatch(i) }
	}

}

/// Keeps the playing patch in view (the user's request, 2026-11-20): each
/// time a patch is played from the playlist (a click, Next and Previous,
/// MIDI or OSC), its row scrolls to about a third of the way down, so a
/// few patches before it and more after it show. Only then: scrolling by
/// hand is left alone. It finds the SwiftUI Table's NSTableView as the
/// one whose scroll view covers this background view.
private struct PlayingRowScroller: NSViewRepresentable {
	let row: Int
	let plays: Int

	final class Coordinator {
		var plays: Int?
	}

	func makeCoordinator() -> Coordinator { Coordinator() }
	func makeNSView(context: Context) -> NSView { NSView() }

	func updateNSView(_ view: NSView, context: Context) {
		let c = context.coordinator
		guard c.plays != plays else { return }
		let first = c.plays == nil	// the panel just appeared: no load to follow
		c.plays = plays
		guard !first, row >= 0 else { return }
		DispatchQueue.main.async {	// once the table has the new rows
			guard let table = Self.table(covering: view), row < table.numberOfRows,
				let scroll = table.enclosingScrollView else { return }
			let clip = scroll.contentView
			let inset = clip.contentInsets.top	// the header
			let visible = clip.bounds.height - inset
			let r = table.rect(ofRow: row)
			var y = r.midY - visible / 3 - inset
			y = min(max(y, -inset), max(table.frame.height - clip.bounds.height, -inset))
			NSAnimationContext.runAnimationGroup { ctx in
				ctx.duration = 0.2
				clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
			}
			scroll.reflectScrolledClipView(clip)
		}
	}

	/// the table whose scroll view is where this view is
	private static func table(covering view: NSView) -> NSTableView? {
		guard let window = view.window, let root = window.contentView else { return nil }
		let frame = view.convert(view.bounds, to: nil)
		var best: NSTableView?
		var bestArea: CGFloat = 0
		func search(_ v: NSView) {
			if let t = v as? NSTableView, let s = t.enclosingScrollView {
				let overlap = s.convert(s.bounds, to: nil).intersection(frame)
				let area = overlap.isNull ? 0 : overlap.width * overlap.height
				if area > bestArea { best = t; bestArea = area }
				return
			}
			v.subviews.forEach(search)
		}
		search(root)
		return best
	}
}

// MARK: Auto-advance (Mac addition, the user's request, 2026-11-20)

/// What an auto-advance length counts (whorld::AutoAdvance UNIT_*)
enum AutoAdvanceUnit: Int, CaseIterable {
	case seconds = 0, beats, bars

	var label: String {
		switch self {
		case .seconds: "sec"
		case .beats: "beats"
		case .bars: "bars"
		}
	}

	func describe(_ length: Double) -> String {
		let n = length == length.rounded() ? String(Int(length)) : String(format: "%g", length)
		switch self {
		case .seconds: return length == 1 ? "1 second" : "\(n) seconds"
		case .beats: return length == 1 ? "1 beat" : "\(n) beats"
		case .bars: return length == 1 ? "1 bar" : "\(n) bars"
		}
	}
}

/// The Playlist panel's Play / Stop button, with how long each patch plays:
/// a number and its unit (seconds, beats or bars), saved with the playlist.
struct AutoAdvanceControls: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		let _ = model.changes.playlist.n
		let e = model.engine
		let unit = AutoAdvanceUnit(rawValue: e.autoAdvanceUnit) ?? .seconds
		let length = e.autoAdvanceLength
		HStack(spacing: 4) {
			AutoAdvanceButton(running: e.autoAdvancing, enabled: !model.playlistPatches.isEmpty,
				unit: unit, length: length, engine: e,
				setLength: { model.setAutoAdvanceLength($0, unit: $1) }) { model.setAutoAdvance(!e.autoAdvancing) }
				.frame(width: 32, height: 22)
			NumberField(
				value: length,
				format: { String(format: "%g", $0) },
				parse: { Double($0.trimmingCharacters(in: .whitespaces)) ?? NumberField.fraction($0) ?? length },
				commit: { model.setAutoAdvanceLength(Self.clamp($0, unit), unit: unit) },
				step: { v, d, k in Self.clamp((k.apply(v, size: 1, direction: d) * 10).rounded() / 10, unit) },	// one, scaled by the modifiers, to a tenth
				lo: Self.range(unit).lowerBound,
				hi: Self.range(unit).upperBound,
				width: NumberField.width(characters: 4),
				fractions: true)
				.hoverTip("How long each patch plays before the next, in \(unit == .seconds ? "seconds" : unit == .beats ? "beats" : "bars (4 beats)").")
			Picker("", selection: Binding(
				get: { unit },
				set: { u in model.setAutoAdvanceLength(Self.clamp(length, u), unit: u) })) {
				ForEach(AutoAdvanceUnit.allCases, id: \.self) { Text($0.label).tag($0) }
			}
			.labelsHidden()
			.fixedSize()
			.hoverTip("Count in seconds, or in beats or bars of the music's beat (with an audio input, or Ableton Link). Without a beat it counts at the last tempo heard, or 120 BPM.")
		}
	}

	static func range(_ unit: AutoAdvanceUnit) -> ClosedRange<Double> {
		switch unit {
		case .seconds: 1...3600
		case .beats: 1...1024
		case .bars: 0.25...256
		}
	}

	static func clamp(_ v: Double, _ unit: AutoAdvanceUnit) -> Double {
		guard v.isFinite else { return 30 }
		return min(max(v, range(unit).lowerBound), range(unit).upperBound)
	}
}

/// Play / Stop, in AppKit so its progress line and tooltip can follow the
/// count many times a second without SwiftUI laying out the panel again
/// (which drops tooltips). The line under the symbol fills toward the next
/// patch: the accent color, or orange while counting beats without a beat.
/// `strip`: the stats strip's borderless form, lit on hover as its others are.
struct AutoAdvanceButton: NSViewRepresentable {
	var strip = false
	let running: Bool
	let enabled: Bool
	let unit: AutoAdvanceUnit
	let length: Double
	let engine: WHEngine
	/// a right click's lengths (the user's request, 2026-11-20)
	var setLength: ((Double, AutoAdvanceUnit) -> Void)? = nil
	let action: () -> Void

	/// the lengths a right click offers
	static let presets: [(Double, AutoAdvanceUnit)] = [
		(15, .seconds), (30, .seconds), (60, .seconds), (120, .seconds),
		(4, .beats), (8, .beats), (16, .beats),
		(4, .bars), (8, .bars), (16, .bars), (32, .bars),
	]

	final class Button: NSButton {
		var running = false { didSet { if running != oldValue { update() } } }
		var unit = AutoAdvanceUnit.seconds
		var length = 30.0
		weak var engine: WHEngine?
		var onPress: (() -> Void)?
		var onLength: ((Double, AutoAdvanceUnit) -> Void)?
		var strip = false {
			didSet {
				guard strip != oldValue else { return }
				isBordered = !strip
				updateTrackingAreas()
				update()
			}
		}
		private var hover = false { didSet { if hover != oldValue { needsDisplay = true } } }
		private var progress = 0.0
		private var following = true
		private var timer: Timer?

		override init(frame: NSRect) {
			super.init(frame: frame)
			bezelStyle = .rounded
			setButtonType(.momentaryPushIn)
			imagePosition = .imageOnly
			target = self
			action = #selector(pressed)
			update()
		}

		required init?(coder: NSCoder) { fatalError() }

		@objc private func pressed() { onPress?() }

		override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

		// a right click: how long each patch plays, from the usual lengths
		override func menu(for event: NSEvent) -> NSMenu? {
			guard onLength != nil else { return nil }
			let menu = NSMenu()
			let head = NSMenuItem(title: "Each patch plays", action: nil, keyEquivalent: "")
			head.isEnabled = false
			menu.addItem(head)
			var last: AutoAdvanceUnit?
			for (i, p) in AutoAdvanceButton.presets.enumerated() {
				if let last, last != p.1 { menu.addItem(.separator()) }
				last = p.1
				let item = NSMenuItem(title: p.1.describe(p.0), action: #selector(pickLength(_:)), keyEquivalent: "")
				item.target = self
				item.tag = i
				item.state = p.0 == length && p.1 == unit ? .on : .off
				menu.addItem(item)
			}
			return menu
		}

		override func rightMouseDown(with event: NSEvent) {
			guard let menu = menu(for: event) else { return super.rightMouseDown(with: event) }
			NSMenu.popUpContextMenu(menu, with: event, for: self)
		}

		@objc private func pickLength(_ item: NSMenuItem) {
			let p = AutoAdvanceButton.presets[item.tag]
			onLength?(p.0, p.1)
		}

		override func updateTrackingAreas() {
			super.updateTrackingAreas()
			trackingAreas.forEach(removeTrackingArea)
			guard strip else { return }
			addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
				owner: self))
		}

		override func mouseEntered(with event: NSEvent) { hover = strip }
		override func mouseExited(with event: NSEvent) { hover = false }

		func update() {
			var image = NSImage(systemSymbolName: running ? "stop.fill" : "play.fill",
				accessibilityDescription: running ? "Stop" : "Play")
			if strip { image = image?.withSymbolConfiguration(.init(scale: .small)) }
			// Stop in the accent color in the Playlist panel too, as on the
			// Perform Bar (the user's request, 2026-11-24): a bordered
			// button ignores contentTintColor, so the symbol carries it
			if running { image = image?.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])) }
			self.image = image
			contentTintColor = running ? .controlAccentColor : strip && isEnabled ? .labelColor : nil
			if running, timer == nil {
				let t = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
					MainActor.assumeIsolated { self?.poll() }
				}
				RunLoop.main.add(t, forMode: .common)
				timer = t
			} else if !running {
				timer?.invalidate()
				timer = nil
				progress = 0
			}
			poll()
			needsDisplay = true
		}

		private func poll() {
			guard isShowing || !running else { return }	// behind full screen, say: the ring waits
			var f: ObjCBool = true
			var tempo = 0.0
			let p = running ? engine?.autoAdvanceProgress(followingBeat: &f, tempo: &tempo) ?? 0 : 0
			let beats = unit != .seconds
			let follow = !beats || f.boolValue
			let how = !beats ? "" : follow
				? String(format: " Following the beat, %.0f BPM.", tempo)
				: String(format: " No beat now: counting at %.0f BPM until there is one.", tempo)
			let tip = running
				? "Stop playing through the playlist. Each patch plays \(unit.describe(length)), then the next; after the last, the first again.\(how)"
				: "Play through the playlist: \(unit.describe(length)) each, then the next, round and round. A patch played by hand starts its count afresh."
			let tipped = onLength == nil ? tip : tip + " Right-click for another length."
			let shownTip = HoverTips.gate(tipped)	// Show tips on hover
			if toolTip != shownTip { toolTip = shownTip }
			if abs(p - progress) > 0.002 || follow != following {
				progress = p
				following = follow
				needsDisplay = true
			}
		}

		override func draw(_ dirtyRect: NSRect) {
			if strip, isEnabled, hover || isHighlighted {	// as StripToggleStyle
				NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.18 : 0.09).setFill()
				NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
			}
			super.draw(dirtyRect)
			guard running else { return }
			let inner = bounds.insetBy(dx: strip ? 3 : 7, dy: 0)
			let y = bounds.maxY - (strip ? 2.5 : 5.5)	// flipped: near the bezel's bottom
			let track = NSRect(x: inner.minX, y: y, width: inner.width, height: 2)
			NSColor.tertiaryLabelColor.setFill()
			NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
			(following ? NSColor.controlAccentColor : NSColor.systemOrange).setFill()
			var fill = track
			fill.size.width = track.width * min(max(progress, 0), 1)
			NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
		}

		override var isFlipped: Bool { true }

		deinit { timer?.invalidate() }
	}

	func makeNSView(context: Context) -> Button { Button(frame: .zero) }

	func updateNSView(_ b: Button, context: Context) {
		b.engine = engine
		b.strip = strip
		b.unit = unit
		b.length = length
		b.onPress = action
		b.onLength = setLength
		b.isEnabled = enabled || running
		b.running = running
		b.update()
	}
}

/// A playlist row drag (Mac addition): the rows' indices as text with a
/// prefix, so a drop of other text is ignored
enum PlaylistRowDrag {
	static let prefix = "whorld-playlist-rows:"

	static func payload(_ row: Int, _ selection: Set<Int>) -> String {
		let rows = selection.contains(row) ? selection.sorted() : [row]
		return prefix + rows.map(String.init).joined(separator: ",")
	}

	static func rows(_ text: String) -> [Int]? {
		guard text.hasPrefix(prefix) else { return nil }
		let r = text.dropFirst(prefix.count).split(separator: ",").compactMap { Int($0) }
		return r.isEmpty ? nil : r
	}
}
