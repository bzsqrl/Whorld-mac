// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// The Patches panel (new in the Mac port, the user's request, 2026-11-22):
// the patches in a folder and its subfolders, Documents/Whorld/Patches unless
// another is chosen. Clicking one plays it at once, crossfading as the
// playlist does; the arrow keys move through the list playing each, to
// audition patches while building a set; drag patches into the Playlist
// panel (docked under this one the first time) to add them. Windows Whorld
// has nothing like it.

import AppKit
import SwiftUI

/// The patch files the panel lists, and the folder they come from. Shared,
/// so a docked pane and a floating window show the same.
@MainActor
final class PatchBrowserStore: ObservableObject {
	static let shared = PatchBrowserStore()
	/// the folder chosen with Choose Folder…; none: the Whorld Patches folder
	private static let folderKey = "Browser_sFolder"
	/// more than this many are left out, so a huge folder can't stall the panel
	static let limit = 5000

	struct Item: Identifiable, Hashable {
		let url: URL
		/// its folder under the listed one ("" for the folder itself)
		let group: String
		var id: URL { url }
		var name: String { url.deletingPathExtension().lastPathComponent }
	}

	@Published private(set) var items: [Item] = []
	@Published private(set) var folder: URL
	@Published private(set) var truncated = false
	/// patches taken off the list (Delete, or Remove from List; the user's
	/// request, 2026-11-25): the files stay, and they come back with
	/// Refresh, another folder, or the next launch
	private var removed = Set<URL>()

	/// undoable (Edit > Undo Remove from List; the user's request,
	/// 2026-11-25), and redoable
	func remove(_ urls: Set<URL>) {
		let urls = Set(urls.map(\.standardizedFileURL))
		removed.formUnion(urls)
		items.removeAll { removed.contains($0.url.standardizedFileURL) }
		AppModel.shared.recordUndo(key: "patches remove \(UUID())", title: "Remove from List", list: true) {
			PatchBrowserStore.shared.putBack(urls)
		}
	}

	private func putBack(_ urls: Set<URL>) {
		removed.subtract(urls)
		reload()
		AppModel.shared.recordUndo(key: "patches remove \(UUID())", title: "Remove from List", list: true) {
			PatchBrowserStore.shared.remove(urls)
		}
	}

	/// the folder listed again, removed patches included
	func refresh() {
		removed = []
		reload()
	}

	private var activeObserver: Any?

	private init() {
		folder = Self.savedFolder() ?? WhorldFolders.folder(.patches)
		activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
			object: nil, queue: .main) { _ in
			MainActor.assumeIsolated { PatchBrowserStore.shared.reload() }	// files added in the Finder meanwhile
		}
		reload()
	}

	private static func savedFolder() -> URL? {
		guard let p = UserDefaults.standard.string(forKey: folderKey), !p.isEmpty else { return nil }
		var isDir: ObjCBool = false
		guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return nil }
		return URL(fileURLWithPath: p, isDirectory: true)
	}

	/// whether the folder is the Whorld Patches folder, not one chosen
	var isWhorldFolder: Bool { folder.standardizedFileURL == WhorldFolders.folder(.patches).standardizedFileURL }

	/// Settings > General > Whorld folder changed: the new Patches folder,
	/// unless a folder of its own is listed
	func whorldFolderMoved() {
		if Self.savedFolder() == nil { folder = WhorldFolders.folder(.patches) }
		reload()
	}

		func setFolder(_ url: URL?) {
		removed = []
		if let url {
			UserDefaults.standard.set(url.path, forKey: Self.folderKey)
			folder = url
		} else {
			UserDefaults.standard.removeObject(forKey: Self.folderKey)
			folder = WhorldFolders.folder(.patches)
		}
		reload()
	}

	/// Lists the folder's patches, its own first, then each subfolder's,
	/// by name (as the Finder sorts them)
	func reload() {
		let fm = FileManager.default
		let base = folder.standardizedFileURL
		var found: [Item] = []
		var cut = false
		if let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
			for case let url as URL in e where url.pathExtension.lowercased() == "whp" {
				if found.count >= Self.limit {
					cut = true
					break
				}
				let dir = url.deletingLastPathComponent().standardizedFileURL.path
				var group = dir.hasPrefix(base.path) ? String(dir.dropFirst(base.path.count)) : dir
				if group.hasPrefix("/") { group.removeFirst() }
				if !removed.contains(url.standardizedFileURL) { found.append(Item(url: url, group: group)) }
			}
		}
		found.sort {
			if $0.group != $1.group {
				if $0.group.isEmpty || $1.group.isEmpty { return $0.group.isEmpty }
				return $0.group.localizedStandardCompare($1.group) == .orderedAscending
			}
			return $0.name.localizedStandardCompare($1.name) == .orderedAscending
		}
		if found != items { items = found }
		truncated = cut
	}
}

/// Drags from the Patches panel into the Playlist: the files' paths as text,
/// marked so the Playlist knows them from its own rows (PlaylistRowDrag)
enum PatchFileDrag {
	static let prefix = "whorld-patch-files:"

	static func payload(_ urls: [URL]) -> String {
		prefix + urls.map(\.path).joined(separator: "\n")
	}

	static func paths(_ text: String) -> [String]? {
		guard text.hasPrefix(prefix) else { return nil }
		let p = text.dropFirst(prefix.count).split(separator: "\n").map(String.init)
		return p.isEmpty ? nil : p
	}
}

struct PatchBrowserPanel: View {
	@EnvironmentObject private var model: AppModel
	@ObservedObject private var store = PatchBrowserStore.shared
	@State private var selection = Set<URL>()
	@State private var search = ""

	/// the items the search leaves
	private var shown: [PatchBrowserStore.Item] {
		let q = search.trimmingCharacters(in: .whitespaces)
		return q.isEmpty ? store.items : store.items.filter {
			$0.name.localizedCaseInsensitiveContains(q) || $0.group.localizedCaseInsensitiveContains(q)
		}
	}

	/// which columns show (right-click the header), kept in the settings;
	/// Folder hidden at first
	@State private var columns = TableColumnCustomization<PatchBrowserStore.Item>()
	private static let columnsKey = "Patches_columns"

	var body: some View {
		let shown = shown
		// a Table, as the Playlist's: a SwiftUI List with draggable rows
		// doesn't select on a click (macOS); subfolders are a column
		VStack(spacing: 0) {
			header
			Divider()
			if store.items.isEmpty {
				empty
			} else {
				Table(of: PatchBrowserStore.Item.self, selection: $selection, columnCustomization: $columns) {
					TableColumn("Patch") { item in
						HStack(spacing: 4) {
							Image(systemName: "play.fill")
								.foregroundStyle(.green)
								.opacity(item.url.standardizedFileURL == model.playingFile?.standardizedFileURL ? 1 : 0)
							Text(item.name).lineLimit(1).truncationMode(.middle)
						}
						.hoverTip(item.url.path)
					}
					.width(min: 120, ideal: 200)
					.customizationID("patch")
					.disabledCustomizationBehavior(.visibility)	// always shown
					// as the Playlist's (the user's request, 2026-11-24)
					TableColumn("Author") { item in
						Text(model.patchAuthor(item.url.path))
							.foregroundStyle(.secondary)
							.lineLimit(1)
							.truncationMode(.tail)
					}
					.width(min: 60, ideal: 110)
					.customizationID("author")
					// its subfolder, or the listed folder's name for one in it
					// (it was empty there, and squeezed away with no subfolders)
					TableColumn("Folder") { item in
						Text(item.group.isEmpty ? store.folder.lastPathComponent : item.group)
							.foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
					}
					.width(min: 50, ideal: 90)
					.customizationID("folder")
					.defaultVisibility(.hidden)	// as the Playlist's (the user's choice, 2026-11-24)
				} rows: {
					ForEach(shown) { item in
						TableRow(item).itemProvider {
							let urls = selection.contains(item.url) ? orderedSelection() : [item.url]
							return NSItemProvider(object: PatchFileDrag.payload(urls) as NSString)
						}
					}
				}
				// a letter doesn't jump to (and play) a patch; Delete takes the
				// selected ones off the list (not Image > Clear)
				.background(NoTypeSelect(onDelete: { removeSelected() }))
				.background(FitColumns())	// columns to the pane's width
				.onAppear { columns = StoredColumns.load(Self.columnsKey) ?? columns }
				.onChange(of: columns) { _, c in StoredColumns.save(c, Self.columnsKey) }
				.contextMenu(forSelectionType: URL.self) { urls in
					menu(for: urls)
				} primaryAction: { urls in
					if urls.count == 1, let url = urls.first { model.playPatchFile(url) }	// double-click or Return: play again
				}
			}
			if store.truncated {
				Text("Showing the first \(PatchBrowserStore.limit) patches")
					.font(.caption).foregroundStyle(.secondary).padding(4)
			}
		}
		.onChange(of: selection) { old, new in
			// a click, or an arrow key, plays the patch it lands on (one
			// clicked alone; adding to a selection with ⌘ or ⇧ doesn't)
			guard new.count == 1, let url = new.first, old != new else { return }
			model.playPatchFile(url)
		}
	}

	/// Delete, or Remove from List: off the list, the files untouched
	private func removeSelected() {
		guard !selection.isEmpty else { return }
		store.remove(selection)
		selection = []
	}

	/// the selected patches in the list's order
	private func orderedSelection() -> [URL] {
		store.items.map(\.url).filter { selection.contains($0) }
	}

	@ViewBuilder private func menu(for urls: Set<URL>) -> some View {
		let ordered = store.items.map(\.url).filter { urls.contains($0) }
		if ordered.count == 1, let url = ordered.first {
			Button("Play") { model.playPatchFile(url) }
			Button("Open as Patch") { model.open(url) }
		}
		if !ordered.isEmpty {
			Button(ordered.count == 1 ? "Add to Playlist" : "Add \(ordered.count) to Playlist") {
				model.addPatchesToPlaylist(ordered.map(\.path))
			}
			Divider()
			Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(ordered) }
			Divider()
			// off the list until Refresh; the files stay (the user's request, 2026-11-25)
			Button(ordered.count == 1 ? "Remove from List" : "Remove \(ordered.count) from List") {
				store.remove(Set(ordered))
				selection.subtract(ordered)
			}
		}
	}

	private var header: some View {
		HStack(spacing: 6) {
			Menu {
				Button("Whorld Patches Folder") { store.setFolder(nil) }
					.disabled(store.isWhorldFolder)
				Button("Choose Folder…") { chooseFolder() }
				Divider()
				Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.folder]) }
				Button("Refresh") { store.refresh() }	// removed patches back too
			} label: {
				// the icon alone: the panel's title already says Patches (the
				// user's choice, 2026-11-23); the folder's name stays for VoiceOver
				Label(store.folder.lastPathComponent, systemImage: "folder")
					.labelStyle(.iconOnly)
			}
			.menuStyle(.borderlessButton)
			.fixedSize()
			.hoverTip("Listing \(store.folder.path) and its subfolders. Choose another folder here.")
			TextField("Search", text: $search)
				.textFieldStyle(.roundedBorder)
				.controlSize(.small)
			Text("\(store.items.count)")
				.font(.caption).foregroundStyle(.secondary)
				.monospacedDigit()
				.hoverTip("Patches in this folder and its subfolders")
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 5)
	}

	private var empty: some View {
		VStack(spacing: 8) {
			Spacer()
			Text("No patches in \(store.folder.lastPathComponent)")
				.foregroundStyle(.secondary)
			Text("Save patches there, or choose another folder.")
				.font(.caption).foregroundStyle(.secondary)
			Button("Choose Folder…") { chooseFolder() }
			Spacer()
		}
		.frame(maxWidth: .infinity)
		.padding()
	}

	private func chooseFolder() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.canCreateDirectories = true
		panel.directoryURL = store.folder
		panel.prompt = "Show Patches"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		store.setFolder(url)
	}
}
