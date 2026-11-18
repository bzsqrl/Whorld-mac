// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyleft 2025 Chris Korda (original Whorld); port Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// The workspace: the main window as one container, after Windows Whorld's
// CMainFrame, whose dockable bars sit around the render view. The output is
// in the middle; the panels are in a left, a right and a bottom region, each
// an arrangement of split views (DockNode) whose dividers can be dragged. A
// panel moves by dragging its title bar onto another panel (near an edge it
// goes above, below, left or right of it, splitting that panel's pane; on
// the title bar or in the middle it joins that panel's tabs, as Windows'
// docking bars stack) or near an edge of the output (it joins that region),
// or with its menu; it can also float as a window of its own. View > Detach (CWhorldApp::SetDetached)
// moves the output to a window of its own, for a projector; the panels then
// fill the workspace. The arrangement and the divider positions persist.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Layout

/// The panels (MainDockBarDef.h's bars, as the Mac port has them).
enum PanelID: String, CaseIterable, Codable, Identifiable {
	// in the View menu's order, which numbers their keys (the user's
	// order, 2026-11-18); layouts store the raw values, not the order
	case params, master, globals, properties, playlist
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
		}
	}

	/// What the panel controls, in brief: the tip on its title (the user's
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
			"Hold a key with the pointer over the picture and scroll (two fingers up or down, or the mouse wheel) to move its control; up increases."
		}
	}

	/// Option-Command plus the panel's place in the View menu (1 to 8)
	/// shows or hides it (the user's request, 2026-11-18: one run of keys
	/// to remember, instead of a letter each with Shift-Command, where a
	/// wrong letter did something else; Shift-Command-3, 4 and 5 are
	/// macOS's screenshots, so Option-Command)
	var shortcut: KeyEquivalent {
		let n = Self.allCases.firstIndex(of: self)! + 1
		return KeyEquivalent(Character(String(n)))
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
		case .properties, .playlist: .left
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
	var scrollsItself: Bool { self == .playlist || self == .mapping || self == .modulation || self == .keymap }

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

	/// With `id` as a tab beside `target`, showing.
	func tabbing(_ id: PanelID, with target: PanelID) -> DockNode {
		switch self {
		case .panel(let p):
			return p == target ? .tabs([p, id], selected: id) : self
		case .tabs(let ids, _):
			return ids.contains(target) ? .tabs(ids + [id], selected: id) : self
		case .split(let axis, let kids):
			return .split(axis, kids.map { $0.tabbing(id, with: target) })
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

	enum CodingKeys: String, CodingKey { case left, right, bottom, floating, detached, lastRegion, lastFloating }

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
		if let r = region(of: id) {
			lastRegion[id] = r
			setRoot(root(r)?.removing(id), r)
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
				move(id, to: layout.lastRegion[id] ?? id.defaultRegion)
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

// MARK: Split views

/// An NSSplitView of SwiftUI views, keyed by string. Divider positions are
/// saved under the autosave name; a new arrangement gets the initial sizes.
struct SplitView: NSViewRepresentable {
	let vertical: Bool	// panes side by side
	let items: [String]
	let autosave: String
	/// a pane's starting size along the split, or nil to share what's left
	var initialSize: (String) -> CGFloat? = { _ in nil }
	/// the pane that grows when the window does
	var flexible: String? = nil
	/// changing it puts the panes back to their starting sizes
	var arrangeGeneration = 0
	let content: (String) -> AnyView

	final class Coordinator: NSObject, NSSplitViewDelegate {
		var hosts: [String: NSHostingView<AnyView>] = [:]
		var items: [String] = []
		var autosave = ""
		var arrangeGeneration = 0
		var parent: SplitView
		static let minPane: CGFloat = 120

		init(_ parent: SplitView) { self.parent = parent }

		func splitView(_ s: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
			let v = s.arrangedSubviews[i]
			return max(proposed, (s.isVertical ? v.frame.minX : v.frame.minY) + Self.minPane)
		}

		func splitView(_ s: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
			guard i + 1 < s.arrangedSubviews.count else { return proposed }
			let v = s.arrangedSubviews[i + 1]
			return min(proposed, (s.isVertical ? v.frame.maxX : v.frame.maxY) - Self.minPane - s.dividerThickness)
		}
	}

	/// Applies the initial sizes at the first layout with a real size, and
	/// redraws after each layout: NSSplitView repaints only around its
	/// current dividers, so where a divider used to be (after a pane was
	/// added, removed or moved) its line would stay behind.
	final class DockSplitView: NSSplitView {
		var pendingInitial: (() -> Bool)?

		override func layout() {
			super.layout()
			if let apply = pendingInitial, bounds.width > 0, bounds.height > 0, apply() {
				pendingInitial = nil
			}
			needsDisplay = true
		}

		/// Redraws and lays out the whole window, once, at the next turn of the run loop.
		/// After panes are added, removed or moved, AppKit doesn't always
		/// repaint everywhere they were: a line where a divider or a pane's
		/// edge used to be can stay on screen until something else redraws it.
		func redisplayWindowSoon() {
			DispatchQueue.main.async { [weak self] in
				guard let root = self?.window?.contentView else { return }
				// and lays it out: a table's rows keep what they drew (a
				// line where a pane's edge was) until their next layout
				func mark(_ v: NSView) {
					v.needsLayout = true
					v.needsDisplay = true
					v.layer?.setNeedsDisplay()
					v.subviews.forEach(mark)
				}
				mark(root)
			}
		}
	}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	/// A split view takes the size it's offered. Without this, SwiftUI asks
	/// AppKit for its fitting size, which builds a temporary constraint
	/// engine over every panel inside, at each layout of the window (ten a
	/// second while a movie plays, for the movie bar).
	func sizeThatFits(_ proposal: ProposedViewSize, nsView: DockSplitView, context: Context) -> CGSize? {
		proposal.replacingUnspecifiedDimensions(by: CGSize(width: 480, height: 320))
	}

	func makeNSView(context: Context) -> DockSplitView {
		let s = DockSplitView()
		s.isVertical = vertical
		s.dividerStyle = .thin
		s.delegate = context.coordinator
		rebuild(s, context.coordinator)
		return s
	}

	func updateNSView(_ s: DockSplitView, context: Context) {
		let c = context.coordinator
		c.parent = self
		if c.items != items || c.autosave != autosave || s.isVertical != vertical {
			rebuild(s, c)
		} else {
			for id in items {
				c.hosts[id]?.rootView = content(id)
			}
			if c.arrangeGeneration != arrangeGeneration {
				arrange(s)
			}
		}
		c.arrangeGeneration = arrangeGeneration
	}

	private func rebuild(_ s: DockSplitView, _ c: Coordinator) {
		s.autosaveName = nil
		s.isVertical = vertical	// SwiftUI may hand back the view a split the other way had
		for v in s.arrangedSubviews {
			s.removeArrangedSubview(v)
			v.removeFromSuperview()
		}
		for (i, id) in items.enumerated() {
			let host = c.hosts[id] ?? NSHostingView(rootView: content(id))
			host.rootView = content(id)
			host.sizingOptions = []	// the split view sizes the pane, not its content
			c.hosts[id] = host
			s.addArrangedSubview(host)
			s.setHoldingPriority(id == flexible ? .defaultLow : NSLayoutConstraint.Priority(260), forSubviewAt: i)
		}
		c.hosts = c.hosts.filter { items.contains($0.key) }
		c.items = items
		c.autosave = autosave
		s.redisplayWindowSoon()
		let saved = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames " + autosave) != nil
		if saved {
			s.autosaveName = autosave	// restores the saved positions
			return
		}
		arrange(s)
	}

	/// Starting sizes, at the next layout (and saved).
	/// Puts the dividers at these positions. A divider only trades space
	/// between its two panes, so one beside a pane with none yet (a pane
	/// just added) can't move far: last to first, then first to last,
	/// each finds room.
	private static func place(_ s: NSSplitView, _ at: [CGFloat]) {
		for i in at.indices.reversed() { s.setPosition(at[i], ofDividerAt: i) }
		for i in at.indices { s.setPosition(at[i], ofDividerAt: i) }
	}

	private func arrange(_ s: DockSplitView) {
		let name = autosave, ids = items, initial = initialSize, isVertical = vertical
		let shares = SplitShares.current[name]
		s.pendingInitial = { [weak s] in
			guard let s else { return true }
			let total = isVertical ? s.bounds.width : s.bounds.height
			let t = s.dividerThickness
			if let shares, shares.count == ids.count, ids.count > 1 {	// a saved layout's proportions
				let room = total - t * CGFloat(ids.count - 1)
				let sum = max(shares.reduce(0, +), 1e-9)
				var pos: CGFloat = 0, at: [CGFloat] = []
				for i in 0..<(ids.count - 1) {
					pos += room * CGFloat(shares[i] / sum)
					at.append(pos)
					pos += t
				}
				Self.place(s, at)
				s.autosaveName = name
				s.redisplayWindowSoon()
				return true
			}
			var fixed = ids.map(initial)
			var nFlex = fixed.filter { $0 == nil }.count
			let room = total - t * CGFloat(max(ids.count - 1, 0))
			// the forms' sizes don't leave the rest room (a pane spanning a
			// small region, say): all share it alike
			if fixed.compactMap({ $0 }).reduce(0, +) + CGFloat(nFlex) * Coordinator.minPane > room {
				fixed = ids.map { _ in nil }
				nFlex = ids.count
			}
			let used = fixed.compactMap { $0 }.reduce(0, +) + t * CGFloat(max(ids.count - 1, 0))
			let flex = nFlex > 0 ? max((total - used) / CGFloat(nFlex), Coordinator.minPane) : 0
			var pos: CGFloat = 0, at: [CGFloat] = []
			for i in 0..<max(ids.count - 1, 0) {
				pos += fixed[i] ?? flex
				at.append(pos)
				pos += t
			}
			Self.place(s, at)
			s.autosaveName = name
			s.redisplayWindowSoon()
			return true
		}
		s.needsLayout = true
	}
}

// MARK: Panels

/// A panel's content, as a docked pane or a floating window shows it.
struct PanelBody: View {
	let id: PanelID

	var body: some View {
		switch id {
		case .params: ParamsPanel()
		case .master: MasterPanel()
		case .globals: GlobalsPanel()
		case .properties: PropertiesPanel()
		case .playlist: PlaylistPanel()
		case .mapping: MappingPanel()
		case .modulation: ModulationView()
		case .keymap: KeyMapView()
		}
	}
}

extension UTType {
	/// A panel being dragged by its title bar. A type of its own, not plain
	/// text: a text field or table under the pointer would take text itself,
	/// so the drop never reached the panel.
	static let whorldPanel = UTType(exportedAs: "io.github.bzsqrl.whorld.panel")
}

/// A form panel in its pane or window: as wide as the pane, so its sliders
/// stretch to fill it (as a table's columns do), down to the form's
/// narrowest width, below which it scrolls sideways; rows keep their height
/// from the top and scroll if the pane is shorter.
struct FormScroller: View {
	let id: PanelID

	var body: some View {
		GeometryReader { g in
			ScrollView([.horizontal, .vertical]) {
				PanelBody(id: id)
					.frame(width: max(g.size.width, id.formMinWidth), alignment: .topLeading)
					.frame(minHeight: g.size.height, alignment: .top)
			}
		}
	}
}

private func loadPanel(_ providers: [NSItemProvider], _ done: @escaping @MainActor (PanelID) -> Void) -> Bool {
	let type = UTType.whorldPanel.identifier
	guard let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type) }) else { return false }
	_ = p.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
		guard let data, let id = PanelID(rawValue: String(decoding: data, as: UTF8.self)) else { return }
		Task { @MainActor in done(id) }
	}
	return true
}

/// Where a panel being dragged over a pane would go: beside it (above,
/// below, left or right) or into its tabs.
enum DropSpot: Equatable {
	case edge(DockEdge)
	case tab
}

/// Where a panel dragged over the Whorld window would go: a pane's spot,
/// a region beside the output, or along one side of a whole region, as
/// long as it (a span: across all the bottom's panes, say; 2026-11-18).
enum DragTarget: Equatable {
	case pane(PanelID, DropSpot)
	case region(Region)
	case span(Region, DockEdge)
}

/// A span shown while a title bar is dragged (the drop delegate whose it
/// is, so another's leaving doesn't clear it)
struct SpanHover: Equatable {
	let owner: String	// a pane's panel, or "output"
	let region: Region
	let edge: DockEdge
}

/// A docked pane: one panel, or a stack of tabs showing one of them, under
/// a slim title bar (the tabs, when stacked) to drag it by, with its menu.
/// The panel scrolls if its pane is smaller than it is.
struct DockedPanel: View {
	let tabs: [PanelID]	// the panels in this pane; one unless stacked
	let id: PanelID	// the one showing
	let region: Region
	@ObservedObject var layout: LayoutModel
	@State private var spot: DropSpot? = nil	// where a panel dropped now would go

	static let headerHeight: CGFloat = 24

	var body: some View {
		GeometryReader { g in
			chrome
				.onDrop(of: [.whorldPanel], delegate: PanelDropDelegate(id: id, size: g.size,
					layout: layout, spot: $spot))
		}
		.background(DockFrameProbe { [layout, id] v in layout.paneViews[id] = .init(v) }
			.id(id))	// (a different tab showing: its own probe; a weak reference, gone with its view)
	}

	/// a floating panel's window dragged over this pane, or a panel's title bar
	private var shownSpot: DropSpot? {
		if let spot { return spot }
		if case .pane(let p, let s)? = layout.windowDragHover, p == id { return s }
		return nil
	}

	private var chrome: some View {
		VStack(spacing: 0) {
			HStack(spacing: 6) {
				Image(systemName: "line.3.horizontal")
					.foregroundStyle(.tertiary)
					.overlay(PanelDragSource(id: id, layout: layout, help: "Drag to move \(id.title); let go away from a dock spot to float it"))	// the grip keeps how to move it
				if tabs.count > 1 {
					tabStrip
					Spacer(minLength: 0)
				} else {
					HStack(spacing: 0) {	// the title and the space after it: drag to move
						Text(id.title)
							.font(.caption.weight(.semibold))
						Spacer(minLength: 0)
					}
					.overlay(PanelDragSource(id: id, layout: layout, help: id.summary))	// what it controls
				}
				Menu {
					ForEach(Region.allCases, id: \.self) { r in
						Button("Move to \(r.title)") { layout.move(id, to: r) }
							.disabled(r == region && tabs.count == 1)
					}
					Button("Float in a Window") { layout.float(id) }
					Divider()
					Button("Hide") { layout.hide(id) }
				} label: {
					Image(systemName: "ellipsis.circle")
				}
				.menuStyle(.borderlessButton)
				.menuIndicator(.hidden)
				.fixedSize()
				.help("\(id.title): move, float or hide")
				Button { layout.hide(id) } label: {
					Image(systemName: "xmark").font(.caption2)
				}
				.buttonStyle(.borderless)
				.help("Hide \(id.title)")
			}
			.padding(.horizontal, 8)
			.frame(height: Self.headerHeight)
			.background(.bar)
			Divider()
			content
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
				.id(id)	// a different tab is a different panel
		}
		.background(Color(nsColor: .windowBackgroundColor))	// opaque over the split view
		.overlay { dropHighlight }
	}

	/// The stacked panels' tabs: click one to show it, drag one to move it.
	private var tabStrip: some View {
		HStack(spacing: 2) {
			ForEach(tabs, id: \.self) { t in
				Text(t.title)
					.font(.caption.weight(t == id ? .semibold : .regular))
					.foregroundStyle(t == id ? .primary : .secondary)
					.lineLimit(1)
					.padding(.horizontal, 7)
					.frame(height: 19)
					.background(t == id ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
						in: RoundedRectangle(cornerRadius: 4))
					.overlay(PanelDragSource(id: t, layout: layout, help: t == id ? t.summary : "Show \(t.title)",
						onClick: { layout.select(t) }))
			}
		}
	}

	/// What a drop now would do: the half of the pane a panel beside it
	/// would take, or the whole pane outlined for a new tab.
	@ViewBuilder private var dropHighlight: some View {
		switch shownSpot {
		case .edge(let e)?:
			GeometryReader { g in
				let rowAxis = e.axis == .row
				ZStack(alignment: e.alignment) {
					Rectangle().fill(Color.accentColor.opacity(0.18))
					Rectangle().fill(Color.accentColor)
						.frame(width: rowAxis ? 3 : nil, height: rowAxis ? nil : 3)
				}
				.frame(width: rowAxis ? g.size.width / 2 : g.size.width, height: rowAxis ? g.size.height : g.size.height / 2)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: e.alignment)
			}
			.allowsHitTesting(false)
		case .tab?:
			ZStack(alignment: .top) {
				Rectangle().fill(Color.accentColor.opacity(0.12))
				Rectangle().fill(Color.accentColor.opacity(0.35)).frame(height: Self.headerHeight)
			}
			.overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
			.allowsHitTesting(false)
		case nil:
			EmptyView()
		}
	}

	@ViewBuilder private var content: some View {
		if id.scrollsItself {	// a table: fills the pane and scrolls itself, sideways too if narrower
			PanelBody(id: id)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
		} else {
			FormScroller(id: id)
		}
	}
}

/// Dropping a panel's title bar (or tab) on a pane: on its title bar or in
/// its middle, the panel joins the pane's tabs; nearer an edge, it goes on
/// that side (above, below, left or right).
struct PanelDropDelegate: DropDelegate {
	let id: PanelID
	let size: CGSize
	let layout: LayoutModel
	@Binding var spot: DropSpot?

	private func spot(at p: CGPoint) -> DropSpot { Self.spot(at: p, size: size) }

	/// (also for a floating panel's window dragged over the pane: LayoutModel.dragTarget)
	static func spot(at p: CGPoint, size: CGSize) -> DropSpot {
		if p.y <= DockedPanel.headerHeight { return .tab }
		let w = max(size.width, 1), h = max(size.height, 1)
		// distances to each edge as a fraction of the pane, so a wide pane
		// doesn't favour top and bottom
		let d: [(DockEdge, CGFloat)] = [(.top, p.y / h), (.bottom, (h - p.y) / h),
			(.leading, p.x / w), (.trailing, (w - p.x) / w)]
		let nearest = d.min { $0.1 < $1.1 }!
		return nearest.1 > 0.3 ? .tab : .edge(nearest.0)	// the middle of the pane: a tab
	}

	func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.whorldPanel]) }

	func dropUpdated(info: DropInfo) -> DropProposal? {
		let span = layout.span(onPane: id, at: info.location, size: size)
		layout.showSpan(span, owner: id.rawValue)
		// over its own pane: no highlight, and let go there it stays put
		spot = span != nil || layout.draggedPanel == id ? nil : spot(at: info.location)
		return DropProposal(operation: .move)
	}

	func dropExited(info: DropInfo) {
		spot = nil
		layout.showSpan(nil, owner: id.rawValue)
	}

	func performDrop(info: DropInfo) -> Bool {
		let span = layout.span(onPane: id, at: info.location, size: size)
		let s = spot(at: info.location)
		spot = nil
		layout.showSpan(nil, owner: id.rawValue)
		let target = id, layout = layout
		return loadPanel(info.itemProviders(for: [.whorldPanel])) { dragged in
			if let span { layout.dock(dragged, at: span); return }
			switch s {
			case .tab: layout.tab(dragged, with: target)
			case .edge(let e): layout.move(dragged, to: e, of: target)
			}
		}
	}
}

/// A floating panel: Window > the panel's own window (the Window scenes).
struct FloatingPanel: View {
	let id: PanelID
	@EnvironmentObject private var model: AppModel
	@Environment(\.dismissWindow) private var dismissWindow

	var body: some View {
		Group {
			if id.scrollsItself {
				PanelBody(id: id)
			} else {
				FormScroller(id: id)
			}
		}
			.frame(minWidth: id.floatingMinSize.width, minHeight: id.floatingMinSize.height)
			.toolbar {
				ToolbarItem {
					Button("Dock") { model.layout.move(id, to: model.layout.layout.lastRegion[id] ?? id.defaultRegion) }
						.help("Dock \(id.title) in the Whorld window")
				}
			}
			.background(FloatingWindowHelper(id: id, layout: model.layout))
			.onAppear {
				if !model.layout.floatingAppeared(id) {
					dismissWindow(id: id.rawValue)	// it's docked: macOS restored a stale window
				}
			}
			.onDisappear { model.layout.floatingClosed(id) }
	}
}

// MARK: Dragging panels in and out (2026-11-18)

/// Registers a view filling its SwiftUI view's place (a pane, the output),
/// whose frame the docking drag asks for (LayoutModel.dragTarget).
struct DockFrameProbe: NSViewRepresentable {
	let report: (NSView) -> Void

	final class Probe: NSView {
		override func hitTest(_ point: NSPoint) -> NSView? { nil }	// never in the way
	}

	func makeNSView(context: Context) -> Probe {
		let p = Probe()
		report(p)
		return p
	}

	func updateNSView(_ p: Probe, context: Context) {
		report(p)
	}

}

/// A docked panel's title bar (or tab), as an AppKit drag source: dragged
/// onto a pane or the output's edge, the drop delegates move it; let go
/// anywhere else (in the Whorld window too), it floats there. A click is `onClick` (a tab
/// shows). Its tip is `help`.
struct PanelDragSource: NSViewRepresentable {
	let id: PanelID
	let layout: LayoutModel
	let help: String
	var onClick: (() -> Void)? = nil

	final class Source: NSView, NSDraggingSource {
		var id: PanelID = .params
		weak var layout: LayoutModel?
		var onClick: (() -> Void)?
		private var down: NSEvent?
		private var dragging = false

		override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }	// drag from a floating panel's window, too

		override func mouseDown(with event: NSEvent) {
			down = event
			dragging = false
		}

		override func mouseDragged(with event: NSEvent) {
			guard let down, !dragging else { return }
			let a = down.locationInWindow, b = event.locationInWindow
			guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
			dragging = true
			let item = NSPasteboardItem()
			item.setString(id.rawValue, forType: NSPasteboard.PasteboardType(UTType.whorldPanel.identifier))
			let drag = NSDraggingItem(pasteboardWriter: item)
			let image = Self.image(id.title)
			let at = convert(down.locationInWindow, from: nil)
			drag.setDraggingFrame(NSRect(x: at.x - 12, y: at.y - image.size.height / 2,
				width: image.size.width, height: image.size.height), contents: image)
			let session = beginDraggingSession(with: [drag], event: down, source: self)
			session.animatesToStartingPositionsOnCancelOrFail = false	// it floats where let go
			layout?.draggedPanel = id
		}

		override func mouseUp(with event: NSEvent) {
			if !dragging { onClick?() }
			down = nil
			dragging = false
		}

		func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
			.move
		}

		func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
			dragging = false
			down = nil
			layout?.draggedPanel = nil
			// let go anywhere but a dock spot (its own pane, a pane or the
			// output's edge, whose drop delegates take it): it floats there,
			// in the Whorld window too (the user's request, 2026-11-18)
			guard operation.isEmpty, let layout else { return }
			let id = self.id
			DispatchQueue.main.async { layout.float(id, at: screenPoint) }
		}

		/// the title in a rounded tag, under the pointer while dragging
		static func image(_ title: String) -> NSImage {
			let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
				.foregroundColor: NSColor.labelColor]
			let text = NSAttributedString(string: title, attributes: attrs)
			let size = NSSize(width: ceil(text.size().width) + 20, height: 22)
			return NSImage(size: size, flipped: false) { r in
				NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
				NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).fill()
				text.draw(at: NSPoint(x: 10, y: (r.height - text.size().height) / 2))
				return true
			}
		}
	}

	func makeNSView(context: Context) -> Source { Source() }

	func updateNSView(_ v: Source, context: Context) {
		v.id = id
		v.layout = layout
		v.onClick = onClick
		v.toolTip = help
	}
}

/// A floating panel's window: above the Whorld windows while Whorld is the
/// active app (a palette; with another app active, an ordinary window, so it
/// doesn't cover that app), placed where a panel dragged out was let go, and
/// dragged by its title bar over the Whorld window, docked where let go (the
/// pane or the output's edge highlights, as when dragging a title bar).
struct FloatingWindowHelper: NSViewRepresentable {
	let id: PanelID
	let layout: LayoutModel

	final class Helper: NSView {
		var id: PanelID = .params
		weak var layout: LayoutModel?
		private var observers: [NSObjectProtocol] = []
		private var timer: Timer?

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			observers.forEach(NotificationCenter.default.removeObserver)
			observers = []
			guard let w = window else { stopTracking(); return }
			let nc = NotificationCenter.default
			setLevel()
			for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
				observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
					MainActor.assumeIsolated { self?.setLevel() }
				})
			}
			observers.append(nc.addObserver(forName: NSWindow.willMoveNotification, object: w, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.startTracking() }
			})
			if let p = layout?.pendingFloatOrigin.removeValue(forKey: id) {
				DispatchQueue.main.async { [weak w] in	// after SwiftUI has sized it
					guard let w else { return }
					var f = w.frame
					f.origin = NSPoint(x: p.x - 40, y: p.y - f.height + 10)	// its title bar under the pointer
					if let area = (NSScreen.screens.first { $0.frame.contains(p) } ?? w.screen)?.visibleFrame {
						f.origin.x = min(max(f.origin.x, area.minX), area.maxX - f.width)
						f.origin.y = min(max(f.origin.y, area.minY), area.maxY - f.height)
					}
					w.setFrame(f, display: true)
				}
			}
		}

		private func setLevel() {
			window?.level = NSApp.isActive ? .floating : .normal
		}

		/// while its title bar is held: where letting go would dock it
		private func startTracking() {
			guard timer == nil else { return }
			timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
				MainActor.assumeIsolated { self?.track() }
			}
		}

		private func stopTracking() {
			timer?.invalidate()
			timer = nil
			window?.alphaValue = 1
			if layout?.windowDragHover != nil { layout?.windowDragHover = nil }
		}

		private func track() {
			guard let layout, let w = window else { stopTracking(); return }
			let target = hoverTarget()
			if NSEvent.pressedMouseButtons & 1 == 0 {	// let go
				stopTracking()
				if let target {
					let id = self.id
					DispatchQueue.main.async { layout.dock(id, at: target) }
				}
				return
			}
			if layout.windowDragHover != target { layout.windowDragHover = target }
			w.alphaValue = target == nil ? 1 : 0.6	// see the highlight through it
		}

		private func hoverTarget() -> DragTarget? {
			guard let layout, let main = AppModel.shared.mainWindow, main.isVisible, !main.isMiniaturized else { return nil }
			let p = NSEvent.mouseLocation
			guard main.frame.contains(p) else { return nil }
			return layout.dragTarget(at: main.convertPoint(fromScreen: p), dragging: id, in: main)
		}
	}

	func makeNSView(context: Context) -> Helper { Helper() }

	func updateNSView(_ v: Helper, context: Context) {
		v.id = id
		v.layout = layout
	}
}

// MARK: Workspace

struct WorkspaceView: View {
	@EnvironmentObject private var model: AppModel
	@ObservedObject var layout: LayoutModel
	@Environment(\.openWindow) private var openWindow
	@Environment(\.dismissWindow) private var dismissWindow

	var body: some View {
		let l = layout.layout
		let top = (l.left == nil ? [] : ["left"]) + (l.detached ? [] : ["center"]) + (l.right == nil ? [] : ["right"])
		let rows = (top.isEmpty ? [] : ["top"]) + (l.bottom == nil ? [] : ["bottom"])
		Group {
			if rows.isEmpty {
				VStack(spacing: 8) {
					Text("The output is in its own window.")
					Text("Show panels from the View menu, or choose View > Detach to bring the output back.")
						.foregroundStyle(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				SplitView(vertical: false, items: rows, autosave: "Whorld.V." + rows.joined(separator: "|"),
					initialSize: { $0 == "bottom" && rows.count > 1 ? 300 : nil },
					flexible: "top", arrangeGeneration: layout.arrangeGeneration) { id in
					id == "top" ? AnyView(topRow(top)) : AnyView(region(.bottom))
				}
			}
		}
		.frame(minWidth: 480, minHeight: 320)
		.onAppear {
			layout.openFloating = { openWindow(id: $0.rawValue) }
			layout.closeFloating = { dismissWindow(id: $0.rawValue) }
			for id in layout.layout.floating {
				openWindow(id: id.rawValue)
			}
		}
	}

	private func topRow(_ top: [String]) -> some View {
		SplitView(vertical: true, items: top, autosave: "Whorld.H." + top.joined(separator: "|"),
			initialSize: { $0 == "left" ? 360 : $0 == "right" ? 440 : nil },
			flexible: top.contains("center") ? "center" : nil, arrangeGeneration: layout.arrangeGeneration) { id in
			switch id {
			case "left": AnyView(region(.left))
			case "right": AnyView(region(.right))
			default: AnyView(OutputArea(layout: layout).environmentObject(model))
			}
		}
	}

	private func region(_ r: Region) -> some View {
		node(layout.layout.root(r), region: r)
			.overlay { spanHighlight(r) }
			.background(DockFrameProbe { [layout] v in layout.regionViews[r] = .init(v) })
	}

	/// A span a drop now would make: a band along that side of the whole
	/// region, as a pane edge's highlight is along the pane's.
	@ViewBuilder private func spanHighlight(_ r: Region) -> some View {
		if let e = layout.spanShown(on: r) {
			GeometryReader { g in
				let rowAxis = e.axis == .row
				ZStack(alignment: e.alignment) {
					Rectangle().fill(Color.accentColor.opacity(0.22))
					Rectangle().fill(Color.accentColor)
						.frame(width: rowAxis ? 4 : nil, height: rowAxis ? nil : 4)
				}
				.frame(width: rowAxis ? min(g.size.width / 3, 320) : g.size.width,
					height: rowAxis ? g.size.height : min(g.size.height / 3, 200))
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: e.alignment)
			}
			.allowsHitTesting(false)
		}
	}

	/// A region's arrangement, drawn as split views inside split views.
	private func node(_ n: DockNode?, region r: Region) -> AnyView {
		switch n {
		case nil:
			return AnyView(Color.clear)
		case .panel(let id)?:
			return AnyView(DockedPanel(tabs: [id], id: id, region: r, layout: layout).environmentObject(model))
		case .tabs(let ids, let sel)?:
			return AnyView(DockedPanel(tabs: ids, id: sel, region: r, layout: layout).environmentObject(model))
		case .split(let axis, let kids)?:
			// the forms start whole (their preferred size along the split) and
			// the rest share what's left, unless every pane is a form
			let lengths = kids.map { k -> CGFloat? in
				if case .panel(let id) = k { return id.preferredLength(along: axis) }
				return nil
			}
			let sizedAll = lengths.allSatisfy { $0 != nil }
			let size = Dictionary(uniqueKeysWithValues: zip(kids.map(\.key), lengths))
			return AnyView(SplitView(vertical: axis == .row, items: kids.map(\.key),
				autosave: "Whorld.\(r.rawValue).\(n!.key)",
				initialSize: { key in sizedAll ? nil : size[key] ?? nil },
				flexible: kids.first { k in size[k.key] ?? nil == nil }?.key,
				arrangeGeneration: layout.arrangeGeneration) { key in
				node(kids.first { $0.key == key }, region: r)
			})
		}
	}
}

/// The output in the workspace, which also takes dropped panels: near its
/// left, right or bottom edge sends one to that region.
struct OutputArea: View {
	@EnvironmentObject private var model: AppModel
	@ObservedObject var layout: LayoutModel
	@State private var target: Region? = nil

	var body: some View {
		GeometryReader { g in
			OutputView(panelDrop: EdgeDropDelegate(size: g.size, layout: layout, target: $target))
				.overlay {
					if let target = target ?? hoverRegion {
						let w = g.size.width / 4, h = g.size.height / 4
						Rectangle().fill(Color.accentColor.opacity(0.35))
							.frame(width: target == .bottom ? nil : w, height: target == .bottom ? h : nil)
							.frame(maxWidth: .infinity, maxHeight: .infinity,
								alignment: target == .left ? .leading : target == .right ? .trailing : .bottom)
							.allowsHitTesting(false)
					}
				}
		}
		.background(DockFrameProbe { [layout] v in layout.outputView = .init(v) })
	}

	private var hoverRegion: Region? {
		if case .region(let r)? = layout.windowDragHover { return r }
		return nil
	}
}

struct EdgeDropDelegate: DropDelegate {
	let size: CGSize
	let layout: LayoutModel
	@Binding var target: Region?

	static func region(_ p: CGPoint, size: CGSize) -> Region? {
		if p.x < size.width / 4 { return .left }
		if p.x > size.width * 3 / 4 { return .right }
		if p.y > size.height * 3 / 4 { return .bottom }
		return nil
	}

	/// What a drop at a point does: right by an edge the output shares with
	/// a region (within LayoutModel.spanBand), along that region's whole
	/// side (across all the bottom's panes, say); nearer the edge than the
	/// middle, into that region, at its end.
	static func target(_ p: CGPoint, size: CGSize, layout: LayoutModel) -> DragTarget? {
		let b = LayoutModel.spanBand, l = layout.layout
		if p.y > size.height - b, l.bottom != nil { return .span(.bottom, .top) }
		if p.x < b, l.left != nil { return .span(.left, .trailing) }
		if p.x > size.width - b, l.right != nil { return .span(.right, .leading) }
		return region(p, size: size).map { .region($0) }
	}

	private func target(_ p: CGPoint) -> DragTarget? { Self.target(p, size: size, layout: layout) }

	func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.whorldPanel]) }

	func dropUpdated(info: DropInfo) -> DropProposal? {
		let t = self.target(info.location)
		if case .region(let r)? = t { target = r } else { target = nil }
		layout.showSpan(t, owner: "output")
		return DropProposal(operation: t == nil ? .forbidden : .move)
	}

	func dropExited(info: DropInfo) {
		target = nil
		layout.showSpan(nil, owner: "output")
	}

	func performDrop(info: DropInfo) -> Bool {
		target = nil
		layout.showSpan(nil, owner: "output")
		guard let t = self.target(info.location) else { return false }
		let layout = layout
		return loadPanel(info.itemProviders(for: [.whorldPanel])) { id in layout.dock(id, at: t) }
	}
}

// MARK: Detached output

/// View > Detach (CWhorldApp::SetDetached): the output in a window of its
/// own, whose place is remembered (as RK_RENDER_WND is). Closing it docks
/// the output again.
@MainActor
final class OutputWindowController: NSObject, NSWindowDelegate {
	private(set) var window: NSWindow?
	var onClose: (() -> Void)?

	func show(model: AppModel, near frame: NSRect?) {
		guard window == nil else { return }
		let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
			styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
		w.title = "Whorld Output"
		w.isReleasedWhenClosed = false
		w.collectionBehavior.insert(.fullScreenNone)	// Whorld's own full screen
		w.contentView = NSHostingView(rootView: OutputView().environmentObject(model))
		w.delegate = self
		if !w.setFrameUsingName("WhorldOutputWindow") {	// first time: 1024 x 768 over the workspace
			if let frame {
				w.setFrameOrigin(NSPoint(x: frame.midX - 512, y: frame.midY - 384))
			} else {
				w.center()
			}
		}
		w.setFrameAutosaveName("WhorldOutputWindow")
		window = w
		w.makeKeyAndOrderFront(nil)
	}

	func hide() {
		guard let w = window else { return }
		window = nil
		w.delegate = nil
		w.saveFrame(usingName: "WhorldOutputWindow")
		w.orderOut(nil)
		w.contentView = nil
	}

	func windowWillClose(_ notification: Notification) {
		MainActor.assumeIsolated { onClose?() }
	}
}
