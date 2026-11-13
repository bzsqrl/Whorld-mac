// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Audio modulation (new in the Mac port; AUDIO_PLAN.md): the Modulation
// window (Window > Modulation...). At the top, the audio input
// (WHAudioInput) and a live meter of what the analysis hears; below, the
// routing rows (ModMap): which sound moves which control, and by how much.
// Everything here is a setting, the same for every patch and playlist, and
// the patches themselves never change (the engine adds the offsets as it
// draws).

import AppKit
import SwiftUI

/// The audio input's settings, kept in Whorld's settings.
enum AudioSettings {
	static let inputKey = "Audio_sInputUID"	// "" none, "default", or a device uid
	static let firstKey = "Audio_nChannelFirst"
	static let countKey = "Audio_nChannelCount"	// 0: all channels, mixed
	static let gainKey = "Audio_fGainDb"
	static let rangeKey = "Audio_fRangeDb"
	static let autoLevelKey = "Audio_bAutoLevel"
	static let hitThresholdKey = "Audio_fHitThreshold"

	static func register() {
		UserDefaults.standard.register(defaults: [
			inputKey: "", firstKey: 0, countKey: 0, gainKey: 0.0, rangeKey: 36.0, autoLevelKey: false, hitThresholdKey: 4.0,
		])
	}

	/// At launch: the analysis settings, then the input chosen last time.
	@MainActor static func apply() {
		register()
		let d = UserDefaults.standard
		let input = WHAudioInput.shared
		input.gainDb = d.double(forKey: gainKey)
		input.rangeDb = d.double(forKey: rangeKey)
		input.autoLevel = d.bool(forKey: autoLevelKey)
		input.hitThreshold = d.double(forKey: hitThresholdKey)
		selectInput()
	}

	@MainActor static func selectInput() {
		let d = UserDefaults.standard
		WHAudioInput.shared.selectDevice(d.string(forKey: inputKey) ?? "",
			channelFirst: d.integer(forKey: firstKey), count: d.integer(forKey: countKey))
	}
}

/// Window > Modulation...
struct ModulationView: View {
	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			AudioInputSection()
				.padding(16)
			Divider()
			ModRowsSection()
		}
		.frame(minWidth: 1130, minHeight: 640)
		.onAppear { AudioSettings.register() }
	}
}

/// Redraws when the audio input's state or device list changes.
@MainActor
final class AudioInputWatch: ObservableObject {
	static let shared = AudioInputWatch()
	private init() {
		WHAudioInput.shared.changeHandler = { [weak self] in self?.objectWillChange.send() }
	}
}

/// The input: device, channels, gain, auto-level, hit sensitivity, status
/// and meter.
private struct AudioInputSection: View {
	@ObservedObject private var watch = AudioInputWatch.shared
	@AppStorage(AudioSettings.inputKey) private var inputUID = ""
	@AppStorage(AudioSettings.firstKey) private var channelFirst = 0
	@AppStorage(AudioSettings.countKey) private var channelCount = 0
	@AppStorage(AudioSettings.gainKey) private var gainDb = 0.0
	@AppStorage(AudioSettings.rangeKey) private var rangeDb = 36.0	// mastered music lives in the top 15 to 20 dB
	@AppStorage(AudioSettings.autoLevelKey) private var autoLevel = false
	@AppStorage(AudioSettings.hitThresholdKey) private var hitThreshold = 4.0

	private var input: WHAudioInput { .shared }

	var body: some View {
		let devices = WHAudioInput.devices
		let selected = selectedDevice(devices)
		Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
			GridRow {
				Text("Input").gridColumnAlignment(.trailing)
				HStack {
					Picker("", selection: $inputUID) {
						Text("None").tag("")
						Text("System default" + (WHAudioInput.defaultDevice.map { " (\($0.name))" } ?? "")).tag("default")
						if !devices.isEmpty {
							Divider()
						}
						ForEach(devices, id: \.uid) { d in
							Text(d.name).tag(d.uid)
						}
						if !inputUID.isEmpty, inputUID != "default", !devices.contains(where: { $0.uid == inputUID }) {
							Text("Not connected").tag(inputUID)
						}
					}
					.labelsHidden()
					.frame(width: 260)
					Picker("", selection: channelBinding) {
						Text("All channels, mixed").tag(ChannelChoice(first: 0, count: 0))
						let n = selected?.channels ?? 0
						if n > 2 {
							ForEach(Array(stride(from: 0, to: n - 1, by: 2)), id: \.self) { i in
								Text("Channels \(i + 1)–\(i + 2), mixed").tag(ChannelChoice(first: i, count: 2))
							}
						}
						if n > 1 {
							ForEach(0..<n, id: \.self) { i in
								Text("Channel \(i + 1)").tag(ChannelChoice(first: i, count: 1))
							}
						}
					}
					.labelsHidden()
					.frame(width: 200)
					.disabled((selected?.channels ?? 0) < 2)
				}
			}
			GridRow {
				Text("Gain")
				HStack {
					Slider(value: Binding(get: { gainDb }, set: { gainDb = ($0 * 2).rounded() / 2 }), in: -24...24)	// half-dB steps, no tick marks
						.frame(width: 260)
					Text(String(format: "%+.1f dB", gainDb + 0))	// + 0: never "-0.0"
						.monospacedDigit()
						.frame(width: 64, alignment: .trailing)
					Toggle("Auto-level", isOn: $autoLevel)
						.help("Follows the music's recent peak, so quiet and loud material both use the whole range.")
				}
			}
			GridRow {
				Text("Range")
				HStack {
					Slider(value: Binding(get: { rangeDb }, set: { rangeDb = $0.rounded() }), in: 12...60)
						.frame(width: 260)
					Text(String(format: "%.0f dB", rangeDb))
						.monospacedDigit()
						.frame(width: 64, alignment: .trailing)
					Text(autoLevel ? "below the recent peak" : "below full scale")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				.help("How far below the top a sound can be and still move the meters and rows. Mastered music sits in the top 15 to 20 dB, so a smaller range makes it move more.")
			}
			GridRow {
				Text("Hit sensitivity")
				HStack {
					// the analyzer's threshold, in deviations: lower is more sensitive
					Slider(value: Binding(get: { 10 - hitThreshold }, set: { hitThreshold = 10 - $0 }), in: 2...8)
						.frame(width: 260)
					Text("fewer ← → more")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			GridRow {
				Text("")
				AudioStatus(state: input.state, text: input.statusText)
			}
			GridRow(alignment: .top) {
				Text("Hearing")
				AudioMeter()
			}
		}
		.onChange(of: inputUID) { AudioSettings.selectInput() }
		.onChange(of: channelFirst) { AudioSettings.selectInput() }
		.onChange(of: channelCount) { AudioSettings.selectInput() }
		.onChange(of: gainDb) { _, v in input.gainDb = v }
		.onChange(of: rangeDb) { _, v in input.rangeDb = v }
		.onChange(of: autoLevel) { _, v in input.autoLevel = v }
		.onChange(of: hitThreshold) { _, v in input.hitThreshold = v }
	}

	private struct ChannelChoice: Hashable {
		var first: Int
		var count: Int
	}

	private var channelBinding: Binding<ChannelChoice> {
		Binding(get: { ChannelChoice(first: channelCount == 0 ? 0 : channelFirst, count: channelCount) },
			set: { channelFirst = $0.first; channelCount = $0.count })
	}

	private func selectedDevice(_ devices: [WHAudioDevice]) -> WHAudioDevice? {
		if inputUID == "default" {
			return WHAudioInput.defaultDevice
		}
		return devices.first { $0.uid == inputUID }
	}
}

private struct AudioStatus: View {
	let state: WHAudioState
	let text: String

	var body: some View {
		HStack(spacing: 8) {
			Text(text)
				.font(.caption)
				.foregroundStyle(state == .denied || state == .unavailable ? Color.red : Color.secondary)
				.fixedSize(horizontal: false, vertical: true)
			if state == .denied {
				Button("Open Privacy Settings") {
					if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
						NSWorkspace.shared.open(url)
					}
				}
				.controlSize(.small)
			}
		}
	}
}

/// What the analysis hears: bars for the level, bands and brightness, and
/// lights that flash on hits. Thirty times a second while shown.
private struct AudioMeter: View {
	@State private var lastCounts: [UInt32] = [0, 0, 0]
	@State private var flashUntil: [Date] = [.distantPast, .distantPast, .distantPast]
	@State private var history: [(time: Date, counts: [UInt32])] = []	// the last few seconds, for rates

	var body: some View {
		TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
			let r = WHAudioInput.shared.reading()
			let now = context.date
			HStack(alignment: .top, spacing: 24) {
				VStack(alignment: .leading, spacing: 4) {
					bar("Level", r.level, detail: r.levelDb > -150 ? String(format: "%.0f dB", r.levelDb) : "")
					bar("Bass", r.bass)
					bar("Low Mid", r.lowMid)
					bar("High Mid", r.highMid)
					bar("Treble", r.treble)
					bar("Brightness", r.brightness)
				}
				VStack(alignment: .leading, spacing: 8) {
					light("Hit", lit: now < flashUntil[0], rate: rate(0))
					light("Kick", lit: now < flashUntil[1], rate: rate(1))
					light("Hats", lit: now < flashUntil[2], rate: rate(2))
					Text("hits a second, over 4 s")
						.font(.caption2)
						.foregroundStyle(.secondary)
				}
			}
			.onChange(of: [r.hits, r.kicks, r.hats]) { _, counts in
				for i in 0..<3 where counts[i] != lastCounts[i] {
					flashUntil[i] = Date().addingTimeInterval(0.12)
				}
				lastCounts = counts
			}
			.onChange(of: Int(now.timeIntervalSinceReferenceDate * 4)) {	// four times a second
				history.append((now, [r.hits, r.kicks, r.hats]))
				history.removeAll { now.timeIntervalSince($0.time) > 4.1 }
			}
		}
	}

	private func bar(_ name: String, _ value: Float, detail: String = "") -> some View {
		HStack(spacing: 8) {
			Text(name)
				.font(.caption)
				.frame(width: 70, alignment: .trailing)
			ZStack(alignment: .leading) {
				RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.2))
				RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
					.frame(width: max(0, CGFloat(min(max(value, 0), 1))) * 220)
			}
			.frame(width: 220, height: 8)
			Text(detail)
				.font(.caption)
				.monospacedDigit()
				.foregroundStyle(.secondary)
		}
	}

	/// hits a second of one kind over the last 4 seconds (nil until there's enough)
	private func rate(_ i: Int) -> Double? {
		guard let first = history.first, let last = history.last else { return nil }
		let dt = last.time.timeIntervalSince(first.time)
		guard dt > 1 else { return nil }
		return Double(last.counts[i] &- first.counts[i]) / dt
	}

	private func light(_ name: String, lit: Bool, rate: Double?) -> some View {
		HStack(spacing: 6) {
			Circle()
				.fill(lit ? Color.accentColor : Color.secondary.opacity(0.25))
				.frame(width: 12, height: 12)
			Text(name).font(.caption)
				.frame(width: 34, alignment: .leading)
			Text(rate.map { String(format: "%.1f/s", $0) } ?? "")
				.font(.caption)
				.monospacedDigit()
				.foregroundStyle(.secondary)
		}
	}
}

// MARK: Routing

/// A routing row as Whorld's settings keep it: the source and action by
/// tag, the target by its mapping tag (as the key map stores it), so files
/// survive changes to the order of things. Missing fields read as defaults.
struct ModRowSetting: Codable, Identifiable, Equatable {
	var id = UUID()
	var on = true
	var source = "Bass"
	var target = "LineWidth"	// a control's mapping tag
	var prop = 0				// a parameter's column: Val or Global (WHParamProperty)
	var action = ""				// a ModActions tag: the row fires it instead of moving a control
	var amount = 0.25			// -1 to 1, of the target's slider travel
	var curve = 0				// ModRow::CURVE_*
	var centered = false
	var attackMs = 10.0
	var releaseMs = 200.0
	var threshold = 0.5			// for the gate curve and for actions

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
	}

	var isAction: Bool { !action.isEmpty }
	var isTrigger: Bool { WHModRow.isTriggerSource(source) }

	/// whether this Whorld knows the source, and the action or control
	var isKnown: Bool {
		guard WHModRow.sourceTags.contains(source) else { return false }
		if isAction {
			return WHModRow.actionTags.contains(action)
		}
		let i = WHMappingInfo.target(forTag: target)
		return i >= 0 && WHModRow.isModulatableTarget(i, prop: prop)
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
		return r
	}
}

/// The routing rows, depth and bypass: a setting (Modulation_v1), applied to
/// the engine whenever it changes.
@MainActor
final class ModMap: ObservableObject {
	static let shared = ModMap()
	private static let defaultsKey = "Modulation_v1"

	struct File: Codable {
		var version = 1
		var depth = 1.0
		var bypass = false
		var rows: [ModRowSetting] = []
	}

	@Published var rows: [ModRowSetting] { didSet { changed() } }
	@Published var depth: Double { didSet { changed() } }	// 0 to 1, scales every row
	@Published var bypass: Bool { didSet { changed() } }	// off: the patches as they are
	/// what an import skipped, for the window to say
	@Published var notice: String?
	private weak var engine: WHEngine?

	private init() {
		var f = File(rows: Self.standard)
		if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
			let saved = try? JSONDecoder().decode(File.self, from: data) {
			f = saved
		}
		rows = f.rows
		depth = f.depth
		bypass = f.bypass
	}

	/// Starting rows: bass widens the lines, each kick pulses the zoom, and
	/// (off until wanted) a hit randomizes the oscillators' phases.
	static let standard: [ModRowSetting] = {
		var hit = ModRowSetting.make("Hit", "", 0, on: false)
		hit.action = "RandomPhase"
		return [
			.make("Bass", "LineWidth", 0.3, attack: 10, release: 150),
			.make("Kick", "Zoom", 0.08, release: 250),
			hit,
		]
	}()

	var file: File { File(depth: depth, bypass: bypass, rows: rows) }

	/// sends the rows to the engine (and from now on, each change)
	func attach(_ engine: WHEngine) {
		self.engine = engine
		apply()
	}

	private func changed() {
		if let data = try? JSONEncoder().encode(file) {
			UserDefaults.standard.set(data, forKey: Self.defaultsKey)
		}
		apply()
		AppModel.shared.changes.main.bump()	// Image > Audio Modulation's check mark
	}

	private func apply() {
		// every row, so the engine's row levels line up with these;
		// rows it doesn't know (from a newer Whorld) do nothing
		engine?.setModulationRows(rows.map { $0.engineRow() }, depth: depth, bypass: bypass)
	}

	func restoreDefaults() {
		rows = Self.standard
		depth = 1
		bypass = false
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
		let known = f.rows.filter { $0.isKnown }
		let skipped = f.rows.count - known.count
		rows = known
		depth = min(max(f.depth, 0), 1)
		bypass = f.bypass
		notice = skipped > 0 ? "\(skipped) row\(skipped == 1 ? "" : "s") skipped: from a newer Whorld, with a source or control this one doesn't have." : nil
	}

	// MARK: Carrying out actions and remote control

	/// The rows' fired actions (bits, 1 << tag index), as the menus do them.
	func perform(_ actions: UInt32, _ model: AppModel) {
		let tags = WHModRow.actionTags
		for (i, tag) in tags.enumerated() where actions & (1 << UInt32(i)) != 0 {
			switch tag {
			case "RandomPhase": model.engine.randomPhase()
			case "RandomOrigin": model.engine.randomOrigin()
			case "RotateHue": model.rotateHue()
			case "Clear": model.engine.clear()
			case "NextPatch": model.stepPatch(1)
			case "PrevPatch": model.stepPatch(-1)
			case "NextSnapshot": if model.hasSnapshots { model.snapshotNext() }
			case "PrevSnapshot": if model.hasSnapshots { model.snapshotPrev() }
			default: break
			}
		}
	}

	/// OSC: /w/mod/on (kind 0: 1, 0, or -1 to toggle) and /w/mod/depth (kind 1)
	func osc(kind: Int, value: Double) {
		if kind == 0 {
			bypass = value < 0 ? !bypass : value == 0
		} else {
			depth = min(max(value, 0), 1)
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
		groups.append(("Actions", WHModRow.actionTags.map { TargetChoice(action: $0) }))
		return groups
	}()

	static func name(_ c: TargetChoice) -> String {
		c.action.isEmpty ? KeyMap.name(target: c.target, prop: c.prop) : WHModRow.actionName(c.action)
	}
}

/// The rows' live levels, polled from the engine while the window shows.
@MainActor
private final class ModLevels: ObservableObject {
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

/// The routing table and its controls.
private struct ModRowsSection: View {
	@ObservedObject private var map = ModMap.shared
	@StateObject private var levels = ModLevels()
	@State private var selection = Set<ModRowSetting.ID>()

	var body: some View {
		VStack(spacing: 0) {
			Table($map.rows, selection: $selection) {
				TableColumn("On") { $r in
					Toggle("", isOn: $r.on).labelsHidden()
				}
				.width(30)
				TableColumn("Source") { $r in
					Picker("", selection: $r.source) {
						let tags = WHModRow.sourceTags
						Section("Sound") {
							ForEach(tags.filter { !WHModRow.isTriggerSource($0) }, id: \.self) { t in
								Text(WHModRow.sourceName(t)).tag(t)
							}
						}
						Section("Hits") {
							ForEach(tags.filter { WHModRow.isTriggerSource($0) }, id: \.self) { t in
								Text(WHModRow.sourceName(t)).tag(t)
							}
						}
						if !tags.contains(r.source) {
							Text(r.source + " (unknown)").tag(r.source)
						}
					}
					.labelsHidden()
				}
				.width(min: 100, ideal: 110)
				TableColumn("Live") { $r in
					LevelBar(value: level(of: r.id))
				}
				.width(60)
				TableColumn("Target") { $r in
					Picker("", selection: Binding(
						get: { ModMap.TargetChoice(target: r.isAction ? "" : r.target, prop: r.isAction ? 0 : r.prop, action: r.action) },
						set: { c in
							r.action = c.action
							if c.action.isEmpty {
								r.target = c.target
								r.prop = c.prop
							}
						})) {
						ForEach(ModMap.targetGroups, id: \.title) { g in
							Section(g.title) {
								ForEach(g.choices, id: \.self) { c in
									Text(ModMap.name(c)).tag(c)
								}
							}
						}
					}
					.labelsHidden()
				}
				.width(min: 150, ideal: 170)
				TableColumn("Amount") { $r in
					if r.isAction {
						Text("fires").foregroundStyle(.secondary)
					} else {
						HStack(spacing: 4) {
							Slider(value: Binding(get: { r.amount }, set: { r.amount = ($0 * 100).rounded() / 100 }), in: -1...1)
							Text(String(format: "%+.0f%%", r.amount * 100))
								.monospacedDigit()
								.frame(width: 44, alignment: .trailing)
						}
					}
				}
				.width(min: 150, ideal: 170)
				TableColumn("Curve") { $r in
					Picker("", selection: $r.curve) {
						Text("Linear").tag(0)
						Text("Soft").tag(1)
						Text("Hard").tag(2)
						Text("Gate").tag(3)
					}
					.labelsHidden()
				}
				.width(min: 70, ideal: 80)
				TableColumn("Polarity") { $r in
					if r.isAction {
						Text("—").foregroundStyle(.secondary)
					} else {
						Picker("", selection: $r.centered) {
							Text("Up").tag(false)
							Text("Centered").tag(true)
						}
						.labelsHidden()
					}
				}
				.width(min: 80, ideal: 90)
				TableColumn("Attack") { $r in
					if r.isTrigger {
						Text("—").foregroundStyle(.secondary)	// a hit's pulse starts at once
					} else {
						MsField(value: $r.attackMs)
					}
				}
				.width(64)
				TableColumn("Release") { $r in
					MsField(value: $r.releaseMs)
				}
				.width(64)
				TableColumn("Threshold") { $r in
					if r.curve == 3 || (r.isAction && !r.isTrigger) {
						TextField("", value: $r.threshold, format: .number.precision(.fractionLength(2)))
							.multilineTextAlignment(.trailing)
							.frame(width: 48)
					} else {
						Text("—").foregroundStyle(.secondary)
					}
				}
				.width(64)
			}
			Divider()
			VStack(alignment: .leading, spacing: 8) {
				if let notice = map.notice {
					Text(notice).font(.caption).foregroundStyle(.orange)
				}
				Text("Each row moves a control by a share of its slider as the sound (or a hit) rises, from the patch's own value; the patch itself never changes. Rows on the same control add up. Attack and release smooth the movement (ms); a hit's pulse fades over its release. Actions fire on a hit, or when a sound rises past the threshold.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				HStack(spacing: 12) {
					Button {
						var r = ModRowSetting()
						if let sel = map.rows.last(where: { selection.contains($0.id) }) {
							r = sel
							r.id = UUID()
						}
						map.rows.append(r)
						selection = [r.id]
					} label: { Image(systemName: "plus") }
						.help("Add a row (a copy of the selected one, if any)")
					Button {
						map.rows.removeAll { selection.contains($0.id) }
						selection = []
					} label: { Image(systemName: "minus") }
						.help("Remove the selected rows")
						.disabled(selection.isEmpty)
					Divider().frame(height: 16)
					Toggle("Modulation on", isOn: Binding(get: { !map.bypass }, set: { map.bypass = !$0 }))
						.help("Image > Audio Modulation (⌘8). Off: the patches as they are.")
					Text("Depth")
					Slider(value: $map.depth, in: 0...1)
						.frame(width: 140)
					Text(String(format: "%.0f%%", map.depth * 100))
						.monospacedDigit()
						.frame(width: 40, alignment: .trailing)
					Spacer()
					Button("Restore Defaults") { map.restoreDefaults() }
					Button("Import…") { map.importFile() }
					Button("Export…") { map.export() }
				}
			}
			.padding(10)
		}
		.onAppear { levels.start() }
		.onDisappear { levels.stop() }
	}

	private func level(of id: ModRowSetting.ID) -> Double {
		guard let i = map.rows.firstIndex(where: { $0.id == id }), i < levels.levels.count else { return 0 }
		return levels.levels[i]
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

/// A time in milliseconds, 0 to 5000.
private struct MsField: View {
	@Binding var value: Double

	var body: some View {
		TextField("", value: Binding(get: { value }, set: { value = min(max($0.rounded(), 0), 5000) }), format: .number)
			.multilineTextAlignment(.trailing)
			.frame(width: 52)
	}
}
