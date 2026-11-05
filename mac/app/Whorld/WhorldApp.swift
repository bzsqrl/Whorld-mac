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

/// Main property indices (WhorldBase MAIN_*)
enum MainProp: Int {
	case origin, drawMode, orgMotion, hue, mirror, reverse, convex, invertColor, loopHue, zoomCenter, antialiasing
}

/// Master property indices (WhorldBase MASTER_*)
enum MasterProp: Int {
	case speed, zoom, damping, trail, rings, tempo, hueSpan, canvasScale, copies, spread
}

/// App state shared by the windows, menus and app delegate. All document
/// edits go through here so they're undoable, as in CWhorldDoc.
@MainActor
final class AppModel: ObservableObject {
	static let shared = AppModel()
	static let logStats = ProcessInfo.processInfo.environment["WHORLD_STATS"] == "1"

	let engine = WHEngine()
	let undoManager = UndoManager()
	@Published private(set) var title = "Untitled"
	@Published var showFrameRate = false
	@Published var fullResolution = true
	@Published private(set) var statsText = ""
	/// Bumped after every change so views and menus refresh.
	@Published private(set) var revision = 0

	/// Undo coalescing key of the edit on top of the undo stack
	/// (CUndoManager::NotifyUndoableEdit with UE_COALESCE).
	private var coalesceKey: String?

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
		undoManager.levelsOfUndo = 100
		engine.setSnapshotLetterbox(Preferences.snapshotLetterbox)
	}

	func changed() {
		revision &+= 1
	}

	// MARK: Undo

	/// Registers an undo step unless it coalesces with the previous one:
	/// consecutive edits of the same thing are one step, as on Windows.
	private func recordUndo(key: String, title: String, restore: @escaping () -> Void) {
		let replaying = undoManager.isUndoing || undoManager.isRedoing
		if !replaying && key == coalesceKey && undoManager.canUndo {
			return
		}
		undoManager.registerUndo(withTarget: self) { _ in restore() }
		undoManager.setActionName(title)
		coalesceKey = replaying ? nil : key
	}

	func undo() {
		coalesceKey = nil
		undoManager.undo()
		changed()
	}

	func redo() {
		coalesceKey = nil
		undoManager.redo()
		changed()
	}

	private func resetUndo() {
		undoManager.removeAllActions()
		coalesceKey = nil
	}

	// CWhorldDoc::GetUndoTitle
	static func paramTitle(_ iParam: Int, _ prop: WHParamProperty) -> String {
		var t = WHControls.paramName(iParam)
		if prop != .val {
			t += " " + WHControls.paramPropertyName(prop.rawValue)
		}
		return t
	}

	// MARK: Document edits

	func setParam(_ iParam: Int, _ prop: WHParamProperty, _ value: Double) {
		let old = engine.paramValue(iParam, property: prop)
		guard old != value else { return }
		recordUndo(key: "param \(iParam) \(prop.rawValue)", title: Self.paramTitle(iParam, prop)) { [weak self] in
			self?.setParam(iParam, prop, old)
		}
		engine.setParamValue(value, param: iParam, property: prop)
		changed()
	}

	func setMaster(_ iProp: Int, _ value: Double) {
		let old = engine.masterValue(iProp)
		guard old != value else { return }
		recordUndo(key: "master \(iProp)", title: WHControls.masterName(iProp)) { [weak self] in
			self?.setMaster(iProp, old)
		}
		engine.setMasterValue(value, prop: iProp)
		changed()
	}

	// CWhorldDoc::SetZoom
	func setZoom(_ zoom: Double, damping: Bool = true) {
		let old = engine.masterValue(MasterProp.zoom.rawValue)
		guard old != zoom else { return }
		recordUndo(key: "zoom", title: WHControls.masterName(MasterProp.zoom.rawValue)) { [weak self] in
			self?.setZoom(old, damping: false)
		}
		engine.setZoom(zoom, damping: damping)
		changed()
	}

	func setOrigin(_ pt: CGPoint) {
		let old = engine.origin
		guard old != pt else { return }
		recordUndo(key: "main \(MainProp.origin.rawValue)", title: WHControls.mainName(MainProp.origin.rawValue)) { [weak self] in
			self?.setOrigin(old)
		}
		engine.origin = pt
		changed()
	}

	func setHue(_ hue: Double) {
		let old = engine.hue
		guard old != hue else { return }
		recordUndo(key: "main \(MainProp.hue.rawValue)", title: WHControls.mainName(MainProp.hue.rawValue)) { [weak self] in
			self?.setHue(old)
		}
		engine.hue = hue
		changed()
	}

	func setDrawMode(_ mode: UInt32) {
		let old = engine.drawMode
		guard old != mode else { return }
		recordUndo(key: "main \(MainProp.drawMode.rawValue)", title: WHControls.mainName(MainProp.drawMode.rawValue)) { [weak self] in
			self?.setDrawMode(old)
		}
		engine.setDrawMode(mode)
		changed()
	}

	func setOriginMotion(_ motion: WHOriginMotion) {
		let old = engine.originMotion
		guard old != motion else { return }
		recordUndo(key: "main \(MainProp.orgMotion.rawValue)", title: WHControls.mainName(MainProp.orgMotion.rawValue)) { [weak self] in
			self?.setOriginMotion(old)
		}
		engine.setOriginMotion(motion)
		changed()
	}

	/// Toggles a boolean main property; undo toggles it back.
	func toggle(_ prop: MainProp) {
		recordUndo(key: "main \(prop.rawValue)", title: WHControls.mainName(prop.rawValue)) { [weak self] in
			self?.toggle(prop)
		}
		switch prop {
		case .mirror: engine.toggleMirror()
		case .reverse: engine.toggleReverse()
		case .convex: engine.toggleConvex()
		case .invertColor: engine.invertColor.toggle()
		case .loopHue: engine.toggleLoopHue()
		case .zoomCenter: engine.toggleZoomCenter()
		case .antialiasing: engine.toggleAntialiasing()
		default: assertionFailure("not a boolean main property")
		}
		changed()
	}

	func isOn(_ prop: MainProp) -> Bool {
		switch prop {
		case .mirror: return engine.mirror
		case .reverse: return engine.reverse
		case .convex: return engine.convex
		case .invertColor: return engine.invertColor
		case .loopHue: return engine.loopHue
		case .zoomCenter: return engine.zoomCenter
		case .antialiasing: return engine.antialiasing
		default: return false
		}
	}

	static let drawModeFill: UInt32 = 0x01		// DM_FILL
	static let drawModeOutline: UInt32 = 0x02	// DM_OUTLINE

	func toggleFill() { setDrawMode(engine.drawMode ^ Self.drawModeFill) }
	func toggleOutline() { setDrawMode(engine.drawMode ^ Self.drawModeOutline) }

	// CWhorldDoc::OnImageOriginCenter
	func originCenter() {
		setOriginMotion(.park)
		setOrigin(CGPoint(x: 0.5, y: 0.5))
	}

	func toggleOriginDrag() { setOriginMotion(engine.originMotion == .drag ? .park : .drag) }
	func toggleOriginRandom() { setOriginMotion(engine.originMotion == .random ? .park : .random) }

	// CWhorldDoc::OnMouseWheel: zoom, or damping with Shift, in normalized
	// slider space (CWhorldDoc::OffsetMasterProp)
	func wheel(notches: Double, shift: Bool) {
		let delta = notches * Preferences.wheelSense / 100
		let iProp = (shift ? MasterProp.damping : MasterProp.zoom).rawValue
		let old = engine.masterValue(iProp)
		var norm = WHControls.masterNorm01(iProp, value: old) + delta
		norm = min(max(norm, 0), 1)
		let value = WHControls.masterDenorm01(iProp, value: norm)
		guard value != old else { return }
		if shift {
			setMaster(iProp, value)
		} else {
			setZoom(value)
		}
	}

	// MARK: Files

	private func updateTitle() {
		if let path = engine.patchPath {
			title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
		} else {
			title = "Untitled"
		}
	}

	var windowTitle: String {
		_ = revision
		return engine.modified ? title + " — Edited" : title
	}

	func newPatch() {
		guard confirmDiscard() else { return }
		engine.newPatch()
		resetUndo()
		updateTitle()
		changed()
	}

	func open(_ url: URL) {
		guard confirmDiscard() else { return }
		do {
			try engine.openPatch(atPath: url.path)
			resetUndo()
			NSDocumentController.shared.noteNewRecentDocumentURL(url)
		} catch {
			NSAlert(error: error).runModal()
		}
		updateTitle()
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

	@discardableResult
	func save() -> Bool {
		if let path = engine.patchPath {
			return write(to: URL(fileURLWithPath: path))
		}
		return saveAs()
	}

	@discardableResult
	func saveAs() -> Bool {
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.whorldPatch]
		panel.nameFieldStringValue = title + ".whp"
		guard panel.runModal() == .OK, let url = panel.url else { return false }
		return write(to: url)
	}

	private func write(to url: URL) -> Bool {
		do {
			try engine.savePatch(toPath: url.path)
			NSDocumentController.shared.noteNewRecentDocumentURL(url)
			updateTitle()
			changed()
			return true
		} catch {
			NSAlert(error: error).runModal()
			return false
		}
	}

	/// Asks to save unsaved changes. Returns false if the user cancels.
	func confirmDiscard() -> Bool {
		guard engine.modified else { return true }
		let alert = NSAlert()
		alert.messageText = "Do you want to save the changes you made to \"\(title)\"?"
		alert.informativeText = "Your changes will be lost if you don't save them."
		alert.addButton(withTitle: "Save")
		alert.addButton(withTitle: "Cancel")
		alert.addButton(withTitle: "Don't Save")
		switch alert.runModal() {
		case .alertFirstButtonReturn: return save()
		case .alertThirdButtonReturn: return true
		default: return false
		}
	}

	func toggleFullScreen() {
		mainWindow?.toggleFullScreen(nil)
	}

	var mainWindow: NSWindow? {
		NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
			?? NSApp.mainWindow
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	func application(_ application: NSApplication, open urls: [URL]) {
		if let url = urls.first {
			Task { @MainActor in AppModel.shared.open(url) }
		}
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		MainActor.assumeIsolated {
			AppModel.shared.confirmDiscard() ? .terminateNow : .terminateCancel
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
				.navigationTitle(model.windowTitle)
		}
		.defaultSize(width: 1024, height: 768)
		.commands {
			WhorldCommands(model: model)
		}

		Window("Parameters", id: "params") {
			ParamsPanel().environmentObject(model)
		}
		.keyboardShortcut("p", modifiers: [.command, .shift])
		.defaultPosition(.topTrailing)

		Window("Master", id: "master") {
			MasterPanel().environmentObject(model)
		}
		.keyboardShortcut("m", modifiers: [.command, .shift])
		.windowResizability(.contentSize)

		Window("Globals", id: "globals") {
			GlobalsPanel().environmentObject(model)
		}
		.keyboardShortcut("g", modifiers: [.command, .shift])
		.windowResizability(.contentSize)

		Window("Properties", id: "properties") {
			PropertiesPanel().environmentObject(model)
		}
		.keyboardShortcut("r", modifiers: [.command, .shift])
		.windowResizability(.contentSize)

		Settings {
			PreferencesView().environmentObject(model)
		}
	}
}
