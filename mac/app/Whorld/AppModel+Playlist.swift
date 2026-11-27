// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// The playlist and auto-advance (AppModel, split out of WhorldApp.swift on 2026-11-22;
// no change in behavior).

import AppKit
import SwiftUI

extension AppModel {
	// MARK: Playlist

	func newPlaylist() {
		guard confirmDiscardPlaylist() else { return }
		engine.newPlaylist()
		playlistURL = nil
		playingPatch = -1
		cuedPatch = -1	// a new playlist: no cue, the first bank
		cueBank = 0
		cancelLaunch()
		playlistTitle = "Untitled Playlist"
		playlistModified = false
		mappingSelection = []
		resetUndo(lists: true)	// a new playlist: its edits' undo too
		changed()
	}

	func openPlaylist() {
		guard confirmDiscardPlaylist() else { return }
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.whorldPlaylist]
		panel.directoryURL = WhorldFolders.start(.playlists)
		guard panel.runModal() == .OK, let url = panel.url else { return }
		WhorldFolders.used(.playlists, url)
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
		cuedPatch = -1	// a new playlist: no cue, the first bank
		cueBank = 0
		cancelLaunch()
			checkMissingPatches()
			playlistTitle = url.deletingPathExtension().lastPathComponent
			playlistModified = false
			mappingSelection = []
			resetUndo(lists: true)	// a new playlist: its edits' undo too
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
		panel.directoryURL = WhorldFolders.start(.playlists)
		// the panel layout goes in the playlist if this is checked (remembered)
		let include = NSButton(checkboxWithTitle: "Include the panel layout", target: nil, action: nil)
		include.state = Preferences.playlistSavesLayout ? .on : .off
		include.toolTip = HoverTips.gate("Saves the panels' arrangement with the playlist, to restore when it's opened (Whorld for Mac only; Windows Whorld ignores it).")
		let row = NSStackView(views: [include])
		row.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
		panel.accessoryView = row
		guard panel.runModal() == .OK, let url = panel.url else { return false }
		WhorldFolders.used(.playlists, url)
		let on = include.state == .on
		UserDefaults.standard.set(on, forKey: "Playlist_bSaveLayout")
		engine.playlistLayout = on ? currentLayoutFile().line : nil
		return writePlaylist(to: url)
	}

	func writePlaylist(to url: URL) -> Bool {
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
	/// next to the playlist, then in Documents/Whorld/Patches (where the
	/// sample playlists' patches are, named without a folder; 2026-11-22).
	/// resolvePatchPath, remembered (pathCache): for the Playlist's rows and
	/// authors, drawn often. Playing a patch looks again, uncached.
	func resolvedPatchPath(_ stored: String) -> URL? {
		if let hit = pathCache[stored] { return hit }
		let url = resolvePatchPath(stored)
		pathCache[stored] = url
		return url
	}

	/// the remembered lookups let go: the playlist or its file changed, the
	/// Whorld folder moved, or Whorld came back to the front (files may have
	/// moved in the Finder meanwhile)
	func forgetPatchPaths() {
		pathCache.removeAll(keepingCapacity: true)
		authorChecked.removeAll(keepingCapacity: true)
	}

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
		let inPatches = WhorldFolders.folder(.patches).appendingPathComponent(name)
		if fm.fileExists(atPath: inPatches.path) {
			return inPatches
		}
		return nil
	}

	// CPlaylistBar::Play (also from the MIDI and OSC Patch target). Unlike
	// Windows, which asks to save an edited patch first (except in full
	// screen), this never asks: playing through a playlist live shouldn't
	// be interrupted, and unsaved edits are simply let go (the user's choice,
	// 2026-11-09). File > New, Open and Quit still ask.
	@discardableResult
	func playPatch(_ index: Int, automatic: Bool = false) -> Bool {
		// another patch played meanwhile calls off a Go waiting for the beat
		if pendingLaunch >= 0, index != pendingLaunch { cancelLaunch() }
		let paths = engine.playlistPatches
		guard index >= 0, index < paths.count, let url = resolvePatchPath(paths[index]) else { return false }
		let before = automatic ? nil : playState()
		guard engine.playPatch(atPath: url.path) else { return false }
		if !automatic {	// played by hand: auto-advance counts from now
			engine.restartAutoAdvance()
		}
		playedName = url.deletingPathExtension().lastPathComponent
		playingPatch = index
		// the cued patch played, however (Auto Advance, ⌘↓, a click, Go):
		// the cue moves on to the next, so Return doesn't play it again
		if cuedPatch == index { cuedPatch = (index + 1) % paths.count }
		playingFile = url
		patchPlays += 1
		originFromPatch()
		resetUndo()
		if let before { recordPlayUndo(before) }
		updateTitle()
		changed()
		return true
	}

	/// The Patches panel (PatchBrowser.swift): plays a patch file at once,
	/// crossfading and letting unsaved edits go, as playPatch does. If the
	/// playlist has it, that entry is the one playing.
	@discardableResult
	func playPatchFile(_ url: URL) -> Bool {
		let before = playState()
		guard engine.playPatch(atPath: url.path) else { return false }
		engine.restartAutoAdvance()
		let target = url.standardizedFileURL
		playingPatch = engine.playlistPatches.firstIndex { resolvePatchPath($0)?.standardizedFileURL == target } ?? -1
		playedName = url.deletingPathExtension().lastPathComponent
		playingFile = url
		patchPlays += 1
		originFromPatch()
		resetUndo()
		recordPlayUndo(before)
		updateTitle()
		changed()
		return true
	}

	// MARK: Undo Play Patch (Mac addition, the user's request, 2026-11-27)

	/// What playing a patch replaces: the document (with any unsaved edits)
	/// and which patch the window says is playing
	struct PlayState {
		let document: WHDocumentState
		let playedName: String?
		let playingFile: URL?
		let playingPatch: Int
	}

	func playState() -> PlayState {
		PlayState(document: engine.documentState(), playedName: playedName,
			playingFile: playingFile, playingPatch: playingPatch)
	}

	/// Edit > Undo Play Patch puts the patch that was playing back, as it
	/// was, edits and all (only those edits' own undo steps are gone, as
	/// after any play); Redo plays the patch again. Registered with the
	/// lists' undo, which a play keeps. Auto Advance's plays aren't steps;
	/// the cue stays where it is.
	func recordPlayUndo(_ before: PlayState) {
		recordUndo(key: "play \(UUID())", title: "Play Patch", list: true) { [weak self] in
			guard let self else { return }
			let undone = self.playState()
			self.restorePlayState(before)
			self.recordPlayUndo(undone)	// the redo
		}
	}

	private func restorePlayState(_ s: PlayState) {
		if pendingLaunch >= 0 { cancelLaunch() }
		engine.restoreDocumentState(s.document)
		playedName = s.playedName
		playingFile = s.playingFile
		playingPatch = s.playingPatch < engine.playlistPatches.count ? s.playingPatch : -1
		engine.restartAutoAdvance()
		patchPlays += 1
		originFromPatch()
		resetUndo()
		updateTitle()
		changes.document.bump()
	}

	/// The Patches panel's Add to Playlist and drags: the files go in after
	/// the selected entry (else at the end), or at `offset`, and are selected
	func addPatchesToPlaylist(_ paths: [String], at offset: Int? = nil) {
		guard !paths.isEmpty else { return }
		var all = playlistPatches
		let at = min(offset ?? ((playlistSelection.max() ?? all.count - 1) + 1), all.count)
		all.insert(contentsOf: paths, at: at)
		setPlaylistPatches(all, title: "Add Patches")
		playlistSelection = Set(at..<(at + paths.count))
	}

	// MARK: Auto-advance (Mac addition, the user's request, 2026-11-20)

	/// Starts or stops playing through the playlist (the Playlist panel's
	/// Play button, Image > Auto Advance, MIDI and OSC). Starting keeps the
	/// patch playing, or plays the selected one (else the first).
	func setAutoAdvance(_ on: Bool) {
		let n = engine.playlistPatches.count
		guard on != engine.autoAdvancing, !on || n > 0 else { return }
		engine.autoAdvancing = on
		if on, !(playingPatch >= 0 && playingPatch < n) {
			playPatch(playlistSelection.min() ?? 0)
		}
		changes.playlist.bump()
		changes.menus.bump()
	}

	/// Image > Blackout (Mac addition, the Perform Bar; the user's
	/// request, 2026-11-20): the picture fades to black, or back
	/// (WHEngine blackout). Not saved: Whorld starts with the picture showing.
	func setBlackout(_ on: Bool) {
		guard on != engine.blackout else { return }
		engine.blackout = on
		changes.main.bump()
		changes.menus.bump()
	}

	private static var lastLengthEdit = Date.distantPast, lengthEdits = 0

	/// How long each patch plays: seconds, beats or bars (AutoAdvanceUnit),
	/// saved with the playlist
	func setAutoAdvanceLength(_ length: Double, unit: AutoAdvanceUnit) {
		guard length != engine.autoAdvanceLength || unit.rawValue != engine.autoAdvanceUnit else { return }
		// undoable with the playlist's edits (the user's request, 2026-11-25);
		// a run of changes (typing, the stepper) is one step
		let oldLength = engine.autoAdvanceLength
		let oldUnit = AutoAdvanceUnit(rawValue: engine.autoAdvanceUnit) ?? .seconds
		let now = Date()
		if now.timeIntervalSince(Self.lastLengthEdit) > 1 { Self.lengthEdits += 1 }
		Self.lastLengthEdit = now
		recordUndo(key: "auto advance length \(Self.lengthEdits)", title: "Auto Advance Length", list: true) { [weak self] in
			self?.setAutoAdvanceLength(oldLength, unit: oldUnit)
		}
		engine.autoAdvanceUnit = unit.rawValue
		engine.autoAdvanceLength = length
		playlistModified = true
		changes.playlist.bump()
	}

	/// Time for the next patch: the one after, wrapping round, passing over
	/// any that can't be found or read
	func autoAdvanceNext() {
		guard engine.autoAdvancing else { return }
		let n = engine.playlistPatches.count
		guard n > 0 else { return }
		let from = playingPatch >= 0 && playingPatch < n ? playingPatch : -1
		for k in 1...n where playPatch((from + k + n) % n, automatic: true) {
			return
		}
	}

	/// V1's patch mode (Mac addition, saved with the playlist): in Geometry
	/// mode New, Open and playing a patch change only its shape and motion
	/// parameters (WHEngine geometryMode). Set from the menu or the panel,
	/// it marks the playlist edited; from MIDI or OSC (onMidi kind 7) it
	/// doesn't, as V1's PatchMode controller didn't, so live switching
	/// doesn't leave a playlist to save.
	func setGeometryMode(_ on: Bool) {
		guard on != engine.geometryMode else { return }
		// undoable with the playlist's edits (the user's request, 2026-11-25)
		recordUndo(key: "geometry \(UUID())", title: on ? "Geometry Only" : "Full Patches", list: true) { [weak self] in
			self?.setGeometryMode(!on)
		}
		engine.geometryMode = on
		playlistModified = true
		changes.playlist.bump()
		changes.menus.bump()
	}

	/// The playlist's next (+1) or previous (-1) patch, wrapping around at
	/// the ends; with none playing, the first or last. (A Mac addition:
	/// Image > Next Patch and Previous Patch, Command-Down and Command-Up.)
	func stepPatch(_ step: Int) {
		let n = engine.playlistPatches.count
		guard n > 0 else { return }
		let i = playingPatch >= 0 && playingPatch < n ? (playingPatch + step + n) % n : (step > 0 ? 0 : n - 1)
		playPatch(i)
	}
}
