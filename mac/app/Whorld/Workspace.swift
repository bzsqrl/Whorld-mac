// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyleft 2025 Chris Korda (original Whorld); port Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// The workspace: the main window as one container, after Windows Whorld's
// CMainFrame, whose dockable bars sit around the render view. The output is
// in the middle; the panels are in a left, a right and a bottom region, each
// a split view whose dividers can be dragged. A panel moves by dragging its
// title bar onto another panel (it goes before or after it) or near an edge
// of the output (it goes to that region), or with its menu; it can also
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
	func preferredLength(in region: Region) -> CGFloat? {
		switch (self, region) {
		case (.properties, .left), (.properties, .right): 252
		case (.master, .left), (.master, .right): 334
		case (.params, .bottom): 810
		default: nil
		}
	}

	/// Tables and lists scroll themselves; the others are fixed-size forms.
	var scrollsItself: Bool { self == .params || self == .playlist || self == .mapping }
}

enum Region: String, Codable, CaseIterable {
	case left, right, bottom

	var title: String { rawValue.capitalized }
}

struct Layout: Codable, Equatable {
	var left: [PanelID] = []
	var right: [PanelID] = []
	var bottom: [PanelID] = []
	var floating: [PanelID] = []
	var detached = false
	/// where a hidden or floating panel goes back to
	var lastRegion: [PanelID: Region] = [:]

	/// what a new install shows; Playlist and MIDI Mapping start hidden
	static let standard = Layout(left: [.properties], right: [.master, .globals], bottom: [.params])

	func panels(in r: Region) -> [PanelID] {
		switch r {
		case .left: left
		case .right: right
		case .bottom: bottom
		}
	}

	mutating func setPanels(_ ids: [PanelID], in r: Region) {
		switch r {
		case .left: left = ids
		case .right: right = ids
		case .bottom: bottom = ids
		}
	}

	func region(of id: PanelID) -> Region? {
		Region.allCases.first { panels(in: $0).contains(id) }
	}

	/// takes the panel out of wherever it is
	mutating func remove(_ id: PanelID) {
		if let r = region(of: id) {
			lastRegion[id] = r
			setPanels(panels(in: r).filter { $0 != id }, in: r)
		}
		floating.removeAll { $0 == id }
	}
}

@MainActor
final class LayoutModel: ObservableObject {
	private static let key = "Layout_v1"
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
		if let data = UserDefaults.standard.data(forKey: Self.key),
			let saved = try? JSONDecoder().decode(Layout.self, from: data) {
			layout = saved
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

	/// Docks the panel in a region, before the given panel (or at the end).
	func move(_ id: PanelID, to r: Region, before other: PanelID? = nil) {
		let wasFloating = isFloating(id)
		var l = layout
		l.remove(id)
		var ids = l.panels(in: r)
		if let other, let i = ids.firstIndex(of: other) {
			ids.insert(id, at: i)
		} else {
			ids.append(id)
		}
		l.setPanels(ids, in: r)
		layout = l
		if wasFloating {
			closeFloating?(id)
		}
	}

	/// Docks the panel next to another, before or after it.
	func move(_ id: PanelID, nextTo other: PanelID, after: Bool) {
		guard id != other, let r = layout.region(of: other) else { return }
		let ids = layout.panels(in: r).filter { $0 != id }
		guard let i = ids.firstIndex(of: other) else { return }
		let next = after ? (i + 1 < ids.count ? ids[i + 1] : nil) : other
		move(id, to: r, before: next)
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

/// The panel's identity for dragging, as plain text.
private func panelProvider(_ id: PanelID) -> NSItemProvider {
	NSItemProvider(object: ("whorld-panel:" + id.rawValue) as NSString)
}

private func loadPanel(_ providers: [NSItemProvider], _ done: @escaping @MainActor (PanelID) -> Void) -> Bool {
	guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
	_ = p.loadObject(ofClass: NSString.self) { obj, _ in
		guard let s = obj as? String, s.hasPrefix("whorld-panel:"),
			let id = PanelID(rawValue: String(s.dropFirst("whorld-panel:".count))) else { return }
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
	@State private var dropEdge: Bool? = nil	// true: after, false: before

	var body: some View {
		GeometryReader { g in
			chrome
				.onDrop(of: [.plainText], delegate: PanelDropDelegate(id: id, region: region, size: g.size,
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
		.overlay(alignment: dropEdge == true ? (region == .bottom ? .trailing : .bottom)
			: (region == .bottom ? .leading : .top)) {
			if dropEdge != nil {
				Rectangle().fill(Color.accentColor)
					.frame(width: region == .bottom ? 3 : nil, height: region == .bottom ? nil : 3)
			}
		}
	}

	@ViewBuilder private var content: some View {
		if id.scrollsItself {	// a table or list: as tall as the pane, scrolling sideways if narrower
			GeometryReader { g in
				ScrollView(.horizontal) {
					PanelBody(id: id)
						.frame(height: g.size.height)
				}
			}
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

/// Dropping a panel's title bar on a panel: before it (top or left half) or after it.
private struct PanelDropDelegate: DropDelegate {
	let id: PanelID
	let region: Region
	let size: CGSize
	let layout: LayoutModel
	@Binding var edge: Bool?

	private func after(_ info: DropInfo) -> Bool {
		region == .bottom ? info.location.x > size.width / 2 : info.location.y > size.height / 2
	}

	func dropUpdated(info: DropInfo) -> DropProposal? {
		edge = after(info)
		return DropProposal(operation: .move)
	}

	func dropExited(info: DropInfo) { edge = nil }

	func performDrop(info: DropInfo) -> Bool {
		let isAfter = after(info)
		edge = nil
		let target = id, layout = layout
		return loadPanel(info.itemProviders(for: [.plainText])) { dragged in
			layout.move(dragged, nextTo: target, after: isAfter)
		}
	}
}

/// A floating panel: Window > the panel's own window (the Window scenes).
struct FloatingPanel: View {
	let id: PanelID
	@EnvironmentObject private var model: AppModel
	@Environment(\.dismissWindow) private var dismissWindow

	var body: some View {
		PanelBody(id: id)
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
		let top = (l.left.isEmpty ? [] : ["left"]) + (l.detached ? [] : ["center"]) + (l.right.isEmpty ? [] : ["right"])
		let rows = (top.isEmpty ? [] : ["top"]) + (l.bottom.isEmpty ? [] : ["bottom"])
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
		let ids = layout.layout.panels(in: r)
		// a lone panel fills its region; otherwise the forms start whole
		let sized = ids.count > 1 ? ids.filter { $0.preferredLength(in: r) != nil } : []
		return SplitView(vertical: r == .bottom, items: ids.map(\.rawValue),
			autosave: "Whorld.\(r.rawValue)." + ids.map(\.rawValue).joined(separator: "|"),
			initialSize: { s in
				PanelID(rawValue: s).flatMap { sized.contains($0) && sized.count < ids.count ? $0.preferredLength(in: r) : nil }
			},
			flexible: ids.first { !sized.contains($0) }?.rawValue,
			arrangeGeneration: layout.arrangeGeneration) { s in
			AnyView(DockedPanel(id: PanelID(rawValue: s)!, region: r, layout: layout).environmentObject(model))
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
				.onDrop(of: [.plainText], delegate: EdgeDropDelegate(size: g.size, layout: layout, target: $target))
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

	func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }

	func dropUpdated(info: DropInfo) -> DropProposal? {
		target = region(info.location)
		return DropProposal(operation: target == nil ? .forbidden : .move)
	}

	func dropExited(info: DropInfo) { target = nil }

	func performDrop(info: DropInfo) -> Bool {
		guard let r = region(info.location) else { target = nil; return false }
		target = nil
		let layout = layout
		return loadPanel(info.itemProviders(for: [.plainText])) { id in layout.move(id, to: r) }
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
