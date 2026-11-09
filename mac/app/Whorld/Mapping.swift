// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

import AppKit
import SwiftUI

// The MIDI Mapping window (spec: MappingBar). Columns follow the Windows
// grid: number, event, channel (shown one-based), control, target,
// property (parameter targets only), start and end (percent).

private struct MappingRow: Identifiable {
	let id: Int
	let data: WHMappingData
}

struct MappingPanel: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		let _ = model.changes.mapping.n
		let rows = model.mappings.enumerated().map { MappingRow(id: $0.offset, data: $0.element) }
		VStack(spacing: 0) {
			Table(rows, selection: $model.mappingSelection) {
				TableColumn("#") { row in
					Text("\(row.id + 1)").monospacedDigit().foregroundStyle(.secondary)
				}
				.width(28)
				TableColumn("Event") { row in
					Picker("", selection: binding(row, \.event, "Event")) {
						ForEach(0..<WHMappingInfo.eventCount, id: \.self) { e in
							Text(WHMappingInfo.eventName(e)).tag(Int32(e))
						}
					}
					.labelsHidden()
				}
				.width(min: 90, ideal: 120)
				TableColumn("Channel") { row in
					Picker("", selection: binding(row, \.channel, "Channel")) {
						ForEach(0..<16, id: \.self) { c in
							Text("\(c + 1)").tag(Int32(c))	// one-based
						}
					}
					.labelsHidden()
				}
				.width(64)
				TableColumn("Control") { row in
					IntField(value: Int(row.data.control), range: 0...127) { v in
						var m = row.data
						m.control = Int32(v)
						model.setMapping(row.id, m, column: "Control")
					}
				}
				.width(56)
				TableColumn("Target") { row in
					Picker("", selection: binding(row, \.target, "Target")) {
						TargetMenuItems()
					}
					.labelsHidden()
				}
				.width(min: 120, ideal: 150)
				TableColumn("Property") { row in
					if WHMappingInfo.targetHasProperty(Int(row.data.target)) {
						Picker("", selection: binding(row, \.prop, "Property")) {
							ForEach(0..<6, id: \.self) { p in
								Text(WHControls.paramPropertyName(p)).tag(Int32(p))
							}
						}
						.labelsHidden()
					} else {
						Text("n/a").foregroundStyle(.secondary)	// m_sNotApplicable
					}
				}
				.width(min: 90, ideal: 110)
				TableColumn("Start") { row in
					PercentField(value: row.data.start) { v in
						var m = row.data
						m.start = v
						model.setMapping(row.id, m, column: "Start")
					}
				}
				.width(56)
				TableColumn("End") { row in
					PercentField(value: row.data.end) { v in
						var m = row.data
						m.end = v
						model.setMapping(row.id, m, column: "End")
					}
				}
				.width(56)
			}
			Divider()
			HStack {
				Button { model.insertMapping() } label: { Image(systemName: "plus") }
					.help("Insert a mapping")
				Button { model.deleteMappings() } label: { Image(systemName: "minus") }
					.help("Delete the selected mappings")
					.disabled(model.mappingSelection.isEmpty)
					.keyboardShortcut(.delete, modifiers: [])
				Divider().frame(height: 16)
				Toggle("Learn", isOn: Binding(get: { model.midiLearn }, set: { model.midiLearn = $0 }))
					.toggleStyle(.button)
					.help("Select mappings, then move a control on your MIDI device")
				if model.midiLearn {
					Text(model.mappingSelection.isEmpty ? "Select the mappings to learn" : "Move a MIDI control…")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Spacer()
				Text(model.playlistTitle + (model.playlistModified ? " — Edited" : ""))
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(model.engine.midiInputName ?? "No MIDI input")
					.font(.caption)
					.foregroundStyle(model.engine.midiInputName == nil ? .orange : .secondary)
			}
			.padding(8)
		}
		.background(KeyWindowObserver { model.mappingWindowIsKey = $0 })
	}

	private func binding(_ row: MappingRow, _ key: WritableKeyPath<WHMappingData, Int32>, _ column: String) -> Binding<Int32> {
		Binding(
			get: { row.data[keyPath: key] },
			set: { v in
				var m = row.data
				m[keyPath: key] = v
				model.setMapping(row.id, m, column: column)
			})
	}
}

/// Targets grouped as in the original enumeration: parameters, master
/// properties, then miscellaneous targets.
private struct TargetMenuItems: View {
	var body: some View {
		let nParam = WHMappingInfo.paramTargetCount
		let nMaster = WHMappingInfo.masterTargetCount
		let all = WHMappingInfo.targetCount
		Section("Parameters") {
			ForEach(0..<nParam, id: \.self) { t in Text(WHMappingInfo.targetName(t)).tag(Int32(t)) }
		}
		Section("Master") {
			ForEach(nParam..<(nParam + nMaster), id: \.self) { t in Text(WHMappingInfo.targetName(t)).tag(Int32(t)) }
		}
		Section("Other") {
			ForEach((nParam + nMaster)..<all, id: \.self) { t in Text(WHMappingInfo.targetName(t)).tag(Int32(t)) }
		}
	}
}

/// Integer edit box clamped to a range.
private struct IntField: View {
	let value: Int
	let range: ClosedRange<Int>
	let commit: (Int) -> Void

	var body: some View {
		NumberField(
			value: Double(value),
			format: { String(Int($0)) },
			parse: { Double(min(max(Int(Double($0) ?? 0), range.lowerBound), range.upperBound)) },
			commit: { commit(Int($0)) },
			width: 44)
	}
}

/// Percentage edit box, shown with %g as in CMappingBar::OnListGetdispinfo.
private struct PercentField: View {
	let value: Double
	let commit: (Double) -> Void

	var body: some View {
		let plain = WHControlInfo(rangeMin: 0, rangeMax: 0, defaultPos: 0, pageSize: 0, editScale: 1,
			editPrecision: -1, editMin: 0, editMax: 0, editClamp: false, spinDelta: 0)
		NumberField(
			value: value,
			format: { WHControls.format($0, control: plain) },
			parse: { WHControls.parse($0, control: plain) },
			commit: commit,
			width: 44)
	}
}

/// Reports whether the hosting window is the key window.
struct KeyWindowObserver: NSViewRepresentable {
	let onChange: (Bool) -> Void

	func makeNSView(context: Context) -> NSView {
		let view = ObserverView()
		view.onChange = onChange
		return view
	}

	func updateNSView(_ view: NSView, context: Context) {}

	final class ObserverView: NSView {
		var onChange: ((Bool) -> Void)?
		private var tokens: [NSObjectProtocol] = []

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			tokens.forEach(NotificationCenter.default.removeObserver)
			tokens = []
			guard let window else { return }
			let nc = NotificationCenter.default
			tokens.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
				self?.onChange?(true)
			})
			tokens.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
				self?.onChange?(false)
			})
			onChange?(window.isKeyWindow)
		}
	}
}
