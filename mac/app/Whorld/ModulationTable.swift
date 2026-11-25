// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// The Modulation panel's routing table (split out of Modulation.swift on
// 2026-11-22; no change in behavior): the rows, their menus and fields,
// and the live levels.

import AppKit
import SwiftUI
import Observation

@MainActor
private final class ModLevels: ObservableObject {
	// shared, and observed only by each row's meter (RowLevel): a view that
	// holds it redraws whenever it changes, and the table redrawing 20 times
	// a second dismissed the tooltips in it and on its headers
	static let shared = ModLevels()
	@Published var levels: [Double] = []
	private var timer: Timer?

	func start() {
		guard timer == nil else { return }
		timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				let l = AppModel.shared.engine.modulationLevels.map { $0.doubleValue }
				if l != self.levels {
					self.levels = l
				}
			}
		}
	}

	func stop() {
		timer?.invalidate()
		timer = nil
	}
}

/// The routing rows and the controls below them. (Oscillators locked to the
/// beat were a second table until 2026-11-17; they're rows now, on a
/// parameter's Frequency target.)
struct ModTablesSection: View {
	@Bindable private var map = ModMap.shared
	private let levels = ModLevels.shared	// not observed here (see ModLevels)
	@State private var selection = Set<ModRowSetting.ID>()

	var body: some View {
		VStack(spacing: 0) {
			rowsTable
			Divider()
			HStack(spacing: 12) {
				Button { add() } label: { Image(systemName: "plus") }
					.hoverTip("Add a row (a copy of the selected one, if any)")
				Button { remove() } label: { Image(systemName: "minus") }
					.hoverTip("Remove the selected rows")
					.disabled(selection.isEmpty)
				if let notice = map.notice {
					Text(notice).font(.caption).foregroundStyle(.orange)
				}
				Spacer()
			}
			.padding(10)
		}
		.onAppear { levels.start() }
		.onDisappear { levels.stop() }
	}

	private func add() {
		var r = ModRowSetting()
		if let sel = map.rows.last(where: { selection.contains($0.id) }) {
			r = sel
			r.id = UUID()
		}
		map.rows.append(r)
		selection = [r.id]
	}

	private func remove() {
		map.rows.removeAll { selection.contains($0.id) }
		selection = []
	}

	/// A row's cell that redraws only when its row changes, other than its
	/// Amount: swiping an Amount slider changes the rows many times a
	/// second, and redrawing every row's menus each time made it lag.
	/// (Keyed by place too, since a cell's binding reaches its row by place.)
	/// A row switched off is dimmed, all but its On box (the design audit,
	/// 2026-11-24: it looked exactly like one that acts).
	private func stable<C: View>(_ r: ModRowSetting, dims: Bool = true, @ViewBuilder _ content: @escaping () -> C) -> some View {
		var key = r
		key.amount = 0
		return SameRow(index: map.rows.firstIndex(where: { $0.id == r.id }) ?? -1, row: key, dims: dims, content: content)
			.equatable()
	}

	/// how a row's cells are dimmed while the row is off
	static func rowOpacity(_ r: ModRowSetting) -> Double { r.on ? 1 : 0.45 }

	private var rowsTable: some View {
			Table($map.rows, selection: $selection) {
				TableColumn("On") { $r in
					stable(r, dims: false) {
						Toggle("", isOn: $r.on).labelsHidden()
					}
				}
				.width(46)
				TableColumn("Source") { $r in
					stable(r) {
						HStack(spacing: 2) {
							if r.isOscillator {	// the cycle's length, then its phase
								LengthField(row: $r)
								UnitPicker(row: $r)
								PhaseMenu(row: $r)
							} else {
								if r.isLFO {	// its length, then its shape and phase
									SourceMenu(row: $r)
										.fixedSize()	// "LFO": the length gives way, not this
									LengthField(row: $r)
									UnitPicker(row: $r)
									LfoMenu(row: $r)
								} else if r.isPulse {	// the number, then Beats or Bars, then the phase
									LengthField(row: $r)
									SourceMenu(row: $r)
										.fixedSize()
									PhaseMenu(row: $r)
								} else {
									SourceMenu(row: $r)
								}
							}
						}
					}
				}
				.width(min: 100, ideal: 250)	// a Beat LFO row: the source, length, unit, shape and phase
				TableColumn("Live") { $r in
					RowLevel(index: map.rows.firstIndex(where: { $0.id == r.id }) ?? -1)
						.opacity(Self.rowOpacity(r))
				}
				.width(60)
				TableColumn("Target") { $r in
					stable(r) {
						TargetMenu(row: $r)
					}
				}
				.width(min: 140, ideal: 150)
				TableColumn("Amount") { $r in
					if r.isAction {
						Text("fires").foregroundStyle(.secondary)
							.opacity(Self.rowOpacity(r))
					} else if r.isOscillator {	// what the lock keeps
						PatchOscillator(iParam: WHMappingInfo.target(forTag: r.target))
							.opacity(Self.rowOpacity(r))
					} else {
						HStack(spacing: 4) {
							StepSlider(value: r.amount, range: -1...1, step: 0.01, defaultValue: ModRowSetting().amount) { r.amount = $0 }
							Text(String(format: "%+.0f%%", r.amount * 100 + 0))	// + 0: an older -0 shows as 0%
								.monospacedDigit()
								.frame(width: 44, alignment: .trailing)
						}
						.opacity(Self.rowOpacity(r))
					}
				}
				.width(min: 140, ideal: 150)
				TableColumn("Curve") { $r in
					stable(r) {
						if r.isOscillator {
							Text("—").foregroundStyle(.secondary)
						} else {
							TableChoice(selection: $r.curve, options: [(0, "Linear"), (1, "Soft"), (2, "Hard"), (3, "Gate")])
						}
					}
				}
				.width(min: 70, ideal: 80)
				TableColumn("Polarity") { $r in
					stable(r) {
						if r.isAction || r.isOscillator {
							Text("—").foregroundStyle(.secondary)
						} else {
							TableChoice(selection: $r.centered, options: [(false, "Up"), (true, "Centered")])
						}
					}
				}
				.width(min: 80, ideal: 90)
				TableColumn("Attack · Release") { $r in
					stable(r) {	// one column: a Table takes ten at most
						HStack(spacing: 4) {
							if r.isLFO || r.isOscillator {	// locked to the beat: not smoothed
								Text("—").foregroundStyle(.secondary)
									.frame(width: 52)
								Text("—").foregroundStyle(.secondary)
									.frame(width: 52)
							} else {
								if r.isTrigger {
									Text("—").foregroundStyle(.secondary)	// a hit's pulse starts at once
										.frame(width: 52)
								} else {
									MsField(value: $r.attackMs, defaultValue: ModRowSetting().attackMs)
								}
								MsField(value: $r.releaseMs, defaultValue: ModRowSetting().releaseMs)
							}
						}
					}
				}
				.width(124)
				TableColumn("Offset") { $r in
					stable(r) {
						if r.isTrigger || r.isLFO || r.isOscillator {
							OffsetField(value: $r.offsetMs, earlyAllowed: r.isBeatBased || r.isLFO)
						} else {
							Text("—").foregroundStyle(.secondary)
						}
					}
				}
				.width(64)
				TableColumn("Threshold") { $r in
					stable(r) {
						if !r.isOscillator && (r.curve == 3 || (r.isAction && !r.isTrigger)) {
							RowNumber(value: $r.threshold, lo: 0, hi: 1, fine: 0.01,
								defaultValue: ModRowSetting().threshold, decimals: 2, width: 52)
						} else {
							Text("—").foregroundStyle(.secondary)
						}
					}
				}
				.width(92)
			}
			.background(ColumnTips())
			// Modulation off: the rows act on nothing, so they're dimmed (still
			// editable; the design audit, 2026-11-24)
			.opacity(map.bypass ? 0.5 : 1)
			.frame(minHeight: Self.oneRowHeight)	// the window can shrink to one row (the user's request, 2026-11-18)
	}

	/// the table's header and one row (a row holds a regular-size pop-up)
	static let oneRowHeight: CGFloat = 28 + 34

}

/// See ModTablesSection.stable
private struct SameRow<Content: View>: View, Equatable {
	let index: Int
	let row: ModRowSetting
	var dims = true	// dimmed while its row is off
	@ViewBuilder let content: () -> Content

	static func == (a: Self, b: Self) -> Bool { a.index == b.index && a.row == b.row && a.dims == b.dims }

	var body: some View { content().opacity(dims ? ModTablesSection.rowOpacity(row) : 1) }
}

/// A row's live level: the only view that observes the levels
private struct RowLevel: View {
	let index: Int
	@ObservedObject private var levels = ModLevels.shared

	var body: some View {
		LevelBar(value: index >= 0 && index < levels.levels.count ? levels.levels[index] : 0)
	}
}

/// Tooltips on the routing table's column headers (SwiftUI's TableColumn
/// takes only a text title): the table underneath is an NSTableView, whose
/// columns have header tooltips; each title ends with an info mark.
/// The columns explained, for the Modulation panel's ⋯ > About the Columns
enum ModColumns {
	@MainActor static var about: String { ColumnTips.all }
}

private struct ColumnTips: NSViewRepresentable {
	@AppStorage(HoverTips.key) private var tipsOn = true	// Show tips on hover: updated when it changes
	static let tips: [(title: String, tip: String)] = [
		("On", "Turn the row on or off."),
		("Source", "What moves the target: a level, a band, a hit, the beat, or the Beat LFO (a wave locked to the beat: length, shape and phase in the menu beside it)."),
		("Live", "The source now, after smoothing and the curve."),
		("Target", "The control the row moves, from the patch's own value (the patch never changes; rows on one control add up); an action, fired on a hit; or a parameter's Frequency, which locks its oscillator to the beat (length and phase beside the source)."),
		("Amount", "How far the target moves at full level, as a share of its slider; negative moves it down."),
		("Curve", "Linear; Soft (quiet passages count more); Hard (only loud ones); Gate (all or nothing at the threshold)."),
		("Polarity", "Up: from the value upward. Centered: either side of it."),
		("Attack · Release", "How quickly the movement rises and falls, in ms. A hit's pulse fades over its release."),
		("Offset", "Moves beat rows this many ms early (−) or late. Hits can only be late."),
		("Threshold", "For the Gate curve, and actions on a sound: the level, 0 to 1, that sets them off."),
	]

	/// every column's tip, for the ⓘ under the table
	static var all: String { tips.map { "\($0.title): \($0.tip)" }.joined(separator: "\n\n") }

	func makeNSView(context: Context) -> NSView { NSView() }

	/// Each header's tip on hover (the design audit, 2026-11-24: an ⓘ on
	/// every header was clutter; one ⓘ under the table lists them all)
	func updateNSView(_ view: NSView, context: Context) {
		DispatchQueue.main.async {	// once the table is in the window
			guard let root = view.window?.contentView, let table = Self.table(in: root) else { return }
			for column in table.tableColumns {
				let tip = tipsOn ? Self.tips.first { $0.title == column.title }?.tip : nil
				if column.headerToolTip != tip { column.headerToolTip = tip }
			}
		}
	}

	/// the routing table: the one with these columns (docked, the window
	/// holds the Playlist's and the Patches' tables too)
	private static func table(in view: NSView) -> NSTableView? {
		if let t = view as? NSTableView, t.tableColumns.contains(where: { $0.title == "Attack · Release" }) { return t }
		for sub in view.subviews {
			if let t = table(in: sub) { return t }
		}
		return nil
	}
}

/// A choice in the table as a borderless menu with a small grey chevron, as
/// its Source and Target menus (the design audit, 2026-11-24: the boxed
/// pop-ups beside them looked heavier and more important than they are)
private struct TableChoice<Value: Hashable>: View {
	let selection: Binding<Value>
	let options: [(value: Value, title: String)]

	var body: some View {
		Menu {
			Picker("", selection: selection) {
				ForEach(options.indices, id: \.self) { i in Text(options[i].title).tag(options[i].value) }
			}
			.pickerStyle(.inline)
			.labelsHidden()
		} label: {
			Text(options.first { $0.value == selection.wrappedValue }?.title ?? "")
		}
		.menuStyle(.borderlessButton)
		.fixedSize()
	}
}

/// A row's target: a pull-down of the parameters, each a submenu of its
/// columns (ModMap.targetMenu), then Master, Origin and the actions; the
/// one chosen has a check mark.
private struct TargetMenu: View {
	@Binding var row: ModRowSetting

	private var current: ModMap.TargetChoice {
		ModMap.TargetChoice(target: row.isAction ? "" : row.target, prop: row.isAction ? 0 : row.prop, action: row.action)
	}

	var body: some View {
		let menu = ModMap.targetMenu
		Menu {
			Section("Parameters") {
				ForEach(menu.params, id: \.name) { p in
					Menu(p.name) {
						ForEach(p.choices, id: \.choice) { c in
							item(c.label, c.choice)
						}
					}
				}
			}
			ForEach(menu.others, id: \.title) { g in
				Section(g.title) {
					ForEach(g.choices, id: \.self) { c in
						item(ModMap.name(c), c)
					}
				}
			}
		} label: {
			Text(ModMap.name(current))
		}
		.menuStyle(.borderlessButton)	// a small grey chevron, not the accent box, as the LFO's menu (the design audit, 2026-11-24)
	}

	private func item(_ label: String, _ c: ModMap.TargetChoice) -> some View {
		Toggle(label, isOn: Binding(get: { current == c }, set: { _ in choose(c) }))
	}

	private func choose(_ c: ModMap.TargetChoice) {
		row.action = c.action
		if c.action.isEmpty {
			row.target = c.target
			row.prop = c.prop
		}
		if row.isOscillator {	// its source is the cycle: a beat span
			if !row.isBeatBased {	// a pulse or LFO keeps its length; otherwise a bar
				if !row.isLFO {
					row.lfoBeats = 4
					row.lfoInBars = true
				}
				row.source = ModRowSetting.pulseSource
			}
		}
	}
}

/// The Beat LFO's shape and phase, beside its length
private struct LfoMenu: View {
	@Binding var row: ModRowSetting

	var body: some View {
		Menu {
			Picker("Shape", selection: $row.lfoShape) {
				ForEach(ModRowSetting.lfoShapes.indices, id: \.self) { i in
					Text(ModRowSetting.lfoShapes[i]).tag(i)
				}
			}
			Picker("Phase", selection: $row.lfoPhaseDeg) {
				ForEach([0.0, 90, 180, 270], id: \.self) { d in
					Text(String(format: "%.0f°", d)).tag(d)
				}
				if ![0.0, 90, 180, 270].contains(row.lfoPhaseDeg) {
					Text(String(format: "%.0f°", row.lfoPhaseDeg)).tag(row.lfoPhaseDeg)
				}
			}
		} label: {
			Text("\(shapeName) · \(phaseName)")
		}
		.menuStyle(.borderlessButton)
		.fixedSize()
		.hoverTip("The Beat LFO: \(lengthName), \(shapeName), phase \(String(format: "%.0f°", row.lfoPhaseDeg)). One cycle every so many beats, from the one (Reset to 1.1); Ableton Link's beat, or the beat Whorld hears.")
	}

	private var lengthName: String { row.lengthName.lowercased() }
	private var phaseName: String { String(format: "%.0f°", row.lfoPhaseDeg) }
	private var shapeName: String {
		row.lfoShape >= 0 && row.lfoShape < ModRowSetting.lfoShapes.count ? ModRowSetting.lfoShapes[row.lfoShape] : "Sine"
	}
}

/// A Frequency row's or Beat LFO's length: a number of beats or bars
/// (UnitPicker), whole, a fraction (1/3 for triplets) or a decimal. The
/// arrow keys, a swipe up or down or the wheel step it (by one, or halving
/// and doubling below one; with Shift, halving and doubling); right-click
/// for 1.
private struct LengthField: View {
	@Binding var row: ModRowSetting

	var body: some View {
		let unit = row.lfoInBars ? 4.0 : 1.0
		let lo = ModRowSetting.minBeats / unit, hi = ModRowSetting.maxBeats / unit
		NumberField(value: row.lfoBeats / unit, format: ModRowSetting.lengthText,
			parse: { NumberField.fraction($0) ?? Double($0) ?? 1 },
			commit: { v in setLength(v * unit) },
			step: { v, d, k in
				var x: Double
				if k.scale > 1 || (d > 0 ? v < 1 : v <= 1) {	// Shift (coarse): halving or doubling
					x = d > 0 ? v * 2 : v / 2
					if d > 0 && v < 1 { x = min(x, 1) }	// halves up to one
				} else {
					x = d > 0 ? v.rounded(.down) + 1 : v.rounded(.up) - 1	// whole numbers
				}
				return min(max(x, lo), hi)
			},
			lo: lo, hi: hi, defaultValue: 1, width: 46, fractions: true)
			.hoverTip("The cycle's length, in \(row.lfoInBars ? "bars" : "beats"): any number, or a fraction such as 1/3 (triplets). ↑ ↓ or a swipe step it.")
	}

	private func setLength(_ beats: Double) {
		guard beats.isFinite else { return }
		row.lfoBeats = min(max(beats, ModRowSetting.minBeats), ModRowSetting.maxBeats)
	}
}

/// Beats or bars, for LengthField: changing it keeps the number (2 beats
/// becomes 2 bars)
private struct UnitPicker: View {
	@Binding var row: ModRowSetting

	var body: some View {
		let n = row.lfoInBars ? row.lfoBeats / 4 : row.lfoBeats
		TableChoice(selection: Binding(get: { row.lfoInBars }, set: { bars in
			guard bars != row.lfoInBars else { return }
			row.lfoInBars = bars
			row.lfoBeats = min(max(n * (bars ? 4 : 1), ModRowSetting.minBeats), ModRowSetting.maxBeats)
		}), options: [(false, n == 1 ? "Beat" : "Beats"), (true, n == 1 ? "Bar" : "Bars")])
	}
}

/// A Frequency or Beats row's phase, beside its length: for a Frequency
/// row, where in the oscillator's cycle the one falls; for a pulse, how far
/// into each cycle it comes (with 4 bars, 90° is bar 2)
private struct PhaseMenu: View {
	@Binding var row: ModRowSetting

	var body: some View {
		Menu {
			Picker("Phase", selection: $row.lfoPhaseDeg) {
				ForEach([0.0, 90, 180, 270], id: \.self) { d in
					Text(String(format: "%.0f°", d)).tag(d)
				}
				if ![0.0, 90, 180, 270].contains(row.lfoPhaseDeg) {
					Text(String(format: "%.0f°", row.lfoPhaseDeg)).tag(row.lfoPhaseDeg)
				}
			}
			.pickerStyle(.inline)
		} label: {
			Text(String(format: "%.0f°", row.lfoPhaseDeg))
		}
		.menuStyle(.borderlessButton)
		.fixedSize()
		.hoverTip(row.isPulse
			? "The phase: how far into each cycle the pulse comes, from the one (Reset to 1.1). 0° on the one; with 4 bars, 90° is bar 2, 180° bar 3, 270° bar 4."
			: "The phase: where in the oscillator's cycle the one (Reset to 1.1) falls. With a triangle or sine, 0° puts the one halfway up, 90° at the top, 180° halfway down, 270° at the bottom.")
	}
}

/// A row's source (but a Frequency row's): a pull-down of the sounds, the
/// hits, and the beat: a pulse every so many Beats or Bars (the number in
/// front, LengthField), or the Beat LFO; the one chosen has a check mark.
private struct SourceMenu: View {
	@Binding var row: ModRowSetting

	var body: some View {
		let tags = WHModRow.sourceTags
		let hits = tags.filter {
			WHModRow.isTriggerSource($0) && $0 != ModRowSetting.pulseSource && !ModRowSetting.spanSources.contains($0)
		}
		Menu {
			Section("Sound") {
				ForEach(tags.filter { !WHModRow.isTriggerSource($0) && $0 != "BeatLFO" }, id: \.self) { t in
					item(WHModRow.sourceName(t), t)
				}
			}
			Section("Hits") {
				ForEach(hits, id: \.self) { t in
					item(WHModRow.sourceName(t), t)
				}
			}
			Section("The beat") {
				pulse("Beats", bars: false)
				pulse("Bars", bars: true)
				item(WHModRow.sourceName("BeatLFO"), "BeatLFO")
			}
			if !tags.contains(row.source) {
				item(row.source + " (unknown)", row.source)
			}
		} label: {
			Text(label(tags))
		}
		.menuStyle(.borderlessButton)	// a small grey chevron, not the accent box, as the LFO's menu (the design audit, 2026-11-24)
	}

	private func label(_ tags: [String]) -> String {
		if row.isLFO { return "LFO" }	// short: its length, shape and phase follow
		if row.isPulse {	// after its number: "3 Beats", "1 Bar"
			let n = row.lfoInBars ? row.lfoBeats / 4 : row.lfoBeats
			return (row.lfoInBars ? "Bar" : "Beat") + (n == 1 ? "" : "s")
		}
		return tags.contains(row.source) ? WHModRow.sourceName(row.source) : row.source + " (unknown)"
	}

	private func item(_ label: String, _ tag: String) -> some View {
		Toggle(label, isOn: Binding(get: { row.source == tag }, set: { _ in row.source = tag }))
	}

	/// a pulse every so many beats or bars: the number shown stays (a Beat
	/// LFO's or Frequency row's length becomes the pulse's), else 1
	private func pulse(_ label: String, bars: Bool) -> some View {
		Toggle(label, isOn: Binding(get: { row.isPulse && row.lfoInBars == bars }, set: { _ in
			let keep = row.isPulse || row.isLFO
			let n = keep ? (row.lfoInBars ? row.lfoBeats / 4 : row.lfoBeats) : 1
			if !row.isPulse { row.lfoPhaseDeg = 0 }
			row.source = ModRowSetting.pulseSource
			row.lfoInBars = bars
			row.lfoBeats = min(max(n * (bars ? 4 : 1), ModRowSetting.minBeats), ModRowSetting.maxBeats)
		}))
	}
}

/// A parameter's oscillator in the patch: what a lock keeps (the waveform
/// and amplitude), and whether it moves at all.
private struct PatchOscillator: View {
	let iParam: Int

	var body: some View {
		if iParam < 0 {
			Text("—").foregroundStyle(.secondary)
		} else {
			let model = AppModel.shared
			let _ = model.changes.params[iParam].n	// redraw when the row changes
			let amp = model.engine.paramValue(iParam, property: .amp)
			let wave = WHControls.waveformName(Int(model.engine.paramValue(iParam, property: .wave)))
			if amp == 0 {	// short, for the Amount column; the reason in the tip
				Text("\(wave), amplitude 0")
					.foregroundStyle(.orange)
					.hoverTip("This parameter's amplitude is 0 in the patch, so its oscillator doesn't move, locked to the beat or not.")
			} else {
				Text("\(wave), amplitude \(String(format: "%.3g", amp))")
					.foregroundStyle(.secondary)
			}
		}
	}
}

private struct LevelBar: View {
	let value: Double

	var body: some View {
		ZStack(alignment: .leading) {
			RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.2))
			RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
				.frame(width: CGFloat(min(max(value, 0), 1)) * 48)
		}
		.frame(width: 48, height: 8)
	}
}

/// A trigger row's timing, in milliseconds, -300 to 300: beat-based rows
/// fire that much before (negative) or after the beat; hits can only be
/// held back, so a negative offset does nothing for them (shown grey).
private struct OffsetField: View {
	@Binding var value: Double
	let earlyAllowed: Bool

	var body: some View {
		RowNumber(value: $value, lo: earlyAllowed ? -300 : 0, hi: 300, fine: 1, defaultValue: 0, width: 52)
			.hoverTip(earlyAllowed
				? "Milliseconds before (negative) or after (positive) the beat or bar that the row fires, -300 to 300."
				: "Milliseconds after the hit that the row fires, up to 300 (a hit can't be anticipated).")
	}
}

/// A time in milliseconds, 0 to 5000: an attack or release
private struct MsField: View {
	@Binding var value: Double
	let defaultValue: Double

	var body: some View {
		RowNumber(value: $value, lo: 0, hi: 5000, fine: 10, defaultValue: defaultValue, width: 52)
	}
}

/// A row's number box, as the panels' (NumberField): type a value, or step
/// it with the arrow keys, a swipe up or down or the mouse wheel (`fine`
/// is the normal step, scaled by the modifiers as everywhere: ModifierLadder;
/// to either end with Command-Shift);
/// right-click for `defaultValue`. Kept within lo to hi, on the fine step's
/// grid when stepped (250 steps to 260, then with Shift to 290).
private struct RowNumber: View {
	@Binding var value: Double
	let lo: Double
	let hi: Double
	let fine: Double
	let defaultValue: Double
	var decimals = 0
	let width: CGFloat

	var body: some View {
		NumberField(value: value,
			format: { String(format: "%.\(decimals)f", $0 + 0) },	// + 0: never "-0"
			parse: { Double($0) ?? value },
			commit: {	// to what's shown: whole milliseconds, hundredths of the threshold
				let unit = pow(10, Double(decimals))
				value = min(max(($0 * unit).rounded() / unit, lo), hi)
			},
			step: { v, d, k in	// `fine` is the normal step, scaled by the modifiers, to what's shown
				let unit = pow(10, -Double(decimals))
				var x = (k.apply(v, size: fine, direction: d) / unit).rounded() * unit
				if x == v { x = v + Double(d) * unit }	// a step too small to show: the next shown value
				return min(max(x, lo), hi)
			},
			lo: lo, hi: hi, defaultValue: defaultValue, width: width)
	}
}
