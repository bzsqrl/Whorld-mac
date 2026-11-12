// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

import SwiftUI

// Panels ported from the Windows panes: Parameters (ParamsBar,
// ParamsRowDlg), Master (MasterBar, MasterRowDlg), Globals (GlobalsBar,
// GlobalsRowDlg) and Properties (the main properties). The slider and
// edit-box math comes from the engine (WHControls).

// MARK: Components

/// How far an arrow key moves a focused slider or edit box, from its
/// modifiers: plain arrows a tenth of the control's own step (a slider
/// position, or the edit box's stepper increment), Shift ten steps, and
/// Command-Shift all the way to the end of the range.
enum KeyStep {
	case fine, coarse, end

	init?(_ flags: NSEvent.ModifierFlags) {
		let f = flags.intersection([.shift, .command, .option, .control])
		switch f {
		case []: self = .fine
		case [.shift]: self = .coarse
		case [.shift, .command]: self = .end
		default: return nil
		}
	}

	/// the step's size in the control's own steps (not for .end)
	var scale: Double { self == .fine ? 0.1 : 10 }

	/// base moved `direction` steps of `size` (scaled), on a grid of tenths
	/// of a step so repeated fine steps don't gather rounding error
	func apply(_ base: Double, size: Double, direction: Int) -> Double {
		let tenth = size / 10
		return ((base / tenth).rounded() + Double(direction) * scale * 10) * tenth
	}
}

/// Two-finger trackpad swipes on sliders and edit boxes (new in the Mac
/// port): with the pointer over a slider, a sideways swipe moves it; over an
/// edit box, a swipe up or down steps its value. A swipe belongs to the
/// control under the pointer when it begins, and only if it goes along that
/// control's axis; any other swipe scrolls as usual, even when scrolling
/// brings a control under the pointer. Mouse wheels aren't affected, and
/// the value doesn't coast after the fingers lift.
@MainActor
enum TrackpadSwipe {
	enum Axis { case horizontal, vertical }

	/// Finger travel along the axis, right or up positive, in points
	struct Travel {
		let points: Double
		let first: Bool		// the swipe's first adjustment
	}

	private static weak var candidate: NSView?	// under the pointer as the swipe began
	private static weak var owner: NSView?		// adjusting with this swipe
	private static var beganPassedOn = false	// the scroll view saw the swipe begin
	private static var monitor: Any?

	/// Starts watching for the start of each swipe (once; any control may call it).
	static func install() {
		guard monitor == nil else { return }
		monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
			if e.phase.contains(.began) || e.phase.contains(.mayBegin) {	// a new swipe: no owner yet
				candidate = nil
				owner = nil
				beganPassedOn = false
			}
			return e
		}
	}

	/// For a control's scrollWheel: the travel if the control takes this
	/// event, or nil to pass it on (super.scrollWheel). A zero travel means
	/// take the event but don't change anything.
	static func travel(_ e: NSEvent, for view: NSView, axis: Axis) -> Travel? {
		guard e.hasPreciseScrollingDeltas else { return nil }	// a mouse wheel
		if !e.momentumPhase.isEmpty {	// coasting after the fingers lift
			return owner === view ? Travel(points: 0, first: false) : nil
		}
		if e.phase.contains(.began) {
			candidate = view
		}
		if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
			// the scroll view gets the end if it got the beginning
			return owner === view && !beganPassedOn ? Travel(points: 0, first: false) : nil
		}
		let dx = Double(e.scrollingDeltaX), dy = Double(e.scrollingDeltaY)
		var first = false
		if owner !== view {
			guard candidate === view else { return nil }	// began elsewhere: scroll
			if dx == 0 && dy == 0 {	// no direction yet
				if e.phase.contains(.began) { beganPassedOn = true }
				return nil
			}
			let along = axis == .horizontal ? abs(dx) > abs(dy) : abs(dy) > abs(dx)
			guard along else {	// across the control: scroll
				candidate = nil
				if e.phase.contains(.began) { beganPassedOn = true }
				return nil
			}
			owner = view
			first = true
		}
		// with natural scrolling the deltas follow the fingers; otherwise they're reversed
		let inverted = e.isDirectionInvertedFromDevice
		let points = axis == .horizontal ? (inverted ? dx : -dx) : (inverted ? -dy : dy)
		return Travel(points: points, first: first)
	}
}

/// An edit box: shows the formatted value, and on Return or losing focus
/// parses what was typed, if anything was, as CNumEdit does (it commits only
/// if GetModify). Committing unedited text would round the value to what's
/// shown, and a panel's first field loses focus whenever another window
/// opens. While it has focus, the up and down arrows step the value (see
/// KeyStep), which does what Windows' spin buttons do; right-clicking it
/// restores `defaultValue`.
struct NumberField: View {
	let value: Double
	let format: (Double) -> String
	let parse: (String) -> Double
	let commit: (Double) -> Void
	/// the arrow keys: (value, +1 or -1, step) -> new value, clamped; .end isn't passed
	var step: ((Double, Int, KeyStep) -> Double)? = nil
	var lo: Double? = nil	// where Command-Shift-Down goes, if the range has an end there
	var hi: Double? = nil
	var defaultValue: Double? = nil
	var width: CGFloat = NumberField.standardWidth

	/// fits ten characters of %g (such as -0.0132785) in the box's font
	static let standardWidth: CGFloat = 96
	static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

	var body: some View {
		KeyTextField(value: value, format: format, parse: parse, commit: commit,
			step: step, lo: lo, hi: hi, defaultValue: defaultValue)
			.frame(width: width, height: 22)
	}
}

/// An edit box's arrow keys for a control with a stepper increment
/// (fSpinDelta), clamped to its edit range if it has one, as CNumEdit::AddSpin.
func spinStep(_ ci: WHControlInfo) -> (Double, Int, KeyStep) -> Double {
	{ v, d, k in
		var x = k.apply(v, size: ci.spinDelta, direction: d)
		if abs(x) < 1e-10 { x = 0 }	// as AddSpin: infinitesimal is zero
		if ci.editClamp.boolValue { x = min(max(x, ci.editMin), ci.editMax) }
		return x
	}
}

/// A Master row's arrow keys, for its slider and edit box alike: steps in
/// slider positions, but a fine step is never smaller than the last digit
/// the edit box shows (for Hue Span, Canvas, Copies and Spread one
/// position is one whole unit, so a tenth of one would change nothing you
/// can see), and the result is rounded to that digit.
func masterStep(_ i: Int, _ ci: WHControlInfo, _ v: Double, _ d: Int, _ k: KeyStep) -> Double {
	let p = WHControls.masterPosition(i, value: v)
	let digits = ci.editPrecision >= 0 ? Double(ci.editPrecision) : nil
	// the value of the shown last digit: the box shows value / editScale,
	// except Damping, shown inverted as a percentage, editScale - value * editScale
	// (Controls::FormatMaster)
	let inverted = i == MasterProp.damping.rawValue
	let unit = digits.map { inverted ? pow(10, -$0) / ci.editScale : pow(10, -$0) * ci.editScale }
	var pos: Double
	if k == .fine, let unit {
		// the position of the next shown value that way (log sliders: it varies)
		var next = 0.0
		for candidate in [v + unit, v - unit] {
			let q = WHControls.masterPosition(i, value: candidate)
			if q.isFinite, (q - p) * Double(d) > 0, next == 0 || abs(q - p) < next {
				next = abs(q - p)
			}
		}
		pos = next > 0.1 ? p + Double(d) * next : k.apply(p, size: 1, direction: d)
	} else {
		pos = k.apply(p, size: 1, direction: d)
	}
	pos = min(max(pos, Double(ci.rangeMin)), Double(ci.rangeMax))
	var x = WHControls.masterValue(i, position: pos)
	if let unit { x = (x / unit).rounded() * unit }
	return x
}

/// NumberField's edit box, on NSTextField: SwiftUI's TextField can't see the
/// up and down arrows (its field editor takes them), and the delegate can.
struct KeyTextField: NSViewRepresentable {
	let value: Double
	let format: (Double) -> String
	let parse: (String) -> Double
	let commit: (Double) -> Void
	let step: ((Double, Int, KeyStep) -> Double)?
	let lo: Double?
	let hi: Double?
	let defaultValue: Double?

	/// Right-clicking (or Control-clicking) restores the default, whether or
	/// not the box is being edited (then the field editor gets the click, and
	/// asks its delegate, this field, for a context menu).
	final class Field: NSTextField {
		var onReset: (() -> Bool)?
		var onSwipeStep: ((Int, KeyStep) -> Void)?	// steps up (+) or down (-)
		private var swipeTravel = 0.0
		/// finger travel per arrow-key step
		static let pointsPerStep = 2.0

		override func scrollWheel(with event: NSEvent) {
			guard onSwipeStep != nil,
				let t = TrackpadSwipe.travel(event, for: self, axis: .vertical) else {
				super.scrollWheel(with: event)
				return
			}
			if t.first { swipeTravel = 0 }
			swipeTravel += t.points
			let n = Int(swipeTravel / Self.pointsPerStep)	// whole steps, toward zero
			guard n != 0 else { return }
			swipeTravel -= Double(n) * Self.pointsPerStep
			onSwipeStep?(n, event.modifierFlags.contains(.shift) ? .coarse : .fine)
		}

		override func rightMouseDown(with event: NSEvent) {
			if onReset?() != true { super.rightMouseDown(with: event) }
		}

		override func mouseDown(with event: NSEvent) {
			if event.modifierFlags.contains(.control), onReset?() == true { return }
			super.mouseDown(with: event)
		}

		// NSTextViewDelegate, asked by the field editor
		@objc(textView:menu:forEvent:atIndex:)
		func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at index: Int) -> NSMenu? {
			onReset?() == true ? nil : menu
		}
	}

	final class Coordinator: NSObject, NSTextFieldDelegate {
		var parent: KeyTextField
		var shown = ""	// the text as last formatted: unedited if the field still says it

		init(_ parent: KeyTextField) { self.parent = parent }

		func format(_ v: Double) -> String { parent.format(v) }

		func show(_ field: NSTextField, _ v: Double) {
			shown = parent.format(v)
			field.stringValue = shown
			// the whole value, if the box is too narrow for it
			// (before the first layout, the box is assumed to hold eight characters)
			let room = field.bounds.width > 0 ? field.bounds.width - 22 : 8 * 7.2
			let fits = (shown as NSString).size(withAttributes: [.font: NumberField.font]).width <= room
			field.toolTip = fits ? nil : shown
		}

		// ported from NumEdit.cpp CNumEdit::OnKillfocus: commit only if modified
		func apply(_ field: NSTextField) {
			guard field.stringValue != shown else { return }
			let v = parent.parse(field.stringValue)
			parent.commit(v)
			show(field, v)
		}

		/// commit v and show it, keeping the text selected if editing
		func set(_ field: NSTextField, _ v: Double) {
			parent.commit(v)
			show(field, v)
			(field.currentEditor() as? NSTextView)?.selectAll(nil)
		}

		/// a trackpad swipe: n arrow-key steps from the value shown
		func swipe(_ field: NSTextField, _ n: Int, _ k: KeyStep) {
			guard let step = parent.step else { return }
			var v = field.stringValue != shown ? parent.parse(field.stringValue) : parent.parse(shown)
			for _ in 0..<abs(n) {
				v = step(v, n > 0 ? 1 : -1, k)
			}
			if field.currentEditor() != nil {
				set(field, v)
			} else {
				parent.commit(v)
				show(field, v)
			}
		}

		func reset(_ field: NSTextField) -> Bool {
			guard let v = parent.defaultValue else { return false }
			set(field, v)
			return true
		}

		func controlTextDidEndEditing(_ note: Notification) {
			if let field = note.object as? NSTextField {
				apply(field)
			}
		}

		func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
			guard let field = control as? NSTextField else { return false }
			if sel == #selector(NSResponder.insertNewline(_:)) {	// Return: apply, keep editing
				apply(field)
				textView.selectAll(nil)
				return true
			}
			// the up and down arrows, whatever the modifiers bind them to
			guard let step = parent.step, let e = NSApp.currentEvent, e.type == .keyDown,
				e.keyCode == 126 || e.keyCode == 125, let k = KeyStep(e.modifierFlags) else { return false }
			let up = e.keyCode == 126
			if k == .end {
				guard let v = up ? parent.hi : parent.lo else { NSSound.beep(); return true }
				set(field, v)
			} else {
				let base = field.stringValue != shown ? parent.parse(field.stringValue) : parent.value
				set(field, step(base, up ? 1 : -1, k))
			}
			return true
		}
	}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSTextField {
		let f = Field()
		f.bezelStyle = .roundedBezel
		f.isBezeled = true
		f.font = NumberField.font
		f.alignment = .right
		f.delegate = context.coordinator
		f.cell?.isScrollable = true
		f.cell?.lineBreakMode = .byClipping
		let c = context.coordinator
		f.onReset = { [weak f, weak c] in
			guard let f, let c else { return false }
			return c.reset(f)
		}
		if step != nil {
			TrackpadSwipe.install()
			f.onSwipeStep = { [weak f, weak c] n, k in
				guard let f, let c else { return }
				c.swipe(f, n, k)
			}
		}
		context.coordinator.show(f, value)
		return f
	}

	func updateNSView(_ f: NSTextField, context: Context) {
		let c = context.coordinator
		c.parent = self
		if let editor = f.currentEditor() as? NSTextView {
			// focused: follow outside changes (MIDI, OSC, undo) unless something
			// has been typed, keeping the text selected as focus leaves it
			if editor.string == c.shown && c.format(value) != c.shown {
				c.show(f, value)
				editor.string = c.shown
				editor.selectAll(nil)
			}
		} else if f.stringValue == c.shown || c.shown.isEmpty {	// not being edited
			c.show(f, value)
		}
	}

	func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
		CGSize(width: proposal.width ?? NumberField.standardWidth, height: 22)
	}
}

/// A slider in positions, like a Win32 trackbar: it shows norm(value) and
/// dragging sets denorm(Round(position)). Clicking it gives it focus (with
/// the system focus ring); then the left and right arrows move it (see
/// KeyStep: a tenth of a position, ten with Shift, to either end with
/// Command-Shift). Right-clicking it restores `defaultValue`.
struct PositionSlider: View {
	let value: Double
	let control: WHControlInfo
	let norm: (Double) -> Double
	let denorm: (Double) -> Double
	let commit: (Double) -> Void
	let defaultValue: Double
	/// the arrow keys, if not in plain positions: (value, +1 or -1, step) -> new value; .end isn't passed
	var step: ((Double, Int, KeyStep) -> Double)? = nil
	/// the narrowest it gets; it widens to fill its row
	var width: CGFloat = PositionSlider.minWidth

	static let minWidth: CGFloat = 120

	var body: some View {
		let lo = Double(control.rangeMin), hi = Double(control.rangeMax)
		KeySlider(position: min(max(norm(value), lo), hi), range: lo...hi,
			set: { commit(denorm($0)) },
			reset: { commit(defaultValue) },
			step: step.map { f in { d, k in commit(f(value, d, k)) } })
			.frame(minWidth: width, maxWidth: .infinity, minHeight: 18, maxHeight: 18)
	}
}

struct KeySlider: NSViewRepresentable {
	let position: Double
	let range: ClosedRange<Double>
	let set: (Double) -> Void
	let reset: () -> Void
	var step: ((Int, KeyStep) -> Void)? = nil	// replaces the plain-position step

	final class Slider: NSSlider {
		var onSet: ((Double) -> Void)?
		var onReset: (() -> Void)?
		var onStep: ((Int, KeyStep) -> Void)?
		private var swipePosition = 0.0	// unrounded, during a trackpad swipe

		override var acceptsFirstResponder: Bool { true }

		// a sideways trackpad swipe moves the knob as if dragged: the
		// slider's width of travel covers its range
		override func scrollWheel(with event: NSEvent) {
			guard let t = TrackpadSwipe.travel(event, for: self, axis: .horizontal) else {
				super.scrollWheel(with: event)
				return
			}
			if t.first { swipePosition = doubleValue }
			guard t.points != 0 else { return }
			let width = max(bounds.width, 40)
			swipePosition = min(max(swipePosition + t.points / width * (maxValue - minValue), minValue), maxValue)
			let pos = swipePosition.rounded()	// whole positions, as dragging
			if pos != doubleValue {
				doubleValue = pos
				onSet?(pos)
			}
		}
		override var canBecomeKeyView: Bool { true }

		override func mouseDown(with event: NSEvent) {
			window?.makeFirstResponder(self)	// clicking gives it focus
			if event.modifierFlags.contains(.control) {	// Control-click is a right click
				onReset?()
				return
			}
			super.mouseDown(with: event)
		}

		override func rightMouseDown(with event: NSEvent) {
			window?.makeFirstResponder(self)
			onReset?()
		}

		override func keyDown(with event: NSEvent) {
			if event.keyCode == 125 || event.keyCode == 126 { return }	// up/down: sliders move with left/right only
			guard event.keyCode == 123 || event.keyCode == 124, let k = KeyStep(event.modifierFlags) else {
				super.keyDown(with: event)
				return
			}
			let up = event.keyCode == 124	// right arrow
			if k != .end, let onStep {
				onStep(up ? 1 : -1, k)	// the view then shows the new value
				return
			}
			let pos = k == .end ? (up ? maxValue : minValue)
				: min(max(k.apply(doubleValue, size: 1, direction: up ? 1 : -1), minValue), maxValue)
			doubleValue = pos
			onSet?(pos)
		}

		@objc func changed(_ sender: Any?) {
			onSet?(doubleValue.rounded())	// dragging: whole positions
		}
	}

	func makeNSView(context: Context) -> Slider {
		let s = Slider()
		s.controlSize = .small
		s.isContinuous = true
		s.target = s
		s.action = #selector(Slider.changed(_:))
		s.focusRingType = .exterior
		TrackpadSwipe.install()
		updateNSView(s, context: context)
		return s
	}

	func updateNSView(_ s: Slider, context: Context) {
		s.onSet = set
		s.onReset = reset
		s.onStep = step
		if s.minValue != range.lowerBound || s.maxValue != range.upperBound {
			s.minValue = range.lowerBound
			s.maxValue = range.upperBound
		}
		if abs(s.doubleValue - position) > 1e-6 {
			s.doubleValue = position
		}
	}

	func sizeThatFits(_ proposal: ProposedViewSize, nsView: Slider, context: Context) -> CGSize? {
		CGSize(width: proposal.width ?? PositionSlider.minWidth, height: 18)
	}
}

// MARK: Control tips

/// Hover help on the controls' names (Mac addition; Settings > General >
/// Show tips on control names). Condensed from Whorld's help: the
/// Parameters, Master Controls and Effects pages.
enum ControlTips {
	/// in parameter order (WhorldDef.h PARAMDEF)
	static let params = [
		"How fast rings grow, in pixels per frame; it also sets how often new rings are born. Negative values make rings grow inward from the edges.",
		"The gap between rings, in pixels. Wider spacing means fewer rings, which helps with wide lines or Fill.",
		"The width of each ring's line, in pixels.",
		"The number of sides each ring has, from 3 (a triangle) to 50 (nearly a circle).",
		"How much each ring turns per frame, in degrees; positive is counterclockwise.",
		"Stretches rings sideways (positive) or upright (negative): 1 doubles the width, 2 quadruples it.",
		"How far each ring's center drifts per frame, in pixels, for depth like a tunnel. Skew Angle sets the direction.",
		"The direction rings' centers drift (see Skew Radius), in degrees: 0 is down, 90 is right.",
		"Pushes every other corner out or in, turning polygons into stars (positive) or pinched shapes (negative).",
		"Turns the star points to make pinwheel or turbine shapes; use it with Star Factor.",
		"How fast the ring color cycles around the hue wheel, in degrees per frame.",
		"The rings' lightness, from 0 (black) to 1 (white).",
		"The rings' saturation, from 0 (gray) to 1 (full color).",
		"The rings' opacity, from 0 (invisible) to 1 (solid).",
		"The background's hue, in degrees. The background color also outlines rings in Outline mode.",
		"The background's lightness, from 0 (black) to 1 (white).",
		"The background's saturation, from 0 (gray) to 1 (full color).",
		"The background's opacity, from 0 (transparent, e.g. over Syphon) to 1 (solid).",
		"Curves the sides at the even corners (those Star Factor doesn't move): positive bulges, negative loops.",
		"Curves the sides at the odd corners (the star points): positive bulges, negative loops.",
		"Makes the curves at the even corners lopsided; needs Even Curve.",
		"Makes the curves at the odd corners lopsided; needs Odd Curve.",
	]

	/// a Globals row: the parameter, for every ring
	static func global(_ iParam: Int) -> String {
		params[iParam] + " Here it changes every ring at once, not just new ones."
	}

	/// in master property order (WhorldDef.h MASTERDEF)
	static let master = [
		"The speed of the whole animation, as a percentage of normal. Pause stops it.",
		"Magnifies the picture, as a percentage of normal; Damping smooths it.",
		"Smooths origin movement, zoom and globals: higher is more fluid but slower to respond.",
		"How far rings lag behind a moving origin: 0 keeps them together, higher makes a slinky trail.",
		"The most rings at once; beyond it the oldest disappear. At the maximum, rings live until they leave the canvas.",
		"Beats per minute: how often the origin jumps when Origin Motion is Random.",
		"With Loop Hue on, the size of the range of hues rings cycle through, in degrees.",
		"The area rings live in, as a percentage of the window; a ring vanishes once it's wholly outside it.",
		"Draws several groups of rings, evenly spaced in a circle around the origin (see Spread).",
		"How far the Copies sit from the origin, in pixels.",
		"Old rings fade out over this many rings before the Rings limit removes them; 0 is off.",
	]

	static let hue = "Shifts the color of new rings, in degrees (and the looped range, with Loop Hue). Rotate Hue (F3) also turns existing rings."
	static let fill = "Fills the space between rings with color instead of drawing lines. Affects new rings."
	static let outline = "Outlines filled rings in the background color, for a faceted look. Affects new rings."
	static let mirror = "Mirrors the top-left quarter of the picture into the other three, like a kaleidoscope."
	static let reverse = "Reverses ring growth: expanding rings start contracting, and contracting rings expand."
	static let convex = "Draws the smallest rings last, so filled rings look like a worm rather than a tunnel."
	static let loopHue = "Limits color cycling to a range of hues (Master > Hue Span) instead of the whole wheel."
	static let zoomCenter = "Zooms about the window's center instead of the origin."
	static let antialiasing = "Smooths jagged edges; off is faster, with a crisper, pixelated look."
	static let invertColor = "Shows the rings as a color negative (hue and lightness flip); the background is unchanged."
	static let originMotion = "How the origin (the rings' center) moves: Center, Drag (follows the mouse), Random (jumps in time with Tempo), or Park (stays put)."
}

/// A control name's tip, while Settings > General > Show tips on control
/// names is on: on the name only, not its slider, box or checkbox.
private struct ControlTip: ViewModifier {
	let text: String
	@AppStorage("General_bControlTips") private var on = true

	func body(content: Content) -> some View {
		if on {
			content.help(text)
		} else {
			content
		}
	}
}

extension View {
	func controlTip(_ text: String) -> some View { modifier(ControlTip(text: text)) }
}

// MARK: Parameters

struct ParamsPanel: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		// The workspace (or a floating window) scrolls it, both ways.
		Group {
			// Rows of fixed-width columns, not a Grid: a Grid measures every
			// cell again whenever one changes, about 10 ms per update here.
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: ParamColumn.spacing) {
					Text("Name").frame(width: ParamColumn.name, alignment: .leading)
					Text("Value").frame(minWidth: ParamColumn.slider, maxWidth: .infinity, alignment: .leading)	// over the slider, which stretches
					Color.clear.frame(width: ParamColumn.field, height: 1)
					Text("Waveform").frame(width: ParamColumn.wave, alignment: .leading)
					Text("Amplitude").frame(width: ParamColumn.field, alignment: .leading)
					Text("Frequency").frame(width: ParamColumn.field, alignment: .leading)
					Text("Pulse Width").frame(width: ParamColumn.pw, alignment: .leading)
				}
				.font(.caption)
				.foregroundStyle(.secondary)
				ForEach(0..<WHControls.paramCount, id: \.self) { i in
					ParamRow(iParam: i)
				}
			}
			.padding(10)
		}
	}
}

/// The Parameters panel's column widths. The slider stretches to fill the
/// pane; the rest keep these widths.
enum ParamColumn {
	static let spacing: CGFloat = 8
	static let name: CGFloat = 96
	static let slider: CGFloat = PositionSlider.minWidth	// the narrowest; it stretches
	static let field: CGFloat = 96
	static let wave: CGFloat = 104
	static let pw: CGFloat = 70
	/// the narrowest the panel gets: every column, the gaps, the padding
	static let panelMin: CGFloat = name + slider + field + wave + field + field + pw + 6 * spacing + 20
}

struct ParamRow: View {
	@EnvironmentObject private var model: AppModel
	let iParam: Int

	private func control(_ col: Int) -> WHControlInfo {
		WHControls.paramControl(iParam, column: col)
	}

	private func field(_ prop: WHParamProperty, column: Int, width: CGFloat = NumberField.standardWidth) -> some View {
		let ci = control(column)
		let bounded = ci.editClamp.boolValue
		return NumberField(
			value: model.engine.paramValue(iParam, property: prop),
			format: { WHControls.format($0, control: ci) },
			parse: { WHControls.parse($0, control: ci) },
			commit: { model.setParam(iParam, prop, $0) },
			step: spinStep(ci),
			lo: bounded ? ci.editMin : nil,
			hi: bounded && ci.editMax < Double(Int32.max) ? ci.editMax : nil,	// not Frequency's INT_MAX
			defaultValue: WHControls.paramDefault(iParam, column: column),
			width: width)
	}

	var body: some View {
		let _ = model.changes.params[iParam].n	// redraw for this row's changes only
		let e = model.engine
		HStack(spacing: ParamColumn.spacing) {
			Text(WHControls.paramName(iParam))
				.lineLimit(1)
				.controlTip(ControlTips.params[iParam])
				.frame(width: ParamColumn.name, alignment: .leading)
			PositionSlider(
				value: e.paramValue(iParam, property: .val),
				control: control(0),
				norm: { WHControls.paramPosition(iParam, value: $0) },
				denorm: { WHControls.paramValue(iParam, position: $0) },
				commit: { model.setParam(iParam, .val, $0) },
				defaultValue: WHControls.paramDefault(iParam, column: 0),
				width: ParamColumn.slider)
			field(.val, column: 0)
				.frame(width: ParamColumn.field, alignment: .leading)
			Picker("", selection: Binding(
				get: { Int(e.paramValue(iParam, property: .wave)) },
				set: { model.setParam(iParam, .wave, Double($0)) })) {
				ForEach(0..<WHControls.waveformCount, id: \.self) { w in
					Text(WHControls.waveformName(w)).tag(w)
				}
			}
			.labelsHidden()
			.frame(width: ParamColumn.wave)
			field(.amp, column: 1)
				.frame(width: ParamColumn.field, alignment: .leading)
			field(.freq, column: 2)
				.frame(width: ParamColumn.field, alignment: .leading)
			field(.PW, column: 3, width: 70)
				.frame(width: ParamColumn.pw, alignment: .leading)
		}
	}
}

// MARK: Master

struct MasterPanel: View {
	/// the narrowest the panel gets (name, slider, number box, gaps, padding)
	static let minWidth: CGFloat = 72 + PositionSlider.minWidth + NumberField.standardWidth + 16 + 24

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {	// rows of fixed columns around a stretching slider
			ForEach(0..<WHControls.masterCount, id: \.self) { i in
				MasterRow(i: i)
				if i == MasterProp.hueSpan.rawValue {
					HueRow()	// after Hue Span: the two shape the colors
				}
			}
		}
		.padding(12)
	}
}

struct MasterRow: View {
	@EnvironmentObject private var model: AppModel
	let i: Int

	var body: some View {
		let _ = model.changes.master[i].n	// redraw for this row's changes only
		let ci = WHControls.masterControl(i)
		let value = model.engine.masterValue(i)
		HStack(spacing: 8) {
			Text(WHControls.masterName(i))
				.lineLimit(1)
				.controlTip(ControlTips.master[i])
				.frame(width: 72, alignment: .leading)
			PositionSlider(
				value: value,
				control: ci,
				norm: { WHControls.masterPosition(i, value: $0) },
				denorm: { WHControls.masterValue(i, position: $0) },
				commit: { model.setMaster(i, $0) },
				defaultValue: WHControls.masterDefault(i),
				step: { masterStep(i, ci, $0, $1, $2) })
			NumberField(
				value: value,
				format: { WHControls.formatMaster(i, value: $0) },
				parse: { WHControls.parseMaster(i, text: $0) },
				commit: { model.setMaster(i, $0) },
				step: { masterStep(i, ci, $0, $1, $2) },	// no stepper: as the slider
				lo: WHControls.masterValue(i, position: Double(ci.rangeMin)),
				hi: WHControls.masterValue(i, position: Double(ci.rangeMax)),
				defaultValue: WHControls.masterDefault(i))
		}
	}
}

/// Master's Hue row (Mac addition, V1's Hue): the patch's Hue main
/// property, 0 to 360 degrees, offsetting the hue of new rings. Image >
/// Rotate Hue adds 90 to it.
struct HueRow: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		let _ = model.changes.main.n
		let value = model.engine.hue
		let step: (Double, Int, KeyStep) -> Double = { v, d, k in
			min(max(k.apply(v, size: 10, direction: d), 0), 360)	// a degree, ten with Shift
		}
		HStack(spacing: 8) {
			Text("Hue")
				.lineLimit(1)
				.controlTip(ControlTips.hue)
				.frame(width: 72, alignment: .leading)
			KeySlider(position: min(max(value, 0), 360), range: 0...360,
				set: { model.setHue($0) },
				reset: { model.setHue(0) },
				step: { d, k in model.setHue(step(value, d, k)) })
				.frame(minWidth: PositionSlider.minWidth, maxWidth: .infinity, minHeight: 18, maxHeight: 18)
			NumberField(
				value: value,
				format: { String(format: "%.1f", $0) },
				parse: { min(max(Double($0.trimmingCharacters(in: .whitespaces)) ?? value, 0), 360) },
				commit: { model.setHue($0) },
				step: step,
				lo: 0,
				hi: 360,
				defaultValue: 0)
		}
	}
}

// MARK: Globals

struct GlobalsPanel: View {
	/// the narrowest the panel gets (name, slider, number box, gaps, padding)
	static let minWidth: CGFloat = 96 + PositionSlider.minWidth + NumberField.standardWidth + 16 + 24

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {	// rows of fixed columns around a stretching slider
			ForEach(0..<WHControls.globalCount, id: \.self) { g in
				GlobalRow(i: WHControls.param(forGlobal: g))
			}
		}
		.padding(12)
	}
}

struct GlobalRow: View {
	@EnvironmentObject private var model: AppModel
	let i: Int	// parameter index

	var body: some View {
		let _ = model.changes.params[i].n	// redraw for this row's changes only
		let ci = WHControls.globalControl(i)
		let value = model.engine.paramValue(i, property: .global)
		HStack(spacing: 8) {
			Text(WHControls.paramName(i))
				.lineLimit(1)
				.controlTip(ControlTips.global(i))
				.frame(width: 96, alignment: .leading)
			PositionSlider(
				value: value,
				control: ci,
				norm: { WHControls.globalPosition(i, value: $0) },
				denorm: { WHControls.globalValue(i, position: $0) },
				commit: { model.setParam(i, .global, $0) },
				defaultValue: WHControls.paramDefault(i, column: 4))
			NumberField(
				value: value,
				format: { WHControls.format($0, control: ci) },
				parse: { WHControls.parse($0, control: ci) },
				commit: { model.setParam(i, .global, $0) },
				step: spinStep(ci),
				lo: ci.editMin,
				hi: ci.editMax,
				defaultValue: WHControls.paramDefault(i, column: 4))
		}
	}
}

// MARK: Properties (main properties)

/// The Properties panel: the Image menu's items, in its order, compactly.
/// Origin Center, Drag and Random are one Origin Motion menu, with Park.
/// Clicking a row gives it focus; the up and down arrows move the focus
/// through the list (wrapping), and Space toggles the focused row's
/// checkbox, steps Origin Motion, or presses Random Phase.
/// The top of the Properties panel (Mac addition): the patch's name, and
/// its author if it names one.
private struct PatchCredit: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		let _ = model.changes.document.n
		let author = model.engine.patchAuthor
		VStack(alignment: .leading, spacing: 1) {
			Text(model.title)
				.fontWeight(.semibold)
				.lineLimit(1)
				.truncationMode(.middle)
			Text(author.isEmpty ? "No author" : "by " + author)
				.foregroundStyle(.secondary)
				.lineLimit(2)
		}
		.padding(.horizontal, 4)
		.padding(.vertical, 2)
		.frame(maxWidth: .infinity, alignment: .leading)
		.help(author.isEmpty ? "File > Patch Author… names the patch's author" : "")
	}
}

struct PropertiesPanel: View {
	@EnvironmentObject private var model: AppModel

	/// Origin Motion as the panel shows it. Center isn't a motion: it's Park
	/// with the origin in the middle (Image > Origin Center).
	private enum OriginChoice: Hashable, CaseIterable { case center, drag, random, park }

	private enum Row: Hashable, CaseIterable {
		case fill, outline, mirror, reverse, convex, loopHue, zoomCenter, antialiasing, invertColor
		case origin, randomPhase
	}

	@FocusState private var focus: Row?
	/// Rows take focus only once one is clicked (until focus leaves them):
	/// otherwise SwiftUI gives the first one focus when the window opens, and
	/// Space would toggle Fill instead of pausing.
	@State private var armed = false
	@State private var window = WeakWindow()

	final class WeakWindow { weak var window: NSWindow? }

	var body: some View {
		let _ = model.changes.main.n
		let e = model.engine
		VStack(alignment: .leading, spacing: 1) {
			PatchCredit()
			divider
			check(.fill, "Fill", e.fill)
			check(.outline, "Outline", e.outline)
			check(.mirror, WHControls.mainName(MainProp.mirror.rawValue), model.isOn(.mirror))
			divider
			check(.reverse, WHControls.mainName(MainProp.reverse.rawValue), model.isOn(.reverse))
			check(.convex, WHControls.mainName(MainProp.convex.rawValue), model.isOn(.convex))
			check(.loopHue, WHControls.mainName(MainProp.loopHue.rawValue), model.isOn(.loopHue))
			check(.zoomCenter, WHControls.mainName(MainProp.zoomCenter.rawValue), model.isOn(.zoomCenter))
			check(.antialiasing, WHControls.mainName(MainProp.antialiasing.rawValue), model.isOn(.antialiasing))
			check(.invertColor, WHControls.mainName(MainProp.invertColor.rawValue), model.isOn(.invertColor))
			divider
			row(.origin) {
				HStack(spacing: 6) {
					Text(WHControls.mainName(MainProp.orgMotion.rawValue))
						.controlTip(ControlTips.originMotion)
					Picker("", selection: Binding(
						get: { originChoice(e) },
						set: { setOrigin($0) })) {
						Text("Center").tag(OriginChoice.center)
						Text("Drag").tag(OriginChoice.drag)
						Text("Random").tag(OriginChoice.random)
						Text("Park").tag(OriginChoice.park)
					}
					.labelsHidden()
					.fixedSize()
				}
			}
			divider
			row(.randomPhase) {
				Button("Random Phase") { e.randomPhase() }
			}
		}
		.controlSize(.small)
		.padding(6)
		.fixedSize(horizontal: false, vertical: true)	// as wide as its pane (rows and dividers stretch); compact in height
		.background(MainWindowObserver { window.window = $0 })
		.onChange(of: focus) { _, row in	// Space: see AppModel.keyboardSpaceAction
			if row == nil {
				armed = false
			}
			if let row {
				let w = window
				model.keyboardSpaceAction = { [weak w] in
					guard let win = w?.window, NSApp.keyWindow === win else { return false }
					activate(row)
					return true
				}
			} else {
				model.keyboardSpaceAction = nil
			}
		}
	}

	private var divider: some View {
		Divider().padding(.vertical, 2)
	}

	/// A row: clicking anywhere in it gives it focus, shown by a highlight.
	private func row<Content: View>(_ r: Row, @ViewBuilder _ content: () -> Content) -> some View {
		content()
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 4)
			.padding(.vertical, 1)
			.background(focus == r ? Color.accentColor.opacity(0.28) : Color.clear,
				in: RoundedRectangle(cornerRadius: 3))
			.contentShape(Rectangle())
			.focusable(armed)
			.focused($focus, equals: r)
			.focusEffectDisabled()
			.simultaneousGesture(TapGesture().onEnded {
				armed = true
				focus = r
				DispatchQueue.main.async { focus = r }	// again, once it's focusable
			})
			.onKeyPress(.upArrow) { moveFocus(r, -1) }
			.onKeyPress(.downArrow) { moveFocus(r, 1) }
			.onKeyPress(.space) { activate(r); return .handled }
	}

	private func check(_ r: Row, _ title: String, _ isOn: Bool) -> some View {
		row(r) {
			Toggle(isOn: Binding(get: { isOn }, set: { _ in activate(r) })) {
				Text(title).controlTip(tip(r))	// the name, not the checkbox
			}
				.toggleStyle(.checkbox)
				.focusable(false)	// the row has the focus, not the checkbox
		}
	}

	private func tip(_ r: Row) -> String {
		switch r {
		case .fill: ControlTips.fill
		case .outline: ControlTips.outline
		case .mirror: ControlTips.mirror
		case .reverse: ControlTips.reverse
		case .convex: ControlTips.convex
		case .loopHue: ControlTips.loopHue
		case .zoomCenter: ControlTips.zoomCenter
		case .antialiasing: ControlTips.antialiasing
		case .invertColor: ControlTips.invertColor
		case .origin: ControlTips.originMotion
		case .randomPhase: ""
		}
	}

	private func moveFocus(_ r: Row, _ d: Int) -> KeyPress.Result {
		let all = Row.allCases
		guard let i = all.firstIndex(of: r) else { return .ignored }
		focus = all[(i + d + all.count) % all.count]
		return .handled
	}

	/// Space on a row (or clicking its checkbox)
	private func activate(_ r: Row) {
		switch r {
		case .fill: model.toggleFill()
		case .outline: model.toggleOutline()
		case .mirror: model.toggle(.mirror)
		case .reverse: model.toggle(.reverse)
		case .convex: model.toggle(.convex)
		case .loopHue: model.toggle(.loopHue)
		case .zoomCenter: model.toggle(.zoomCenter)
		case .antialiasing: model.toggle(.antialiasing)
		case .invertColor: model.toggle(.invertColor)
		case .origin:
			let all = OriginChoice.allCases
			let i = all.firstIndex(of: originChoice(model.engine)) ?? 0
			setOrigin(all[(i + 1) % all.count])
		case .randomPhase: model.engine.randomPhase()
		}
	}

	private func originChoice(_ e: WHEngine) -> OriginChoice {
		switch e.originMotion {
		case .drag: return .drag
		case .random: return .random
		default: return e.origin == CGPoint(x: 0.5, y: 0.5) ? .center : .park
		}
	}

	private func setOrigin(_ c: OriginChoice) {
		switch c {
		case .center: model.originCenter()
		case .drag: model.setOriginMotion(.drag)
		case .random: model.setOriginMotion(.random)
		case .park: model.setOriginMotion(.park)
		}
	}
}
