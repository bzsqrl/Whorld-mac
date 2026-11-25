// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// The info overlay (View > Show Info Overlay, ⌥⌘`; the user's request,
// 2026-11-25): what the Perform Bar says, over the picture's bottom-left
// corner, for learning the Key Map, watching performance and trying patches
// full screen before a show. Off at launch, and turned off on entering full
// screen, so it never shows full screen by accident: turned on there, it
// stays. On every picture view (docked, detached, full screen, any
// display), never in Syphon or exports, which take the frames themselves.
// Four lines: the readout (the last control changed and its value, with the
// Key Map key if a key changed it, kept until the next change), the patch and Auto Advance, the
// performance, and the audio with any states on. Sized to the picture, so
// it reads from a distance on a projector.

import AppKit

@MainActor
final class InfoOverlay {
	static let shared = InfoOverlay()

	private let views = NSHashTable<OverlayView>.weakObjects()
	/// the picture views, for the overlay to be put on while it's on and
	/// taken off while it's off: nothing over the picture then, so full
	/// screen keeps macOS's direct path to the display (no compositing)
	private let pictures = NSHashTable<NSView>.weakObjects()
	private var timer: Timer?

	/// a picture view the overlay goes on, bottom left, while it's on
	func attach(to picture: NSView) {
		pictures.add(picture)
		refresh()
	}

	/// on the pictures or off them as the toggle says; updated four times a
	/// second while on, and nothing at all while off (no view, no timer)
	func refresh() {
		let on = AppModel.shared.showInfoOverlay
		if on {
			for p in pictures.allObjects where !p.subviews.contains(where: { $0 is OverlayView }) {
				let v = OverlayView(frame: p.bounds)
				v.autoresizingMask = [.width, .height]
				p.addSubview(v)
				views.add(v)
			}
		} else {
			for v in views.allObjects { v.removeFromSuperview() }
			views.removeAllObjects()
		}
		if on {
			if timer == nil {
				let t = Timer(timeInterval: 0.25, repeats: true) { _ in
					MainActor.assumeIsolated { InfoOverlay.shared.tick() }
				}
				RunLoop.main.add(t, forMode: .common)
				timer = t
			}
			tick()
		} else {
			timer?.invalidate()
			timer = nil
		}
	}

	private func tick() {
		let lines = Self.lines()
		for v in views.allObjects where v.window != nil { v.lines = lines }
	}

	// MARK: What it says

	static func lines() -> [(text: String, warn: Bool)] {
		let m = AppModel.shared
		let e = m.engine
		let feed = StripFeed.shared
		var out: [(String, Bool)] = []

		// 1: the last control changed, with the Key Map key that changed it
		// (to learn the map; the readout records it as it's set), kept until
		// another change; the patch's name before any
		if feed.readoutFull.isEmpty {
			out.append((m.title, false))
		} else {
			out.append((feed.readoutKey.map { "\($0) · \(feed.readoutFull)" } ?? feed.readoutFull, false))
		}

		// 2: the patch's place, and when Auto Advance moves on
		var patch = feed.patch.place.isEmpty ? m.title : "\(feed.patch.place) · \(m.title)"
		if e.autoAdvancing {
			var following: ObjCBool = false
			var tempo = 0.0
			let p = min(max(e.autoAdvanceProgress(followingBeat: &following, tempo: &tempo), 0), 1)
			let left = (1 - p) * e.autoAdvanceLength
			switch AutoAdvanceUnit(rawValue: e.autoAdvanceUnit) ?? .seconds {
			case .seconds:
				let s = Int(left.rounded(.up))
				patch += String(format: " · next in %d:%02d", s / 60, s % 60)
			case .beats: patch += " · next in \(Int(left.rounded(.up))) beats"
			case .bars: patch += String(format: " · next in %.1f bars", left)
			}
		}
		out.append((patch, false))
		if let cue = m.cueLine { out.append((cue, false)) }	// the cue (AppModel+Cue.swift)

		// 3: performance, orange while refreshes are missed
		var perf = String(format: "%.0f fps · %ld missed", e.framesPerSecond, e.missedFrames)
		if e.gpuMilliseconds > 0 { perf += String(format: " · %.1f ms GPU", e.gpuMilliseconds) }
		perf += " · \(e.ringCount) rings"
		if m.autoQuality, !e.autoQualityStatus.isEmpty, e.autoQualityStatus != "auto: as set" {
			perf += " · " + e.autoQualityStatus
		}
		out.append((perf, e.missedFrames > 0))

		// 4: the audio, and any states that are on
		var audio: String
		if ModMap.shared.bypass {
			audio = "Mod off"
		} else {
			let r = WHAudioInput.shared.reading()
			if r.beatLocked.boolValue {
				audio = String(format: "Mod on · %.1f BPM", r.tempo)
				if r.beatInBar >= 0 { audio += String(format: " · bar %d · beat %d", r.barInPhrase + 1, r.beatInBar + 1) }
			} else {
				audio = r.level > 0 ? "Mod on · finding the beat" : "Mod on"
			}
		}
		var tags: [String] = []
		if e.blackout { tags.append("BLACKOUT") }
		if e.paused { tags.append("PAUSED") }
		tags.append(e.geometryMode ? "GEOM" : "FULL")	// the patch mode, always (the user's request, 2026-11-25)
		if e.xray { tags.append("XRAY") }
		if m.syphonState == 2 { tags.append("SYPHON") }
		if !tags.isEmpty { audio += " · " + tags.joined(separator: " · ") }
		out.append((audio, false))
		return out
	}
}

/// The overlay on one picture view: lines on a translucent plate, bottom
/// left, its text sized to the picture; clicks and swipes pass through
final class OverlayView: NSView {
	var lines: [(text: String, warn: Bool)] = [] {
		didSet {
			if lines.map(\.text) != oldValue.map(\.text) || lines.map(\.warn) != oldValue.map(\.warn) { needsDisplay = true }
		}
	}

	override var isFlipped: Bool { false }
	override func hitTest(_ point: NSPoint) -> NSView? { nil }	// the picture takes the mouse

	override func draw(_ dirtyRect: NSRect) {
		guard !lines.isEmpty else { return }
		// sized to the picture: about 1/55 of its height, 11 to 30 points
		let size = min(max(bounds.height / 55, 11), 30)
		let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
		let big = NSFont.monospacedDigitSystemFont(ofSize: size * 1.25, weight: .semibold)
		let texts = lines.enumerated().map { i, l in
			NSAttributedString(string: l.text, attributes: [
				.font: i == 0 ? big : font,
				.foregroundColor: l.warn ? NSColor.systemOrange : (i == 0 ? NSColor.white : NSColor(white: 1, alpha: 0.82)),
			])
		}
		let pad = size * 0.7, gap = size * 0.25
		let maxW = bounds.width - pad * 4
		let sizes = texts.map { t -> NSSize in
			let s = t.size()
			return NSSize(width: min(ceil(s.width), maxW), height: ceil(s.height))
		}
		let w = (sizes.map(\.width).max() ?? 0) + pad * 2
		let h = sizes.map(\.height).reduce(0, +) + gap * CGFloat(max(sizes.count - 1, 0)) + pad * 2
		let plate = NSRect(x: pad, y: pad, width: w, height: h)
		NSColor(white: 0, alpha: 0.55).setFill()
		NSBezierPath(roundedRect: plate, xRadius: size * 0.5, yRadius: size * 0.5).fill()
		var y = plate.maxY - pad
		for (t, s) in zip(texts, sizes) {
			y -= s.height
			t.draw(with: NSRect(x: plate.minX + pad, y: y, width: s.width, height: s.height),
				options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
			y -= gap
		}
	}
}
