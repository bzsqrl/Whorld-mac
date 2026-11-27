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

// MARK: Workspace

struct WorkspaceView: View {
	@EnvironmentObject private var model: AppModel
	@ObservedObject var layout: LayoutModel
	@Environment(\.openWindow) private var openWindow
	@Environment(\.dismissWindow) private var dismissWindow

	var body: some View {
		let l = layout.layout
		// Left or Right full height (the user's request, 2026-11-25): beside
		// the picture and the bottom both, in a split around them; else
		// beside the picture, above the bottom, as before (the same split
		// views, so their saved sizes stay)
		// (only with a bottom: without one a side is the whole height anyway,
		// in the same split views as before)
		let tallLeft = l.bottom != nil && l.isFullHeight(.left), tallRight = l.bottom != nil && l.isFullHeight(.right)
		// detached, the output's place stays, as the swipe pad (OutputView)
		let top = (l.left == nil || tallLeft ? [] : ["left"]) + ["center"] + (l.right == nil || tallRight ? [] : ["right"])
		let rows = (top.isEmpty ? [] : ["top"]) + (l.bottom == nil ? [] : ["bottom"])
		Group {
			if rows.isEmpty {
				VStack(spacing: 8) {
					Text("The output is in its own window.")
					Text("Show panels from the View menu, or choose View > Detach to bring the output back.")
						.foregroundStyle(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if tallLeft || tallRight {
				let outer = (tallLeft ? ["left"] : []) + ["middle"] + (tallRight ? ["right"] : [])
				SplitView(vertical: true, items: outer, autosave: "Whorld.O." + outer.joined(separator: "|"),
					initialSize: { $0 == "left" ? 360 : $0 == "right" ? 440 : nil },
					flexible: "middle", arrangeGeneration: layout.arrangeGeneration) { id in
					switch id {
					case "left": AnyView(region(.left))
					case "right": AnyView(region(.right))
					default: AnyView(rowsView(rows, top: top))
					}
				}
			} else {
				rowsView(rows, top: top)
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

	/// the picture's row (with any side not full height) over the bottom
	private func rowsView(_ rows: [String], top: [String]) -> some View {
		SplitView(vertical: false, items: rows, autosave: "Whorld.V." + rows.joined(separator: "|"),
			initialSize: { $0 == "bottom" && rows.count > 1 ? 300 : nil },
			flexible: "top", arrangeGeneration: layout.arrangeGeneration) { id in
			id == "top" ? AnyView(topRow(top)) : AnyView(region(.bottom))
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
			OutputView(panelDrop: EdgeDropDelegate(size: g.size, layout: layout, target: $target),
				pad: layout.layout.detached)
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
/// the output again. Like a floating panel (FloatingWindowHelper), it stays
/// above the Whorld window while Whorld is the active app, so clicking the
/// panels doesn't hide the picture (the user's request, 2026-11-20); with
/// another app active it's an ordinary window, and on the display full
/// screen covers it goes behind.
@MainActor
final class OutputWindowController: NSObject, NSWindowDelegate {
	private(set) var window: NSWindow?
	var onClose: (() -> Void)?
	private var observers: [NSObjectProtocol] = []

	private func setLevel() {
		guard let w = window else { return }
		let covered = FullScreenController.coveredScreen.map { $0 == w.screen } ?? false
		w.level = NSApp.isActive && !covered ? .floating : .normal
	}

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
		setLevel()
		let nc = NotificationCenter.default
		for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
			FullScreenController.coverChanged] {
			observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.setLevel() }
			})
		}
		observers.append(nc.addObserver(forName: NSWindow.didChangeScreenNotification, object: w, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.setLevel() }	// moved onto, or off, the full screen's display
		})
		w.makeKeyAndOrderFront(nil)
	}

	func hide() {
		guard let w = window else { return }
		window = nil
		observers.forEach(NotificationCenter.default.removeObserver)
		observers = []
		w.delegate = nil
		w.saveFrame(usingName: "WhorldOutputWindow")
		w.orderOut(nil)
		w.contentView = nil
	}

	func windowWillClose(_ notification: Notification) {
		MainActor.assumeIsolated { onClose?() }
	}
}

// MARK: Title bar double-clicks

/// A double-click on a floating panel's window's title bar docks the panel,
/// and on the detached output's, docks the output (the user's request,
/// 2026-11-20: as a double-click on a docked panel's title bar floats it).
/// Not on the window's buttons; taken before macOS's own title bar
/// double-click (zoom or minimize, as System Settings says).
@MainActor
enum TitleBarClicks {
	private static var monitor: Any?

	static func install() {
		guard monitor == nil else { return }
		monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
			guard e.clickCount == 2, let w = e.window else { return e }
			return MainActor.assumeIsolated { handle(e, in: w) } ? nil : e
		}
	}

	private static func handle(_ e: NSEvent, in w: NSWindow) -> Bool {
		let model = AppModel.shared
		let layout = model.layout
		let panel = layout.floatingWindows.first { $0.value.window === w && layout.isFloating($0.key) }?.key
		let output = w === model.outputWindow.window
		guard panel != nil || output else { return false }
		let p = e.locationInWindow
		guard p.y >= w.contentLayoutRect.maxY else { return false }	// below the title bar
		// a button there (the window's own, or the toolbar's Dock): its click
		if let frame = w.contentView?.superview {
			var v = frame.hitTest(frame.convert(p, from: nil))
			while let view = v {
				if view is NSControl || String(describing: type(of: view)).contains("ToolbarItem") { return false }
				v = view.superview
			}
		}
		if let panel {
			layout.dock(panel)
		} else {
			model.toggleDetach()
		}
		return true
	}
}

// MARK: Panel move keys

/// The four moves, as the ⋯ menu lists them
enum PanelMoves {
	static let all: [(title: String, edge: DockEdge, key: KeyEquivalent)] = [
		("Left", .leading, .leftArrow), ("Right", .trailing, .rightArrow),
		("Up", .top, .upArrow), ("Down", .bottom, .downArrow),
	]
}

/// Option-Command and an arrow moves the panel under the pointer a step
/// (LayoutModel.step; the user's request, 2026-11-19; gone 2026-11-25 when
/// the arrow chords went to the cue, back 2026-11-27 on ⌥⌘ alone, the
/// interface's modifiers). Taken before anything else, wherever the
/// pointer is: the ⋯ menus show these keys, and none of them should act on
/// its own panel from afar. Nothing else in Whorld uses them (the cue is
/// ⌥ alone, and ⇧⌥⌘ for its first and last; text and number boxes don't).
@MainActor
enum PanelKeys {
	private static var monitor: Any?

	static func install() {
		guard monitor == nil else { return }
		monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
			guard e.modifierFlags.intersection([.shift, .command, .option, .control]) == [.command, .option] else { return e }
			let edge: DockEdge
			switch e.keyCode {
			case 123: edge = .leading
			case 124: edge = .trailing
			case 126: edge = .top
			case 125: edge = .bottom
			default: return e
			}
			MainActor.assumeIsolated {
				guard NSApp.modalWindow == nil else { return }
				let layout = AppModel.shared.layout
				if let id = layout.panelUnderPointer() {
					layout.step(id, toward: edge, far: false)
				}
			}
			return nil
		}
	}
}

