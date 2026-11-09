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
// panel moves by dragging its title bar onto another panel (it goes above,
// below, left or right of it, by the nearest edge, splitting that panel's
// pane) or near an edge of the output (it joins that region), or with its
// menu; it can also
// float as a window of its own. Window > Detach (CWhorldApp::SetDetached)
// moves the output to a window of its own, for a projector; the panels then
// fill the workspace. The arrangement and the divider positions persist.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Layout

/// The panels (MainDockBarDef.h's bars, as the Mac port has them).
enum PanelID: String, CaseIterable, Codable, Identifiable {
	case params, master, globals, properties, playlist, mapping

	var id: String { rawValue }

	var title: String {
		switch self {
		case .params: "Parameters"
		case .master: "Master"
		case .globals: "Globals"
		case .properties: "Properties"
		case .playlist: "Playlist"
		case .mapping: "MIDI Mapping"
		}
	}

	/// ⇧⌘ plus this shows or hides the panel
	var shortcut: KeyEquivalent {
		switch self {
		case .params: "p"
		case .master: "m"
		case .globals: "g"
		case .properties: "r"
		case .playlist: "a"
		case .mapping: "i"
		}
	}

	/// After MainDockBarDef.h (Params and Playlist left, Master and Globals
	/// right, Mapping bottom), except that Parameters, a wide table here,
	/// goes along the bottom, and Properties (Windows' Numbers) on the left.
	var defaultRegion: Region {
		switch self {
		case .params, .mapping: .bottom
		case .master, .globals: .right
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
		case (.master, .column): 334
		case (.params, .row): 810
		default: nil
		}
	}

	/// Tables scroll themselves (both ways); the others are forms the
	/// workspace scrolls.
	var scrollsItself: Bool { self == .playlist || self == .mapping }

	/// a floating window's smallest content size
	var floatingMinSize: CGSize {
		switch self {
		case .params: CGSize(width: 800, height: 300)
		case .mapping: CGSize(width: 680, height: 240)
		case .playlist: CGSize(width: 360, height: 200)
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

/// A region's arrangement: one panel, or panes split one above another or
/// side by side, each of which can be split again, so a panel can go above,
/// below, left or right of any other.
indirect enum DockNode: Codable, Equatable {
	case panel(PanelID)
	case split(SplitAxis, [DockNode])

	var panels: [PanelID] {
		switch self {
		case .panel(let id): [id]
		case .split(_, let kids): kids.flatMap(\.panels)
		}
	}

	func contains(_ id: PanelID) -> Bool { panels.contains(id) }

	/// Names the subtree: a split view's pane, and (with the region) where
	/// its divider positions are saved, so each arrangement keeps its own.
	var key: String {
		switch self {
		case .panel(let id): id.rawValue
		case .split(let axis, let kids): "\(axis.rawValue)(" + kids.map(\.key).joined(separator: ",") + ")"
		}
	}

	/// Without the panel; nil if nothing is left.
	func removing(_ id: PanelID) -> DockNode? {
		switch self {
		case .panel(let p): return p == id ? nil : self
		case .split(let axis, let kids): return Self.make(axis, kids.compactMap { $0.removing(id) })
		}
	}

	/// With `id` on the given side of `target` (which must be here).
	func inserting(_ id: PanelID, at edge: DockEdge, of target: PanelID) -> DockNode {
		let new = DockNode.panel(id)
		switch self {
		case .panel(let p):
			guard p == target else { return self }
			return .split(edge.axis, edge.isAfter ? [self, new] : [new, self])
		case .split(let axis, var kids):
			guard let i = kids.firstIndex(where: { $0.contains(target) }) else { return self }
			if axis == edge.axis, kids[i] == .panel(target) {	// a sibling in this split
				kids.insert(new, at: edge.isAfter ? i + 1 : i)
			} else {
				kids[i] = kids[i].inserting(id, at: edge, of: target)
			}
			return Self.make(axis, kids)!
		}
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

	/// what a new install shows; Playlist and MIDI Mapping start hidden
	static let standard = Layout(left: .panel(.properties), right: .split(.column, [.panel(.master), .panel(.globals)]),
		bottom: .panel(.params))

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

	init() {
		let defaults = UserDefaults.standard
		if let data = defaults.data(forKey: Self.key),
			let saved = try? JSONDecoder().decode(Layout.self, from: data) {
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
		if show == isShown(id) { return }
		if show {
			move(id, to: layout.lastRegion[id] ?? id.defaultRegion)
		} else {
			hide(id)
		}
	}

	func hide(_ id: PanelID) {
		let wasFloating = isFloating(id)
		layout.remove(id)
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

	func float(_ id: PanelID) {
		guard !isFloating(id) else { return }
		layout.remove(id)
		layout.floating.append(id)
		openFloating?(id)
	}

	/// A floating panel's window closed: the panel is hidden.
	func floatingClosed(_ id: PanelID) {
		if isFloating(id) {
			layout.floating.removeAll { $0 == id }
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
			move(id, to: layout.lastRegion[id] ?? id.defaultRegion)
		}
	}

	/// Window > Reset Layout: the standard arrangement and divider positions.
	func reset() {
		for id in layout.floating {
			closeFloating?(id)
		}
		let defaults = UserDefaults.standard
		for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.splitPrefix) {
			defaults.removeObject(forKey: key)
		}
		var l = Layout.standard
		l.detached = layout.detached
		layout = l
		showAll()
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
		if c.items != items || c.autosave != autosave {
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
	private func arrange(_ s: DockSplitView) {
		let name = autosave, ids = items, initial = initialSize, isVertical = vertical
		s.pendingInitial = { [weak s] in
			guard let s else { return true }
			let total = isVertical ? s.bounds.width : s.bounds.height
			let t = s.dividerThickness
			let fixed = ids.map(initial)
			let nFlex = fixed.filter { $0 == nil }.count
			let used = fixed.compactMap { $0 }.reduce(0, +) + t * CGFloat(max(ids.count - 1, 0))
			let flex = nFlex > 0 ? max((total - used) / CGFloat(nFlex), Coordinator.minPane) : 0
			var pos: CGFloat = 0
			for i in 0..<max(ids.count - 1, 0) {
				pos += fixed[i] ?? flex
				s.setPosition(pos, ofDividerAt: i)
				pos += t
			}
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
		}
	}
}

extension UTType {
	/// A panel being dragged by its title bar. A type of its own, not plain
	/// text: a text field or table under the pointer would take text itself,
	/// so the drop never reached the panel.
	static let whorldPanel = UTType(exportedAs: "io.github.bzsqrl.whorld.panel")
}

/// The panel's identity for dragging, within Whorld only.
private func panelProvider(_ id: PanelID) -> NSItemProvider {
	let p = NSItemProvider()
	p.registerDataRepresentation(forTypeIdentifier: UTType.whorldPanel.identifier, visibility: .ownProcess) { done in
		done(Data(id.rawValue.utf8), nil)
		return nil
	}
	return p
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

/// A docked panel: a slim title bar to drag it by, with its menu, over the
/// panel, which scrolls if its pane is smaller than it is.
struct DockedPanel: View {
	let id: PanelID
	let region: Region
	@ObservedObject var layout: LayoutModel
	@State private var dropEdge: DockEdge? = nil	// where a panel dropped now would go

	var body: some View {
		GeometryReader { g in
			chrome
				.onDrop(of: [.whorldPanel], delegate: PanelDropDelegate(id: id, size: g.size,
					layout: layout, edge: $dropEdge))
		}
	}

	private var chrome: some View {
		VStack(spacing: 0) {
			HStack(spacing: 6) {
				Image(systemName: "line.3.horizontal")
					.foregroundStyle(.tertiary)
				Text(id.title)
					.font(.caption.weight(.semibold))
				Spacer()
				Menu {
					ForEach(Region.allCases, id: \.self) { r in
						Button("Move to \(r.title)") { layout.move(id, to: r) }
							.disabled(r == region)
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
				Button { layout.hide(id) } label: {
					Image(systemName: "xmark").font(.caption2)
				}
				.buttonStyle(.borderless)
				.help("Hide \(id.title)")
			}
			.padding(.horizontal, 8)
			.frame(height: 24)
			.background(.bar)
			.contentShape(Rectangle())
			.onDrag { panelProvider(id) }
			Divider()
			content
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		}
		.background(Color(nsColor: .windowBackgroundColor))	// opaque over the split view
		.overlay {
			if let e = dropEdge {	// the side the dropped panel will take: a tinted half with a bar on its edge
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
			}
		}
	}

	@ViewBuilder private var content: some View {
		if id.scrollsItself {	// a table: fills the pane and scrolls itself, sideways too if narrower
			PanelBody(id: id)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
		} else {	// a form: top left in a bigger pane, scrolling in a smaller one
			GeometryReader { g in
				ScrollView([.horizontal, .vertical]) {
					PanelBody(id: id)
						.frame(minWidth: g.size.width, minHeight: g.size.height, alignment: .topLeading)
				}
			}
		}
	}
}

/// Dropping a panel's title bar on a panel: it goes on the side of it whose
/// edge the pointer is nearest (above, below, left or right).
private struct PanelDropDelegate: DropDelegate {
	let id: PanelID
	let size: CGSize
	let layout: LayoutModel
	@Binding var edge: DockEdge?

	private func nearestEdge(_ p: CGPoint) -> DockEdge {
		let w = max(size.width, 1), h = max(size.height, 1)
		// distances to each edge as a fraction of the pane, so a wide pane
		// doesn't favour top and bottom
		let d: [(DockEdge, CGFloat)] = [(.top, p.y / h), (.bottom, (h - p.y) / h),
			(.leading, p.x / w), (.trailing, (w - p.x) / w)]
		return d.min { $0.1 < $1.1 }!.0
	}

	func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.whorldPanel]) }

	func dropUpdated(info: DropInfo) -> DropProposal? {
		edge = nearestEdge(info.location)
		return DropProposal(operation: .move)
	}

	func dropExited(info: DropInfo) { edge = nil }

	func performDrop(info: DropInfo) -> Bool {
		let e = nearestEdge(info.location)
		edge = nil
		let target = id, layout = layout
		return loadPanel(info.itemProviders(for: [.whorldPanel])) { dragged in
			layout.move(dragged, to: e, of: target)
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
			} else {	// docked, the workspace scrolls a form
				ScrollView([.horizontal, .vertical]) { PanelBody(id: id) }
			}
		}
			.frame(minWidth: id.floatingMinSize.width, minHeight: id.floatingMinSize.height)
			.toolbar {
				ToolbarItem {
					Button("Dock") { model.layout.move(id, to: model.layout.layout.lastRegion[id] ?? id.defaultRegion) }
						.help("Dock \(id.title) in the Whorld window")
				}
			}
			.onAppear {
				if !model.layout.floatingAppeared(id) {
					dismissWindow(id: id.rawValue)	// it's docked: macOS restored a stale window
				}
			}
			.onDisappear { model.layout.floatingClosed(id) }
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
					Text("Show panels from the View menu, or choose Window > Detach to bring the output back.")
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
	}

	/// A region's arrangement, drawn as split views inside split views.
	private func node(_ n: DockNode?, region r: Region) -> AnyView {
		switch n {
		case nil:
			return AnyView(Color.clear)
		case .panel(let id)?:
			return AnyView(DockedPanel(id: id, region: r, layout: layout).environmentObject(model))
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
			OutputView()
				.overlay {
					if let target {
						let w = g.size.width / 4, h = g.size.height / 4
						Rectangle().fill(Color.accentColor.opacity(0.35))
							.frame(width: target == .bottom ? nil : w, height: target == .bottom ? h : nil)
							.frame(maxWidth: .infinity, maxHeight: .infinity,
								alignment: target == .left ? .leading : target == .right ? .trailing : .bottom)
							.allowsHitTesting(false)
					}
				}
				.onDrop(of: [.whorldPanel], delegate: EdgeDropDelegate(size: g.size, layout: layout, target: $target))
		}
	}
}

private struct EdgeDropDelegate: DropDelegate {
	let size: CGSize
	let layout: LayoutModel
	@Binding var target: Region?

	private func region(_ p: CGPoint) -> Region? {
		if p.x < size.width / 4 { return .left }
		if p.x > size.width * 3 / 4 { return .right }
		if p.y > size.height * 3 / 4 { return .bottom }
		return nil
	}

	func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.whorldPanel]) }

	func dropUpdated(info: DropInfo) -> DropProposal? {
		target = region(info.location)
		return DropProposal(operation: target == nil ? .forbidden : .move)
	}

	func dropExited(info: DropInfo) { target = nil }

	func performDrop(info: DropInfo) -> Bool {
		guard let r = region(info.location) else { target = nil; return false }
		target = nil
		let layout = layout
		return loadPanel(info.itemProviders(for: [.whorldPanel])) { id in layout.move(id, to: r) }
	}
}

// MARK: Detached output

/// Window > Detach (CWhorldApp::SetDetached): the output in a window of its
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
