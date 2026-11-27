// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// MIDI Learn mode (Mac addition, the user's design, 2026-11-26; after
// Ableton Live's MIDI Map Mode): with Learn on (View > MIDI Learn, ⌥⌘L, or
// the MIDI Mapping panel's Learn), the whole window is in the mode.
// Mappable controls are tinted, with their MIDI inputs in small boxes
// (no banner: the tint says it, the user's choice); the MIDI Mapping
// panel says what's picked and heard. Playlist rows map their position
// (the Patch target with one value), not the patch. A click on a control picks it as
// the target (and changes nothing): the next MIDI input adds a mapping for
// it, selected, so moving another control replaces that input. A click on
// a mapped control picks its mapping to learn again; Option-click adds
// another. One input may move several controls. Releases (note off) are
// never learned. Esc, Done or entering full screen ends the mode; Delete
// removes the selected mapping.

import AppKit
import SwiftUI

@MainActor
@Observable
final class LearnMode {
	static let shared = LearnMode()

	/// the mode is on (AppModel.midiLearn)
	var on = false
	/// a control clicked and waiting for MIDI: its target and property (a
	/// Playlist row: the Patch target, and its position)
	var pending: (target: Int, prop: Int)?
	var pendingSlot: Int?
	/// the last message heard, as the banner says it
	var heard = ""
	/// what the last learn did ("CC 21 now moves 3 controls")
	var note = ""

	// MARK: The controls' mappings

	/// each control's mappings, by "target.prop", rebuilt when they change
	@ObservationIgnored private var cache: [String: [WHMappingData]] = [:]
	@ObservationIgnored private var cacheVersion = -1

	static func key(_ target: Int, _ prop: Int) -> String {
		"\(target).\(WHMappingInfo.targetHasProperty(target) ? prop : 0)"
	}

	func mappings(target: Int, prop: Int) -> [WHMappingData] {
		refresh()
		return cache[Self.key(target, prop)] ?? []
	}

	private func refresh() {
		let m = AppModel.shared
		let v = m.changes.mapping.n
		if v != cacheVersion {
			cacheVersion = v
			let all = m.mappings
			cache = Dictionary(grouping: all) { Self.key(Int($0.target), Int($0.prop)) }
			slots = Dictionary(grouping: all.filter { Self.slot(of: $0) != nil }) { Self.slot(of: $0)! }
		}
	}
	@ObservationIgnored private var slots: [Int: [WHMappingData]] = [:]

	// MARK: Playlist slots

	/// the Patch target, a Playlist row's (its position, 0 to 127)
	static var patchTarget: Int { WHMappingInfo.target(forTag: "Patch") }
	static let slotMax = 127	// the Patch target's highest position (a note's range)

	/// a slot's range: start and end both its position, as a percentage
	static func percent(_ slot: Int) -> Double { Double(slot) * 100 / Double(slotMax) }

	/// the slot a mapping plays, if it's one (the Patch target with one value)
	static func slot(of d: WHMappingData) -> Int? {
		guard Int(d.target) == patchTarget, d.start == d.end else { return nil }
		return Int((d.start / 100 * Double(slotMax)).rounded())
	}

	func slotMappings(_ slot: Int) -> [WHMappingData] {
		refresh()
		return slots[slot] ?? []
	}

	/// a Playlist row clicked in the mode: its slot's mapping picked to
	/// learn again, or (none, or with Option) the row waits for MIDI
	func clickSlot(_ slot: Int, add: Bool) {
		guard slot <= Self.slotMax else { return }
		let m = AppModel.shared
		let all = m.mappings
		note = ""
		if !add, let first = all.indices.first(where: { Self.slot(of: all[$0]) == slot }) {
			pending = nil
			pendingSlot = nil
			m.mappingSelection = [first]
		} else {
			m.mappingSelection = []
			pending = (Self.patchTarget, 0)
			pendingSlot = slot
		}
	}

	func isPickedSlot(_ slot: Int) -> Bool {
		if pending != nil { return pendingSlot == slot }
		let m = AppModel.shared
		let all = m.mappings
		return m.mappingSelection.contains { $0 < all.count && Self.slot(of: all[$0]) == slot }
	}

	/// a mapping's input, short: N36 (a note), CC21, PB (the wheel)...
	static func short(_ d: WHMappingData) -> String {
		switch d.event {
		case 0: "Off\(d.control)"
		case 1: "N\(d.control)"
		case 2: "KA\(d.control)"
		case 3: "CC\(d.control)"
		case 4: "PC"
		case 5: "AT"
		case 6: "PB"
		default: "?"
		}
	}

	/// and in full, for the banner and tips
	static func long(_ d: WHMappingData) -> String {
		let name = WHMappingInfo.eventName(Int(d.event))
		let n = d.event <= 3 ? " \(d.control)" : ""
		return "\(name)\(n), channel \(d.channel + 1)"
	}

	// MARK: Clicking controls

	/// a control clicked in the mode: its mapping picked to learn again, or
	/// (none, or with Option) the control waits for MIDI to add one
	func click(tag: String, prop: Int, add: Bool) {
		let t = WHMappingInfo.target(forTag: tag)
		guard t >= 0 else { return }
		pendingSlot = nil
		let p = WHMappingInfo.targetHasProperty(t) ? prop : 0
		let m = AppModel.shared
		let all = m.mappings
		let existing = all.indices.filter { Int(all[$0].target) == t && (!WHMappingInfo.targetHasProperty(t) || Int(all[$0].prop) == p) }
		note = ""
		if !add, let first = existing.first {
			pending = nil
			m.mappingSelection = [first]
		} else {
			m.mappingSelection = []
			pending = (t, p)
		}
	}

	/// whether a control is the one picked (waiting, or its mapping selected)
	func isPicked(target t: Int, prop: Int) -> Bool {
		let p = WHMappingInfo.targetHasProperty(t) ? prop : 0
		if let w = pending { return pendingSlot == nil && w.target == t && w.prop == p }
		let m = AppModel.shared
		let all = m.mappings
		return m.mappingSelection.contains { i in
			i < all.count && Int(all[i].target) == t && (!WHMappingInfo.targetHasProperty(t) || Int(all[i].prop) == p)
		}
	}

	/// what the banner says is picked
	var pickedText: String? {
		let m = AppModel.shared
		if let s = pendingSlot, pending != nil { return "Playlist slot \(s + 1): move a control" }
		if let w = pending { return Self.targetText(w.target, w.prop) + ": move a control" }
		let all = m.mappings
		guard let i = m.mappingSelection.min(), i < all.count else { return nil }
		let d = all[i]
		let what = Self.slot(of: d).map { "Playlist slot \($0 + 1)" } ?? Self.targetText(Int(d.target), Int(d.prop))
		return what + " (" + Self.long(d) + "): move a control to change it"
	}

	static func targetText(_ t: Int, _ prop: Int) -> String {
		let name = WHMappingInfo.targetName(t)
		guard WHMappingInfo.targetHasProperty(t), let p = WHParamProperty(rawValue: prop), p != .val else { return name }
		let col = ["Value", "Waveform", "Amplitude", "Frequency", "Pulse Width", "Global"]
		return name + " · " + (prop < col.count ? col[prop] : "")
	}
}

// MARK: The controls

extension View {
	/// a control MIDI can map: in MIDI Learn mode tinted, with its inputs,
	/// and a click picks it instead of using it
	@ViewBuilder func midiLearnable(_ tag: String?, prop: Int = 0) -> some View {
		if let tag { modifier(MidiLearnable(tag: tag, prop: prop)) } else { self }
	}
}

struct MidiLearnable: ViewModifier {
	let tag: String
	let prop: Int

	func body(content: Content) -> some View {
		content.overlay {
			if LearnMode.shared.on { LearnOverlay(tag: tag, prop: prop) }
		}
	}
}

extension View {
	/// a Playlist row in MIDI Learn mode: its position mappable
	func midiLearnSlot(_ slot: Int, learning: Bool) -> some View {
		overlay { if learning { SlotOverlay(slot: slot) } }
	}
}

private struct SlotOverlay: View {
	@EnvironmentObject private var model: AppModel
	let slot: Int

	var body: some View {
		let _ = (model.changes.mapping.n, model.mappingSelection)
		let mode = LearnMode.shared
		let _ = (mode.pending?.target, mode.pendingSlot)
		let ok = slot <= LearnMode.slotMax
		let maps = ok ? mode.slotMappings(slot) : []
		let picked = ok && mode.isPickedSlot(slot)
		LearnTint(picked: picked, maps: maps, dimmed: !ok)
			.contentShape(Rectangle())
			.onTapGesture { mode.clickSlot(slot, add: NSEvent.modifierFlags.contains(.option)) }
			.help(!ok ? "Only the first 128 playlist positions can be mapped"
				: maps.isEmpty ? "Playlist slot \(slot + 1): click, then move a control on your MIDI device. It maps the position, not the patch."
				: maps.map(LearnMode.long).joined(separator: "; ") + ". Click to learn again; Option-click to add another.")
	}
}

/// the tint and the inputs' box, a control's or a slot's
private struct LearnTint: View {
	let picked: Bool
	let maps: [WHMappingData]
	var dimmed = false

	var body: some View {
		RoundedRectangle(cornerRadius: 4)
			.fill(Color.accentColor.opacity(dimmed ? 0.04 : picked ? 0.35 : 0.12))
			.overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(dimmed ? 0.15 : picked ? 1 : 0.5), lineWidth: picked ? 2 : 1))
			.overlay(alignment: .topTrailing) {
				if let first = maps.first {
					Text(LearnMode.short(first) + (maps.count > 1 ? "+\(maps.count - 1)" : ""))
						.font(.system(size: 9, weight: .semibold).monospacedDigit())
						.padding(.horizontal, 3)
						.background(Capsule().fill(Color.accentColor))
						.foregroundStyle(.white)
						.offset(x: 2, y: -5)
						.allowsHitTesting(false)
				}
			}
	}
}

private struct LearnOverlay: View {
	@EnvironmentObject private var model: AppModel
	let tag: String
	let prop: Int

	var body: some View {
		let _ = model.changes.mapping.n
		let mode = LearnMode.shared
		let t = WHMappingInfo.target(forTag: tag)
		let maps = t >= 0 ? mode.mappings(target: t, prop: prop) : []
		let picked = t >= 0 && mode.isPicked(target: t, prop: prop)
		let _ = (mode.pending?.target, model.mappingSelection)
		LearnTint(picked: picked, maps: maps)
			.contentShape(Rectangle())
			.onTapGesture {
				mode.click(tag: tag, prop: prop, add: NSEvent.modifierFlags.contains(.option))
			}
			.help(maps.isEmpty ? "Click, then move a control on your MIDI device"
				: maps.map(LearnMode.long).joined(separator: "; ") + ". Click to learn again; Option-click to add another.")
	}
}
