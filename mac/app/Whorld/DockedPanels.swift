// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyleft 2025 Chris Korda (original Whorld); port Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// The panels in the workspace (split out of Workspace.swift on 2026-11-22;
// no change in behavior): a docked pane with its title bar and tabs, a
// floating panel's window, the form scroller, and dragging panels in, out
// and between panes.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
		case .patches: PatchBrowserPanel()
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
/// stretch to fill it (as a table's columns do), its columns fitted to the
/// width (FormFit), down to the form's narrowest width, below which it
/// scrolls sideways; rows keep their height from the top and scroll if the
/// pane is shorter. It scrolls sideways only then: a sideways swipe meant
/// for a slider otherwise moved the panel (the user's request, 2026-11-22).
struct FormScroller: View {
	let id: PanelID
	/// Key Map keys in panels (View > Show Key Map in Panels) widen every row
	@AppStorage(KeyBadge.defaultsKey) private var badges = false
	/// System Settings' scroll bars, Always (or Automatic with a mouse): the
	/// vertical scroll bar then takes its width from the pane, and a form as
	/// wide as the pane had its last column under it (found 2026-11-22)
	@State private var legacyScrollers = NSScroller.preferredScrollerStyle == .legacy

	var body: some View {
		let _ = badges
		GeometryReader { g in
			let scroller = legacyScrollers ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
			let width = g.size.width - scroller
			ScrollView(width >= id.formMinWidth ? .vertical : [.horizontal, .vertical]) {
				PanelBody(id: id)
					.environment(\.formWidth, max(width, id.formMinWidth))
					.environment(\.formHeight, g.size.height)
					.frame(width: max(width, id.formMinWidth), alignment: .topLeading)
					.frame(minHeight: g.size.height, alignment: .top)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
			legacyScrollers = NSScroller.preferredScrollerStyle == .legacy
		}
	}
}

func loadPanel(_ providers: [NSItemProvider], _ done: @escaping @MainActor (PanelID) -> Void) -> Bool {
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
	case fullHeight(Region)	// into Left or Right, which becomes the window's whole height
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
	@State private var hovered = false	// the pointer is over it: its header tinted faintly
	@State private var headerAnchor = ViewAnchor()	// for About's popover from the ⋯ menu

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

	private func title(_ s: String) -> some View {
		Text(s)
			.font(.caption.weight(.semibold))
			.lineLimit(1)
			.overlay(PanelDragSource(id: id, layout: layout, help: ""))
	}

	/// an explanation from the ⋯ menu, under the header: once the menu has
	/// closed (its closing would close it), and staying put (the pointer is
	/// on the menu, not the header)
	private func showAbout(_ text: String) {
		DispatchQueue.main.async {
			if let v = headerAnchor.view { InfoPopover.shared.toggle(text, from: v, rect: v.bounds, followPointer: false) }
		}
	}

	private var chrome: some View {
		VStack(spacing: 0) {
			HStack(spacing: 6) {
				Image(systemName: "line.3.horizontal")
					.foregroundStyle(.tertiary)
					.overlay(PanelDragSource(id: id, layout: layout, help: "Drag to move \(id.title); let go away from a dock spot to float it"))	// the grip keeps how to move it
				if tabs.count > 1 {
					tabStrip
					PanelInfoButton(id: id)	// the showing tab's
					Color.clear	// the space after the tabs: drag (or double-click) the showing tab
						.frame(maxWidth: .infinity, maxHeight: .infinity)
						.overlay(PanelDragSource(id: id, layout: layout, help: ""))
				} else {
					HStack(spacing: 0) {	// the title and the space after it: drag to move
						// narrowing, the ⓘ goes first, then the short name;
						// only then does it truncate (the design audit,
						// 2026-11-24: "Pr…" while the ⓘ kept its room)
						ViewThatFits(in: .horizontal) {
							HStack(spacing: 0) {
								title(id.title)
								// what the panel controls: click for it (the user's
								// request, 2026-11-19; it was the title's hover tip)
								PanelInfoButton(id: id)
									.padding(.leading, 4)
							}
							title(id.title)
							title(id.shortTitle)
							title(id.shortTitle).frame(minWidth: 0).truncationMode(.tail)
						}
						.layoutPriority(1)
						Color.clear
							.frame(maxWidth: .infinity, maxHeight: .infinity)
							.overlay(PanelDragSource(id: id, layout: layout, help: ""))
					}
				}
				Menu {
					// ⌥⌘ and the arrows over the panel do these (PanelKeys; back
					// 2026-11-27, the user's choice); All the Way has no keys
					// (⇧⌥⌘↑ ↓ are the cue's first and last)
					ForEach(PanelMoves.all, id: \.title) { m in
						Button("Move " + m.title) { layout.step(id, toward: m.edge, far: false) }
							.keyboardShortcut(m.key, modifiers: [.command, .option])
					}
					Menu("Move All the Way") {
						ForEach(PanelMoves.all, id: \.title) { m in
							Button(m.title) { layout.step(id, toward: m.edge, far: true) }
						}
					}
					Divider()
					ForEach(Region.allCases, id: \.self) { r in
						Button("Move to \(r.title) Area") { layout.move(id, to: r) }
							.disabled(r == region && tabs.count == 1)
					}
					Button("Float in a Window") { layout.float(id) }
					// the side the window's whole height (the user's request, 2026-11-25)
					if region != .bottom {
						Divider()
						Toggle("\(region.title) Full Height", isOn: Binding(
							get: { layout.layout.fullHeight.contains(region) },
							set: { layout.setFullHeight(region, $0) }))
					}
					Divider()
					// the ⓘ's explanation, here too: a narrow header drops the ⓘ
					Button("About \(id.title)…") {
						showAbout(id.summary)
					}
					// the Modulation table's columns (its ⓘ under the table is
					// gone; the user's request, 2026-11-25)
					if id == .modulation {
						Button("About the Columns…") {
							showAbout(ModColumns.about)
						}
					}
					Button("Hide") { layout.hide(id) }
				} label: {
					Image(systemName: "ellipsis.circle")
				}
				.menuStyle(.borderlessButton)
				.menuIndicator(.hidden)
				.fixedSize()
				.hoverTip("\(id.title): move, float or hide")
				// float it in a window of its own (the user's request,
				// 2026-11-27); a floating panel's title bar has the dock icon
				Button { layout.float(id) } label: {
					// a window lifted off another (arrow.up.right.square, the
					// first choice, isn't drawn in the app's panels: some
					// symbols aren't, though they are in a test app; found
					// 2026-11-27)
					Image(systemName: "macwindow.on.rectangle")
				}
				.buttonStyle(.borderless)
				.hoverTip("Float \(id.title) in a window of its own (or double-click the title bar)")
				.accessibilityLabel("Float \(id.title)")
				Button { layout.hide(id) } label: {
					Image(systemName: "xmark").font(.caption2)
				}
				.buttonStyle(.borderless)
				.hoverTip("Hide \(id.title)")
			}
			.padding(.horizontal, 8)
			.frame(height: Self.headerHeight)
			.hoverTip(id.title)	// the whole name, where it's shortened
			// a tone of its own, so each panel reads as a block where panels
			// meet, and a faint accent while the pointer is over the panel
			// (the design audit, 2026-11-24)
			.background(Color.accentColor.opacity(hovered ? 0.1 : 0))
			.background(Color.primary.opacity(0.055))
			.background(.bar)
			.background(ViewAnchor.Probe(anchor: headerAnchor))
			.overlay {	// a flash: moved with the keys, or as far as it goes
				Color.accentColor.opacity(layout.flashing == id ? 0.45 : 0)
					.allowsHitTesting(false)
					.animation(.easeOut(duration: 0.25), value: layout.flashing == id)
			}
			Divider()
			content
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
				.id(id)	// a different tab is a different panel
		}
		.background(Color(nsColor: .windowBackgroundColor))	// opaque over the split view
		.overlay { dropHighlight }
		.onHover { hovered = $0 }	// the header's faint tint
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
					.overlay(PanelDragSource(id: t, layout: layout, help: t == id ? "" : "Show \(t.title)",
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
				// an icon, as the docked panel's float icon (the user's
				// request, 2026-11-27; was a Dock button)
				ToolbarItem {
					Button { model.layout.dock(id) } label: {
						Image(systemName: "rectangle.on.rectangle")	// the float icon's partner (the user's choice, 2026-11-27)
					}
					.hoverTip("Dock \(id.title) in the Whorld window, where it was (or double-click the title bar)")
					.accessibilityLabel("Dock \(id.title)")
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
	@AppStorage(HoverTips.key) private var tipsOn = true	// Show tips on hover: updated when it changes

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
			// a double-click on the title bar (not a tab, which is a click
			// target): the panel floats in its window (the user's request,
			// 2026-11-20; its window's title bar docks it, TitleBarClicks)
			if !dragging, event.clickCount == 2, onClick == nil, let layout {
				let id = self.id
				down = nil
				DispatchQueue.main.async { layout.float(id) }
				return
			}
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
		v.toolTip = help.isEmpty || !tipsOn ? nil : help
	}
}

/// The ⓘ after a panel's title: a click shows what the panel controls
/// (PanelID.summary), as every ⓘ does (InfoButton). No hover tip.
struct PanelInfoButton: View {
	let id: PanelID

	var body: some View {
		InfoButton(text: id.summary, small: true, withTips: true)	// with View > Show Tips on Hover
			.accessibilityLabel("About \(id.title)")
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
			layout?.floatingWindows[id] = LayoutModel.WeakWindow(w)	// (LayoutModel.reveal)
			let nc = NotificationCenter.default
			setLevel()
			for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
				FullScreenController.coverChanged] {
				observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
					MainActor.assumeIsolated { self?.setLevel() }
				})
			}
			observers.append(nc.addObserver(forName: NSWindow.didChangeScreenNotification, object: w, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.setLevel() }	// moved onto, or off, the full screen's display
			})
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

		/// above the Whorld windows while Whorld is active, but behind the
		/// picture on the display full screen covers
		private func setLevel() {
			guard let w = window else { return }
			let covered = FullScreenController.coveredScreen.map { $0 == w.screen } ?? false
			w.level = NSApp.isActive && !covered ? .floating : .normal
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
