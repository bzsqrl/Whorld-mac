// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
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
		WorkspaceView(layout: model.layout)
			.background(MainWindowObserver { model.workspaceWindowAppeared($0) })
	}
}

/// The output: the render view with the movie bar and frame-rate overlays,
/// taking dropped files. In the workspace's middle, or in the detached
/// output window.
struct OutputView: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		RenderView(engine: model.engine, fullResolution: model.fullResolution)
			.ignoresSafeArea()
			.frame(minWidth: 320, minHeight: 240)
			.overlay(alignment: .bottom) {
				MovieBar()
			}
			.overlay(alignment: .topLeading) {
				if model.showFrameRate {
					StatsOverlay(stats: model.stats)
				}
			}
			.onDrop(of: [.fileURL], isTargeted: nil) { providers in
				guard let provider = providers.first else { return false }
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
}

/// The frame-rate overlay. It observes only the statistics, so their update
/// each second redraws this text and nothing else.
struct StatsOverlay: View {
	@ObservedObject var stats: StatsModel

	var body: some View {
		Text(stats.text)
			.font(.system(.caption, design: .monospaced))
			.foregroundStyle(.white)
			.padding(6)
			.background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
			.padding(8)
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
	let fullResolution: Bool

	func makeNSView(context: Context) -> WHRenderView {
		let view = WHRenderView(frame: .zero)
		view.engine = engine
		view.fullResolution = fullResolution
		view.wheelHandler = { notches, shift in
			Task { @MainActor in AppModel.shared.wheel(notches: notches, shift: shift) }
		}
		return view
	}

	func updateNSView(_ view: WHRenderView, context: Context) {
		view.fullResolution = fullResolution
	}

	/// The render view takes the size it's offered (no fitting-size measuring).
	func sizeThatFits(_ proposal: ProposedViewSize, nsView: WHRenderView, context: Context) -> CGSize? {
		proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
	}
}
