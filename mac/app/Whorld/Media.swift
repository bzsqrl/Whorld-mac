// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
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
		return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory())	// SetDefaultExportImageFolder: Pictures
	}

	/// CMainFrame::PromptingForExport: prompt unless full screen on the only screen.
	var promptingForExport: Bool {
		Preferences.register()
		let fullScreenSingle = (mainWindow?.styleMask.contains(.fullScreen) ?? false) && NSScreen.screens.count == 1
		return Preferences.defaults.bool(forKey: "Export_bPromptUser") && !fullScreenSingle
	}

	/// CMainFrame::MakeUniqueExportPath with CWhorldApp::GetTimestampFileName
	/// (UTC, like GetSystemTime): Whorld-YYYY-MM-DD-hh-mm-ss-mmm.ext
	func makeUniqueExportPath(_ ext: String) -> URL? {
		let folder = exportFolder
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

	private func savePanel(_ type: UTType, title: String, name: String) -> URL? {
		let panel = NSSavePanel()
		panel.title = title
		panel.allowedContentTypes = [type]
		panel.nameFieldStringValue = name
		return panel.runModal() == .OK ? panel.url : nil
	}

	/// The export options dialog (CExportDlg). Returns nil if canceled.
	func runExportOptions() -> ExportOptions? {
		var opts = ExportOptions.load()
		let view = ExportOptionsView(options: Binding(get: { opts }, set: { opts = $0 }), viewSize: engine.viewSize)
		let host = NSHostingView(rootView: view)
		host.frame = NSRect(x: 0, y: 0, width: 340, height: 150)
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

	// CMainFrame::OnFileTakeSnapshot and WriteSnapshot
	func takeSnapshot() {
		let url: URL?
		if promptingForExport {
			url = savePanel(.whorldSnapshot, title: "Snapshot Save As", name: "Untitled.whs")
		} else {
			url = makeUniqueExportPath("whs")
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
		guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
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
		let url: URL?
		if promptingForExport {
			url = savePanel(.whorldMovie, title: "Movie Save As", name: "Untitled.whm")
		} else {
			url = makeUniqueExportPath("whm")
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
		guard panel.runModal() == .OK, let url = panel.url else { return }
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
		var opts = MovieExportOptions(frameCount: ms.frameCount, frameRate: ms.frameRate)
		let host = NSHostingView(rootView: MovieExportOptionsView(options: Binding(get: { opts }, set: { opts = $0 }),
			viewSize: engine.viewSize))
		host.frame = NSRect(x: 0, y: 0, width: 360, height: 210)
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
			width: Int32(opts.width), height: Int32(opts.height),
			progress: { [weak self] done in self?.movieExportProgress = (done, total) },
			completion: { [weak self] error in
				self?.movieExportProgress = nil
				if let error { self?.alert("The movie export stopped.", error) }
			})
	}

	// MARK: Playlist

	var playlistPatches: [String] { engine.playlistPatches }

	func setPlaylistPatches(_ paths: [String], title: String) {
		let old = playlistPatches
		recordUndo(key: "playlist " + title + " \(paths.count)", title: title) { [weak self] in
			self?.setPlaylistPatches(old, title: title)
		}
		engine.setPlaylistPatches(paths)
		playlistModified = true
		changed()
	}

	// CPlaylistBar::Insert
	func insertPatches() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.whorldPatch]
		panel.allowsMultipleSelection = true
		guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
		var paths = playlistPatches
		let at = min((playlistSelection.max() ?? paths.count - 1) + 1, paths.count)
		paths.insert(contentsOf: panel.urls.map { $0.path }, at: at)
		setPlaylistPatches(paths, title: "Insert")
		playlistSelection = Set(at..<(at + panel.urls.count))
	}

	// CPlaylistBar::Delete
	func deletePatches() {
		guard !playlistSelection.isEmpty else { return }
		let paths = playlistPatches.enumerated().filter { !playlistSelection.contains($0.offset) }.map { $0.element }
		setPlaylistPatches(paths, title: "Delete")
		playlistSelection = []
		playingPatch = -1
	}

	// CPlaylistBar::Move
	func movePatches(from source: IndexSet, to destination: Int) {
		var paths = playlistPatches
		paths.move(fromOffsets: source, toOffset: destination)
		setPlaylistPatches(paths, title: "Move")
	}

	// CPlaylist::CheckPatchPaths and CMissingFilesDlg: offer to search a
	// folder for patches that can't be found
	func checkMissingPatches() {
		var paths = playlistPatches
		let missing = paths.indices.filter { !paths[$0].isEmpty && resolvePatchPath(paths[$0]) == nil }
		guard !missing.isEmpty else { return }
		let a = NSAlert()
		a.messageText = "\(missing.count) of the playlist's \(paths.count) patches can't be found."
		a.informativeText = "Patch paths from Windows look like C:\\…; search a folder for them by file name?"
		a.addButton(withTitle: "Search Folder…")
		a.addButton(withTitle: "Proceed")
		guard a.runModal() == .alertFirstButtonReturn else { return }
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.message = "Choose a folder to search, including its subfolders."
		guard panel.runModal() == .OK, let root = panel.url else { return }
		// index .whp files under the folder by lowercased name (CFileSearchDlg)
		var byName: [String: String] = [:]
		if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
			for case let url as URL in e where url.pathExtension.lowercased() == "whp" {
				byName[url.lastPathComponent.lowercased()] = byName[url.lastPathComponent.lowercased()] ?? url.path
			}
		}
		var found = 0
		for i in missing {
			let name = paths[i].split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? paths[i]
			if let hit = byName[name.lowercased()] {
				paths[i] = hit
				found += 1
			}
		}
		if found > 0 {
			engine.setPlaylistPatches(paths)
			playlistModified = true	// replacing missing files counts as modification
		}
		alert("Found \(found) of \(missing.count) missing patches.")
		changed()
	}
}

// MARK: Views

struct ExportOptionsView: View {
	@Binding var options: ExportOptions
	let viewSize: CGSize

	var body: some View {
		Form {
			Toggle("Use view size (\(Int(viewSize.width)) × \(Int(viewSize.height)))", isOn: $options.useViewSize)
			HStack {
				TextField("Width", value: $options.width, format: .number.grouping(.never))
				Text("×")
				TextField("Height", value: $options.height, format: .number.grouping(.never))
			}
			.disabled(options.useViewSize)
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

/// CMovieExportDlg options
struct MovieExportOptions {
	enum FrameSize: Int { case movie, view, custom }	// FSP_*
	var frameSize = FrameSize.movie
	var width = 1920
	var height = 1080
	var scaleToFit = 0
	var allFrames = true
	var start: Int64 = 0
	var end: Int64
	let frameCount: Int64
	let frameRate: Float

	init(frameCount: Int64, frameRate: Float) {
		self.frameCount = frameCount
		self.frameRate = frameRate
		end = max(frameCount - 1, 0)
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
			Picker("Frame size", selection: $options.frameSize) {
				Text("Movie").tag(MovieExportOptions.FrameSize.movie)
				Text("View (\(Int(viewSize.width)) × \(Int(viewSize.height)))").tag(MovieExportOptions.FrameSize.view)
				Text("Custom").tag(MovieExportOptions.FrameSize.custom)
			}
			if options.frameSize == .custom {
				HStack {
					TextField("Width", value: $options.width, format: .number.grouping(.never))
					Text("×")
					TextField("Height", value: $options.height, format: .number.grouping(.never))
				}
			}
			Picker("Scale to fit", selection: $options.scaleToFit) {
				Text("None").tag(0)
				Text("Width").tag(1)
				Text("Height").tag(2)
				Text("Both").tag(3)
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

	var body: some View {
		TimelineView(.periodic(from: .now, by: 0.1)) { _ in
			let ms = model.movieState
			if ms.io != .closed || model.movieExportProgress != nil {
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
		}
	}

	// CMovieBar::UpdateTime
	private func timeText(_ ms: WHMovieState) -> String {
		let f = max(ms.frame - 1, 0)
		guard ms.frameRate > 0 else { return "\(f)" }
		let t = Double(f) / Double(ms.frameRate)
		return String(format: "%d:%02d.%02d  %lld / %lld", Int(t) / 60, Int(t) % 60, Int(t * 100) % 100, f, ms.frameCount)
	}
}

/// The playlist window (CPlaylistBar): patch name and folder, playing
/// indicator; double-click or Return plays.
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

	var body: some View {
		let _ = model.revision
		let rows = model.playlistPatches.enumerated().map { Row(id: $0.offset, path: $0.element) }
		VStack(spacing: 0) {
			Table(rows, selection: $model.playlistSelection) {
				TableColumn("Patch") { row in
					HStack(spacing: 4) {
						Image(systemName: "play.fill")
							.foregroundStyle(.green)
							.opacity(row.id == model.playingPatch ? 1 : 0)
						Text(row.name)
							.foregroundStyle(model.resolvePatchPath(row.path) == nil ? .secondary : .primary)
					}
				}
				.width(min: 120, ideal: 180)
				TableColumn("Folder") { row in
					Text(row.folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
				}
			}
			.contextMenu(forSelectionType: Int.self) { _ in
				Button("Play") { playSelected() }
				Button("Delete") { model.deletePatches() }
			} primaryAction: { sel in
				if let i = sel.first { model.playPatch(i) }
			}
			.onKeyPress(.return) {
				playSelected()
				return .handled
			}
			Divider()
			HStack {
				Button { model.insertPatches() } label: { Image(systemName: "plus") }
					.help("Insert patches")
				Button { model.deletePatches() } label: { Image(systemName: "minus") }
					.help("Delete the selected patches")
					.disabled(model.playlistSelection.isEmpty)
				Button { moveSelection(-1) } label: { Image(systemName: "arrow.up") }
					.help("Move up")
					.disabled(model.playlistSelection.isEmpty)
				Button { moveSelection(1) } label: { Image(systemName: "arrow.down") }
					.help("Move down")
					.disabled(model.playlistSelection.isEmpty)
				Spacer()
				Text(model.playlistTitle + (model.playlistModified ? " — Edited" : ""))
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			.padding(8)
		}
		.frame(minWidth: 360, minHeight: 200)
	}

	private func playSelected() {
		if let i = model.playlistSelection.min() { model.playPatch(i) }
	}

	private func moveSelection(_ delta: Int) {
		let sel = model.playlistSelection.sorted()
		guard let first = sel.first, let last = sel.last else { return }
		let count = model.playlistPatches.count
		if delta < 0 && first == 0 || delta > 0 && last == count - 1 { return }
		model.movePatches(from: IndexSet(sel), to: delta < 0 ? first - 1 : last + 2)
		model.playlistSelection = Set(sel.map { $0 + delta })
	}
}
