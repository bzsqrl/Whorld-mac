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

/// An edit box: shows the formatted value, and on Return or losing focus
/// parses what was typed, if anything was, as CNumEdit does (it commits only
/// if GetModify). Committing unedited text would round the value to what's
/// shown, and a panel's first field loses focus whenever another window
/// opens. Optional stepper (spin control). While it has focus, the up and
/// down arrows step the value: by the stepper's increment, or by `step`.
struct NumberField: View {
	let value: Double
	let format: (Double) -> String
	let parse: (String) -> Double
	let commit: (Double) -> Void
	var spin: ((Double, Int) -> Double)? = nil
	/// the arrow keys' step where there's no stepper: (value, +1 or -1) -> new value
	var step: ((Double, Int) -> Double)? = nil
	var width: CGFloat = 72

	var body: some View {
		HStack(spacing: 2) {
			KeyTextField(value: value, format: format, parse: parse, commit: commit, step: spin ?? step)
				.frame(width: width, height: 22)
			if let spin {
				Stepper("", onIncrement: { commit(spin(value, 1)) }, onDecrement: { commit(spin(value, -1)) })
					.labelsHidden()
					.controlSize(.mini)
			}
		}
	}
}

/// NumberField's edit box, on NSTextField: SwiftUI's TextField can't see the
/// up and down arrows (its field editor takes them), and the delegate can.
struct KeyTextField: NSViewRepresentable {
	let value: Double
	let format: (Double) -> String
	let parse: (String) -> Double
	let commit: (Double) -> Void
	let step: ((Double, Int) -> Double)?

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

		func controlTextDidEndEditing(_ note: Notification) {
			if let field = note.object as? NSTextField {
				apply(field)
			}
		}

		func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
			guard let field = control as? NSTextField else { return false }
			switch sel {
			case #selector(NSResponder.insertNewline(_:)):	// Return: apply, keep editing
				apply(field)
				textView.selectAll(nil)
				return true
			case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
				guard let step = parent.step else { return false }
				let base = field.stringValue != shown ? parent.parse(field.stringValue) : parent.value
				let v = step(base, sel == #selector(NSResponder.moveUp(_:)) ? 1 : -1)
				parent.commit(v)
				show(field, v)
				textView.selectAll(nil)
				return true
			default:
				return false
			}
		}
	}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSTextField {
		let f = NSTextField()
		f.bezelStyle = .roundedBezel
		f.isBezeled = true
		f.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
		f.alignment = .right
		f.delegate = context.coordinator
		f.cell?.isScrollable = true
		f.cell?.lineBreakMode = .byClipping
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

/// A slider in integer positions, like a Win32 trackbar: it shows
/// Round(norm(value)) and sets denorm(position). Clicking it gives it focus
/// (with the system focus ring); then the left and right arrows move it a
/// position at a time (a trackbar's line size).
struct PositionSlider: View {
	let value: Double
	let control: WHControlInfo
	let norm: (Double) -> Double
	let denorm: (Double) -> Double
	let commit: (Double) -> Void
	var width: CGFloat = 160

	var body: some View {
		let lo = Double(control.rangeMin), hi = Double(control.rangeMax)
		KeySlider(position: min(max(norm(value).rounded(.toNearestOrEven), lo), hi), range: lo...hi,
			set: { commit(denorm($0)) },
			reset: { commit(denorm(Double(control.defaultPos))) })
			.frame(width: width, height: 18)
	}
}

struct KeySlider: NSViewRepresentable {
	let position: Double
	let range: ClosedRange<Double>
	let set: (Double) -> Void
	let reset: () -> Void

	final class Slider: NSSlider {
		var onSet: ((Double) -> Void)?
		var onReset: (() -> Void)?

		override var acceptsFirstResponder: Bool { true }
		override var canBecomeKeyView: Bool { true }

		override func mouseDown(with event: NSEvent) {
			window?.makeFirstResponder(self)	// clicking gives it focus
			super.mouseDown(with: event)
		}

		override func keyDown(with event: NSEvent) {
			switch event.keyCode {
			case 123: step(-1)	// left arrow
			case 124: step(1)	// right arrow
			default: super.keyDown(with: event)
			}
		}

		private func step(_ d: Double) {
			let pos = min(max(doubleValue.rounded() + d, minValue), maxValue)
			doubleValue = pos
			onSet?(pos)
		}

		@objc func changed(_ sender: Any?) {
			onSet?(doubleValue.rounded())
		}

		@objc func resetToDefault(_ sender: Any?) {
			onReset?()
		}
	}

	func makeNSView(context: Context) -> Slider {
		let s = Slider()
		s.controlSize = .small
		s.isContinuous = true
		s.target = s
		s.action = #selector(Slider.changed(_:))
		s.focusRingType = .exterior
		let menu = NSMenu()
		let item = NSMenuItem(title: "Reset to Default", action: #selector(Slider.resetToDefault(_:)), keyEquivalent: "")
		item.target = s
		menu.addItem(item)
		s.menu = menu
		updateNSView(s, context: context)
		return s
	}

	func updateNSView(_ s: Slider, context: Context) {
		s.onSet = set
		s.onReset = reset
		if s.minValue != range.lowerBound || s.maxValue != range.upperBound {
			s.minValue = range.lowerBound
			s.maxValue = range.upperBound
		}
		if s.doubleValue.rounded() != position {
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
		let _ = model.revision
		ScrollView {
			Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
				GridRow {
					Text("Name"); Text("Value"); Text(""); Text("Waveform"); Text("Amplitude"); Text("Frequency"); Text("Pulse Width")
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

struct ParamRow: View {
	@EnvironmentObject private var model: AppModel
	let iParam: Int

	private func control(_ col: Int) -> WHControlInfo {
		WHControls.paramControl(iParam, column: col)
	}

	private func field(_ prop: WHParamProperty, column: Int, width: CGFloat = 72) -> some View {
		let ci = control(column)
		return NumberField(
			value: model.engine.paramValue(iParam, property: prop),
			format: { WHControls.format($0, control: ci) },
			parse: { WHControls.parse($0, control: ci) },
			commit: { model.setParam(iParam, prop, $0) },
			spin: { WHControls.spin($0, control: ci, direction: $1) },
			width: width)
	}

	var body: some View {
		let e = model.engine
		GridRow {
			Text(WHControls.paramName(iParam))
				.frame(minWidth: 96, alignment: .leading)
			PositionSlider(
				value: e.paramValue(iParam, property: .val),
				control: control(0),
				norm: { WHControls.paramPosition(iParam, value: $0) },
				denorm: { WHControls.paramValue(iParam, position: $0) },
				commit: { model.setParam(iParam, .val, $0) })
			field(.val, column: 0)
			Picker("", selection: Binding(
				get: { Int(e.paramValue(iParam, property: .wave)) },
				set: { model.setParam(iParam, .wave, Double($0)) })) {
				ForEach(0..<WHControls.waveformCount, id: \.self) { w in
					Text(WHControls.waveformName(w)).tag(w)
				}
			}
			.labelsHidden()
			.frame(width: 104)
			field(.amp, column: 1)
			field(.freq, column: 2)
			field(.PW, column: 3, width: 52)
		}
	}
}

// MARK: Master

struct MasterPanel: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		let _ = model.revision
		Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
			ForEach(0..<WHControls.masterCount, id: \.self) { i in
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
						width: 200)
					NumberField(
						value: value,
						format: { WHControls.formatMaster(i, value: $0) },
						parse: { WHControls.parseMaster(i, text: $0) },
						commit: { model.setMaster(i, $0) },
						step: { v, d in	// no stepper: a slider position
							let pos = WHControls.masterPosition(i, value: v).rounded() + Double(d)
							return WHControls.masterValue(i, position: min(max(pos, Double(ci.rangeMin)), Double(ci.rangeMax)))
						})
				}
			}
		}
		.padding(12)
	}
}

// MARK: Globals

struct GlobalsPanel: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		let _ = model.revision
		Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
			ForEach(0..<WHControls.globalCount, id: \.self) { g in
				let i = WHControls.param(forGlobal: g)
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
						width: 200)
					NumberField(
						value: value,
						format: { WHControls.format($0, control: ci) },
						parse: { WHControls.parse($0, control: ci) },
						commit: { model.setParam(i, .global, $0) },
						spin: { WHControls.spin($0, control: ci, direction: $1) })
				}
			}
		}
		.padding(12)
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
		let _ = model.revision
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
