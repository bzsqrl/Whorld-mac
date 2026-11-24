// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Named layouts (new in the Mac port, the user's request, 2026-11-22): Edit,
// Perform and the user's own, in the Window menu on Control-Command-1 to 9.
// Each remembers how it was left, like separate workspaces: switching away
// keeps the panels, divider positions and floating windows as they are,
// with whether the Perform Bar shows, and switching back restores them. Whether the picture is detached, and where
// the windows are, carry over, so a switch never takes the picture off a
// projector. Window > Reset Layout puts the current one back to its
// defaults: Edit's is the standard layout, Perform's a big picture with
// Patches over Playlist on the left and a narrow Parameters (its columns
// fitted to it, FormFit) over Master on the right, and a saved one's is the arrangement it was saved with. Kept in the
// app's settings (Layouts_v1); .whlayout files are for import and export.

import AppKit
import SwiftUI

struct NamedLayout: Codable, Identifiable, Equatable {
	static func == (a: NamedLayout, b: NamedLayout) -> Bool { a.id == b.id && a.name == b.name }

	/// "edit", "perform", or a saved one's UUID
	var id: String
	var name: String
	/// as it was left; nil: its defaults
	var file: LayoutFile?
	/// a saved one's defaults: the arrangement it was saved with
	var saved: LayoutFile?
	/// View > Show Perform Bar, as left (an older one's "oscillators", for
	/// Parameters' columns, is ignored: they fit the pane now)
	var performBar: Bool?
	/// View > Show Properties in Perform Bar, as left
	var propsBar: Bool?

	var isBuiltIn: Bool { id == NamedLayouts.editID || id == NamedLayouts.performID }
}

@MainActor
final class NamedLayouts: ObservableObject {
	static let shared = NamedLayouts()
	static let editID = "edit", performID = "perform"
	private static let key = "Layouts_v1"

	private struct Stored: Codable {
		var active: String
		var items: [NamedLayout]
	}

	@Published private(set) var items: [NamedLayout]
	@Published private(set) var active: String

	private init() {
		let builtIn = [NamedLayout(id: Self.editID, name: "Edit"), NamedLayout(id: Self.performID, name: "Perform")]
		if let data = UserDefaults.standard.data(forKey: Self.key),
			let s = try? JSONDecoder().decode(Stored.self, from: data) {
			// the built-in ones first, whatever was stored
			let own = s.items.filter { !$0.isBuiltIn }
			let all = builtIn.map { b in s.items.first { $0.id == b.id } ?? b } + own
			items = all
			active = all.contains { $0.id == s.active } ? s.active : Self.editID
		} else {
			items = builtIn
			active = Self.editID	// the arrangement Whorld has now is Edit's
		}
	}

	private func save() {
		if let data = try? JSONEncoder().encode(Stored(active: active, items: items)) {
			UserDefaults.standard.set(data, forKey: Self.key)
		}
		AppModel.shared.changes.menus.bump()
	}

	var current: NamedLayout? { items.first { $0.id == active } }

	/// Control-Command and its place, 1 to 9
	static func shortcut(_ index: Int) -> KeyEquivalent? {
		index < 9 ? KeyEquivalent(Character(String(index + 1))) : nil
	}

	// MARK: Defaults

	/// What Reset Layout puts it back to
	func defaults(_ item: NamedLayout) -> LayoutFile {
		switch item.id {
		case Self.editID:
			var f = LayoutFile(layout: .standard)
			f.splits = Layout.standardSplits
			return f
		case Self.performID:
			return Self.performDefault
		default:
			return item.saved ?? LayoutFile(layout: .standard)
		}
	}

	/// Perform: the picture large; Patches over the Playlist in a narrow
	/// left column; Parameters (narrow) over Master on the right; nothing
	/// along the bottom (the user's choice, 2026-11-22). The Key Map cheat
	/// sheet stands in for the Key Map panel.
	static let performDefault: LayoutFile = {
		var l = Layout(left: .split(.column, [.panel(.patches), .panel(.playlist)]),
			right: .split(.column, [.panel(.params), .panel(.master)]))
		l.lastRegion = [.properties: .bottom, .globals: .bottom, .mapping: .bottom]
		var f = LayoutFile(layout: l)
		f.splits = [
			"Whorld.H.left|center|right": [0.17, 0.59, 0.24],
			"Whorld.left.column(patches,playlist)": [0.5, 0.5],
			"Whorld.right.column(params,master)": [0.6, 0.4],
		]
		return f
	}()

	/// Perform plays the Properties from the bar (it has no Properties
	/// panel); Edit has the panel
	private func defaultPropsBar(_ item: NamedLayout) -> Bool? {
		switch item.id {
		case Self.editID: false
		case Self.performID: true
		default: item.saved == nil ? nil : item.propsBar
		}
	}

	private func defaultPerformBar(_ item: NamedLayout) -> Bool? {
		switch item.id {
		case Self.editID: nil
		case Self.performID: true
		default: item.saved == nil ? nil : item.performBar
		}
	}

	// MARK: Switching

	/// The current one as it is now, kept with it
	private func captureCurrent() {
		guard let i = items.firstIndex(where: { $0.id == active }) else { return }
		let model = AppModel.shared
		items[i].file = model.currentLayoutFile()
		items[i].performBar = model.showStats
		items[i].propsBar = model.showPropsBar
	}

	/// Window > a layout: as it was left (or its defaults)
	func switchTo(_ id: String) {
		guard id != active, let target = items.first(where: { $0.id == id }) else { return }
		captureCurrent()
		active = id
		apply(target.file ?? defaults(target), performBar: target.file == nil ? defaultPerformBar(target) : target.performBar,
			propsBar: target.file == nil ? defaultPropsBar(target) : target.propsBar)
		save()
	}

	/// Window > Reset Layout: the current one's defaults
	func resetCurrent() {
		guard let i = items.firstIndex(where: { $0.id == active }) else { return }
		items[i].file = nil
		apply(defaults(items[i]), performBar: defaultPerformBar(items[i]), propsBar: defaultPropsBar(items[i]))
		save()
	}

	/// Arranges the panels as `f` says; the picture stays detached or docked
	/// as it is, and the windows where they are
	private func apply(_ f: LayoutFile, performBar: Bool?, propsBar: Bool? = nil) {
		let model = AppModel.shared
		var f = f
		f.layout.detached = model.layout.layout.detached
		f.window = nil
		f.output = nil
		model.applyLayout(f)
		if let performBar, model.showStats != performBar { model.showStats = performBar }
		if let propsBar, model.showPropsBar != propsBar { model.showPropsBar = propsBar }
	}

	// MARK: The user's own

	/// Window > Save Layout As…: the arrangement now, under a name; the same
	/// name as a saved one replaces it. It becomes the current layout.
	func saveCurrentAs() {
		guard let name = Self.askName(title: "Save the layout as:", initial: current?.isBuiltIn == false ? current!.name : "") else { return }
		if let b = items.first(where: { $0.isBuiltIn && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
			let a = NSAlert()
			a.messageText = "\"\(b.name)\" is one of Whorld's own layouts."
			a.informativeText = "Choose another name. To change \(b.name), switch to it and arrange it: it remembers."
			a.runModal()
			return
		}
		captureCurrent()
		let model = AppModel.shared
		var item = NamedLayout(id: UUID().uuidString, name: name)
		if let old = items.firstIndex(where: { !$0.isBuiltIn && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
			item.id = items[old].id
			items.remove(at: old)
		}
		item.saved = model.currentLayoutFile()
		item.performBar = model.showStats
		item.propsBar = model.showPropsBar
		items.append(item)
		active = item.id
		save()
	}

	/// Window > Import Layout…: a .whlayout file, as a saved layout named
	/// after it, made current
	func importFile(_ f: LayoutFile, name: String) {
		captureCurrent()
		var item = NamedLayout(id: UUID().uuidString, name: name)
		if let old = items.firstIndex(where: { !$0.isBuiltIn && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
			item.id = items[old].id
			items.remove(at: old)
		}
		item.saved = f
		items.append(item)
		active = item.id
		apply(f, performBar: nil)
		save()
	}

	/// Window > Delete Layout: a saved one; Whorld switches to Edit
	func deleteCurrent() {
		guard let item = current, !item.isBuiltIn else { return }
		let a = NSAlert()
		a.messageText = "Delete the layout \"\(item.name)\"?"
		a.informativeText = "Whorld switches to the Edit layout. This can't be undone."
		a.addButton(withTitle: "Delete")
		a.addButton(withTitle: "Cancel")
		guard a.runModal() == .alertFirstButtonReturn else { return }
		switchTo(Self.editID)
		items.removeAll { $0.id == item.id }
		save()
	}

	/// Window > Rename Layout…: a saved one
	func renameCurrent() {
		guard let i = items.firstIndex(where: { $0.id == active }), !items[i].isBuiltIn,
			let name = Self.askName(title: "Rename the layout:", initial: items[i].name) else { return }
		if items.contains(where: { $0.id != active && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
			let a = NSAlert()
			a.messageText = "There's already a layout called \"\(name)\"."
			a.runModal()
			return
		}
		items[i].name = name
		save()
	}

	private static func askName(title: String, initial: String) -> String? {
		let a = NSAlert()
		a.messageText = title
		a.addButton(withTitle: "Save")
		a.addButton(withTitle: "Cancel")
		let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
		field.stringValue = initial
		field.placeholderString = "Layout name"
		a.accessoryView = field
		a.window.initialFirstResponder = field
		guard a.runModal() == .alertFirstButtonReturn else { return nil }
		let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		return name.isEmpty ? nil : name
	}
}
