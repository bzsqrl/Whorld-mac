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
				.width(min: 22, ideal: 28, max: 32)
				// the menus as the Modulation table's: borderless (TableChoice;
				// the user's request, 2026-11-27)
				TableColumn("Event") { row in
					TableChoice(selection: binding(row, \.event, "Event"),
						options: (0..<WHMappingInfo.eventCount).map { (Int32($0), WHMappingInfo.eventName($0)) })
				}
				.width(min: 90, ideal: 120)
				TableColumn("Channel") { row in
					TableChoice(selection: binding(row, \.channel, "Channel"),
						options: (0..<16).map { (Int32($0), "\($0 + 1)") })	// one-based
				}
				.width(min: 40, ideal: 64, max: 64)
				TableColumn("Control") { row in
					IntField(value: Int(row.data.control), range: 0...127) { v in
						var m = row.data
						m.control = Int32(v)
						model.setMapping(row.id, m, column: "Control")
					}
				}
				.width(min: 40, ideal: 56, max: 72)
				TableColumn("Target") { row in
					Menu {
						Picker("", selection: binding(row, \.target, "Target")) {
							TargetMenuItems()
						}
						.pickerStyle(.inline)
						.labelsHidden()
					} label: {
						// a Playlist slot (MIDI Learn's: the Patch target with one
						// value) says so (2026-11-27; it read "Patch", 3.937 to 3.937)
						Text(LearnMode.slot(of: row.data).map { "Playlist Slot \($0 + 1)" }
							?? WHMappingInfo.targetName(Int(row.data.target)))
					}
					.menuStyle(.borderlessButton)
					.fixedSize()
				}
				.width(min: 120, ideal: 150)
				TableColumn("Property") { row in
					if let slot = LearnMode.slot(of: row.data) {
						// the slot's place, to change without learning again
						IntField(value: slot + 1, range: 1...(LearnMode.slotMax + 1)) { v in
							var m = row.data
							m.start = LearnMode.percent(v - 1)
							m.end = m.start
							model.setMapping(row.id, m, column: "Slot")
						}
						.hoverTip("The playlist place this plays (1 to 128), whatever patch is there")
					} else if WHMappingInfo.targetHasProperty(Int(row.data.target)) {
						TableChoice(selection: binding(row, \.prop, "Property"),
							options: (0..<6).map { (Int32($0), WHControls.paramPropertyName($0)) })
					} else {
						Text("n/a").foregroundStyle(.secondary)	// m_sNotApplicable
					}
				}
				.width(min: 90, ideal: 110)
				TableColumn("Start") { row in
					if LearnMode.slot(of: row.data) != nil {
						Text("—").foregroundStyle(.secondary)	// a slot's range is its place (Property)
					} else {
						PercentField(value: row.data.start) { v in
							var m = row.data
							m.start = v
							model.setMapping(row.id, m, column: "Start")
						}
					}
				}
				.width(min: 40, ideal: 56, max: 72)
				TableColumn("End") { row in
					if LearnMode.slot(of: row.data) != nil {
						Text("—").foregroundStyle(.secondary)
					} else {
						PercentField(value: row.data.end) { v in
							var m = row.data
							m.end = v
							model.setMapping(row.id, m, column: "End")
						}
					}
				}
				.width(min: 40, ideal: 56, max: 72)
				// Mac addition (the user's request, 2026-11-26): a switch
				// flips on each press, for pads that send presses only;
				// off, it follows the input (on while held), as on Windows
				TableColumn("Toggle") { row in
					if WHMappingInfo.targetIsSwitch(Int(row.data.target)) {
						Toggle("", isOn: Binding(get: { row.data.toggle != 0 }, set: { on in
							var m = row.data
							m.toggle = on ? 1 : 0
							model.setMapping(row.id, m, column: "Toggle")
						}))
						.labelsHidden()
						.hoverTip("On: each press flips the switch, and the release does nothing (for pads that latch). Off: the switch follows the input, on while held, as on Windows.")
					} else {
						Text("n/a").foregroundStyle(.secondary)
					}
				}
				.width(min: 40, ideal: 50, max: 50)
			}
			.background(FitColumns())	// columns to the pane's width, scrolling sideways only when they can't fit
			Divider()
			HStack {
				Button { model.insertMapping() } label: { Image(systemName: "plus") }
					.hoverTip("Insert a mapping")
				Button { model.deleteMappings() } label: { Image(systemName: "minus") }
					.hoverTip("Delete the selected mappings")
					.disabled(model.mappingSelection.isEmpty)
					.keyboardShortcut(.delete, modifiers: [])
				Divider().frame(height: 16)
				Toggle("Learn", isOn: Binding(get: { model.midiLearn }, set: { model.setMidiLearn($0) }))
					.toggleStyle(.button)
					.hoverTip("MIDI Learn mode (View > MIDI Learn, ⌥⌘L): click a control anywhere in Whorld, a Playlist row (its position), or a mapping here, then move a knob, fader or pad on your MIDI device. Esc ends it.")
				if model.midiLearn {
					let mode = LearnMode.shared
					VStack(alignment: .leading, spacing: 0) {
						Text(mode.pickedText ?? "Click a control, a Playlist row or a mapping")
						if !mode.note.isEmpty || !mode.heard.isEmpty {
							Text(mode.note.isEmpty ? "Heard: " + mode.heard : mode.note)
								.foregroundStyle(.secondary)
						}
					}
					.font(.caption)
					.lineLimit(1)
					.truncationMode(.tail)
				}
				Spacer()
				Text(model.playlistTitle + (model.playlistModified ? " — Edited" : ""))
					.font(.caption)
					.foregroundStyle(.secondary)
				MidiInputMenu()	// the MIDI input, here too (as Settings > Input; the user's request, 2026-11-26)
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

/// Targets grouped as in the original enumeration: parameters (in the
/// Parameters panel's order), master properties, then miscellaneous targets.
private struct TargetMenuItems: View {
	var body: some View {
		let nParam = WHMappingInfo.paramTargetCount
		let nMaster = WHMappingInfo.masterTargetCount
		let all = WHMappingInfo.targetCount
		Section("Parameters") {
			ForEach(WHControls.paramDisplayOrder.filter { $0 < nParam }, id: \.self) { t in Text(WHMappingInfo.targetName(t)).tag(Int32(t)) }
		}
		Section("Master") {
			ForEach(nParam..<(nParam + nMaster), id: \.self) { t in Text(WHMappingInfo.targetName(t)).tag(Int32(t)) }
		}
		// cue, then go's (Go to Pad 16) a section of their own (2026-11-25)
		let cue = WHMappingInfo.target(forTag: "Go")
		let otherEnd = cue >= 0 ? cue : all
		Section("Other") {
			ForEach((nParam + nMaster)..<otherEnd, id: \.self) { t in Text(WHMappingInfo.targetName(t)).tag(Int32(t)) }
		}
		if cue >= 0 {
			Section("Cue, Then Go") {
				ForEach(cue..<all, id: \.self) { t in Text(WHMappingInfo.targetName(t)).tag(Int32(t)) }
			}
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

/// The MIDI input, chosen at the foot of the MIDI Mapping panel: the same
/// setting as Settings' (Midi_sInputDevice)
private struct MidiInputMenu: View {
	@EnvironmentObject private var model: AppModel
	@AppStorage("Midi_sInputDevice") private var midiInput = ""

	var body: some View {
		let _ = model.changes.midi.n	// devices come and go
		let names = model.engine.midiInputNames
		Menu {
			Picker("MIDI Input", selection: $midiInput) {
				Text("None").tag("")
				ForEach(names, id: \.self) { Text($0).tag($0) }
				if !midiInput.isEmpty && !names.contains(midiInput) {
					Text(midiInput + " (not connected)").tag(midiInput)
				}
			}
			.pickerStyle(.inline)
		} label: {
			Label(midiInput.isEmpty ? "No MIDI input" : midiInput, systemImage: "pianokeys")
				.font(.caption)
				.foregroundStyle(midiInput.isEmpty || !names.contains(midiInput) ? .orange : .secondary)
		}
		.menuStyle(.borderlessButton)
		.fixedSize()
		.hoverTip("The MIDI device Whorld listens to (also in Settings > Input)")
		.onChange(of: midiInput) { _, name in
			model.engine.midiInputName = name.isEmpty ? nil : name
		}
	}
}
