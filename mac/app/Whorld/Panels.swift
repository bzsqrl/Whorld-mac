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
/// opens. Optional stepper (spin control).
struct NumberField: View {
	let value: Double
	let format: (Double) -> String
	let parse: (String) -> Double
	let commit: (Double) -> Void
	var spin: ((Double, Int) -> Double)? = nil
	var width: CGFloat = 72

	@State private var text = ""
	@State private var shown = ""	// the text as last formatted: unedited if text equals it
	@FocusState private var focused: Bool

	var body: some View {
		HStack(spacing: 2) {
			TextField("", text: $text)
				.textFieldStyle(.roundedBorder)
				.font(.system(.body, design: .monospaced))
				.multilineTextAlignment(.trailing)
				.frame(width: width)
				.focused($focused)
				.onSubmit(apply)
				.onChange(of: focused) { _, isFocused in
					if !isFocused { apply() }
				}
			if let spin {
				Stepper("", onIncrement: { commit(spin(value, 1)) }, onDecrement: { commit(spin(value, -1)) })
					.labelsHidden()
					.controlSize(.mini)
			}
		}
		.onAppear { show(value) }
		.onChange(of: value) { _, newValue in
			if !focused { show(newValue) }
		}
	}

	private func show(_ v: Double) {
		text = format(v)
		shown = text
	}

	// ported from NumEdit.cpp CNumEdit::OnKillfocus
	private func apply() {
		guard text != shown else { return }	// not modified
		let v = parse(text)
		commit(v)
		show(v)
	}
}

/// A slider in integer positions, like a Win32 trackbar: it shows
/// Round(norm(value)) and sets denorm(position).
struct PositionSlider: View {
	let value: Double
	let control: WHControlInfo
	let norm: (Double) -> Double
	let denorm: (Double) -> Double
	let commit: (Double) -> Void
	var width: CGFloat = 160

	var body: some View {
		let lo = Double(control.rangeMin), hi = Double(control.rangeMax)
		Slider(value: Binding(
			get: { min(max(norm(value).rounded(.toNearestOrEven), lo), hi) },
			set: { pos in commit(denorm(pos.rounded())) }),
			in: lo...hi)
			.frame(width: width)
			.controlSize(.small)
			.contextMenu {
				Button("Reset to Default") { commit(denorm(Double(control.defaultPos))) }
			}
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
						commit: { model.setMaster(i, $0) })
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

struct PropertiesPanel: View {
	@EnvironmentObject private var model: AppModel

	private func check(_ prop: MainProp) -> some View {
		Toggle(WHControls.mainName(prop.rawValue), isOn: Binding(
			get: { model.isOn(prop) },
			set: { _ in model.toggle(prop) }))
			.toggleStyle(.checkbox)
	}

	var body: some View {
		let _ = model.revision
		let e = model.engine
		let plain = WHControlInfo(rangeMin: 0, rangeMax: 0, defaultPos: 0, pageSize: 0, editScale: 1,
			editPrecision: -1, editMin: 0, editMax: 0, editClamp: false, spinDelta: 0)
		Form {
			LabeledContent(WHControls.mainName(MainProp.origin.rawValue)) {
				HStack {
					NumberField(value: e.origin.x,
						format: { WHControls.format($0, control: plain) },
						parse: { WHControls.parse($0, control: plain) },
						commit: { model.setOrigin(CGPoint(x: $0, y: e.origin.y)) })
					NumberField(value: e.origin.y,
						format: { WHControls.format($0, control: plain) },
						parse: { WHControls.parse($0, control: plain) },
						commit: { model.setOrigin(CGPoint(x: e.origin.x, y: $0)) })
				}
			}
			LabeledContent(WHControls.mainName(MainProp.drawMode.rawValue)) {
				HStack {
					Toggle("Fill", isOn: Binding(get: { e.fill }, set: { _ in model.toggleFill() }))
					Toggle("Outline", isOn: Binding(get: { e.outline }, set: { _ in model.toggleOutline() }))
				}
			}
			Picker(WHControls.mainName(MainProp.orgMotion.rawValue), selection: Binding(
				get: { e.originMotion },
				set: { model.setOriginMotion($0) })) {
				Text("Park").tag(WHOriginMotion.park)
				Text("Drag").tag(WHOriginMotion.drag)
				Text("Random").tag(WHOriginMotion.random)
			}
			LabeledContent(WHControls.mainName(MainProp.hue.rawValue)) {
				NumberField(value: e.hue,
					format: { WHControls.format($0, control: plain) },
					parse: { WHControls.parse($0, control: plain) },
					commit: { model.setHue($0) })
			}
			check(.mirror)
			check(.reverse)
			check(.convex)
			check(.invertColor)
			check(.loopHue)
			check(.zoomCenter)
			check(.antialiasing)
		}
		.formStyle(.grouped)
		.frame(width: 340, height: 600)
	}
}
