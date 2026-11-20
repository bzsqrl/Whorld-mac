// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

import SwiftUI
import UniformTypeIdentifiers

/// The main window: the workspace (Workspace.swift).
struct ContentView: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		VStack(spacing: 0) {
			if model.showStats {
				StatsStrip()
				Divider()
			}
			WorkspaceView(layout: model.layout)
		}
			.background(MainWindowObserver { model.workspaceWindowAppeared($0) })
			.modifier(DocumentTitle())
	}
}

/// The window title, in a modifier of its own: a change to it (the first
/// edit after a save) redraws just this, not the workspace.
private struct DocumentTitle: ViewModifier {
	@EnvironmentObject private var model: AppModel

	func body(content: Content) -> some View {
		content.navigationTitle(model.windowTitle)
			.navigationSubtitle(model.windowSubtitle)
	}
}

/// The output: the render view with the movie bar overlay,
/// taking dropped files. In the workspace's middle, or in the detached
/// output window.
struct OutputView: View {
	@EnvironmentObject private var model: AppModel
	/// in the workspace, panels dropped near its edges (one drop target for
	/// both: an inner one would take every drag over it, panels' too)
	var panelDrop: EdgeDropDelegate? = nil

	var body: some View {
		RenderView(engine: model.engine, renderScale: model.renderScale, smoothUpscaling: model.smoothUpscaling)
			.ignoresSafeArea()
			.frame(minWidth: 320, minHeight: 240)
			.overlay(alignment: .bottom) {
				MovieBar()
			}
			.onDrop(of: panelDrop == nil ? [.fileURL] : [.fileURL, .whorldPanel],
				delegate: OutputDropDelegate(model: model, panels: panelDrop))
	}
}

/// Files dropped on the output open; panels go to the workspace's
/// EdgeDropDelegate.
struct OutputDropDelegate: DropDelegate {
	let model: AppModel
	let panels: EdgeDropDelegate?

	private func panelDelegate(_ info: DropInfo) -> EdgeDropDelegate? {
		info.hasItemsConforming(to: [.whorldPanel]) ? panels : nil
	}

	func validateDrop(info: DropInfo) -> Bool {
		panelDelegate(info) != nil || info.hasItemsConforming(to: [.fileURL])
	}

	func dropUpdated(info: DropInfo) -> DropProposal? {
		if let p = panelDelegate(info) { return p.dropUpdated(info: info) }
		return info.hasItemsConforming(to: [.whorldPanel]) ? DropProposal(operation: .forbidden) : nil
	}

	func dropExited(info: DropInfo) { panels?.dropExited(info: info) }

	func performDrop(info: DropInfo) -> Bool {
		if let p = panelDelegate(info) { return p.performDrop(info: info) }
		guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
		let model = model
		_ = provider.loadObject(ofClass: URL.self) { url, _ in
			guard let url else { return }
			Task { @MainActor in
				switch url.pathExtension.lowercased() {
				case "whp": model.open(url)
				case "whl": if model.confirmDiscardPlaylist() { model.openPlaylist(url) }
				case "whs": model.loadSnapshots([url])
				case "whm": model.playMovie(url)
				default: break
				}
			}
		}
		return true
	}
}

/// View > Show Stats (Mac addition; the user's request, 2026-11-19): a thin
/// strip across the top of the workspace window, never over the picture,
/// with the frame statistics, the last control swiped over the picture
/// (a held key's, or Zoom and Damping), and the quick performance levers.
/// It replaced the frame-rate overlay and the key readout over the picture.
struct StatsStrip: View {
	@EnvironmentObject private var model: AppModel
	static let height: CGFloat = 24

	var body: some View {
		HStack(spacing: 10) {
			// the live text is AppKit, redrawn by StripFeed: a SwiftUI layout
			// pass every second (or every swipe) would drop the panes' tooltips
			StripText(part: .stats)
				.frame(minWidth: 60, maxWidth: 440)
				.layoutPriority(1)	// a narrow window drops the readout first
			Divider().frame(height: 14)
			StripText(part: .readout)
				.frame(minWidth: 0, maxWidth: 260)
			Spacer(minLength: 0)
			Picker(selection: $model.renderScale) {
				ForEach(AppModel.renderScales, id: \.value) { s in
					Text(s.name.split(separator: " ").first.map(String.init) ?? s.name).tag(s.value)
				}
			} label: {
				Text("Scale").foregroundStyle(.secondary)
			}
			.pickerStyle(.menu)
			.fixedSize()
			Toggle("Auto", isOn: $model.autoQuality)
				.toggleStyle(.checkbox)
				.fixedSize()
			InfoButton(text: Self.info, small: true)
		}
		.controlSize(.small)
		.font(.caption)
		.padding(.horizontal, 10)
		.frame(height: Self.height)
		.frame(maxWidth: .infinity)
		.background(Color(nsColor: .windowBackgroundColor))
	}

	static let info = "Frames drawn a second, display refreshes missed in the last second (orange), the time to draw a frame (on the CPU, and on the GPU with Metal) and the rings drawn; with Automatic quality on, what it has lowered. The display's rate and the renderer are in the statistics' tooltip.\n\nIn the middle, the last control changed by swiping over the picture (Zoom, Damping with Shift, or a held key's control; see the Key Map), with its value.\n\nScale is Render scale and Auto is Automatic quality, as in Settings > Display, which explains them. View > Show Stats (Option-Command-F) hides the strip."
}

/// What the stats strip shows, set by AppModel; its text views redraw only
/// when their part changes.
@MainActor
final class StripFeed {
	static let shared = StripFeed()

	private(set) var stats = ""		// before and after "n missed", which
	private(set) var missed = ""	// is drawn orange when n > 0
	private(set) var statsTail = ""
	private(set) var statsTip = ""
	private(set) var readout = ""
	private(set) var readoutFresh = false	// just changed; dimmed after a few seconds
	private var views: [WeakView] = []
	private var dimWork: DispatchWorkItem?

	private final class WeakView {
		weak var view: StripText.View?
		init(_ v: StripText.View) { view = v }
	}

	func add(_ v: StripText.View) {
		views.removeAll { $0.view == nil || $0.view === v }
		views.append(WeakView(v))
	}

	func remove(_ v: StripText.View) {
		views.removeAll { $0.view == nil || $0.view === v }
	}

	private func redraw(_ part: StripText.Part) {
		for w in views where w.view?.part == part { w.view?.needsDisplay = true }
	}

	func setStats(_ s: String, missed m: String, _ tail: String, tip: String) {
		guard s != stats || m != missed || tail != statsTail || tip != statsTip else { return }
		stats = s
		missed = m
		statsTail = tail
		if tip != statsTip {
			statsTip = tip
			for w in views where w.view?.part == .stats { w.view?.toolTip = tip }
		}
		redraw(.stats)
	}

	func setReadout(_ s: String) {
		if s != readout || !readoutFresh {
			readout = s
			readoutFresh = true
			redraw(.readout)
		}
		dimWork?.cancel()
		let work = DispatchWorkItem { [weak self] in
			MainActor.assumeIsolated {
				self?.readoutFresh = false
				self?.redraw(.readout)
			}
		}
		dimWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
	}
}

/// One of the stats strip's live texts (StripFeed), drawn in AppKit
struct StripText: NSViewRepresentable {
	enum Part { case stats, readout }
	let part: Part

	final class View: NSView {
		var part: Part = .stats

		override var isFlipped: Bool { true }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if window != nil {
				StripFeed.shared.add(self)
				if part == .stats { toolTip = StripFeed.shared.statsTip }
			} else {
				StripFeed.shared.remove(self)
			}
		}

		override func viewDidChangeEffectiveAppearance() {
			super.viewDidChangeEffectiveAppearance()
			needsDisplay = true
		}

		override func draw(_ dirtyRect: NSRect) {
			let feed = StripFeed.shared
			let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
			let style = NSMutableParagraphStyle()
			style.lineBreakMode = .byTruncatingTail
			func attrs(_ color: NSColor) -> [NSAttributedString.Key: Any] {
				[.font: font, .foregroundColor: color, .paragraphStyle: style]
			}
			let text = NSMutableAttributedString()
			switch part {
			case .stats:
				guard !feed.stats.isEmpty else { break }
				let warn = !feed.missed.hasPrefix("0 ")
				text.append(NSAttributedString(string: feed.stats, attributes: attrs(.secondaryLabelColor)))
				text.append(NSAttributedString(string: feed.missed, attributes: attrs(warn ? .systemOrange : .secondaryLabelColor)))
				text.append(NSAttributedString(string: feed.statsTail, attributes: attrs(.secondaryLabelColor)))
			case .readout:
				if feed.readout.isEmpty {
					text.append(NSAttributedString(string: "Swipe over the picture", attributes: attrs(.tertiaryLabelColor)))
				} else {
					text.append(NSAttributedString(string: feed.readout,
						attributes: attrs(feed.readoutFresh ? .labelColor : .secondaryLabelColor)))
				}
			}
			let h = ceil(font.ascender - font.descender + font.leading)
			let r = NSRect(x: 0, y: floor((bounds.height - h) / 2), width: bounds.width, height: h)
			text.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
		}
	}

	func makeNSView(context: Context) -> View {
		let v = View()
		v.part = part
		return v
	}

	func updateNSView(_ v: View, context: Context) {
		if v.part != part {
			v.part = part
			v.needsDisplay = true
		}
	}
}

/// Reports the window it's in, once it's in one.
struct MainWindowObserver: NSViewRepresentable {
	let onWindow: (NSWindow) -> Void

	func makeNSView(context: Context) -> NSView { Observer(onWindow) }
	func updateNSView(_ view: NSView, context: Context) {}

	final class Observer: NSView {
		let onWindow: (NSWindow) -> Void
		init(_ onWindow: @escaping (NSWindow) -> Void) {
			self.onWindow = onWindow
			super.init(frame: .zero)
		}
		required init?(coder: NSCoder) { nil }
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let window { onWindow(window) }
		}
	}
}

/// Hosts the AppKit render view, which drives the engine from its display link.
struct RenderView: NSViewRepresentable {
	let engine: WHEngine
	let renderScale: Double
	let smoothUpscaling: Bool

	func makeNSView(context: Context) -> WHRenderView {
		let view = WHRenderView(frame: .zero)
		view.secondaryClickHandler = {	// a two-finger tap with a key held: that control's default
			MainActor.assumeIsolated { AppModel.shared.resetHeldKeyControl() }
		}
		view.engine = engine
		view.renderScale = renderScale
		view.smoothUpscaling = smoothUpscaling
		view.wheelHandler = { notches, shift, momentum, inverted, trackpad in
			Task { @MainActor in
				AppModel.shared.wheel(notches: notches, shift: shift, momentum: momentum, inverted: inverted, trackpad: trackpad)
			}
		}
		return view
	}

	func updateNSView(_ view: WHRenderView, context: Context) {
		if view.renderScale != renderScale {
			view.renderScale = renderScale
		}
		if view.smoothUpscaling != smoothUpscaling {
			view.smoothUpscaling = smoothUpscaling
		}
	}

	/// The render view takes the size it's offered (no fitting-size measuring).
	func sizeThatFits(_ proposal: ProposedViewSize, nsView: WHRenderView, context: Context) -> CGSize? {
		proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
	}
}
