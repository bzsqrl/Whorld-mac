// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Patch files: open, save, the title (AppModel, split out of WhorldApp.swift on 2026-11-22;
// no change in behavior).

import AppKit
import SwiftUI

extension AppModel {
	// MARK: Files


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
		guard let url = resolvedPatchPath(stored) else { return "" }
		// its file's date checked once until the lookups are forgotten
		if authorChecked.contains(url.path), let cached = authorCache[url.path] { return cached.author }
		authorChecked.insert(url.path)
		let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
		if let cached = authorCache[url.path], cached.date == date {
			return cached.author
		}
		let author = WHEngine.authorOfPatch(atPath: url.path) ?? ""
		authorCache[url.path] = (date, author)
		return author
	}

	func newPatch() {
		guard confirmDiscard() else { return }
		playedName = nil
		engine.newPatch()
		originFromPatch()
		resetUndo()
		updateTitle()
		changed()
	}

	func open(_ url: URL) {
		guard confirmDiscard() else { return }
		do {
			try engine.openPatch(atPath: url.path)
			playedName = nil
			playingFile = url
			originFromPatch()
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
		panel.directoryURL = WhorldFolders.start(.patches)
		if panel.runModal() == .OK, let url = panel.url {
			WhorldFolders.used(.patches, url)
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
		panel.directoryURL = WhorldFolders.start(.patches)
		// the patch's author, or for a patch without one Settings > General > Your name
		let author = NSTextField(string: authorToSuggest)
		author.placeholderString = "who made this patch (optional)"
		author.widthAnchor.constraint(equalToConstant: 280).isActive = true
		let row = NSStackView(views: [NSTextField(labelWithString: "Author:"), author])
		row.spacing = 8
		row.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
		panel.accessoryView = row
		guard panel.runModal() == .OK, let url = panel.url else { return false }
		WhorldFolders.used(.patches, url)
		setPatchAuthor(author.stringValue)
		return write(to: url)
	}

	/// What the Author fields start with: the patch's author, or if it has
	/// none, Settings > General > Your name
	var authorToSuggest: String {
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

	func write(to url: URL) -> Bool {
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
}
