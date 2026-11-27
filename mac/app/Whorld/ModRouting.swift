// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Audio modulation's routing (split out of Modulation.swift on
// 2026-11-22; no change in behavior): the rows' and the beat sync's
// settings, and ModMap, which hands them to the engine.

import AppKit
import SwiftUI
import Observation

// MARK: Routing

/// A routing row as Whorld's settings keep it: the source and action by
/// tag, the target by its mapping tag (as the key map stores it), so files
/// survive changes to the order of things. Missing fields read as defaults.
struct ModRowSetting: Codable, Identifiable, Equatable {
	var id = UUID()
	var on = true
	var source = "Bass"
	var target = "LineWidth"	// a control's mapping tag
	var prop = 0				// a parameter's column: Val, Global, Amp, or Freq (locks its oscillator to the beat) (WHParamProperty)
	var action = ""				// a ModActions tag: the row fires it instead of moving a control
	var amount = 0.25			// -1 to 1, of the target's slider travel
	var curve = 0				// ModRow::CURVE_*
	var centered = false
	var attackMs = 10.0
	var releaseMs = 200.0
	var threshold = 0.5			// for the gate curve and for actions
	var offsetMs = 0.0			// -300 to 300: beat-based sources fire early (-) or late; hits only late
	var lfoBeats = 4.0			// the Beat LFO, or a Frequency row: beats per cycle (any, minBeats to maxBeats)
	var lfoInBars = true		// its length is shown, and typed, in bars (4 beats) or beats
	var lfoShape = 0			// ModRow::LFO_*
	var lfoPhaseDeg = 0.0		// 0 to 359: where in the cycle the one falls

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = ModRowSetting()
		id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
		on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? d.on
		source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? d.source
		target = (try? c.decodeIfPresent(String.self, forKey: .target)) ?? d.target
		prop = (try? c.decodeIfPresent(Int.self, forKey: .prop)) ?? d.prop
		action = (try? c.decodeIfPresent(String.self, forKey: .action)) ?? d.action
		amount = (try? c.decodeIfPresent(Double.self, forKey: .amount)) ?? d.amount
		curve = (try? c.decodeIfPresent(Int.self, forKey: .curve)) ?? d.curve
		centered = (try? c.decodeIfPresent(Bool.self, forKey: .centered)) ?? d.centered
		attackMs = (try? c.decodeIfPresent(Double.self, forKey: .attackMs)) ?? d.attackMs
		releaseMs = (try? c.decodeIfPresent(Double.self, forKey: .releaseMs)) ?? d.releaseMs
		threshold = (try? c.decodeIfPresent(Double.self, forKey: .threshold)) ?? d.threshold
		offsetMs = (try? c.decodeIfPresent(Double.self, forKey: .offsetMs)) ?? d.offsetMs
		lfoBeats = (try? c.decodeIfPresent(Double.self, forKey: .lfoBeats)) ?? d.lfoBeats
		lfoInBars = (try? c.decodeIfPresent(Bool.self, forKey: .lfoInBars)) ?? Self.inBars(lfoBeats)	// (older settings: whole bars in bars)
		normalizeSpan()
		lfoShape = (try? c.decodeIfPresent(Int.self, forKey: .lfoShape)) ?? d.lfoShape
		lfoPhaseDeg = (try? c.decodeIfPresent(Double.self, forKey: .lfoPhaseDeg)) ?? d.lfoPhaseDeg
	}

	var isAction: Bool { !action.isEmpty }
	/// a wave locked to the beat, with its own length, shape and phase
	var isLFO: Bool { source == "BeatLFO" }
	/// the Beat LFO's shapes, as ModRow::LFO_* (Whorld's waveforms)
	static let lfoShapes = ["Sine", "Triangle", "Ramp Up", "Ramp Down", "Square"]
	var isTrigger: Bool { WHModRow.isTriggerSource(source) }
	/// a pulse every so many beats or bars (lfoBeats, lfoInBars), that far
	/// into each cycle (lfoPhaseDeg): the engine's Beats source
	static let pulseSource = "Beats"
	var isPulse: Bool { source == Self.pulseSource }
	/// from the beat's position, so they can fire early
	var isBeatBased: Bool { isPulse || Self.spanSources.contains(source) }
	/// the fixed spans the beat sources had before any length could be typed
	/// (until 2026-11-18): read as Beats rows of those lengths
	static let spanSources = ["Beat", "Bar", "Bar4", "Bar8", "Bar16", "Bar32"]
	static let spanBeats: [String: Double] = ["Beat": 1, "Bar": 4, "Bar4": 16, "Bar8": 32, "Bar16": 64, "Bar32": 128]
	/// A cycle's length: any number of beats or bars, fractions too (1/3
	/// beat for triplets); shorter than a sixteenth of a beat flickers
	static let minBeats = 1.0 / 16
	static let maxBeats = 512.0	// 128 bars

	/// whole bars, shown in bars (older settings and files, which had no unit)
	static func inBars(_ beats: Double) -> Bool {
		beats >= 4 && (beats / 4).rounded() == beats / 4
	}

	/// a length's number as typed: whole, a simple fraction ("1/3",
	/// "3/2"), or a decimal
	static func lengthText(_ n: Double) -> String {
		if n == n.rounded() { return String(format: "%.0f", n) }
		for d in [2.0, 3, 4, 6, 8, 12, 16] {
			let k = (n * d).rounded()
			if abs(n * d - k) < 1e-9 { return String(format: "%.0f/%.0f", k, d) }
		}
		return String(format: "%g", n)
	}

	/// "Bar", "3 beats", "1/3 beat", "2 bars"
	var lengthName: String {
		let n = lfoInBars ? lfoBeats / 4 : lfoBeats
		let unit = lfoInBars ? "bar" : "beat"
		return n == 1 ? unit.capitalized : Self.lengthText(n) + " " + unit + (n > 1 ? "s" : "")
	}

	/// An older fixed span (Beat, Bar, 4-Bar ... 32-Bar) as a Beats row: a
	/// pulse of that length, at no phase; a Frequency row's length was
	/// already its own (lfoBeats; the source only approximated it).
	mutating func normalizeSpan() {
		guard Self.spanSources.contains(source) else { return }
		if !isOscillator {
			lfoBeats = Self.spanBeats[source] ?? 4
			lfoInBars = Self.inBars(lfoBeats)
			lfoPhaseDeg = 0
		}
		source = Self.pulseSource
	}

	/// Locks the target parameter's oscillator to the beat, instead of moving
	/// a control (ModRow::IsOscillatorLock): the target's Frequency column,
	/// the Target menu's Frequency group. One cycle every lfoBeats beats (the source's
	/// span, or a finer length from the menu beside it), at lfoPhaseDeg.
	var isOscillator: Bool { !isAction && prop == WHParamProperty.freq.rawValue }

	/// whether this Whorld knows the source, and the action or control
	var isKnown: Bool {
		guard WHModRow.sourceTags.contains(source) else { return false }
		if isAction {
			return WHModRow.actionTags.contains(action)
		}
		let i = WHMappingInfo.target(forTag: target)
		if isOscillator {
			return i >= 0 && i < WHControls.paramCount && isBeatBased
		}
		return i >= 0 && WHModRow.isModulatableTarget(i, prop: prop)
	}

	/// An oscillator locked to the beat from the older second table
	/// (Oscillators on the Beat, until 2026-11-17), as a row
	static func fromSync(_ y: ModSyncSetting) -> ModRowSetting {
		var r = ModRowSetting()
		r.on = y.on
		r.target = y.param
		r.prop = WHParamProperty.freq.rawValue
		r.lfoBeats = y.beats > 0 ? y.beats : 4
		r.lfoInBars = inBars(r.lfoBeats)
		r.source = pulseSource
		r.lfoPhaseDeg = y.phaseDeg
		r.offsetMs = y.offsetMs
		return r
	}

	func engineRow() -> WHModRow {
		let r = WHModRow()
		r.on = on
		r.source = source
		r.action = isAction ? action : nil
		r.target = WHMappingInfo.target(forTag: target)
		r.prop = prop
		r.amount = amount
		r.curve = curve
		r.centered = centered
		r.attack = attackMs / 1000
		r.releaseTime = releaseMs / 1000
		r.threshold = threshold
		r.offset = min(max(offsetMs, -300), 300) / 1000
		r.lfoBeats = lfoBeats > 0 ? lfoBeats : 4
		r.lfoShape = lfoShape >= 0 && lfoShape < Self.lfoShapes.count ? lfoShape : 0
		r.lfoPhase = (lfoPhaseDeg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
		return r
	}

	static func make(_ source: String, _ target: String, _ amount: Double, attack: Double = 10, release: Double = 200,
		prop: WHParamProperty = .val, on: Bool = true) -> ModRowSetting {
		var r = ModRowSetting()
		r.source = source
		r.target = target
		r.prop = prop.rawValue
		r.amount = amount
		r.attackMs = attack
		r.releaseMs = release
		r.on = on
		r.normalizeSpan()
		return r
	}
}

/// A parameter's oscillator locked to the beat (9.7), as the settings keep
/// it: the parameter by its mapping tag. Missing fields read as defaults.
struct ModSyncSetting: Codable, Identifiable, Equatable {
	var id = UUID()
	var on = true
	var param = "LineWidth"	// a parameter's mapping tag
	var beats = 4.0			// beats per cycle
	var phaseDeg = 0.0		// 0 to 359: where in the cycle the one falls
	var offsetMs = 0.0		// -300 to 300: early (-) or late

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = ModSyncSetting()
		id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
		on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? d.on
		param = (try? c.decodeIfPresent(String.self, forKey: .param)) ?? d.param
		beats = (try? c.decodeIfPresent(Double.self, forKey: .beats)) ?? d.beats
		phaseDeg = (try? c.decodeIfPresent(Double.self, forKey: .phaseDeg)) ?? d.phaseDeg
		offsetMs = (try? c.decodeIfPresent(Double.self, forKey: .offsetMs)) ?? d.offsetMs
	}

	/// the parameter's index, or -1 if this Whorld doesn't have it
	var paramIndex: Int {
		let i = WHMappingInfo.target(forTag: param)
		return i >= 0 && i < WHControls.paramCount ? i : -1
	}
	var isKnown: Bool { paramIndex >= 0 && beats > 0 }

	func engineSync() -> WHModSync {
		let y = WHModSync()
		y.on = on && isKnown
		y.param = max(paramIndex, 0)
		y.beats = beats
		y.phase = (phaseDeg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
		y.offset = min(max(offsetMs, -300), 300) / 1000
		return y
	}
}

/// The routing rows, depth and bypass: a setting (Modulation_v1), applied to
/// the engine whenever it changes.
@MainActor
@Observable
final class ModMap {
	static let shared = ModMap()
	private static let defaultsKey = "Modulation_v1"

	struct File: Codable {
		var version = 1
		var depth = 1.0
		var bypass = false
		var followTempo = false	// Tempo follows the beat (render-only)
		var rows: [ModRowSetting] = []
		var syncs: [ModSyncSetting] = []	// oscillators locked to the beat

		init(depth: Double = 1, bypass: Bool = false, followTempo: Bool = false, rows: [ModRowSetting] = [], syncs: [ModSyncSetting] = []) {
			self.depth = depth
			self.bypass = bypass
			self.followTempo = followTempo
			self.rows = rows
			self.syncs = syncs
		}

		init(from decoder: Decoder) throws {	// missing fields read as defaults
			let c = try decoder.container(keyedBy: CodingKeys.self)
			version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
			depth = (try? c.decodeIfPresent(Double.self, forKey: .depth)) ?? 1
			bypass = (try? c.decodeIfPresent(Bool.self, forKey: .bypass)) ?? false
			followTempo = (try? c.decodeIfPresent(Bool.self, forKey: .followTempo)) ?? false
			rows = (try? c.decodeIfPresent([ModRowSetting].self, forKey: .rows)) ?? []
			syncs = (try? c.decodeIfPresent([ModSyncSetting].self, forKey: .syncs)) ?? []
		}

		enum CodingKeys: String, CodingKey { case version, depth, bypass, followTempo, rows, syncs }

		func encode(to encoder: Encoder) throws {	// syncs are read (older files), never written
			var c = encoder.container(keyedBy: CodingKeys.self)
			try c.encode(version, forKey: .version)
			try c.encode(depth, forKey: .depth)
			try c.encode(bypass, forKey: .bypass)
			try c.encode(followTempo, forKey: .followTempo)
			try c.encode(rows, forKey: .rows)
		}

		/// the rows, with an older file's oscillators on the beat as rows
		var allRows: [ModRowSetting] { rows + syncs.map(ModRowSetting.fromSync) }
	}

	var rows: [ModRowSetting] { didSet { changed() } }
	var depth: Double { didSet { changed() } }	// 0 to 1, scales every row
	var bypass: Bool {	// off: the patches as they are
		didSet {
			changed()
			if bypass != oldValue {
				// Audio > Audio Modulation's check mark; only then, since a bump
				// redraws the menus and panels, too much for every step of a slider
				AppModel.shared.changes.main.bump()
			}
		}
	}
	var followTempo: Bool { didSet { changed() } }	// Tempo follows the beat
	/// what an import skipped, for the window to say
	var notice: String?
	@ObservationIgnored private weak var engine: WHEngine?

	/// Edit > Undo for the rows, Depth and Tempo follows the beat (the
	/// user's request, 2026-11-25); not the on/off switch, a live control
	struct UndoState: Equatable {
		var rows: [ModRowSetting]
		var depth: Double
		var followTempo: Bool
	}
	@ObservationIgnored private lazy var undo = AppModel.SnapshotUndo<UndoState>(
		read: { [unowned self] in UndoState(rows: self.rows, depth: self.depth, followTempo: self.followTempo) },
		write: { [unowned self] s in
			self.rows = s.rows
			self.depth = s.depth
			self.followTempo = s.followTempo
		},
		describe: { old, new in Self.describe(old, new) })

	/// what changed, to name the undo step and to tell one edit from the next
	private static func describe(_ old: UndoState, _ new: UndoState) -> (key: String, title: String) {
		if old.rows == new.rows {
			return old.depth != new.depth ? ("mod depth", "Modulation Depth") : ("mod tempo", "Tempo Follows the Beat")
		}
		let a = old.rows, b = new.rows
		if a.map(\.id) == b.map(\.id), let i = a.indices.first(where: { a[$0] != b[$0] }),
			!a.indices.contains(where: { $0 != i && a[$0] != b[$0] }) {
			// the row, and which of its fields: a slider's drag is one step
			let e = JSONEncoder()
			e.outputFormatting = .sortedKeys
			func fields(_ r: ModRowSetting) -> [String: String] {
				guard let d = try? e.encode(r), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
				return o.mapValues { "\($0)" }
			}
			let fa = fields(a[i]), fb = fields(b[i])
			let changed = Set(fa.keys).union(fb.keys).filter { fa[$0] != fb[$0] }.sorted()
			return ("mod \(a[i].id) \(changed)", changed == ["on"] ? "Modulation Row On" : "Modulation Row")
		}
		if b.count > a.count { return ("mod add", "Add Modulation Row") }
		if b.count < a.count { return ("mod remove", a.count - b.count == 1 ? "Remove Modulation Row" : "Remove Modulation Rows") }
		return ("mod move", "Move Modulation Row")
	}

	private init() {
		// a new install starts with modulation off (the user's request,
		// 2026-11-23): its starting rows ran on the internal tempo with no
		// audio, moving the first patch on its own; the rows are there for
		// the switch (Audio > Audio Modulation)
		var f = File(bypass: true, rows: Self.standard)
		if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
			let saved = try? JSONDecoder().decode(File.self, from: data) {
			f = saved
		}
		rows = f.allRows
		depth = f.depth
		bypass = f.bypass
		followTempo = f.followTempo
		if !f.syncs.isEmpty, let data = try? JSONEncoder().encode(file) {	// saved as rows from now on
			UserDefaults.standard.set(data, forKey: Self.defaultsKey)
		}
		undo.start()
	}

	/// Starting rows (the user's choice, 2026-11-20: beat-based and subtle,
	/// with a few examples off; was Bass, Kick and Hit, a first guess): a
	/// push of Speed and Line Width on every beat, and slow swells of the
	/// whole picture's star and pinwheel over 4 and 8 bars. Off until wanted:
	/// Random Phase every 8 bars, Rotate Hue every 16, and Bass on Line Width,
	/// a row that follows the sound itself.
	static let standard: [ModRowSetting] = {
		func swell(_ target: String, _ amount: Double, bars: Double) -> ModRowSetting {
			var r = ModRowSetting.make("BeatLFO", target, amount, prop: .global)
			r.lfoBeats = bars * 4
			r.lfoInBars = true
			r.lfoShape = 0		// ModRow::LFO_Sine
			r.centered = true	// either side of the patch's own shape
			return r
		}
		func every(_ span: String, _ action: String) -> ModRowSetting {
			var r = ModRowSetting.make(span, "", 0, on: false)
			r.action = action
			return r
		}
		return [
			.make("Beat", "Speed", 0.06, release: 250),
			.make("Beat", "LineWidth", 0.08, release: 200),
			swell("StarFactor", 0.2, bars: 4),
			swell("Pinwheel", 0.2, bars: 8),
			every("Bar8", "RandomPhase"),
			every("Bar16", "RotateHue"),
			.make("Bass", "LineWidth", 0.2, attack: 10, release: 150, on: false),
		]
	}()

	var file: File { File(depth: depth, bypass: bypass, followTempo: followTempo, rows: rows) }

	/// sends the rows to the engine (and from now on, each change)
	func attach(_ engine: WHEngine) {
		self.engine = engine
		apply()
	}

	/// applied at once; saved half a second after the last change (a
	/// slider's drag saved every tick; the performance review, 2026-11-27),
	/// and when Whorld quits, if one's still waiting
	private func changed() {
		undo.note()
		apply()
		saveWork?.cancel()
		let work = DispatchWorkItem { MainActor.assumeIsolated { ModMap.shared.save() } }
		saveWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
		if quitObserver == nil {
			quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
				object: nil, queue: .main) { _ in
				MainActor.assumeIsolated { ModMap.shared.saveNow() }
			}
		}
	}
	@ObservationIgnored private var saveWork: DispatchWorkItem?
	@ObservationIgnored private var quitObserver: Any?

	private func save() {
		saveWork = nil
		if let data = try? JSONEncoder().encode(file) {
			UserDefaults.standard.set(data, forKey: Self.defaultsKey)
		}
	}

	/// a waiting save, now (Whorld quitting)
	func saveNow() {
		guard let work = saveWork else { return }
		work.cancel()
		save()
	}

	private func apply() {
		// every row, so the engine's row levels line up with these;
		// rows it doesn't know (from a newer Whorld) do nothing
		// (Frequency rows lock oscillators: the engine makes them syncs)
		engine?.setModulationRows(rows.map { $0.engineRow() }, syncs: [],
			depth: depth, bypass: bypass, followTempo: followTempo)
	}

	func restoreDefaults() {
		undo.batch("Restore Modulation Defaults") {
			rows = Self.standard
			depth = 1
			followTempo = false	// the switch stays as it is
		}
		notice = nil
	}

	// MARK: Files

	func export() {
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.json]
		panel.nameFieldStringValue = "Whorld Modulation.json"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		let e = JSONEncoder()
		e.outputFormatting = [.prettyPrinted, .sortedKeys]
		do {
			try e.encode(file).write(to: url, options: .atomic)
		} catch {
			NSAlert(error: error).runModal()
		}
	}

	func importFile() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.json]
		guard panel.runModal() == .OK, let url = panel.url else { return }
		guard let data = try? Data(contentsOf: url),
			let f = try? JSONDecoder().decode(File.self, from: data), f.version >= 1 else {
			let a = NSAlert()
			a.messageText = "Can't import \"\(url.lastPathComponent)\"."
			a.informativeText = "It isn't a Whorld modulation file."
			a.runModal()
			return
		}
		let all = f.allRows
		let known = all.filter { $0.isKnown }
		let skipped = all.count - known.count
		undo.batch("Import Modulation") {
			rows = known
			depth = min(max(f.depth, 0), 1)
			followTempo = f.followTempo
		}
		bypass = f.bypass
		notice = skipped > 0 ? "\(skipped) row\(skipped == 1 ? "" : "s") skipped: from a newer Whorld, with a source, control or parameter this one doesn't have." : nil
	}

	// MARK: Carrying out actions and remote control

	/// The rows' fired actions (bits, 1 << tag index), as the menus do them.
	func perform(_ actions: UInt32, _ model: AppModel) {
		let tags = WHModRow.actionTags
		for (i, tag) in tags.enumerated() where actions & (1 << UInt32(i)) != 0 {
			switch tag {
			// Random Phase and Clear flash their Properties chips (as by hand),
			// but don't take the readout, which modulation never does
			case "RandomPhase":
				model.engine.randomPhase()
				ActionFlash.shared.fire(.randomPhase)
			case "RandomOrigin": model.engine.randomOrigin()
			case "RotateHue": model.rotateHue(readout: false)	// no readout: not by hand
			case "Clear":
				model.engine.clear()
				ActionFlash.shared.fire(.clear)
			case "NextPatch": model.stepPatch(1)
			case "PrevPatch": model.stepPatch(-1)
			case "NextSnapshot": if model.hasSnapshots { model.snapshotNext() }
			case "PrevSnapshot": if model.hasSnapshots { model.snapshotPrev() }
			default: break
			}
		}
	}

	/// OSC: /w/mod/on (kind 0: 1, 0, or -1 to toggle), /w/mod/depth (kind 1),
	/// /w/mod/downbeat (kind 2), /w/mod/bars (kind 3), /w/mod/beatback,
	/// beatfwd, barback, barfwd (kinds 4 to 7) and /w/mod/halfbeat (kind 8);
	/// and the MIDI targets
	func osc(kind: Int, value: Double) {
		if kind == 2 {
			Self.markDownbeat()
		} else if kind == 3 {
			Self.resetBars()
		} else if kind >= 4 && kind <= 7 {
			Self.nudge(beats: [-1, 1, -4, 4][kind - 4])
		} else if kind == 8 {
			Self.shiftHalfBeat()
		} else if kind == 0 {
			bypass = value < 0 ? !bypass : value == 0
		} else {
			undo.unrecorded { depth = min(max(value, 0), 1) }	// remote control (MIDI, OSC): no undo step
		}
	}

	/// The count a beat (or 4, a bar) back or on, the beat kept, without
	/// firing anything; waves locked to the beat ease to their new place.
	/// While Ableton Link drives the beat, whose beat within the bar is the
	/// session's, by bars: a beat's nudge moves a bar that way.
	static func nudge(beats: Int) {
		if WHLink.shared.drivesBeat {
			WHLink.shared.nudgeBars(beats > 0 ? max(beats / 4, 1) : min(beats / 4, -1))
		} else {
			WHAudioInput.shared.nudgeBeats(beats)
		}
	}

	/// The beat itself half a beat later, or back: for a beat found on the
	/// off-beats. Not while Ableton Link drives the beat (the session's beat
	/// is right by definition).
	static func shiftHalfBeat() {
		if !WHLink.shared.drivesBeat {
			WHAudioInput.shared.shiftHalfBeat()
		}
	}

	/// Half Beat Back (-1) and Forward (+1): the count moved half a beat,
	/// as nudge moves it by beats (the user's request, 2026-11-19). Not
	/// while Ableton Link drives the beat, as shiftHalfBeat.
	static func shiftHalfBeats(_ halves: Int) {
		if !WHLink.shared.drivesBeat {
			WHAudioInput.shared.shiftHalfBeats(halves)
		}
	}

	/// Reset to 1.1 (Mark Downbeat): Ableton Link's beat while it drives, else the tracker's
	static func markDownbeat() {
		if WHLink.shared.drivesBeat {
			WHLink.shared.markDownbeat()
		} else {
			WHAudioInput.shared.markDownbeat()
		}
	}

	/// Reset Bar Count: the nearest bar is bar 1, keeping the beat (Link's
	/// while it drives, else the tracker's)
	static func resetBars() {
		if WHLink.shared.drivesBeat {
			WHLink.shared.resetBars()
		} else {
			WHAudioInput.shared.resetBars()
		}
	}

	// MARK: Menus

	/// Where a row's target can point: the controls a modulation can move,
	/// grouped as the Key Map shows them, then the actions.
	struct TargetChoice: Hashable {
		var target = ""
		var prop = 0
		var action = ""
	}

	static let targetGroups: [(title: String, choices: [TargetChoice])] = {
		var groups: [(String, [TargetChoice])] = []
		for g in KeyMap.groups {
			let choices = g.choices.filter {
				WHModRow.isModulatableTarget(WHMappingInfo.target(forTag: $0.target), prop: $0.prop)
			}.map { TargetChoice(target: $0.target, prop: $0.prop) }
			if !choices.isEmpty {
				groups.append((g.title, choices))
			}
		}
		// a parameter's Frequency: its oscillator locked to the beat (ModRowSetting.isOscillator)
		groups.append(("Frequency", WHControls.paramDisplayOrder.filter { $0 < WHMappingInfo.paramTargetCount }.map {
			TargetChoice(target: WHMappingInfo.targetTag($0), prop: WHParamProperty.freq.rawValue)
		}))
		groups.append(("Actions", WHModRow.actionTags.map { TargetChoice(action: $0) }))
		return groups
	}()

	/// The Target menu: a submenu for each parameter, holding its columns
	/// (Value, Amplitude, Frequency, Pulse Width, Global, where a row can
	/// move them), so the list is the parameters, not every column of each;
	/// then Master, Origin and the actions as they are.
	static let targetMenu: (params: [(name: String, choices: [(label: String, choice: TargetChoice)])],
		others: [(title: String, choices: [TargetChoice])]) = {
		let nParams = WHMappingInfo.paramTargetCount
		var byParam: [String: [TargetChoice]] = [:]
		var others: [(title: String, choices: [TargetChoice])] = []
		for g in targetGroups {
			var rest: [TargetChoice] = []
			for c in g.choices {
				let i = c.action.isEmpty ? WHMappingInfo.target(forTag: c.target) : -1
				if i >= 0 && i < nParams {
					byParam[c.target, default: []].append(c)
				} else {
					rest.append(c)
				}
			}
			if !rest.isEmpty {
				others.append((g.title, rest))
			}
		}
		let order: [WHParamProperty] = [.val, .amp, .freq, .PW, .global]	// the Parameters panel's columns
		let params = WHControls.paramDisplayOrder.filter { $0 < nParams }.compactMap { i -> (name: String, choices: [(label: String, choice: TargetChoice)])? in
			guard let cs = byParam[WHMappingInfo.targetTag(i)] else { return nil }
			let sorted = cs.sorted { a, b in
				(order.firstIndex(of: WHParamProperty(rawValue: a.prop) ?? .val) ?? 0) < (order.firstIndex(of: WHParamProperty(rawValue: b.prop) ?? .val) ?? 0)
			}
			return (WHControls.paramName(i), sorted.map { (WHControls.paramPropertyName($0.prop), $0) })
		}
		return (params, others)
	}()

	static func name(_ c: TargetChoice) -> String {
		if !c.action.isEmpty {
			return WHModRow.actionName(c.action)
		}
		return KeyMap.name(target: c.target, prop: c.prop)	// a Frequency row: "Star Factor Frequency"
	}
}

/// The rows' live levels, polled from the engine while the window shows.
