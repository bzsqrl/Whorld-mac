// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
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

/// An edit box: shows the formatted value, and on Return or losing focus
/// parses what was typed, if anything was, as CNumEdit does (it commits only
/// if GetModify). Committing unedited text would round the value to what's
/// shown, and a panel's first field loses focus whenever another window
/// opens. Optional stepper (spin control). While it has focus, the up and
/// down arrows step the value (see KeyStep); right-clicking it restores
/// `defaultValue`.
struct NumberField: View {
	let value: Double
	let format: (Double) -> String
	let parse: (String) -> Double
	let commit: (Double) -> Void
	var spin: ((Double, Int) -> Double)? = nil	// the stepper
	/// the arrow keys: (value, +1 or -1, step) -> new value, clamped; .end isn't passed
	var step: ((Double, Int, KeyStep) -> Double)? = nil
	var lo: Double? = nil	// where Command-Shift-Down goes, if the range has an end there
	var hi: Double? = nil
	var defaultValue: Double? = nil
	var width: CGFloat = 72

	var body: some View {
		HStack(spacing: 2) {
			KeyTextField(value: value, format: format, parse: parse, commit: commit,
				step: step, lo: lo, hi: hi, defaultValue: defaultValue)
				.frame(width: width, height: 22)
			if let spin {
				Stepper("", onIncrement: { commit(spin(value, 1)) }, onDecrement: { commit(spin(value, -1)) })
					.labelsHidden()
					.controlSize(.mini)
			}
		}
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

		func show(_ field: NSTextField, _ v: Double) {
			shown = parent.format(v)
			field.stringValue = shown
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
		f.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
		f.alignment = .right
		f.delegate = context.coordinator
		f.cell?.isScrollable = true
		f.cell?.lineBreakMode = .byClipping
		let c = context.coordinator
		f.onReset = { [weak f, weak c] in
			guard let f, let c else { return false }
			return c.reset(f)
		}
		context.coordinator.show(f, value)
		return f
	}

	func updateNSView(_ f: NSTextField, context: Context) {
		let c = context.coordinator
		c.parent = self
		if f.currentEditor() == nil, f.stringValue == c.shown || c.shown.isEmpty {	// not being edited
			c.show(f, value)
		}
	}

	func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
		CGSize(width: proposal.width ?? 72, height: 22)
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
	var width: CGFloat = 160

	var body: some View {
		let lo = Double(control.rangeMin), hi = Double(control.rangeMax)
		KeySlider(position: min(max(norm(value), lo), hi), range: lo...hi,
			set: { commit(denorm($0)) },
			reset: { commit(defaultValue) },
			step: step.map { f in { d, k in commit(f(value, d, k)) } })
			.frame(width: width, height: 18)
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

		override var acceptsFirstResponder: Bool { true }
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
		CGSize(width: proposal.width ?? 160, height: 18)
	}
}

// MARK: Parameters

struct ParamsPanel: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		ScrollView {
			// Rows of fixed-width columns, not a Grid: a Grid measures every
			// cell again whenever one changes, about 10 ms per update here.
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: ParamColumn.spacing) {
					Text("Name").frame(width: ParamColumn.name, alignment: .leading)
					Text("Value").frame(width: ParamColumn.slider + ParamColumn.spacing + ParamColumn.field, alignment: .leading)
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
		.frame(minWidth: 800, minHeight: 300)
	}
}

/// The Parameters panel's column widths (a number box with its stepper).
enum ParamColumn {
	static let spacing: CGFloat = 8
	static let name: CGFloat = 96
	static let slider: CGFloat = 160
	static let field: CGFloat = 90
	static let wave: CGFloat = 104
	static let pw: CGFloat = 70
}

struct ParamRow: View {
	@EnvironmentObject private var model: AppModel
	let iParam: Int

	private func control(_ col: Int) -> WHControlInfo {
		WHControls.paramControl(iParam, column: col)
	}

	private func field(_ prop: WHParamProperty, column: Int, width: CGFloat = 72) -> some View {
		let ci = control(column)
		let bounded = ci.editClamp.boolValue
		return NumberField(
			value: model.engine.paramValue(iParam, property: prop),
			format: { WHControls.format($0, control: ci) },
			parse: { WHControls.parse($0, control: ci) },
			commit: { model.setParam(iParam, prop, $0) },
			spin: { WHControls.spin($0, control: ci, direction: $1) },
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
			field(.PW, column: 3, width: 52)
				.frame(width: ParamColumn.pw, alignment: .leading)
		}
	}
}

// MARK: Master

struct MasterPanel: View {
	var body: some View {
		Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
			ForEach(0..<WHControls.masterCount, id: \.self) { i in
				MasterRow(i: i)
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
		GridRow {
			Text(WHControls.masterName(i))
				.frame(minWidth: 72, alignment: .leading)
			PositionSlider(
				value: value,
				control: ci,
				norm: { WHControls.masterPosition(i, value: $0) },
				denorm: { WHControls.masterValue(i, position: $0) },
				commit: { model.setMaster(i, $0) },
				defaultValue: WHControls.masterDefault(i),
				step: { masterStep(i, ci, $0, $1, $2) },
				width: 200)
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

// MARK: Globals

struct GlobalsPanel: View {
	var body: some View {
		Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
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
		GridRow {
			Text(WHControls.paramName(i))
				.frame(minWidth: 96, alignment: .leading)
			PositionSlider(
				value: value,
				control: ci,
				norm: { WHControls.globalPosition(i, value: $0) },
				denorm: { WHControls.globalValue(i, position: $0) },
				commit: { model.setParam(i, .global, $0) },
				defaultValue: WHControls.paramDefault(i, column: 4),
				width: 200)
			NumberField(
				value: value,
				format: { WHControls.format($0, control: ci) },
				parse: { WHControls.parse($0, control: ci) },
				commit: { model.setParam(i, .global, $0) },
				spin: { WHControls.spin($0, control: ci, direction: $1) },
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
		.fixedSize()
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
			Toggle(title, isOn: Binding(get: { isOn }, set: { _ in activate(r) }))
				.toggleStyle(.checkbox)
				.focusable(false)	// the row has the focus, not the checkbox
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
