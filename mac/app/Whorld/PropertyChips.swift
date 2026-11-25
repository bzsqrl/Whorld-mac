// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// The Properties as chips (the user's choice, 2026-11-24, from the design
// studies: Windows' toolbar icons, but readable): the Image menu's switches
// as rounded chips lit in the accent color while on, its two actions
// outlined (they flash when pressed and never stay lit), and Origin as one
// four-way switch. Each chip has a small icon drawn from Whorld's own
// shapes and, with room, its name; without room, its shortcut instead. The
// Properties panel groups them by job (PropertiesPanel); the Perform Bar
// can show the live ones as a row of its own (PropertiesStrip, View > Show
// Properties in Perform Bar).

import AppKit
import SwiftUI

/// A Properties item: a switch or an action of the Image menu
enum PropItem: CaseIterable {
	case fill, outline, xor, mirror, convex, reverse, invertColor, loopHue, rotateHue, randomPhase, pause, clear, zoomCenter, antialiasing

	var name: String {
		switch self {
		case .fill: "Fill"
		case .outline: "Outline"
		case .xor: "XOR"
		case .mirror: "Mirror"
		case .convex: "Convex"
		case .reverse: "Reverse"
		case .invertColor: "Invert Color"
		case .loopHue: "Loop Hue"
		case .rotateHue: "Rotate Hue"
		case .randomPhase: "Random Phase"
		case .pause: "Pause"
		case .clear: "Clear"
		case .zoomCenter: "Zoom Center"
		case .antialiasing: "Antialiasing"
		}
	}

	/// the menu's shortcut (Commands.swift): the number keys in the
	/// Properties' order (the user's request, 2026-11-24)
	var key: String {
		switch self {
		case .fill: "⌘1"
		case .outline: "⌘2"
		case .xor: "⌘3"
		case .mirror: "⌘4"
		case .convex: "⌘5"
		case .reverse: "⌘6"
		case .invertColor: "⌘7"
		case .rotateHue: "⌘8"
		case .loopHue: "⌘9"
		case .randomPhase: "⌘0"
		case .pause: "Space"
		case .clear: "Delete"
		case .zoomCenter: "⌥⌘Z"
		case .antialiasing: "⌥⌘A"
		}
	}

	/// where room is short (the Properties panel's text-only step)
	var shortName: String {
		switch self {
		case .invertColor: "Invert"
		case .rotateHue: "Rotate"
		case .loopHue: "Loop"
		case .randomPhase: "Phase"
		case .zoomCenter: "Zoom Ctr"
		case .antialiasing: "Antialias"
		default: name
		}
	}

	var isAction: Bool { self == .rotateHue || self == .randomPhase || self == .clear }

	var tip: String {
		switch self {
		case .fill: ControlTips.fill
		case .outline: ControlTips.outline
		case .xor: ControlTips.xor
		case .mirror: ControlTips.mirror
		case .convex: ControlTips.convex
		case .reverse: ControlTips.reverse
		case .invertColor: ControlTips.invertColor
		case .loopHue: ControlTips.loopHue
		case .zoomCenter: ControlTips.zoomCenter
		case .antialiasing: ControlTips.antialiasing
		case .rotateHue: "Turns the colors of the rings showing by 90 degrees, and Hue with them."
		case .randomPhase: "Puts every oscillator at a random point in its cycle."
		case .pause: "Freezes the picture; Shift-Space steps it a frame at a time."
		case .clear: "Removes every ring; new ones keep coming."
		}
	}

	@MainActor func isOn(_ model: AppModel) -> Bool {
		let e = model.engine
		switch self {
		case .fill: return e.fill
		case .outline: return e.outline
		case .xor: return e.xray
		case .mirror: return model.isOn(.mirror)
		case .convex: return model.isOn(.convex)
		case .reverse: return model.isOn(.reverse)
		case .invertColor: return model.isOn(.invertColor)
		case .loopHue: return model.isOn(.loopHue)
		case .zoomCenter: return model.isOn(.zoomCenter)
		case .antialiasing: return model.isOn(.antialiasing)
		case .pause: return e.paused
		case .rotateHue, .randomPhase, .clear: return false
		}
	}

	@MainActor func perform(_ model: AppModel) {
		switch self {
		case .fill: model.toggleFill()
		case .outline: model.toggleOutline()
		case .xor: model.toggleXRay()
		case .mirror: model.toggle(.mirror)
		case .convex: model.toggle(.convex)
		case .reverse: model.toggle(.reverse)
		case .invertColor: model.toggle(.invertColor)
		case .loopHue: model.toggle(.loopHue)
		case .zoomCenter: model.toggle(.zoomCenter)
		case .antialiasing: model.toggle(.antialiasing)
		case .rotateHue: model.rotateHue()
		case .randomPhase: model.randomPhase()
		case .pause: model.togglePause()
		case .clear: model.clear()
		}
	}
}

/// Origin Motion as the Properties show it. Center isn't a motion: it's
/// Park with the origin in the middle (Image > Origin Center).
enum OriginChoice: CaseIterable {
	case center, park, drag, random	// the menu's order (the user's request, 2026-11-24)

	var name: String {
		switch self {
		case .center: "Center"
		case .drag: "Drag"
		case .random: "Random"
		case .park: "Park"
		}
	}

	var help: String {
		switch self {
		case .center: "Origin Center (⌘−): the rings' center in the middle of the picture"
		case .park: "Origin Park (⇧⌘−): the origin stays where it is"
		case .drag: "Origin Drag (⌘=): the origin follows the mouse"
		case .random: "Origin Random (⇧⌘=): the origin jumps in time with Tempo"
		}
	}

	@MainActor static func now(_ model: AppModel) -> OriginChoice {
		switch model.engine.originMotion {
		case .drag: return .drag
		case .random: return .random
		default: return model.originAtCenter ? .center : .park
		}
	}

	@MainActor func choose(_ model: AppModel) {
		switch self {
		case .center: model.originCenter()
		case .drag: model.setOriginMotion(.drag)
		case .random: model.setOriginMotion(.random)
		case .park: model.setOriginMotion(.park)
		}
	}
}

// MARK: Icons

/// A chip's icon, drawn in a 16-point square in the chip's text color:
/// shapes from Whorld's own (a pentagon ring, its star points) where they
/// can say what the switch does
struct PropIcon: View {
	enum Kind { case item(PropItem), origin(OriginChoice) }
	let kind: Kind
	var size: CGFloat = 14

	var body: some View {
		Canvas { ctx, sz in
			Self.draw(kind, in: &ctx, scale: sz.width / 16)
		}
		.frame(width: size, height: size)
		.accessibilityHidden(true)
	}

	private static let line = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)

	/// the pentagon's corners, radius r about (8, 8.4), the first at the top
	private static func corners(_ r: Double) -> [CGPoint] {
		(0..<5).map { (i: Int) -> CGPoint in
			let a: Double = Double(i) * 0.4 * Double.pi - 0.5 * Double.pi
			return CGPoint(x: 8.0 + cos(a) * r, y: 8.4 + sin(a) * r)
		}
	}

	private static func pentagon(_ r: Double) -> Path {
		var p = Path()
		p.addLines(corners(r))
		p.closeSubpath()
		return p
	}

	private static func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
		Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
	}

	private static func draw(_ kind: Kind, in ctx: inout GraphicsContext, scale: CGFloat) {
		ctx.scaleBy(x: scale, y: scale)
		let g = ctx
		func stroke(_ p: Path) { g.stroke(p, with: .foreground, style: line) }
		func fill(_ p: Path, eo: Bool = false) { g.fill(p, with: .foreground, style: FillStyle(eoFill: eo)) }
		switch kind {
		case .item(.fill): fill(pentagon(6.2))
		case .item(.outline): stroke(pentagon(6)); stroke(pentagon(3.1))
		case .item(.xor):	// two rings, their overlap cut out
			var p = circle(6, 8, 4.4); p.addPath(circle(10, 8, 4.4)); fill(p, eo: true)
		case .item(.mirror):
			ctx.stroke(Path { $0.move(to: CGPoint(x: 8, y: 2)); $0.addLine(to: CGPoint(x: 8, y: 14)) },
				with: .foreground, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [1.4, 1.8]))
			stroke(Path { p in p.move(to: CGPoint(x: 5.8, y: 4)); p.addLine(to: CGPoint(x: 2.6, y: 8)); p.addLine(to: CGPoint(x: 5.8, y: 12)) })
			stroke(Path { p in p.move(to: CGPoint(x: 10.2, y: 4)); p.addLine(to: CGPoint(x: 13.4, y: 8)); p.addLine(to: CGPoint(x: 10.2, y: 12)) })
		case .item(.convex):	// a pentagon bulging outward
			let pts = corners(6)
			var p = Path()
			p.move(to: pts[0])
			for k in 0..<5 {
				let a = pts[k], b = pts[(k + 1) % 5]
				let mx: CGFloat = (a.x + b.x) / 2, my: CGFloat = (a.y + b.y) / 2
				p.addQuadCurve(to: b, control: CGPoint(x: mx + (mx - 8) * 0.28, y: my + (my - 8.4) * 0.28))
			}
			stroke(p)
		case .item(.reverse):	// growth turned inward
			stroke(Path { p in
				p.move(to: CGPoint(x: 1.8, y: 8)); p.addLine(to: CGPoint(x: 6.2, y: 8))
				p.move(to: CGPoint(x: 4.3, y: 5.9)); p.addLine(to: CGPoint(x: 6.4, y: 8)); p.addLine(to: CGPoint(x: 4.3, y: 10.1))
				p.move(to: CGPoint(x: 14.2, y: 8)); p.addLine(to: CGPoint(x: 9.8, y: 8))
				p.move(to: CGPoint(x: 11.7, y: 5.9)); p.addLine(to: CGPoint(x: 9.6, y: 8)); p.addLine(to: CGPoint(x: 11.7, y: 10.1))
			})
		case .item(.invertColor):
			stroke(circle(8, 8, 5.6))
			fill(Path { p in p.addArc(center: CGPoint(x: 8, y: 8), radius: 5.6, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false); p.closeSubpath() })
		case .item(.loopHue):	// hue going back and forth within its span: an arc, arrows at both ends
			let c = CGPoint(x: 8, y: 9.6), r = 5.8
			stroke(Path { p in p.addArc(center: c, radius: r, startAngle: .degrees(195), endAngle: .degrees(345), clockwise: false) })
			for (deg, sign) in [(195.0, -1.0), (345.0, 1.0)] {	// each end, pointing on along the arc
				let t = deg * Double.pi / 180
				let tip = CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
				let dx = -sin(t) * sign, dy = cos(t) * sign	// the arc's direction there, outward
				stroke(Path { p in
					for w in [0.6, -0.6] {	// two wings, swept back
						let bx = -(dx * cos(w) - dy * sin(w)) * 2.6, by = -(dx * sin(w) + dy * cos(w)) * 2.6
						p.move(to: CGPoint(x: tip.x + bx, y: tip.y + by)); p.addLine(to: tip)
					}
				})
			}
		case .item(.rotateHue):	// the hue wheel, a quarter of it lit: a quarter turn
			stroke(circle(8, 8, 5.6))
			stroke(Path { p in
				p.move(to: CGPoint(x: 8, y: 2.4)); p.addLine(to: CGPoint(x: 8, y: 13.6))
				p.move(to: CGPoint(x: 2.4, y: 8)); p.addLine(to: CGPoint(x: 13.6, y: 8))
			})
			fill(Path { p in
				p.move(to: CGPoint(x: 8, y: 8))
				p.addArc(center: CGPoint(x: 8, y: 8), radius: 5.6, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
				p.closeSubpath()
			})
		case .item(.randomPhase):	// a die
			stroke(Path(roundedRect: CGRect(x: 2.4, y: 2.4, width: 11.2, height: 11.2), cornerRadius: 2.6))
			fill(circle(5.5, 5.5, 0.95)); fill(circle(8, 8, 0.95)); fill(circle(10.5, 10.5, 0.95))
		case .item(.pause):	// two bars
			fill(Path(roundedRect: CGRect(x: 4, y: 3, width: 2.8, height: 10), cornerRadius: 1))
			fill(Path(roundedRect: CGRect(x: 9.2, y: 3, width: 2.8, height: 10), cornerRadius: 1))
		case .item(.clear):	// an empty picture: a ring struck through
			stroke(circle(8, 8, 5.4))
			stroke(Path { p in p.move(to: CGPoint(x: 3.4, y: 12.6)); p.addLine(to: CGPoint(x: 12.6, y: 3.4)) })
		case .item(.zoomCenter):	// cross hairs
			stroke(circle(8, 8, 4.4))
			stroke(Path { p in
				for (a, b) in [((8.0, 1.6), (8.0, 4.6)), ((8.0, 11.4), (8.0, 14.4)), ((1.6, 8.0), (4.6, 8.0)), ((11.4, 8.0), (14.4, 8.0))] {
					p.move(to: CGPoint(x: a.0, y: a.1)); p.addLine(to: CGPoint(x: b.0, y: b.1))
				}
			})
		case .item(.antialiasing):	// a smooth line
			stroke(Path { p in p.move(to: CGPoint(x: 2.6, y: 13.4)); p.addCurve(to: CGPoint(x: 13.4, y: 2.6), control1: CGPoint(x: 7, y: 12), control2: CGPoint(x: 9, y: 5)) })
		case .origin(.center): stroke(circle(8, 8, 5.6)); fill(circle(8, 8, 1.5))
		case .origin(.drag):	// a pointer
			stroke(Path { p in
				p.move(to: CGPoint(x: 4, y: 2.6)); p.addLine(to: CGPoint(x: 12.4, y: 8.2)); p.addLine(to: CGPoint(x: 8.8, y: 9.1))
				p.addLine(to: CGPoint(x: 10.8, y: 13.2)); p.addLine(to: CGPoint(x: 9.2, y: 13.9)); p.addLine(to: CGPoint(x: 7.2, y: 9.9))
				p.addLine(to: CGPoint(x: 4.4, y: 12.2)); p.closeSubpath()
			})
		case .origin(.random):	// scattered points
			for (x, y) in [(4.0, 5.0), (11.6, 3.8), (8.0, 9.0), (3.6, 12.2), (12.4, 12.0)] { fill(circle(x, y, 1.15)) }
		case .origin(.park):	// a pin
			stroke(Path { p in
				p.move(to: CGPoint(x: 8, y: 14.2))
				p.addCurve(to: CGPoint(x: 3.8, y: 6.2), control1: CGPoint(x: 5.2, y: 10.6), control2: CGPoint(x: 3.8, y: 8.4))
				p.addArc(center: CGPoint(x: 8, y: 6.2), radius: 4.2, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
				p.addCurve(to: CGPoint(x: 8, y: 14.2), control1: CGPoint(x: 12.2, y: 8.4), control2: CGPoint(x: 10.8, y: 10.6))
			})
			stroke(circle(8, 6.2, 1.4))
		}
		}
}

// MARK: Chips

/// A one-time action just happened (Rotate Hue, Random Phase, Clear), from
/// a chip, the menu, a shortcut or an F-key: its chips flash, in the panel
/// and on the Perform Bar alike (the user's request, 2026-11-24)
@MainActor @Observable
final class ActionFlash {
	static let shared = ActionFlash()
	private(set) var count: [PropItem: Int] = [:]

	func fire(_ item: PropItem) { count[item, default: 0] &+= 1 }
}

/// How a chip shows its item
enum ChipLabel { case iconAndName, shortName, icon }

/// A chip's look: a switch lit in the accent color while on; an action
/// outlined, flashing as it's pressed
private struct ChipStyle: ButtonStyle {
	let on: Bool
	let action: Bool
	let height: CGFloat
	let label: ChipLabel
	var flash = false	// an action just happened: lit as if pressed

	func makeBody(configuration: Configuration) -> some View {
		let pressed = configuration.isPressed || flash
		configuration.label
			.font(.system(size: height < 24 ? 11 : 12, weight: .medium))
			.foregroundStyle(on ? Color.white : Color.primary)
			.padding(.leading, label == .icon ? 0 : label == .shortName ? 8 : 6)
			.padding(.trailing, label == .icon ? 0 : 8)
			.frame(width: label == .icon ? height + 6 : nil, height: height)
			.background {
				let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)
				if action {
					shape.fill(pressed ? Color.accentColor.opacity(0.35) : Color.clear)
					shape.strokeBorder(pressed ? Color.accentColor : Color.primary.opacity(0.28), lineWidth: 1)
				} else {
					shape.fill(on ? Color.accentColor.opacity(pressed ? 0.8 : 1) : Color.primary.opacity(pressed ? 0.2 : 0.09))
				}
			}
			.contentShape(Rectangle())
	}
}

/// A switch or an action, as a chip: its icon and name, its short name, or
/// its icon; its name, shortcut and what it does in the tooltip
struct PropChip: View {
	@EnvironmentObject private var model: AppModel
	let item: PropItem
	var label = ChipLabel.iconAndName
	var height: CGFloat = 24
	@State private var flashing = false

	var body: some View {
		let _ = model.changes.main.n	// redrawn on its own: its parent's redraw doesn't reach it (same inputs)
		let fired = item.isAction ? ActionFlash.shared.count[item, default: 0] : 0
		let on = item.isOn(model)
		Button { item.perform(model) } label: {
			HStack(spacing: 5) {
				if label != .shortName {
					PropIcon(kind: .item(item), size: height < 24 ? 13 : 14)
				}
				if label != .icon {
					Text(label == .shortName ? item.shortName : item.name).lineLimit(1).fixedSize()
				}
			}
		}
		.buttonStyle(ChipStyle(on: on, action: item.isAction, height: height, label: label, flash: flashing))
		.onChange(of: fired) {	// the action happened, however it was triggered: a short flash
			flashing = true
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { flashing = false }
		}
		.focusable(false)
		.hoverTip("\(item.name) (\(item.key))\(item.isAction ? "" : on ? ": on" : ": off"). \(item.tip)")
		.accessibilityLabel(item.name)
		.accessibilityValue(item.isAction ? "" : on ? "on" : "off")
	}
}

/// Origin: one four-way switch, the current choice lit; with labels, or
/// icons alone, across or (vertical) down
struct OriginSwitch: View {
	@EnvironmentObject private var model: AppModel
	var labels = true
	var vertical = false
	var height: CGFloat = 24

	var body: some View {
		let _ = model.changes.main.n	// redrawn on its own, as PropChip
		let now = OriginChoice.now(model)
		let buttons = ForEach(OriginChoice.allCases, id: \.self) { c in
			Button { if c != now { c.choose(model) } } label: {
				HStack(spacing: 4) {
					PropIcon(kind: .origin(c), size: height < 24 ? 12 : 13)
					if labels { Text(c.name).lineLimit(1).fixedSize() }
				}
				.font(.system(size: height < 24 ? 11 : 12, weight: .medium))
				.foregroundStyle(c == now ? Color.white : Color.primary)
				.padding(.horizontal, labels ? 8 : 0)
				.frame(width: labels ? nil : height + 2, height: height - 4)
				.background(Capsule().fill(c == now ? Color.accentColor : Color.clear))
				.contentShape(Capsule())
			}
			.buttonStyle(.plain)
			.focusable(false)
			.hoverTip(c.help)
			.accessibilityLabel("Origin " + c.name)
			.accessibilityAddTraits(c == now ? .isSelected : [])
		}
		Group {
			if vertical {
				VStack(spacing: 2) { buttons }
			} else {
				HStack(spacing: 2) { buttons }
			}
		}
		.padding(2)
		.background(RoundedRectangle(cornerRadius: height / 2, style: .continuous).fill(Color.primary.opacity(0.09)))
		.fixedSize()
	}
}

// MARK: The panel

/// The Properties panel (study A, the user's choice, 2026-11-24): the
/// chips grouped by job, in the shortcuts' order, each group named at every
/// width (the user's request, 2026-11-24). As the panel narrows it steps
/// down through six arrangements, taking the first that fits its width
/// (width matters more than height, the user's call): the group names
/// beside their chips; above them, with icons and names across; short names
/// across; icons across; short names down; icons down. No shortcut badges
/// (too cluttered); the tooltips name each chip. Zoom Center and
/// Antialiasing, rarely played, are last and smaller.
struct PropertiesPanel: View {
	@EnvironmentObject private var model: AppModel

	private enum Group: CaseIterable {
		case drawing, shape, color, once, origin, quality

		var name: String {
			switch self {
			case .drawing: "Drawing"
			case .shape: "Shape"
			case .color: "Color"
			case .once: "Actions"	// was Once (the user's choice, 2026-11-24: Pause stays on)
			case .origin: "Origin"
			case .quality: "Quality"
			}
		}

		var items: [PropItem] {
			switch self {
			case .drawing: [.fill, .outline, .xor]
			case .shape: [.mirror, .convex, .reverse]
			case .color: [.invertColor, .rotateHue, .loopHue]
			case .once: [.randomPhase, .pause, .clear]	// Pause and Clear: the user's request, 2026-11-24
			case .origin: []
			case .quality: [.zoomCenter, .antialiasing]
			}
		}

		var height: CGFloat { self == .quality ? 20 : 24 }
	}

	@Environment(\.formHeight) private var paneHeight

	/// The groups a line, as few lines as the pane's height needs (the
	/// user's request, 2026-11-25: wide and short, fewer, longer rows): one
	/// group a line (6 lines), 2 (3 lines), 3 (2) or all 6 (1)
	private static let perLine = [1, 2, 3, 6]

	/// about how tall n groups a line are, padding included: a line is a
	/// group's name and its chips
	private static func height(perLine n: Int) -> CGFloat {
		let lines = CGFloat((Group.allCases.count + n - 1) / n)
		return lines * 40 + (lines - 1) * 9 + 16
	}

	var body: some View {
		// the fewest groups a line whose lines fit the pane's height (all
		// six in one line if none do); a line too wide for the width tries
		// fewer groups, taller, the pane scrolling
		let fits = Self.perLine.first { Self.height(perLine: $0) <= paneHeight } ?? 6
		let tries = Self.perLine.filter { $0 <= fits }.reversed()
		ViewThatFits(in: .horizontal) {
			ForEach(Array(tries), id: \.self) { n in
				if n > 1 {
					// icons and names, short names, then icons, n groups a line
					arrangement(.iconAndName, perLine: n)
					arrangement(.shortName, perLine: n)
					arrangement(.icon, perLine: n)
				}
			}
			// one group a line, as before: across, then down for a narrow pane
			// 1: icons and names across
			arrangement(.iconAndName, down: false)
			// 2: short names across, no icons
			arrangement(.shortName, down: false)
			// 3: icons across
			arrangement(.icon, down: false)
			// 4: short names down
			arrangement(.shortName, down: true)
			// 5: icons down, the narrowest
			arrangement(.icon, down: true)
		}
		.padding(8)
		.frame(maxWidth: .infinity, alignment: .topLeading)
	}

	/// each group's name above its chips, a row (or a column) of its own
	/// (the four groups of three were one grid of columns for a while; the
	/// user preferred each row spaced on its own, 2026-11-24)
	private func arrangement(_ label: ChipLabel, down: Bool) -> some View {
		VStack(alignment: .leading, spacing: 9) {
			ForEach(Group.allCases, id: \.self) { g in
				group(g, label, down: down)
			}
		}
	}

	/// n groups a line, side by side, each its name over its chips
	private func arrangement(_ label: ChipLabel, perLine n: Int) -> some View {
		let all = Group.allCases
		let lines = stride(from: 0, to: all.count, by: n).map { Array(all[$0..<min($0 + n, all.count)]) }
		return VStack(alignment: .leading, spacing: 9) {
			ForEach(lines.indices, id: \.self) { i in
				HStack(alignment: .top, spacing: 18) {
					ForEach(lines[i], id: \.self) { g in group(g, label, down: false) }
				}
				.fixedSize()
			}
		}
	}

	private func group(_ g: Group, _ label: ChipLabel, down: Bool) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			groupName(g)
			if down { column(g, label) } else { row(g, label) }
		}
	}

	private func groupName(_ g: Group) -> some View {
		Text(g.name.uppercased())
			.font(.system(size: 9.5, weight: .semibold))
			.tracking(0.8)
			.foregroundStyle(.secondary)
			.fixedSize()
	}

	/// a group's chips across
	@ViewBuilder private func row(_ g: Group, _ label: ChipLabel) -> some View {
		if g == .origin {
			OriginSwitch(labels: label == .iconAndName)
				.controlTip(ControlTips.originMotion)
		} else {
			HStack(spacing: 5) {
				ForEach(g.items, id: \.self) { PropChip(item: $0, label: label, height: g.height) }
			}
			.fixedSize()
		}
	}

	/// a group's chips down
	@ViewBuilder private func column(_ g: Group, _ label: ChipLabel) -> some View {
		if g == .origin {
			OriginSwitch(labels: label != .icon, vertical: true)
				.controlTip(ControlTips.originMotion)
		} else {
			VStack(alignment: .leading, spacing: 5) {
				ForEach(g.items, id: \.self) { PropChip(item: $0, label: label, height: g.height) }
			}
			.fixedSize()
		}
	}
}

// MARK: The Perform Bar's row

/// The Perform Bar's Properties row (study C; View > Show Properties in
/// Perform Bar): the switches and actions played live, in the panel's
/// groups and order, as icons only, each named and described in its
/// tooltip (the user's request, 2026-11-24), Zoom Center and Antialiasing
/// last.
struct PropertiesStrip: View {
	static let height: CGFloat = 28

	var body: some View {
		FirstClickHost(content: AnyView(PropertiesStripContent().environmentObject(AppModel.shared)))
			.frame(height: Self.height)
	}
}

private struct PropertiesStripContent: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		let _ = model.changes.main.n
		// narrowing, whole groups hide in this order (the user's choice,
		// 2026-11-24): Quality, Origin, Shape, Color, Drawing; never Actions
		PriorityBar(spacing: 4) {
			ForEach([PropItem.fill, .outline, .xor], id: \.self) { chip($0).barRank(5) }
			divider
			ForEach([PropItem.mirror, .convex, .reverse], id: \.self) { chip($0).barRank(3) }
			divider
			ForEach([PropItem.invertColor, .rotateHue, .loopHue], id: \.self) { chip($0).barRank(4) }
			divider
			chip(.randomPhase)
			chip(.pause)
			chip(.clear)
			divider
			OriginSwitch(labels: false, height: 22).barRank(2)
			divider
			chip(.zoomCenter).barRank(1)	// the user's request, 2026-11-24
			chip(.antialiasing).barRank(1)
			Spacer(minLength: 0).barFiller()
		}
		.padding(.horizontal, 8)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.clipped()	// hidden items sit out of sight (PriorityBar)
	}

	private var divider: some View {
		BarRule().padding(.horizontal, 3)
	}

	private func chip(_ item: PropItem) -> some View {
		PropChip(item: item, label: .icon, height: 22)
	}
}
