// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// The Key Map cheat sheet (new in the Mac port, the user's request,
// 2026-11-22): press the key left of 1 (` on US keyboards) with the pointer
// over the picture or the swipe pad, and a drawing of the keyboard shows
// which key moves which control, over that view, until the key is pressed
// again (a toggle since the user's second request that day; it was held).
// A click-through window of its own over the view, so swipes, held keys,
// taps and drags still reach the picture beneath, it's never in Syphon or
// exports, and never over a full-screen picture. It follows the view as its
// window moves or resizes, and hides if the view leaves its window or goes
// full screen.

import AppKit
import SwiftUI

@MainActor
final class KeyCheatSheet {
	static let shared = KeyCheatSheet()

	/// the key that shows it: left of 1 (ANSI grave, ISO section)
	static let keyCodes: Set<UInt16> = [50, 10]
	static let keyLabel = "`"

	private var panel: NSPanel?
	/// the picture or swipe pad it's over, and the observers that follow it
	private weak var host: NSView?
	private var observers: [Any] = []
	/// shown and not hidden since (the panel itself is hidden while Whorld
	/// is inactive, hidesOnDeactivate, and comes back with it)
	private(set) var isShown = false

	/// the sheet's window, which the pointer test looks past (OutputKeys)
	var windowNumber: Int? { isShown ? panel?.windowNumber : nil }

	func toggle(over view: NSView) {
		if isShown { hide() } else { show(over: view) }
	}

	/// Shows the sheet centered over `view` (a picture or the swipe pad),
	/// scaled down to fit it
	func show(over view: NSView) {
		guard place(over: view) else { return }
		host = view
		isShown = true
		follow(view)
	}

	/// Sizes and places the sheet over the view; false (and hidden) where it
	/// can't go: no window, full screen, or too small to read
	@discardableResult
	private func place(over view: NSView) -> Bool {
		// never over a full-screen picture, which the audience may see (the
		// user's rule, 2026-11-22); the swipe pad and windowed pictures only
		guard let window = view.window, !(window is FullScreenWindow) else {
			hide()
			return false
		}
		let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
		let natural = KeyCheatSheetView.naturalSize
		let scale = min(1, (rect.width - 24) / natural.width, (rect.height - 24) / natural.height)
		guard scale > 0.3 else {	// too small a view to read it
			hide()
			return false
		}
		let size = CGSize(width: natural.width * scale, height: natural.height * scale)
		let host = NSHostingView(rootView: KeyCheatSheetView(scale: scale))
		host.frame = CGRect(origin: .zero, size: size)
		let p = panel ?? makePanel()
		p.contentView = host
		p.setFrame(CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
			width: size.width, height: size.height), display: true)
		p.level = NSWindow.Level(rawValue: max(window.level.rawValue, NSWindow.Level.floating.rawValue) + 1)	// above full screen too
		p.orderFront(nil)
		panel = p
		return true
	}

	func hide() {
		panel?.orderOut(nil)
		isShown = false
		host = nil
		for o in observers { NotificationCenter.default.removeObserver(o) }
		observers = []
	}

	/// Keeps it over the view as its window moves or resizes (the panes'
	/// dividers resize the view itself)
	private func follow(_ view: NSView) {
		for o in observers { NotificationCenter.default.removeObserver(o) }
		observers = []
		view.postsFrameChangedNotifications = true
		let names: [(Notification.Name, AnyObject?)] = [
			(NSWindow.didMoveNotification, view.window), (NSWindow.didResizeNotification, view.window),
			(NSView.frameDidChangeNotification, view),
		]
		for (name, object) in names {
			observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
				MainActor.assumeIsolated { KeyCheatSheet.shared.refresh() }
			})
		}
	}

	/// Back over its view, or hidden if the view has left its window (the
	/// picture detached or docked) or gone full screen
	func refresh() {
		guard isShown else { return }
		guard let view = host, view.window != nil, place(over: view) else {
			hide()
			return
		}
	}

	private func makePanel() -> NSPanel {
		let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
		p.isOpaque = false
		p.backgroundColor = .clear
		p.hasShadow = true
		p.ignoresMouseEvents = true
		p.hidesOnDeactivate = true
		p.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .ignoresCycle]
		return p
	}
}

/// The keyboard, US layout, with each Key Map key's control on it, colored
/// by kind
struct KeyCheatSheetView: View {
	let scale: CGFloat
	@ObservedObject private var map = KeyMap.shared

	static let keyW: CGFloat = 60, keyH: CGFloat = 50, gap: CGFloat = 5, pad: CGFloat = 16
	/// the rows from the digits down, and each row's indent in keys
	static let rows: [(keys: [String], indent: CGFloat)] = [
		(["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="], 0),
		(["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]", "\\"], 0.5),
		(["a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'"], 0.75),
		(["z", "x", "c", "v", "b", "n", "m", ",", ".", "/"], 1.25),
	]
	static let headerH: CGFloat = 30, footerH: CGFloat = 26
	static var naturalSize: CGSize {
		CGSize(width: pad * 2 + 13.5 * (keyW + gap), height: pad * 2 + headerH + 4 * (keyH + gap) + footerH)
	}

	enum Kind: CaseIterable {
		case shape, color, master, other
		var title: String {
			switch self {
			case .shape: "Shape"
			case .color: "Color"
			case .master: "Master"
			case .other: "Hue, origin"
			}
		}
		var tint: Color {
			switch self {
			case .shape: .blue
			case .color: .pink
			case .master: .orange
			case .other: .green
			}
		}
	}

	private static let colorParams: Set<String> = ["Color Speed", "Lightness", "Saturation", "Alpha",
		"Bk Hue", "Bk Lightness", "Bk Saturation", "Bk Alpha"]

	static func kind(_ b: KeyBinding) -> Kind {
		guard let t = b.targetIndex else { return .other }
		let nParams = WHMappingInfo.paramTargetCount, nMaster = WHMappingInfo.masterTargetCount
		if t < nParams { return colorParams.contains(WHControls.paramName(t)) ? .color : .shape }
		if t < nParams + nMaster { return .master }
		return .other
	}

	var body: some View {
		let s = scale
		let byKey = Dictionary(map.bindings.filter { !$0.key.isEmpty && $0.targetIndex != nil }.map { ($0.key, $0) },
			uniquingKeysWith: { a, _ in a })
		let onGrid = Set(Self.rows.flatMap(\.keys))
		let others = map.bindings.filter { !$0.key.isEmpty && $0.targetIndex != nil && !onGrid.contains($0.key) }
		VStack(alignment: .leading, spacing: Self.gap * s) {
			HStack(spacing: 14 * s) {
				Text("Key Map").font(.system(size: 17 * s, weight: .bold))
				Text("Hold a key over the picture and swipe").font(.system(size: 13 * s)).foregroundStyle(.secondary)
				Spacer(minLength: 0)
				ForEach(Kind.allCases, id: \.self) { k in
					HStack(spacing: 4 * s) {
						RoundedRectangle(cornerRadius: 2 * s).fill(k.tint).frame(width: 10 * s, height: 10 * s)
						Text(k.title).font(.system(size: 12 * s)).foregroundStyle(.secondary)
					}
				}
			}
			.frame(height: Self.headerH * s)
			ForEach(Self.rows.indices, id: \.self) { r in
				HStack(spacing: Self.gap * s) {
					Color.clear.frame(width: Self.rows[r].indent * (Self.keyW + Self.gap) * s, height: 1)
					ForEach(Self.rows[r].keys, id: \.self) { key in
						cap(key, byKey[key], s)
					}
				}
			}
			Text(others.isEmpty
				? "Press \(KeyCheatSheet.keyLabel) again to close. View › Key Map changes the keys."
				: "Also: " + others.map { "\($0.keyLabel) \($0.displayName)" }.joined(separator: ", "))
				.font(.system(size: 12 * s)).foregroundStyle(.secondary)
				.lineLimit(1).minimumScaleFactor(0.6)
				.frame(height: Self.footerH * s, alignment: .leading)
		}
		.padding(Self.pad * s)
		.frame(width: Self.naturalSize.width * s, height: Self.naturalSize.height * s, alignment: .topLeading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14 * s))
		.environment(\.colorScheme, .dark)
	}

	@ViewBuilder private func cap(_ key: String, _ b: KeyBinding?, _ s: CGFloat) -> some View {
		let isSheetKey = key == KeyCheatSheet.keyLabel
		VStack(alignment: .leading, spacing: 1 * s) {
			Text(key.uppercased())
				.font(.system(size: 13 * s, weight: .bold, design: .monospaced))
				.foregroundStyle(b == nil && !isSheetKey ? .tertiary : .primary)
			if let b {
				Text(b.displayName)
					.font(.system(size: 10.5 * s, weight: .medium))
					.lineLimit(2).minimumScaleFactor(0.7)
					.multilineTextAlignment(.leading)
			} else if isSheetKey {
				Text("Sheet").font(.system(size: 10.5 * s)).foregroundStyle(.secondary)
			}
			Spacer(minLength: 0)
		}
		.padding(5 * s)
		.frame(width: Self.keyW * s, height: Self.keyH * s, alignment: .topLeading)
		.background(RoundedRectangle(cornerRadius: 6 * s)
			.fill(b.map { Self.kind($0).tint.opacity(0.32) } ?? Color.white.opacity(isSheetKey ? 0.16 : 0.05)))
		.overlay(RoundedRectangle(cornerRadius: 6 * s)
			.strokeBorder(b.map { Self.kind($0).tint.opacity(0.8) } ?? Color.white.opacity(0.12), lineWidth: 1))
	}
}
