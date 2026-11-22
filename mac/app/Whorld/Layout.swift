// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyleft 2025 Chris Korda (original Whorld); port Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// The workspace's arrangement (split out of Workspace.swift on 2026-11-22;
// no change in behavior): the panels (PanelID), the regions, the docking
// tree (DockNode), the saved Layout and LayoutFile, and LayoutModel, which
// shows, hides, floats, docks and moves panels.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Layout

/// The panels (MainDockBarDef.h's bars, as the Mac port has them).
enum PanelID: String, CaseIterable, Codable, Identifiable {
	// in the View menu's order, which numbers their keys (the user's
	// order, 2026-11-18); layouts store the raw values, not the order
	case params, master, globals, properties, playlist
	case patches	// the patch browser (PatchBrowser.swift; the user's request, 2026-11-22), beside the Playlist
	case modulation	// the Modulation window, a panel since 2026-11-18 (the user's request)
	case mapping
	case keymap		// the Key Map window, a panel since 2026-11-18 (the user's request); its raw value is the window's id

	var id: String { rawValue }

	var title: String {
		switch self {
		case .params: "Parameters"
		case .master: "Master"
		case .globals: "Globals"
		case .properties: "Properties"
		case .playlist: "Playlist"
		case .mapping: "MIDI Mapping"
		case .modulation: "Modulation"
		case .keymap: "Key Map"
		case .patches: "Patches"
		}
	}

	/// What the panel controls, in brief: behind the ⓘ by its title (the user's
	/// request, 2026-11-18; it was how to move it, now the grip's tip)
	var summary: String {
		switch self {
		case .params:
			"The rings' shape, motion and color: each parameter's value, and the oscillator (waveform, amplitude, frequency, pulse width) that moves it."
		case .master:
			"Controls for the whole picture: speed, zoom, damping, trail, the number of rings, tempo, hue, canvas size, copies, spread and fade."
		case .globals:
			"Offsets to the shape and motion parameters that change every ring at once, not just new ones."
		case .properties:
			"Drawing switches (Fill, Outline, Mirror and the rest), how the origin moves, and Random Phase."
		case .playlist:
			"The patches to play: double-click one or press Return, or step through them with ⌘↓ and ⌘↑ (Image > Next Patch, Previous Patch)."
		case .mapping:
			"Which MIDI controls move which of Whorld's controls, and over what range. Turn on Learn to map one by moving it."
		case .modulation:
			"Audio modulation: what Whorld hears, and the rows that let the music and its beat move the picture."
		case .keymap:
			"Hold a key with the pointer over the picture and scroll (two fingers up or down, or the mouse wheel) to move its control; up increases. Press ` (left of 1) over the picture to show them all on a keyboard, and again to hide it."
		case .patches:
			"The patches in Documents › Whorld › Patches (or a folder you choose) and its subfolders. Click one to play it; the arrow keys play each in turn. Drag patches into the Playlist to add them."
		}
	}

	/// Option-Command plus the panel's place in the View menu (1 to 9)
	/// shows or hides it (the user's request, 2026-11-18: one run of keys
	/// to remember, instead of a letter each with Shift-Command, where a
	/// wrong letter did something else; Shift-Command-3, 4 and 5 are
	/// macOS's screenshots, so Option-Command)
	/// 1 to 9 (Patches sixth, after the Playlist, the user's choice,
	/// 2026-11-22; Show Perform Bar moved to Shift-Command-B); nil past the
	/// ninth (Option-Command-0 is Origin Park).
	var shortcut: KeyEquivalent? {
		let n = Self.allCases.firstIndex(of: self)! + 1
		return n <= 9 ? KeyEquivalent(Character(String(n))) : nil
	}

	var shortcutModifiers: EventModifiers { [.command, .option] }

	/// Shown for the first time, it floats (Modulation and the Key Map,
	/// windows of their own until they became panels), rather than docking
	/// in its region.
	var opensFloating: Bool { self == .modulation || self == .keymap }

	/// After MainDockBarDef.h (Params and Playlist left, Master and Globals
	/// right, Mapping bottom), except that Parameters, a wide table here,
	/// goes along the bottom, and Properties (Windows' Numbers) on the left.
	var defaultRegion: Region {
		switch self {
		case .params, .mapping, .modulation: .bottom
		case .master, .globals, .keymap: .right
		case .properties, .playlist, .patches: .left
		}
	}

	/// The starting size along a region's split that shows all of a form
	/// (with its title bar): the height of a side panel, the width of a
	/// bottom one. Nil for the panels that share what's left and scroll:
	/// with every panel shown, the forms are whole and the lists give way.
	func preferredLength(along axis: SplitAxis) -> CGFloat? {
		switch (self, axis) {
		case (.properties, .column): 252
		case (.master, .column): 358
		case (.params, .row): 810
		default: nil
		}
	}

	/// Tables scroll themselves (both ways); the others are forms the
	/// workspace scrolls.
	var scrollsItself: Bool { self == .playlist || self == .mapping || self == .modulation || self == .keymap || self == .patches }

	/// A form's narrowest width: it stretches to fill a wider pane (its
	/// sliders widen) and scrolls sideways in a narrower one.
	var formMinWidth: CGFloat {
		switch self {
		case .params: ParamColumn.panelMin
		case .master: MasterPanel.minWidth
		case .globals: GlobalsPanel.minWidth
		case .properties: 116	// its widest row, Random Phase (2026-11-18: with Origin's menu under its name, not beside)
		default: 190
		}
	}

	/// a floating window's smallest content size
	var floatingMinSize: CGSize {
		switch self {
		case .params: CGSize(width: 800, height: 300)
		case .mapping: CGSize(width: 680, height: 240)
		case .playlist: CGSize(width: 360, height: 200)
		case .modulation: CGSize(width: 640, height: 0)	// its own content sets its height (one row of the table)
		case .keymap: CGSize(width: 460, height: 360)	// (its window's smallest)
		case .patches: CGSize(width: 240, height: 240)
		default: CGSize(width: 0, height: 0)
		}
	}
}

enum Region: String, Codable, CaseIterable {
	case left, right, bottom

	var title: String { rawValue.capitalized }

	/// how a region lines up panels added to it: the sides top to bottom,
	/// the bottom side by side
	var axis: SplitAxis { self == .bottom ? .row : .column }
}

/// A split's direction: panes one above another, or side by side.
enum SplitAxis: String, Codable {
	case column, row
}

/// Where a dropped panel goes, relative to the panel it's dropped on.
enum DockEdge {
	case top, bottom, leading, trailing

	var axis: SplitAxis { self == .top || self == .bottom ? .column : .row }
	var isAfter: Bool { self == .bottom || self == .trailing }

	var alignment: Alignment {
		switch self {
		case .top: .top
		case .bottom: .bottom
		case .leading: .leading
		case .trailing: .trailing
		}
	}
}

/// A region's arrangement: one panel, panels stacked as tabs in one pane
/// (as Windows' docking bars can be), or panes split one above another or
/// side by side, each of which can be split again, so a panel can go above,
/// below, left or right of any other, or join its tabs.
indirect enum DockNode: Codable, Equatable {
	case panel(PanelID)
	case tabs([PanelID], selected: PanelID)	// two or more; `selected` is the one showing
	case split(SplitAxis, [DockNode])

	var panels: [PanelID] {
		switch self {
		case .panel(let id): [id]
		case .tabs(let ids, _): ids
		case .split(_, let kids): kids.flatMap(\.panels)
		}
	}

	/// a pane of its own: a panel or a tab stack, not a split
	var isPane: Bool {
		if case .split = self { return false }
		return true
	}

	func contains(_ id: PanelID) -> Bool { panels.contains(id) }

	/// Names the subtree: a split view's pane, and (with the region) where
	/// its divider positions are saved, so each arrangement keeps its own.
	var key: String {
		switch self {
		case .panel(let id): id.rawValue
		case .tabs(let ids, _): "tabs(" + ids.map(\.rawValue).joined(separator: ",") + ")"	// not the selection
		case .split(let axis, let kids): "\(axis.rawValue)(" + kids.map(\.key).joined(separator: ",") + ")"
		}
	}

	/// Without the panel; nil if nothing is left.
	func removing(_ id: PanelID) -> DockNode? {
		switch self {
		case .panel(let p): return p == id ? nil : self
		case .tabs(let ids, let sel):
			guard let i = ids.firstIndex(of: id) else { return self }
			let rest = ids.filter { $0 != id }
			// the tab beside it shows when the showing one goes
			return Self.makeTabs(rest, selected: sel == id ? rest[min(i, rest.count - 1)] : sel)
		case .split(let axis, let kids): return Self.make(axis, kids.compactMap { $0.removing(id) })
		}
	}

	/// With `id` on the given side of `target` (which must be here).
	func inserting(_ id: PanelID, at edge: DockEdge, of target: PanelID) -> DockNode {
		let new = DockNode.panel(id)
		switch self {
		case .panel, .tabs:	// splits the pane (a whole tab stack moves over)
			guard contains(target) else { return self }
			return .split(edge.axis, edge.isAfter ? [self, new] : [new, self])
		case .split(let axis, var kids):
			guard let i = kids.firstIndex(where: { $0.contains(target) }) else { return self }
			if axis == edge.axis, kids[i].isPane {	// a sibling in this split
				kids.insert(new, at: edge.isAfter ? i + 1 : i)
			} else {
				kids[i] = kids[i].inserting(id, at: edge, of: target)
			}
			return Self.make(axis, kids)!
		}
	}

	/// With `id` as a tab beside `target`, showing: last in the stack, or
	/// just before or after `target` (putting a panel back, DockNode.restoring).
	func tabbing(_ id: PanelID, with target: PanelID, beside: DockEdge? = nil) -> DockNode {
		switch self {
		case .panel(let p):
			guard p == target else { return self }
			return .tabs(beside == .leading ? [id, p] : [p, id], selected: id)
		case .tabs(var ids, _):
			guard let i = ids.firstIndex(of: target) else { return self }
			switch beside {
			case .leading?: ids.insert(id, at: i)
			case .trailing?: ids.insert(id, at: i + 1)
			default: ids.append(id)
			}
			return .tabs(ids, selected: id)
		case .split(let axis, let kids):
			return .split(axis, kids.map { $0.tabbing(id, with: target, beside: beside) })
		}
	}

	/// Where the panel sits in this arrangement, for putting it back after
	/// it has changed: its tab neighbour (and which side of it), or the
	/// pane or split beside it in its split (and which side of that).
	enum Neighbour {
		case tab(PanelID, DockEdge)	// .leading: before that tab
		case side(DockNode, DockEdge)
	}

	func neighbour(of id: PanelID) -> Neighbour? {
		switch self {
		case .panel: return nil
		case .tabs(let ids, _):
			guard let i = ids.firstIndex(of: id), ids.count > 1 else { return nil }
			return i > 0 ? .tab(ids[i - 1], .trailing) : .tab(ids[i + 1], .leading)
		case .split(let axis, let kids):
			if let i = kids.firstIndex(of: .panel(id)) {
				if i > 0 { return .side(kids[i - 1], axis == .row ? .trailing : .bottom) }
				if i + 1 < kids.count { return .side(kids[i + 1], axis == .row ? .leading : .top) }
			}
			return kids.lazy.compactMap { $0.neighbour(of: id) }.first
		}
	}

	/// With `id` on one side of a whole pane or split that's here (nil if it isn't).
	func inserting(_ id: PanelID, at edge: DockEdge, ofNode target: DockNode) -> DockNode? {
		let new = DockNode.panel(id)
		let pair = edge.isAfter ? [target, new] : [new, target]
		if self == target { return Self.make(edge.axis, pair) }
		guard case .split(let axis, var kids) = self else { return nil }
		if let i = kids.firstIndex(of: target) {
			if axis == edge.axis {
				kids.insert(new, at: edge.isAfter ? i + 1 : i)
			} else {
				kids[i] = Self.make(edge.axis, pair)!
			}
			return Self.make(axis, kids)
		}
		for i in kids.indices {
			if let k = kids[i].inserting(id, at: edge, ofNode: target) {
				kids[i] = k
				return Self.make(axis, kids)
			}
		}
		return nil
	}

	/// With the panel put back as it was in `before` (this region's
	/// arrangement when it was taken out), now that the region has changed:
	/// beside the same neighbour on the same side, or the same tab stack;
	/// or beside one of the neighbour's panels still here. Nil if none is.
	func restoring(_ id: PanelID, from before: DockNode) -> DockNode? {
		switch before.neighbour(of: id) {
		case .tab(let t, let side)?:
			return contains(t) ? tabbing(id, with: t, beside: side) : nil
		case .side(let n, let edge)?:
			if let done = inserting(id, at: edge, ofNode: n) { return done }
			let near = edge.isAfter ? n.panels.reversed() : n.panels
			guard let p = near.first(where: contains) else { return nil }
			return inserting(id, at: edge, of: p)
		case nil:
			return nil
		}
	}

	/// With the tab showing (if it's in a stack).
	func selecting(_ id: PanelID) -> DockNode {
		switch self {
		case .panel: return self
		case .tabs(let ids, _): return ids.contains(id) ? .tabs(ids, selected: id) : self
		case .split(let axis, let kids): return .split(axis, kids.map { $0.selecting(id) })
		}
	}

	/// True if the panel is a tab that isn't showing.
	func isHiddenTab(_ id: PanelID) -> Bool {
		switch self {
		case .panel: false
		case .tabs(let ids, let sel): ids.contains(id) && sel != id
		case .split(_, let kids): kids.contains { $0.isHiddenTab(id) }
		}
	}

	/// A tab stack, tidied: one tab left is a plain panel. (Not named
	/// `tabs`: inside it, `.tabs(…)` would call itself, not make the case.)
	private static func makeTabs(_ ids: [PanelID], selected: PanelID) -> DockNode? {
		switch ids.count {
		case 0: return nil
		case 1: return .panel(ids[0])
		default: return .tabs(ids, selected: ids.contains(selected) ? selected : ids[0])
		}
	}

	/// The pane (a panel or a tab stack) holding the panel, if it's here.
	func leaf(containing id: PanelID) -> DockNode? {
		switch self {
		case .panel, .tabs: return contains(id) ? self : nil
		case .split(_, let kids): return kids.lazy.compactMap { $0.leaf(containing: id) }.first
		}
	}

	/// With two panes changing places (each whole: a tab stack moves as one).
	func swapping(_ a: DockNode, _ b: DockNode) -> DockNode {
		switch self {
		case .panel, .tabs: return self == a ? b : self == b ? a : self
		case .split(let axis, let kids): return .split(axis, kids.map { $0.swapping(a, b) })
		}
	}

	/// With `id` along one side of the whole arrangement: below it all, say,
	/// as wide as everything here (a span; 2026-11-18).
	func adding(_ id: PanelID, at edge: DockEdge) -> DockNode {
		Self.make(edge.axis, edge.isAfter ? [self, .panel(id)] : [.panel(id), self])!
	}

	/// With `id` added at the end along `axis` (a region's own direction).
	func appending(_ id: PanelID, along axis: SplitAxis) -> DockNode {
		if case .split(let a, let kids) = self, a == axis {
			return .split(a, kids + [.panel(id)])
		}
		return .split(axis, [self, .panel(id)])
	}

	/// A split, tidied: a lone pane stands for itself, and a pane split the
	/// same way as its parent joins the parent's panes.
	private static func make(_ axis: SplitAxis, _ kids: [DockNode]) -> DockNode? {
		let flat = kids.flatMap { k -> [DockNode] in
			if case .split(let a, let inner) = k, a == axis { return inner }
			return [k]
		}
		switch flat.count {
		case 0: return nil
		case 1: return flat[0]
		default: return .split(axis, flat)
		}
	}
}

struct Layout: Codable, Equatable {
	var left: DockNode?
	var right: DockNode?
	var bottom: DockNode?
	var floating: [PanelID] = []
	var detached = false
	/// where a hidden or floating panel goes back to
	var lastRegion: [PanelID: Region] = [:]
	/// hidden while floating: it floats again when shown (2026-11-18)
	var lastFloating: [PanelID] = []
	/// the exact place it goes back to, in its last region (2026-11-20)
	var lastPlace: [PanelID: DockPlace] = [:]

	enum CodingKeys: String, CodingKey { case left, right, bottom, floating, detached, lastRegion, lastFloating, lastPlace }

	/// Fields missing (a layout from before one was added) read as their
	/// defaults; see also LayoutFile.sanitized, for panels this Whorld lacks.
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		left = try c.decodeIfPresent(DockNode.self, forKey: .left)
		right = try c.decodeIfPresent(DockNode.self, forKey: .right)
		bottom = try c.decodeIfPresent(DockNode.self, forKey: .bottom)
		floating = try c.decodeIfPresent([PanelID].self, forKey: .floating) ?? []
		detached = try c.decodeIfPresent(Bool.self, forKey: .detached) ?? false
		lastRegion = try c.decodeIfPresent([PanelID: Region].self, forKey: .lastRegion) ?? [:]
		lastFloating = try c.decodeIfPresent([PanelID].self, forKey: .lastFloating) ?? []
		lastPlace = (try? c.decodeIfPresent([PanelID: DockPlace].self, forKey: .lastPlace)) ?? [:]	// (only a convenience)
	}

	/// What a new install shows, and Window > Reset Layout: Parameters on the
	/// left beside the picture, Playlist, Properties, Master and Globals along
	/// the bottom, MIDI Mapping hidden (the user's arrangement, 2026-11-11).
	/// The divider positions are in `standardSplits`.
	static let standard: Layout = {
		var l = Layout(left: .panel(.params),
			bottom: .split(.row, [.panel(.playlist), .panel(.properties), .panel(.master), .panel(.globals)]))
		l.lastRegion = [.mapping: .left]
		return l
	}()

	/// The standard layout's split views (by autosave name): each pane's
	/// share of the space, in order
	static let standardSplits: [String: [Double]] = [
		"Whorld.H.left|center": [0.4987, 0.5013],
		"Whorld.V.top|bottom": [0.5836, 0.4164],
		"Whorld.bottom.row(playlist,properties,master,globals)": [0.2502, 0.1352, 0.3360, 0.2786],
	]

	func root(_ r: Region) -> DockNode? {
		switch r {
		case .left: left
		case .right: right
		case .bottom: bottom
		}
	}

	mutating func setRoot(_ node: DockNode?, _ r: Region) {
		switch r {
		case .left: left = node
		case .right: right = node
		case .bottom: bottom = node
		}
	}

	func panels(in r: Region) -> [PanelID] { root(r)?.panels ?? [] }

	func region(of id: PanelID) -> Region? {
		Region.allCases.first { root($0)?.contains(id) == true }
	}

	/// takes the panel out of wherever it is
	mutating func remove(_ id: PanelID) {
		if let r = region(of: id), let old = root(r) {
			lastRegion[id] = r
			let new = old.removing(id)
			lastPlace[id] = DockPlace(before: old, after: new)
			setRoot(new, r)
		}
		floating.removeAll { $0 == id }
	}

	/// The first version's layout (Layout_v1): each region a list of panels.
	struct V1: Codable {
		var left: [PanelID] = []
		var right: [PanelID] = []
		var bottom: [PanelID] = []
		var floating: [PanelID] = []
		var detached = false
		var lastRegion: [PanelID: Region] = [:]
	}

	/// shown again: floating, if it was hidden floating (or floats the first time)
	func showsFloating(_ id: PanelID) -> Bool {
		lastFloating.contains(id) || (id.opensFloating && lastRegion[id] == nil)
	}

	init(left: DockNode? = nil, right: DockNode? = nil, bottom: DockNode? = nil) {
		self.left = left
		self.right = right
		self.bottom = bottom
	}

	init(_ v1: V1) {
		func node(_ ids: [PanelID], _ axis: SplitAxis) -> DockNode? {
			ids.count > 1 ? .split(axis, ids.map { .panel($0) }) : ids.first.map { .panel($0) }
		}
		self.init(left: node(v1.left, .column), right: node(v1.right, .column), bottom: node(v1.bottom, .row))
		floating = v1.floating
		detached = v1.detached
		lastRegion = v1.lastRegion
	}
}

/// Where a panel was taken out of a region (Layout.lastPlace; the user's
/// request, 2026-11-20: docking again puts it back exactly there): the
/// region's arrangement with it, and without it. Unchanged since, the region
/// goes back to `before`, divider positions too (they're saved by
/// arrangement); changed, the panel goes beside its old neighbour.
struct DockPlace: Codable, Equatable {
	var before: DockNode
	var after: DockNode?
}

/// A rectangle as a share of a screen's visible area, so a layout adapts to
/// other displays.
struct UnitRect: Codable, Equatable {
	var x, y, w, h: Double

	init(_ r: NSRect, in area: NSRect) {
		x = Double((r.minX - area.minX) / max(area.width, 1))
		y = Double((r.minY - area.minY) / max(area.height, 1))
		w = Double(r.width / max(area.width, 1))
		h = Double(r.height / max(area.height, 1))
	}

	func rect(in area: NSRect) -> NSRect {
		let r = NSRect(x: area.minX + CGFloat(x) * area.width, y: area.minY + CGFloat(y) * area.height,
			width: CGFloat(w) * area.width, height: CGFloat(h) * area.height)
		return r.intersection(area).isEmpty ? area : r	// keep it on screen
	}
}

/// A saved panel layout (Mac addition): a .whlayout file, or a playlist's
/// [Layout] section (as one line of JSON).
struct LayoutFile: Codable {
	var version = 1
	var layout: Layout
	/// each split view (autosave name): its panes' shares of the space
	var splits: [String: [Double]] = [:]
	var window: UnitRect?	// the Whorld window
	var output: UnitRect?	// the detached output window, if detached
	var floating: [String: UnitRect] = [:]	// floating panels' windows, by panel

	init(layout: Layout) { self.layout = layout }

	/// one line, for a playlist
	var line: String? {
		let e = JSONEncoder()
		e.outputFormatting = [.sortedKeys]
		return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
	}

	init?(line: String) {
		guard let f = try? JSONDecoder().decode(LayoutFile.self, from: Self.sanitized(Data(line.utf8))) else { return nil }
		self = f
	}

	/// A layout's JSON (a LayoutFile, or a Layout) without the panels this
	/// Whorld doesn't have (from a newer one), so the rest of it still
	/// opens: they're taken out of the regions, tabs and lists, as if hidden.
	static func sanitized(_ data: Data) -> Data {
		guard let root = try? JSONSerialization.jsonObject(with: data) else { return data }
		func known(_ v: Any) -> Bool { (v as? String).flatMap(PanelID.init(rawValue:)) != nil }
		// a DockNode as Codable writes it: {"panel":{"_0":id}},
		// {"tabs":{"_0":[ids],"selected":id}}, {"split":{"_0":axis,"_1":[nodes]}}
		func node(_ v: Any) -> Any? {
			guard let d = v as? [String: Any] else { return v }
			if let p = d["panel"] as? [String: Any] {
				return known(p["_0"] ?? "") ? d : nil
			}
			if let t = d["tabs"] as? [String: Any], let ids = t["_0"] as? [Any] {
				let kept = ids.filter(known)
				if kept.isEmpty { return nil }
				if kept.count == 1 { return ["panel": ["_0": kept[0]]] }
				var t2 = t
				t2["_0"] = kept
				if !known(t["selected"] ?? "") { t2["selected"] = kept[0] }
				return ["tabs": t2]
			}
			if let sp = d["split"] as? [String: Any], let kids = sp["_1"] as? [Any] {
				let kept = kids.compactMap(node)
				if kept.isEmpty { return nil }
				if kept.count == 1 { return kept[0] }
				var sp2 = sp
				sp2["_1"] = kept
				return ["split": sp2]
			}
			return d
		}
		func layout(_ l: [String: Any]) -> [String: Any] {
			var l = l
			for k in ["left", "right", "bottom"] {
				if let v = l[k] { l[k] = node(v) }	// (nil removes it)
			}
			for k in ["floating", "lastFloating"] {
				if let a = l[k] as? [Any] { l[k] = a.filter(known) }
			}
			if let a = l["lastRegion"] as? [Any] {	// [PanelID: Region]: key, value, key, value
				var kept: [Any] = []
				var i = 0
				while i + 1 < a.count {
					if known(a[i]) { kept += [a[i], a[i + 1]] }
					i += 2
				}
				l["lastRegion"] = kept
			}
			if let a = l["lastPlace"] as? [Any] {	// [PanelID: DockPlace]: key, value, ...
				var kept: [Any] = []
				var i = 0
				while i + 1 < a.count {
					if known(a[i]), var place = a[i + 1] as? [String: Any], let before = place["before"].flatMap(node) {
						place["before"] = before
						if let after = place["after"] { place["after"] = node(after) }
						kept += [a[i], place]
					}
					i += 2
				}
				l["lastPlace"] = kept
			}
			return l
		}
		guard var d = root as? [String: Any] else { return data }
		if let l = d["layout"] as? [String: Any] {	// a LayoutFile
			d["layout"] = layout(l)
		} else {
			d = layout(d)
		}
		return (try? JSONSerialization.data(withJSONObject: d)) ?? data
	}
}

/// The split views' starting positions as shares of their space: those of
/// the layout last applied, else the standard one's. A split view whose
/// positions weren't saved (first launch, a new arrangement, Reset Layout,
/// applying a layout) arranges by these, else by its panes' starting sizes.
enum SplitShares {
	nonisolated(unsafe) static var current: [String: [Double]] = Layout.standardSplits

	/// the shares of every Whorld split view in a window's content
	@MainActor static func capture(in root: NSView) -> [String: [Double]] {
		var out: [String: [Double]] = [:]
		func walk(_ v: NSView) {
			if let s = v as? NSSplitView, let name = s.autosaveName, name.hasPrefix("Whorld.") {
				let sizes = s.arrangedSubviews.map { Double(s.isVertical ? $0.frame.width : $0.frame.height) }
				let sum = sizes.reduce(0, +)
				if sum > 0 {
					out[name] = sizes.map { $0 / sum }
				}
			}
			v.subviews.forEach(walk)
		}
		walk(root)
		return out
	}
}

@MainActor
final class LayoutModel: ObservableObject {
	private static let key = "Layout_v2"
	private static let keyV1 = "Layout_v1"	// regions as lists, before panels could split each other
	private static let splitPrefix = "NSSplitView Subview Frames Whorld."

	@Published var layout: Layout {
		didSet {
			if let data = try? JSONEncoder().encode(layout) {
				UserDefaults.standard.set(data, forKey: Self.key)
			}
		}
	}
	/// true on the first launch with a workspace: fit the window to the screen
	let isFirstRun: Bool
	/// bumped when Whorld arranges the workspace (first run, Show All Panels,
	/// Reset Layout): the split views go back to their starting sizes
	@Published var arrangeGeneration = 0
	/// set by WorkspaceView, which has SwiftUI's window actions
	var openFloating: ((PanelID) -> Void)?
	var closeFloating: ((PanelID) -> Void)?

	// Docking by dragging a floating panel's window over the Whorld window,
	// and floating by dragging a docked panel's title bar out of it (2026-11-18)
	/// where a floating panel's window, dragged now, would dock (its highlight)
	@Published var windowDragHover: DragTarget?
	/// the docked panes (by the panel showing) and the output: views whose
	/// frames, asked when needed, are theirs (DockFrameProbe)
	final class WeakView { weak var view: NSView?; init(_ v: NSView) { view = v } }
	var paneViews: [PanelID: WeakView] = [:]
	var outputView: WeakView?

	/// a probe's frame in the Whorld window's coordinates (y up)
	private func frame(_ w: WeakView?, in main: NSWindow) -> CGRect? {
		guard let v = w?.view, v.window === main else { return nil }
		return v.convert(v.bounds, to: nil)
	}
	/// where a panel dragged out goes: its window's top left, on screen
	var pendingFloatOrigin: [PanelID: NSPoint] = [:]
	/// the docked panel whose title bar (or tab) is being dragged (PanelDragSource)
	var draggedPanel: PanelID?
	/// the regions' views, for spans (as paneViews)
	var regionViews: [Region: WeakView] = [:]
	/// a span a title bar dragged now would dock along (its highlight)
	@Published var titleDragSpan: SpanHover?

	/// the span a highlight shows on a region now, from either kind of drag
	func spanShown(on r: Region) -> DockEdge? {
		if case .span(let sr, let e)? = windowDragHover, sr == r { return e }
		if let h = titleDragSpan, h.region == r { return h.edge }
		return nil
	}
	func showSpan(_ t: DragTarget?, owner: String) {
		var new: SpanHover? = nil
		if case .span(let r, let e)? = t { new = SpanHover(owner: owner, region: r, edge: e) }
		if new != nil || titleDragSpan?.owner == owner, titleDragSpan != new { titleDragSpan = new }
	}

	/// how near a region's outer side (in points) a panel goes along it all
	static let spanBand: CGFloat = 24

	/// A span from a point on a pane (its own coordinates, y down): within
	/// spanBand of a side the pane shares with its region (on the top, just
	/// under the title bar, which takes tabs), when the region has more than
	/// the one pane.
	func span(onPane pane: PanelID, at p: CGPoint, size: CGSize) -> DragTarget? {
		guard let r = layout.region(of: pane), let root = layout.root(r), !root.isPane,
			let v = paneViews[pane]?.view, let main = v.window,
			let pf = frame(paneViews[pane], in: main), let rf = frame(regionViews[r], in: main) else { return nil }
		let b = Self.spanBand, h = DockedPanel.headerHeight
		if abs(pf.maxY - rf.maxY) < 2, p.y >= h, p.y < h + b { return .span(r, .top) }
		if abs(pf.minY - rf.minY) < 2, p.y > size.height - b { return .span(r, .bottom) }
		if abs(pf.minX - rf.minX) < 2, p.x < b, p.y >= h { return .span(r, .leading) }
		if abs(pf.maxX - rf.maxX) < 2, p.x > size.width - b, p.y >= h { return .span(r, .trailing) }
		return nil
	}

	/// What a panel dropped at a point in the Whorld window would do: as the
	/// drop delegates decide, on a pane (PanelDropDelegate.spot) or near the
	/// output's left, right or bottom (EdgeDropDelegate.region)
	func dragTarget(at p: CGPoint, dragging id: PanelID, in main: NSWindow) -> DragTarget? {
		for (pane, w) in paneViews {
			guard let r = frame(w, in: main), r.contains(p) else { continue }
			// window coordinates have y up; a pane's own, as SwiftUI's, down
			let local = CGPoint(x: p.x - r.minX, y: r.maxY - p.y)
			if let s = span(onPane: pane, at: local, size: r.size) { return s }
			if pane == id { return nil }	// onto itself
			return .pane(pane, PanelDropDelegate.spot(at: local, size: r.size))
		}
		if let r = frame(outputView, in: main), r.contains(p) {
			return EdgeDropDelegate.target(CGPoint(x: p.x - r.minX, y: r.maxY - p.y), size: r.size, layout: self)
		}
		return nil
	}

	func dock(_ id: PanelID, at t: DragTarget) {
		switch t {
		case .pane(let other, .tab): tab(id, with: other)
		case .pane(let other, .edge(let e)): move(id, to: e, of: other)
		case .region(let r): move(id, to: r)
		case .span(let r, let e): span(id, along: e, of: r)
		}
	}

	/// Docks the panel along one side of a whole region: below all the
	/// bottom's panes, as wide as they are, say.
	func span(_ id: PanelID, along edge: DockEdge, of r: Region) {
		let wasFloating = isFloating(id)
		var l = layout
		l.remove(id)
		l.setRoot(l.root(r)?.adding(id, at: edge) ?? .panel(id), r)
		layout = l
		if wasFloating {
			closeFloating?(id)
		}
	}

	// MARK: Moving panels with the keys (2026-11-18/19, the user's request)

	/// a panel's title bar, flashed after a key moved it (or couldn't)
	@Published var flashing: PanelID?
	private var flashWork: DispatchWorkItem?
	/// the floating panels' windows (FloatingWindowHelper), to find the one under the pointer
	final class WeakWindow { weak var window: NSWindow?; init(_ w: NSWindow) { window = w } }
	var floatingWindows: [PanelID: WeakWindow] = [:]

	func flash(_ id: PanelID) {
		flashWork?.cancel()
		flashing = id
		let work = DispatchWorkItem { [weak self] in self?.flashing = nil }
		flashWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
	}

	/// The panel under the pointer: a docked pane (its showing tab) or a
	/// floating panel's window.
	func panelUnderPointer() -> PanelID? {
		let p = NSEvent.mouseLocation
		let n = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
		guard let w = NSApp.window(withWindowNumber: n) else { return nil }
		if let (id, _) = floatingWindows.first(where: { $0.value.window === w }), isFloating(id) {
			return id
		}
		guard w === AppModel.shared.mainWindow else { return nil }
		let local = w.convertPoint(fromScreen: p)
		return paneViews.first { frame($0.value, in: w)?.contains(local) == true }?.key
	}

	/// ⌥⌘ and an arrow over a panel: a step that way (beside the next pane,
	/// or into the next area); with ⇧, all the way, along the whole area's
	/// side. A floating panel docks: ← left, → right, ↓ along the bottom.
	/// The title bar flashes, moved or not (no beep).
	func step(_ id: PanelID, toward d: DockEdge, far: Bool) {
		defer { flash(id) }
		if isFloating(id) {
			switch d {
			case .leading: move(id, to: .left)
			case .trailing: move(id, to: .right)
			case .bottom: move(id, to: .bottom)
			case .top: break	// no area above
			}
			return
		}
		guard let r = layout.region(of: id), let root = layout.root(r), let leaf = root.leaf(containing: id) else { return }
		if far {
			span(id, along: d, of: r)
			return
		}
		if case .tabs(let ids, _) = leaf, let other = ids.first(where: { $0 != id }) {
			move(id, to: d, of: other)	// out of the stack, to that side of it
			return
		}
		if let main = AppModel.shared.mainWindow, let next = neighbor(of: id, in: r, toward: d, main: main),
			let nextLeaf = root.leaf(containing: next) {
			layout.setRoot(root.swapping(leaf, nextLeaf), r)
			return
		}
		// at the area's side: into the next area, or nowhere
		switch (r, d) {
		case (.bottom, .top):	// up into the side column on its half of the window
			let main = AppModel.shared.mainWindow
			let mid = main?.contentView?.bounds.midX ?? 0
			let x = main.flatMap { frame(paneViews[id], in: $0)?.midX } ?? 0
			move(id, to: x < mid ? .left : .right)
		case (.left, .trailing): move(id, to: .right)
		case (.right, .leading): move(id, to: .left)
		case (.left, .bottom):	// down into the bottom row, at its left end
			if layout.bottom != nil { span(id, along: .leading, of: .bottom) } else { move(id, to: .bottom) }
		case (.right, .bottom): move(id, to: .bottom)	// at its right end
		default: break
		}
	}

	/// the nearest pane of the area that way, overlapping across
	private func neighbor(of id: PanelID, in r: Region, toward d: DockEdge, main: NSWindow) -> PanelID? {
		guard let f = frame(paneViews[id], in: main), let mine = layout.root(r)?.leaf(containing: id) else { return nil }
		var best: (id: PanelID, gap: CGFloat, overlap: CGFloat)?
		for (other, w) in paneViews where other != id {
			guard layout.region(of: other) == r, layout.root(r)?.leaf(containing: other) != mine,
				let g = frame(w, in: main) else { continue }
			let across = d.axis == .row
				? min(f.maxY, g.maxY) - max(f.minY, g.minY)	// side by side: overlap in height
				: min(f.maxX, g.maxX) - max(f.minX, g.minX)
			guard across > 4 else { continue }
			let gap: CGFloat	// window coordinates: y up
			switch d {
			case .leading: guard g.maxX <= f.minX + 3 else { continue }; gap = f.minX - g.maxX
			case .trailing: guard g.minX >= f.maxX - 3 else { continue }; gap = g.minX - f.maxX
			case .top: guard g.minY >= f.maxY - 3 else { continue }; gap = g.minY - f.maxY
			case .bottom: guard g.maxY <= f.minY + 3 else { continue }; gap = f.minY - g.maxY
			}
			if best == nil || gap < best!.gap - 1 || (abs(gap - best!.gap) <= 1 && across > best!.overlap) {
				best = (other, gap, across)
			}
		}
		return best?.id
	}

	/// A docked panel's title bar let go away from a dock spot: it floats
	/// in a window there (its top left at the point).
	func float(_ id: PanelID, at screenPoint: NSPoint) {
		pendingFloatOrigin[id] = screenPoint
		float(id)
	}

	init() {
		let defaults = UserDefaults.standard
		if let data = defaults.data(forKey: Self.key),
			let saved = try? JSONDecoder().decode(Layout.self, from: LayoutFile.sanitized(data)) {
			layout = saved
			isFirstRun = false
		} else if let data = defaults.data(forKey: Self.keyV1),
			let old = try? JSONDecoder().decode(Layout.V1.self, from: data) {
			layout = Layout(old)	// saved under Layout_v2 from now on; v1 is left for an older build
			isFirstRun = false
		} else {
			layout = .standard
			isFirstRun = true
		}
	}

	func isShown(_ id: PanelID) -> Bool { layout.region(of: id) != nil || layout.floating.contains(id) }
	func isDocked(_ id: PanelID) -> Bool { layout.region(of: id) != nil }
	func isFloating(_ id: PanelID) -> Bool { layout.floating.contains(id) }

	func setShown(_ id: PanelID, _ show: Bool) {
		// a tab that isn't showing is brought forward rather than hidden
		// (View menu shortcuts reveal a panel stacked behind another)
		if !show, let r = layout.region(of: id), layout.root(r)?.isHiddenTab(id) == true {
			select(id)
			return
		}
		if show == isShown(id) { return }
		if show {
			if layout.showsFloating(id) {
				float(id)
			} else {
				dock(id)
			}
		} else {
			hide(id)
		}
	}

	func hide(_ id: PanelID) {
		let wasFloating = isFloating(id)
		var l = layout
		l.remove(id)
		l.lastFloating.removeAll { $0 == id }
		if wasFloating {
			l.lastFloating.append(id)	// it floats again when shown
		}
		layout = l
		if wasFloating {
			closeFloating?(id)
		}
	}

	/// Docks a floating or hidden panel where it was taken out (Layout
	/// lastPlace): exactly there if its region hasn't changed since, else
	/// beside the same neighbour; failing that, at the end of its last region.
	func dock(_ id: PanelID) {
		guard !isDocked(id) else { return }
		// Patches, docked for the first time: above the Playlist, sharing its
		// pane, so patches can be dragged down into it (2026-11-22; as a tab
		// the Playlist would be hidden while dragging)
		if id == .patches, layout.lastRegion[id] == nil, layout.region(of: .playlist) != nil {
			move(id, to: .top, of: .playlist)
			return
		}
		let r = layout.lastRegion[id] ?? id.defaultRegion
		guard layout.lastRegion[id] != nil, let place = layout.lastPlace[id] else { move(id, to: r); return }
		var l = layout
		let current = l.root(r)
		let new: DockNode?
		if current == place.after, place.before.contains(id) {
			new = place.before
		} else if let current {
			new = current.restoring(id, from: place.before)
		} else {
			new = .panel(id)
		}
		guard let new else { move(id, to: r); return }
		let wasFloating = isFloating(id)
		l.remove(id)	// (from the floating list)
		l.setRoot(new, r)
		layout = l
		if wasFloating {
			closeFloating?(id)
		}
	}

	/// Docks the panel at the end of a region (below or to the right of
	/// what's there).
	func move(_ id: PanelID, to r: Region) {
		let wasFloating = isFloating(id)
		var l = layout
		l.remove(id)
		l.setRoot(l.root(r)?.appending(id, along: r.axis) ?? .panel(id), r)
		layout = l
		if wasFloating {
			closeFloating?(id)
		}
	}

	/// Docks the panel above, below, left or right of another, splitting
	/// that panel's pane.
	func move(_ id: PanelID, to edge: DockEdge, of other: PanelID) {
		guard id != other, layout.region(of: other) != nil else { return }
		let wasFloating = isFloating(id)
		var l = layout
		l.remove(id)
		guard let r = l.region(of: other), let root = l.root(r) else { return }
		l.setRoot(root.inserting(id, at: edge, of: other), r)
		layout = l
		if wasFloating {
			closeFloating?(id)
		}
	}

	/// Stacks the panel as a tab with another (or its tab stack), showing it.
	func tab(_ id: PanelID, with other: PanelID) {
		guard id != other, layout.region(of: other) != nil else { return }
		let wasFloating = isFloating(id)
		var l = layout
		l.remove(id)
		guard let r = l.region(of: other), let root = l.root(r) else { return }
		l.setRoot(root.tabbing(id, with: other), r)
		layout = l
		if wasFloating {
			closeFloating?(id)
		}
	}

	/// Shows a tab of a stack.
	func select(_ id: PanelID) {
		guard let r = layout.region(of: id), let root = layout.root(r) else { return }
		let new = root.selecting(id)
		if new != root {
			layout.setRoot(new, r)
		}
	}

	func float(_ id: PanelID) {
		guard !isFloating(id) else { return }
		var l = layout
		l.remove(id)
		l.floating.append(id)
		l.lastFloating.removeAll { $0 == id }
		layout = l
		openFloating?(id)
	}

	/// A floating panel's window closed: the panel is hidden.
	func floatingClosed(_ id: PanelID) {
		if isFloating(id) {
			var l = layout
			l.floating.removeAll { $0 == id }
			if !l.lastFloating.contains(id) { l.lastFloating.append(id) }	// it floats again when shown
			layout = l
		}
	}

	/// A panel window appeared (perhaps restored by macOS from an earlier
	/// launch): it's floating, unless the panel is docked, in which case the
	/// caller closes it.
	func floatingAppeared(_ id: PanelID) -> Bool {
		if isDocked(id) { return false }
		if !isFloating(id) { layout.floating.append(id) }
		return true
	}

	/// Window > Show All Panels: every hidden panel goes to its region.
	func showAll() {
		for id in PanelID.allCases where !isShown(id) {
			setShown(id, true)	// docked, or floating as it was (Modulation floats)
		}
	}

	/// Forgets the split views' saved divider positions, so they arrange
	/// afresh (by SplitShares)
	func forgetSplitPositions() {
		let defaults = UserDefaults.standard
		for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.splitPrefix) {
			defaults.removeObject(forKey: key)
		}
	}

	/// Window > Reset Layout: the standard arrangement and divider positions,
	/// exactly as a new install shows them (MIDI Mapping hidden; the View
	/// menu shows it).
	func reset() {
		for id in layout.floating {
			closeFloating?(id)
		}
		forgetSplitPositions()
		SplitShares.current = Layout.standardSplits
		var l = Layout.standard
		l.detached = layout.detached
		layout = l
	}
}
