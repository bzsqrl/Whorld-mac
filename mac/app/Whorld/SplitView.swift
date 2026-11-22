// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyleft 2025 Chris Korda (original Whorld); port Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// The workspace's split views (split out of Workspace.swift on 2026-11-22;
// no change in behavior): an NSSplitView of SwiftUI panes, with saved and
// starting divider positions.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
		if c.items != items || c.autosave != autosave || s.isVertical != vertical {
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
		s.isVertical = vertical	// SwiftUI may hand back the view a split the other way had
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
	/// Puts the dividers at these positions. A divider only trades space
	/// between its two panes, so one beside a pane with none yet (a pane
	/// just added) can't move far: last to first, then first to last,
	/// each finds room.
	private static func place(_ s: NSSplitView, _ at: [CGFloat]) {
		for i in at.indices.reversed() { s.setPosition(at[i], ofDividerAt: i) }
		for i in at.indices { s.setPosition(at[i], ofDividerAt: i) }
	}

	private func arrange(_ s: DockSplitView) {
		let name = autosave, ids = items, initial = initialSize, isVertical = vertical
		let shares = SplitShares.current[name]
		s.pendingInitial = { [weak s] in
			guard let s else { return true }
			let total = isVertical ? s.bounds.width : s.bounds.height
			let t = s.dividerThickness
			if let shares, shares.count == ids.count, ids.count > 1 {	// a saved layout's proportions
				let room = total - t * CGFloat(ids.count - 1)
				let sum = max(shares.reduce(0, +), 1e-9)
				var pos: CGFloat = 0, at: [CGFloat] = []
				for i in 0..<(ids.count - 1) {
					pos += room * CGFloat(shares[i] / sum)
					at.append(pos)
					pos += t
				}
				Self.place(s, at)
				s.autosaveName = name
				s.redisplayWindowSoon()
				return true
			}
			var fixed = ids.map(initial)
			var nFlex = fixed.filter { $0 == nil }.count
			let room = total - t * CGFloat(max(ids.count - 1, 0))
			// the forms' sizes don't leave the rest room (a pane spanning a
			// small region, say): all share it alike
			if fixed.compactMap({ $0 }).reduce(0, +) + CGFloat(nFlex) * Coordinator.minPane > room {
				fixed = ids.map { _ in nil }
				nFlex = ids.count
			}
			let used = fixed.compactMap { $0 }.reduce(0, +) + t * CGFloat(max(ids.count - 1, 0))
			let flex = nFlex > 0 ? max((total - used) / CGFloat(nFlex), Coordinator.minPane) : 0
			var pos: CGFloat = 0, at: [CGFloat] = []
			for i in 0..<max(ids.count - 1, 0) {
				pos += fixed[i] ?? flex
				at.append(pos)
				pos += t
			}
			Self.place(s, at)
			s.autosaveName = name
			s.redisplayWindowSoon()
			return true
		}
		s.needsLayout = true
	}
}
