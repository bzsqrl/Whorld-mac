// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
	// Whorld patch (.whp), declared in Info.plist
	static let whorldPatch = UTType(importedAs: "io.github.bzsqrl.whorld.patch", conformingTo: .data)
}

/// App state shared by the window, the menus and the app delegate.
@MainActor
final class AppModel: ObservableObject {
	static let shared = AppModel()
	static let logStats = ProcessInfo.processInfo.environment["WHORLD_STATS"] == "1"

	let engine = WHEngine()
	@Published private(set) var title = "Untitled"
	@Published var showFrameRate = false
	@Published var fullResolution = true
	@Published private(set) var statsText = ""
	/// Bumped after every engine change so menus refresh their check marks.
	@Published private(set) var revision = 0

	private init() {
		engine.statsHandler = { [weak self] in
			guard let self else { return }
			let e = self.engine
			self.statsText = String(format: "%.0f fps · draw %.1f ms · %d Hz · %ld rings",
				e.framesPerSecond, e.renderMilliseconds, e.refreshRate, e.ringCount)
			if Self.logStats {	// WHORLD_STATS=1: also print, for measuring
				FileHandle.standardError.write(Data((self.statsText + "\n").utf8))
			}
		}
	}

	func changed() {
		revision &+= 1
	}

	func newPatch() {
		engine.newPatch()
		title = "Untitled"
		changed()
	}

	func open(_ url: URL) {
		do {
			try engine.openPatch(atPath: url.path)
			title = url.deletingPathExtension().lastPathComponent
			NSDocumentController.shared.noteNewRecentDocumentURL(url)
		} catch {
			NSAlert(error: error).runModal()
		}
		changed()
	}

	func showOpenPanel() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.whorldPatch]
		panel.allowsMultipleSelection = false
		if panel.runModal() == .OK, let url = panel.url {
			open(url)
		}
	}

	func toggleFullScreen() {
		NSApp.keyWindow?.toggleFullScreen(nil)
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	func application(_ application: NSApplication, open urls: [URL]) {
		if let url = urls.first {
			Task { @MainActor in AppModel.shared.open(url) }
		}
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}
}

@main
struct WhorldApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@StateObject private var model = AppModel.shared

	var body: some Scene {
		Window("Whorld", id: "main") {
			ContentView()
				.environmentObject(model)
				.navigationTitle(model.title)
		}
		.defaultSize(width: 1024, height: 768)
		.commands {
			WhorldCommands(model: model)
		}
	}
}
