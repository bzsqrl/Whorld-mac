// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// The workspace: Detach, Show All Panels, layouts (AppModel, split out of WhorldApp.swift on 2026-11-22;
// no change in behavior).

import AppKit
import SwiftUI

extension AppModel {
	// MARK: Workspace

	var isDetached: Bool { layout.layout.detached }

	/// View > Detach (CMainFrame::OnWindowDetach): the output to a window of
	/// its own, or back to the workspace. Not while full screen, as on Windows.
	func toggleDetach() {
		KeyCheatSheet.shared.hide()	// its picture moves to another window
		guard !isFullScreen else { return }
		if layout.layout.detached {
			outputWindow.hide()
			layout.layout.detached = false
		} else {
			layout.layout.detached = true
			outputWindow.show(model: self, near: mainWindow?.frame)
		}
	}

	/// Window > Show All Panels: every panel in the workspace, and the
	/// workspace filling its display. A detached output stays where it is.
	func showAllPanels() {
		layout.showAll()
		fitWorkspace()
	}

	/// Window > Reset Layout (CMainFrame::OnWindowResetLayout, which asks
	/// first, as this does).
	/// Named layouts (2026-11-22): the current one's defaults.
	func resetLayout() {
		let named = NamedLayouts.shared
		let name = named.current?.name ?? "Edit"
		let alert = NSAlert()
		alert.messageText = "Reset the \(name) layout?"
		alert.informativeText = switch named.active {
		case NamedLayouts.editID: "The panels go back to their standard places and sizes, as when Whorld is first opened."
		case NamedLayouts.performID: "The panels go back to Perform's standard arrangement: a large picture, Patches and Playlist on the left, Parameters and Master on the right."
		default: "The panels go back to the arrangement \(name) was saved with."
		}
		alert.addButton(withTitle: "Reset")
		alert.addButton(withTitle: "Cancel")
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		named.resetCurrent()
		fitWorkspace()
	}

	// MARK: Layouts (Mac addition)

	/// The workspace as it is now: panels, divider proportions, windows
	func currentLayoutFile() -> LayoutFile {
		var f = LayoutFile(layout: layout.layout)
		if let w = mainWindow {
			if let v = w.contentView {
				f.splits = SplitShares.capture(in: v)
			}
			if let area = w.screen?.visibleFrame {
				f.window = UnitRect(w.frame, in: area)
			}
		}
		if layout.layout.detached, let w = outputWindow.window, let area = w.screen?.visibleFrame {
			f.output = UnitRect(w.frame, in: area)
		}
		for id in layout.layout.floating {
			if let w = panelWindow(id), let area = w.screen?.visibleFrame {
				f.floating[id.rawValue] = UnitRect(w.frame, in: area)
			}
		}
		return f
	}

	/// Arranges the workspace as a saved layout says. Before the Whorld
	/// window is up (a playlist reopened at launch), it waits for it.
	func applyLayout(_ f: LayoutFile) {
		guard let main = mainWindow else {
			pendingLayout = f
			return
		}
		for id in layout.layout.floating where !f.layout.floating.contains(id) {
			layout.closeFloating?(id)
		}
		layout.forgetSplitPositions()
		SplitShares.current = Layout.standardSplits.merging(f.splits) { $1 }
		let wasDetached = layout.layout.detached
		layout.layout = f.layout
		if let r = f.window, let area = (main.screen ?? NSScreen.main)?.visibleFrame {
			main.setFrame(r.rect(in: area), display: true)
		}
		if f.layout.detached && !wasDetached {
			outputWindow.show(model: self, near: main.frame)
		} else if !f.layout.detached && wasDetached {
			outputWindow.hide()
		}
		if let r = f.output, let w = outputWindow.window, let area = (w.screen ?? NSScreen.main)?.visibleFrame {
			w.setFrame(r.rect(in: area), display: true)
		}
		for id in f.layout.floating {
			layout.openFloating?(id)
		}
		DispatchQueue.main.async {	// the floating windows are up now
			for (raw, r) in f.floating {
				if let id = PanelID(rawValue: raw), let w = self.panelWindow(id),
					let area = (w.screen ?? NSScreen.main)?.visibleFrame {
					w.setFrame(r.rect(in: area), display: true)
				}
			}
		}
		layout.arrangeGeneration += 1
		changes.menus.bump()
	}

	func panelWindow(_ id: PanelID) -> NSWindow? {
		NSApp.windows.first {
			guard let s = $0.identifier?.rawValue else { return false }
			return s == id.rawValue || s.hasPrefix(id.rawValue + "-")
		}
	}

	/// Window > Export Layout... (Save Layout... before named layouts): the
	/// arrangement now, as a file to share or keep
	func exportLayout() {
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.whorldLayout]
		panel.nameFieldStringValue = (NamedLayouts.shared.current?.name ?? "Layout") + ".whlayout"
		panel.directoryURL = WhorldFolders.start(.layouts)	// Documents/Whorld/Layouts (2026-11-22)
		guard panel.runModal() == .OK, let url = panel.url else { return }
		WhorldFolders.used(.layouts, url)
		let e = JSONEncoder()
		e.outputFormatting = [.prettyPrinted, .sortedKeys]
		do {
			try e.encode(currentLayoutFile()).write(to: url, options: .atomic)
		} catch {
			NSAlert(error: error).runModal()
		}
	}

	/// Window > Import Layout... (Open Layout... before named layouts)
	func importLayout() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.whorldLayout]
		panel.directoryURL = WhorldFolders.start(.layouts)
		guard panel.runModal() == .OK, let url = panel.url else { return }
		WhorldFolders.used(.layouts, url)
		openLayout(url)
	}

	/// A layout file becomes a named layout, named after the file, and the
	/// current one
	func openLayout(_ url: URL) {
		do {
			let f = try JSONDecoder().decode(LayoutFile.self, from: LayoutFile.sanitized(Data(contentsOf: url)))
			NamedLayouts.shared.importFile(f, name: url.deletingPathExtension().lastPathComponent)
		} catch {
			let a = NSAlert()
			a.messageText = "Can't open the layout \"\(url.lastPathComponent)\"."
			a.informativeText = "It isn't a Whorld layout file, or it's damaged."
			a.runModal()
		}
	}

	/// The workspace fills its display's visible area, the panes at their
	/// starting sizes.
	func fitWorkspace() {
		guard let w = mainWindow, let screen = w.screen ?? NSScreen.main else { return }
		w.setFrame(screen.visibleFrame, display: true, animate: true)
		layout.arrangeGeneration += 1
	}

	/// The workspace window is up: restore a detached output, and on the
	/// first launch with a workspace, fit it to its display.
	func workspaceWindowAppeared(_ w: NSWindow) {
		guard !didFitWorkspace else { return }
		didFitWorkspace = true
		// nothing focused at first: AppKit would focus the first number box
		// (Ring Growth's), for no reason (the user's menu audit, 2026-11-18)
		DispatchQueue.main.async {
			if w.firstResponder is NSTextView { w.makeFirstResponder(nil) }
		}
		if layout.layout.detached {
			outputWindow.show(model: self, near: w.frame)
		}
		if layout.isFirstRun {
			DispatchQueue.main.async { self.fitWorkspace() }
		}
		if let f = pendingLayout {	// a playlist's, from before the window was up
			pendingLayout = nil
			DispatchQueue.main.async { self.applyLayout(f) }
		}
	}

	var mainWindow: NSWindow? {
		NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
			?? NSApp.mainWindow
	}

	/// Makes a panel at least `width` wide where there's room (Parameters'
	/// oscillator columns shown; the user's request, 2026-11-22): a docked
	/// pane takes it from the pane beside it, to the right first, then the
	/// left, then its region from its neighbour, and so on out; a floating
	/// window grows, within its display. What can't be found, it scrolls.
	/// What moved is kept, for narrowPanel.
	func widenPanel(_ id: PanelID, to width: CGFloat) {
		widening = nil
		if layout.isFloating(id) {
			guard let w = panelWindow(id), let content = w.contentView else { return }
			let need = width - content.bounds.width
			guard need > 0.5 else { return }
			let old = w.frame
			var f = old
			let area = w.screen?.visibleFrame ?? f
			f.size.width = min(f.width + need, area.width)
			if f.maxX > area.maxX { f.origin.x = max(area.minX, area.maxX - f.width) }
			w.setFrame(f, display: true, animate: true)
			widening = PanelWidening(id: id, window: w, windowFrame: old, widened: w.frame.width)
			return
		}
		guard let pane = layout.paneViews[id]?.view else { return }
		var need = width - pane.bounds.width
		var moves: [PanelWidening.Move] = []
		var v: NSView = pane
		while need > 0.5, let up = v.superview {
			if let s = up as? NSSplitView, s.isVertical, let i = s.arrangedSubviews.firstIndex(of: v) {
				if i + 1 < s.arrangedSubviews.count {	// the divider on its right, moved right
					let before = v.frame.width
					moves.append(.init(split: s, divider: i, position: v.frame.maxX))
					s.setPosition(v.frame.maxX + need, ofDividerAt: i)
					s.layoutSubtreeIfNeeded()
					need -= v.frame.width - before
				}
				if need > 0.5, i > 0 {	// the one on its left, moved left
					let before = v.frame.width
					moves.append(.init(split: s, divider: i - 1, position: v.frame.minX - s.dividerThickness))
					s.setPosition(v.frame.minX - need - s.dividerThickness, ofDividerAt: i - 1)
					s.layoutSubtreeIfNeeded()
					need -= v.frame.width - before
				}
			}
			v = up
		}
		if !moves.isEmpty {
			widening = PanelWidening(id: id, pane: pane, moves: moves, widened: pane.bounds.width)
		}
	}

	/// Gives back what widenPanel took, Parameters' oscillator columns hidden
	/// again (the user's request, 2026-11-22), if the panel is still the
	/// width it was made: resized by hand since, or moved, it stays as it is.
	func narrowPanel(_ id: PanelID) {
		guard let wd = widening, wd.id == id else { return }
		widening = nil
		if let w = wd.window {
			guard layout.isFloating(id), abs(w.frame.width - wd.widened) < 1, let old = wd.windowFrame else { return }
			w.setFrame(old, display: true, animate: true)
			return
		}
		guard let pane = wd.pane, layout.isDocked(id), abs(pane.bounds.width - wd.widened) < 1 else { return }
		for m in wd.moves.reversed() {
			guard let s = m.split else { continue }
			s.setPosition(m.position, ofDividerAt: m.divider)
			s.layoutSubtreeIfNeeded()
		}
	}
}

/// What widenPanel moved: a docked pane's dividers (from the inside out),
/// or a floating window's frame, and the width it left the panel
struct PanelWidening {
	struct Move {
		weak var split: NSSplitView?
		let divider: Int
		let position: CGFloat
	}
	let id: PanelID
	weak var pane: NSView?
	var moves: [Move] = []
	weak var window: NSWindow?
	var windowFrame: NSRect?
	let widened: CGFloat

	init(id: PanelID, pane: NSView, moves: [Move], widened: CGFloat) {
		self.id = id
		self.pane = pane
		self.moves = moves
		self.widened = widened
	}

	init(id: PanelID, window: NSWindow, windowFrame: NSRect, widened: CGFloat) {
		self.id = id
		self.window = window
		self.windowFrame = windowFrame
		self.widened = widened
	}
}
