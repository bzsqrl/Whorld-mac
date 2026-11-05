// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
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
					Text(model.statsText)
						.font(.system(.caption, design: .monospaced))
						.foregroundStyle(.white)
						.padding(6)
						.background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
						.padding(8)
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
}
