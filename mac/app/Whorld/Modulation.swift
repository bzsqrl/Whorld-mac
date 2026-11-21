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
import Observation

/// The audio input's settings, kept in Whorld's settings.
enum AudioSettings {
	static let inputKey = "Audio_sInputUID"	// "" none, "default", or a device uid
	static let firstKey = "Audio_nChannelFirst"
	static let countKey = "Audio_nChannelCount"	// 0: all channels, mixed
	static let gainKey = "Audio_fGainDb"
	static let rangeKey = "Audio_fRangeDb"
	static let autoLevelKey = "Audio_bAutoLevel"
	static let hitThresholdKey = "Audio_fHitThreshold"
	static let linkKey = "Link_bEnabled"
	static let linkSyncKey = "Link_bStartStopSync"

	static func register() {
		UserDefaults.standard.register(defaults: [
			inputKey: "", firstKey: 0, countKey: 0, gainKey: 0.0, rangeKey: 36.0, autoLevelKey: false, hitThresholdKey: 4.0, linkKey: false, linkSyncKey: false,
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
		WHLink.shared.startStopSync = d.bool(forKey: linkSyncKey)
		WHLink.shared.enabled = d.bool(forKey: linkKey)
	}

	@MainActor static func selectInput() {
		let d = UserDefaults.standard
		WHAudioInput.shared.selectDevice(d.string(forKey: inputKey) ?? "",
			channelFirst: d.integer(forKey: firstKey), count: d.integer(forKey: countKey))
	}
}

/// The Modulation panel (View > Modulation, ⌥⌘6), floating or docked. As
/// wide as two columns allow, the input's settings and Hearing side by
/// side; narrower (docked, say), one above the other, and narrower than
/// that, the top half scrolls sideways (the rows table scrolls itself). As
/// short as the top half and one row of the table.
struct ModulationView: View {
	@State private var size = CGSize(width: 1300, height: 800)
	@State private var topHeight: CGFloat = 0

	/// widths the layouts need (measured at their fixed sizes, with padding)
	static let twoColumns: CGFloat = 1240
	static let oneRowTopBar: CGFloat = 780
	static let oneColumn: CGFloat = 640
	/// shorter than the top half and this much table (a short docked pane):
	/// all of it scrolls, the table this tall
	static let tableInScroll: CGFloat = 260

	var body: some View {
		Group {
			if topHeight > 0 && size.height < topHeight + 1 + Self.tableInScroll / 2 {
				ScrollView(.vertical) {
					VStack(alignment: .leading, spacing: 0) {
						topRow
						Divider()
						ModTablesSection()
							.frame(height: Self.tableInScroll)
					}
				}
			} else {
				VStack(alignment: .leading, spacing: 0) {
					topRow
					Divider()
					ModTablesSection()
				}
			}
		}
		.background(NoSliderFocus())
		.background(GeometryReader { g in
			Color.clear
				.onAppear { size = g.size }
				.onChange(of: g.size) { _, s in size = s }
		})
		.onAppear { AudioSettings.register() }
	}

	/// the top half, scrolling sideways if the panel is narrower than one column
	@ViewBuilder private var topRow: some View {
		Group {
			if size.width < Self.oneColumn {
				ScrollView(.horizontal) {
					top
						.frame(width: Self.oneColumn)
				}
				.fixedSize(horizontal: false, vertical: true)
			} else {
				top
			}
		}
		.background(GeometryReader { g in	// its height, to know when the table wouldn't fit
			Color.clear
				.onAppear { topHeight = g.size.height }
				.onChange(of: g.size.height) { _, h in topHeight = h }
		})
	}

	private var top: some View {
		VStack(alignment: .leading, spacing: 0) {
			ModTopBar(twoRows: max(size.width, Self.oneColumn) < Self.oneRowTopBar)
				.padding(.horizontal, 16)
				.padding(.vertical, 10)
			Divider()
			AudioInputSection(stacked: size.width < Self.twoColumns)
				.padding(16)
		}
	}
}

/// The top row: modulation on or off and its depth, then the rows' files.
private struct ModTopBar: View {
	let twoRows: Bool	// narrow: the files' buttons under the switch and depth
	@Bindable private var map = ModMap.shared

	var body: some View {
		if twoRows {
			VStack(alignment: .leading, spacing: 8) {
				HStack(spacing: 12) { switchAndDepth }
				HStack(spacing: 12) { files }
			}
		} else {
			HStack(spacing: 12) {
				switchAndDepth
				Spacer()
				files
			}
		}
	}

	@ViewBuilder private var switchAndDepth: some View {
			Toggle("Modulation", isOn: Binding(get: { !map.bypass }, set: { map.bypass = !$0 }))
				.toggleStyle(.switch)
				.help("All rows on or off; off, the patches play as they are. Audio > Audio Modulation (⌘'), or Mod in the stats strip, OSC /w/mod/on.")
			Text("Depth")
				.padding(.leading, 8)
			StepSlider(value: map.depth, range: 0...1, step: 0.01, defaultValue: 1) { map.depth = $0 }
				.frame(width: 160)
				.help("Scales every row at once. OSC /w/mod/depth.")
			Text(String(format: "%.0f%%", map.depth * 100))
				.monospacedDigit()
				.frame(width: 40, alignment: .trailing)
	}

	@ViewBuilder private var files: some View {
			Button("Restore Defaults") { map.restoreDefaults() }
				.help("The starting rows: bass widens the lines, a kick pulses the zoom.")
			Button("Import…") { map.importFile() }
				.help("Replace the rows with a saved file's.")
			Button("Export…") { map.export() }
				.help("Save the rows, depth and on/off in a file.")
	}
}

/// Redraws when the audio input's state or device list changes.
@MainActor
final class AudioInputWatch: ObservableObject {
	static let shared = AudioInputWatch()
	private init() {
		WHAudioInput.shared.changeHandler = { [weak self] in self?.objectWillChange.send() }
		WHLink.shared.changeHandler = { [weak self] in self?.objectWillChange.send() }
	}
}

/// The input: device, channels, gain, auto-level, hit sensitivity, status
/// and meter.
private struct AudioInputSection: View {
	/// the settings above Hearing, not beside it (a narrow panel)
	let stacked: Bool
	@ObservedObject private var watch = AudioInputWatch.shared
	@AppStorage(AudioSettings.inputKey) private var inputUID = ""
	@AppStorage(AudioSettings.firstKey) private var channelFirst = 0
	@AppStorage(AudioSettings.countKey) private var channelCount = 0
	@AppStorage(AudioSettings.gainKey) private var gainDb = 0.0
	@AppStorage(AudioSettings.rangeKey) private var rangeDb = 36.0	// mastered music lives in the top 15 to 20 dB
	@AppStorage(AudioSettings.autoLevelKey) private var autoLevel = false
	@AppStorage(AudioSettings.hitThresholdKey) private var hitThreshold = 4.0
	@AppStorage(AudioSettings.linkKey) private var linkEnabled = false
	@AppStorage(AudioSettings.linkSyncKey) private var linkSync = false
	// not ModMap: a view that observes it redraws on every step of a slider,
	// and this one lists the audio devices as it draws

	private var input: WHAudioInput { .shared }

	/// Ableton Link's state, for its row
	private var linkStatus: String {
		let link = WHLink.shared
		guard linkEnabled else { return "" }
		let n = link.peers
		if link.reconnecting {
			return link.drivesBeat ? String(format: "Reconnecting… keeping the last tempo (%.1f BPM)", link.tempo)
				: "Reconnecting… the beat comes from the music meanwhile"
		}
		if n == 0 {
			return "No other Link apps yet: the beat comes from the music"
		}
		let apps = n == 1 ? "1 Link app" : "\(n) Link apps"
		let transport = linkSync ? (link.playing ? " · playing" : " · stopped") : ""
		return apps + String(format: " · %.1f BPM", link.tempo) + transport + " · the beat comes from Ableton Link"
	}

	var body: some View {
		let devices = WHAudioInput.devices
		let apps = WHAudioInput.apps
		let selected = selectedDevice(devices)
		// two columns: the input's settings, and what Whorld hears with the
		// beat's buttons (the user's request, 2026-11-18: the window's top half
		// was mostly empty)
		// (one layout or the other, keeping the views, so the meter's host stays)
		let columns = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
			: AnyLayout(HStackLayout(alignment: .top, spacing: 20))
		columns {
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
						if WHAudioInput.tapsAvailable {
							Section("Sound from apps") {
								Text("Everything the Mac plays").tag("tap:all")
								ForEach(apps, id: \.bundleID) { a in
									Text(a.name + (a.playing ? "" : " (quiet)")).tag("tap:app:" + a.bundleID)
								}
								if inputUID.hasPrefix("tap:app:"), !apps.contains(where: { "tap:app:" + $0.bundleID == inputUID }) {
									Text(WHAudioInput.appName(String(inputUID.dropFirst("tap:app:".count))) + " (not using sound)").tag(inputUID)
								}
							}
						}
						if !inputUID.isEmpty, inputUID != "default", !inputUID.hasPrefix("tap:"), !devices.contains(where: { $0.uid == inputUID }) {
							Text("Not connected").tag(inputUID)
						}
					}
					.labelsHidden()
					.frame(width: 220)
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
					.frame(width: 170)
					.disabled((selected?.channels ?? 0) < 2)
				}
			}
			GridRow {
				Text("Gain")
				HStack {
					StepSlider(value: gainDb, range: -24...24, step: 0.5, defaultValue: 0) { gainDb = $0 }	// half-dB steps, no tick marks
						.frame(width: 220)
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
					StepSlider(value: rangeDb, range: 12...60, step: 1, defaultValue: 36) { rangeDb = $0 }
						.frame(width: 220)
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
					StepSlider(value: 10 - hitThreshold, range: 2...8, step: 0.1, defaultValue: 6) { hitThreshold = 10 - $0 }
						.frame(width: 220)
					Text("fewer ← → more")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			GridRow {
				Text("Ableton Link")
				HStack(spacing: 14) {
					Toggle(linkEnabled ? "Enabled" : "Disabled", isOn: $linkEnabled)
						.toggleStyle(.switch)
						.controlSize(.small)
					Toggle("Start/Stop sync", isOn: $linkSync)
						.disabled(!linkEnabled)
						.help("Beats only while the Link session plays (Ableton Live's transport, for one).")
					Text(linkStatus)
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(2)
						.frame(width: 200, alignment: .leading)	// beside the meter: it wraps
				}
				.help("Keeps time with Ableton Live and other Link apps on this Mac or the network: while the session has other apps, its tempo, beats and bars drive Beat and the bars, in place of the beat Whorld hears in the music.")
			}
			// Tempo Follows the Beat is in the Audio menu (it was a row here
			// too until 2026-11-19, the user's request)
			GridRow {
				Text("")
				AudioStatus(state: input.state, text: input.statusText)
			}
		}
		.fixedSize()
		Rectangle()	// a divider between the two, across or down
			.fill(Color(nsColor: .separatorColor))
			.frame(width: stacked ? nil : 1, height: stacked ? 1 : nil)
		VStack(alignment: .leading, spacing: 10) {
			Text("Hearing")
				.help("What Whorld hears, live: the level and bands, the hits (lights and hits a second), and the beat. The beat tracker learns the tempo from the hits and keeps a steady beat through kicks it can't hear (a busy mix, a breakdown).")
			AudioMeter()
			beatButtons
		}
		.fixedSize()
		Spacer(minLength: 0)
		}
		.fixedSize(horizontal: false, vertical: true)	// as tall as its columns: the divider would take all it's offered
		.onChange(of: inputUID) { AudioSettings.selectInput() }
		.onChange(of: channelFirst) { AudioSettings.selectInput() }
		.onChange(of: channelCount) { AudioSettings.selectInput() }
		.onChange(of: gainDb) { _, v in input.gainDb = v }
		.onChange(of: rangeDb) { _, v in input.rangeDb = v }
		.onChange(of: autoLevel) { _, v in input.autoLevel = v }
		.onChange(of: hitThreshold) { _, v in input.hitThreshold = v }
		.onChange(of: linkEnabled) { _, v in WHLink.shared.enabled = v }
		.onChange(of: linkSync) { _, v in WHLink.shared.startStopSync = v }
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

extension AudioInputSection {
	/// Reset to 1.1, the count a beat back or on (with Shift, a bar), and
	/// with Option half a beat: beside the meter, to keep the rows'
	/// phrases with the music's
	/// − or + with its modifiers: a beat, with Shift a bar, with Option
	/// half a beat (none under Ableton Link, which moves by bars)
	private static func step(_ dir: Int, _ mods: NSEvent.ModifierFlags, _ link: Bool) {
		if mods.contains(.option) && !link {
			ModMap.shiftHalfBeats(dir)
		} else {
			ModMap.nudge(beats: dir * (link || mods.contains(.shift) ? 4 : 1))
		}
	}

	private var beatButtons: some View {
		let link = WHLink.shared.drivesBeat	// whose beat within the bar is the session's
		// with Shift a bar, with Option half a beat, as the Audio menu's keys
		let mods = { NSEvent.modifierFlags.intersection([.shift, .option]) }
		return HStack(spacing: 6) {
			Button("Reset to 1.1") { ModMap.markDownbeat() }
				.controlSize(.small)
				.fixedSize()	// the text gives way, not the button
				.help("Press on the \"one\" (a drop, the start of a phrase): the beat nearest the press becomes beat 1 of bar 1, a little early or late alike. Audio > Reset to 1.1 (⌘\\), OSC /w/mod/downbeat.")
			Button { Self.step(-1, mods(), link) } label: { Text("\u{2212}").frame(minWidth: 10) }	// text, not a symbol: docked, the symbols sometimes didn't draw
				.controlSize(.small)
				.help(link ? "The count a bar back (Ableton Link sets the beat within the bar). Audio > Bar Back (⇧⌘[), OSC /w/mod/barback."
					: "The count a beat back, so the music's \"one\" comes a beat later in it; with ⇧, a bar back; with ⌥, half a beat back (for a beat Whorld found on the off-beats). Nothing fires, and waves ease to their new place. Audio > Beat Back (⌘[), Bar Back (⇧⌘[), Half Beat Back (⌥⌘[).")
			Button { Self.step(1, mods(), link) } label: { Text("+").frame(minWidth: 10) }
				.controlSize(.small)
				.help(link ? "The count a bar on (Ableton Link sets the beat within the bar). Audio > Bar Forward (⇧⌘]), OSC /w/mod/barfwd."
					: "The count a beat on; with ⇧, a bar on; with ⌥, half a beat on. Nothing fires, and waves ease to their new place. Audio > Beat Forward (⌘]), Bar Forward (⇧⌘]), Half Beat Forward (⌥⌘]).")
		}
	}
}

/// AppKit gives the window's first slider (Depth) focus as the window
/// opens, with its focus ring; this clears it. A slider takes focus when
/// it's clicked, as usual.
private struct NoSliderFocus: NSViewRepresentable {
	func makeNSView(context: Context) -> Probe { Probe() }
	func updateNSView(_ view: Probe, context: Context) {}

	final class Probe: NSView {
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			DispatchQueue.main.async { [weak self] in	// after AppKit has picked the key view
				guard let window = self?.window, window.firstResponder is KeySlider.Slider else { return }
				window.makeFirstResponder(nil)
			}
		}
	}
}

/// A slider in steps, on the panels' slider (KeySlider), so it works as
/// theirs do: a sideways two-finger swipe or a mouse wheel over it moves it,
/// clicking gives it focus for the left and right arrows, and right-clicking
/// restores `defaultValue`. (SwiftUI's Slider ignores swipes.)
private struct StepSlider: View {
	let value: Double
	let range: ClosedRange<Double>
	let step: Double	// the value of one position
	let defaultValue: Double
	let set: (Double) -> Void

	var body: some View {
		let perUnit = 1 / step	// whole (100, 10, 2), so values come out as 0.29, not 0.29000000000000004
		let lo = (range.lowerBound * perUnit).rounded(), hi = (range.upperBound * perUnit).rounded()
		KeySlider(position: value * perUnit, range: lo...hi,
			set: { set(min(max($0, lo), hi) / perUnit + 0) },	// + 0: never -0 ("-0%")
			reset: { set(defaultValue) },
			controlSize: .regular)
	}
}

/// What the analysis hears: bars for the level, bands and brightness,
/// lights that flash on hits, the beat and the phrase. The labels are
/// SwiftUI and never change; what moves is drawn by small AppKit views
/// that MeterFeed redraws, thirty times a second while shown. (Mac
/// addition, the user's report, 2026-11-18: any SwiftUI update in the
/// meter, however it was driven, laid out every pane of the Whorld window
/// again, and each layout dropped that pane's tooltips, so with Modulation
/// docked no tooltip in the window stayed up while music played. An AppKit
/// redraw lays out nothing.)
private struct AudioMeter: View {
	var body: some View {
		HStack(alignment: .top, spacing: 24) {
			VStack(alignment: .leading, spacing: 4) {
				bar("Level", 0, detail: true)
				bar("Bass", 1)
				bar("Low Mid", 2)
				bar("High Mid", 3)
				bar("Treble", 4)
				bar("Brightness", 5)
			}
			VStack(alignment: .leading, spacing: 8) {
				light("Hit", 0)
				light("Kick", 1)
				light("Hats", 2)
				Text("hits a second, over 4 s")
					.font(.caption2)
					.foregroundStyle(.secondary)
				beatRow
				phraseRow
			}
		}
	}

	private func bar(_ name: String, _ i: Int, detail: Bool = false) -> some View {
		HStack(spacing: 8) {
			Text(name)
				.font(.caption)
				.frame(width: 70, alignment: .trailing)
			MeterLive(part: .bar(i))
				.frame(width: MeterFeed.barWidth, height: 8)
			// a fixed width (the widest reading, "-150 dB"), so the column
			// beside doesn't move as the reading's length changes
			MeterLive(part: detail ? .levelDb : .none)
				.frame(width: MeterFeed.detailWidth, height: MeterFeed.textHeight)
		}
	}

	private func light(_ name: String, _ i: Int) -> some View {
		HStack(spacing: 6) {
			MeterLive(part: .light(i))
				.frame(width: 12, height: 12)
			Text(name).font(.caption)
				.frame(width: 34, alignment: .leading)
			MeterLive(part: .rate(i))
				.frame(width: 44, height: MeterFeed.textHeight)
		}
	}

	/// the beat's light (the tracker's, or Ableton Link's while it drives
	/// the beat), its tempo and place
	private var beatRow: some View {
		HStack(spacing: 6) {
			MeterLive(part: .light(3))
				.frame(width: 12, height: 12)
			Text("Beat").font(.caption)
				.frame(width: 34, alignment: .leading)
			MeterLive(part: .beatText)
				.frame(width: 230, height: MeterFeed.textHeight)
		}
		.padding(.top, 4)
	}

	/// Where the count is in an 8-bar phrase: a box a bar, the current one
	/// lit, orange on the phrase's one (1.1), so you can see whether the
	/// rows' phrases start where the music's do
	private var phraseRow: some View {
		HStack(spacing: 6) {
			Color.clear.frame(width: 12, height: 12)	// under the lights
			Text("Phrase").font(.caption)
				.frame(width: 34, alignment: .leading)
			MeterLive(part: .phrase)
				.frame(width: MeterFeed.phraseWidth, height: 8)
			MeterLive(part: .phraseText)
				.frame(width: 70, height: MeterFeed.textHeight)
		}
	}
}

/// The meter's moving parts, read from the analysis (and Ableton Link)
/// thirty times a second while a meter shows; the parts' views redraw when
/// what they show changes.
@MainActor
private final class MeterFeed {
	static let shared = MeterFeed()

	static let barWidth: CGFloat = 130	// (220 until the meter moved beside the settings)
	static let phraseWidth: CGFloat = 8 * 14 + 7 * 3
	static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
	static let textHeight: CGFloat = ceil(font.ascender - font.descender + font.leading)
	static let detailWidth: CGFloat = ceil(("-150 dB" as NSString).size(withAttributes: [.font: font]).width) + 2

	struct Shown: Equatable {
		var bars = [Float](repeating: 0, count: 6)
		var levelDb = ""
		var lit = [false, false, false, false]	// hit, kick, hats, beat
		var rates = ["", "", ""]
		var beatText = ""
		var phraseBox = -1		// the bar lit, 0 to 7; -1: no count
		var phraseOne = false	// on the phrase's one: orange
		var phraseText = ""
	}
	private(set) var shown = Shown()

	private let views = NSHashTable<MeterLive.View>.weakObjects()
	private var timer: Timer?
	private var lastCounts: [UInt32]?
	private var lastLinkBeat: Int?
	private var flashUntil = [Date](repeating: .distantPast, count: 4)
	private var history: [(time: Date, counts: [UInt32])] = []	// the last few seconds, for rates
	private var lastQuarter = 0

	func add(_ v: MeterLive.View) {
		views.add(v)
		guard timer == nil else { return }
		let t = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
			MainActor.assumeIsolated { MeterFeed.shared.tick() }
		}
		RunLoop.main.add(t, forMode: .common)	// also while a slider is dragged
		timer = t
		tick()
	}

	func remove(_ v: MeterLive.View) {
		views.remove(v)
		if views.allObjects.isEmpty {
			timer?.invalidate()
			timer = nil
		}
	}

	private func tick() {
		let r = WHAudioInput.shared.reading()
		let now = Date()
		let link = Self.linkBeat()
		// a light flashes on each new hit, and on Ableton Link's beats
		let counts = [r.hits, r.kicks, r.hats, r.beats]
		if let last = lastCounts {
			for i in 0..<4 where counts[i] != last[i] {
				flashUntil[i] = now.addingTimeInterval(0.12)
			}
		}
		lastCounts = counts
		if let b = link?.beat, b != lastLinkBeat {
			flashUntil[3] = now.addingTimeInterval(0.12)
		}
		lastLinkBeat = link?.beat
		let quarter = Int(now.timeIntervalSinceReferenceDate * 4)	// four times a second
		if quarter != lastQuarter {
			lastQuarter = quarter
			history.append((now, counts))
			history.removeAll { now.timeIntervalSince($0.time) > 4.1 }
		}

		var s = Shown()
		s.bars = [r.level, r.bass, r.lowMid, r.highMid, r.treble, r.brightness]
		s.levelDb = r.levelDb > -150 ? String(format: "%.0f dB", r.levelDb) : ""
		s.lit = flashUntil.map { now < $0 }
		s.rates = (0..<3).map { i in rate(i).map { String(format: "%.1f/s", $0) } ?? "" }
		let place = r.beatInBar >= 0 ? String(format: " · bar %d · beat %d", r.barInPhrase + 1, r.beatInBar + 1) : ""
		let heard: String = r.beatLocked.boolValue ? String(format: "%.1f BPM", r.tempo) + place
			: (r.level > 0 ? "finding the beat…" : "")
		s.beatText = link?.text ?? heard
		var bar = -1, beat = -1	// 0 to 31, 0 to 3; -1: no count
		if let link {
			if let b = link.beat {
				bar = ((b / 4) % 32 + 32) % 32
				beat = (b % 4 + 4) % 4
			}
		} else if r.beatInBar >= 0 {
			bar = Int(r.barInPhrase)
			beat = Int(r.beatInBar)
		}
		s.phraseBox = bar >= 0 ? bar % 8 : -1
		s.phraseOne = s.phraseBox == 0 && beat == 0
		s.phraseText = s.phraseBox >= 0 ? "bar \(s.phraseBox + 1) of 8" : ""
		guard s != shown else { return }
		let old = shown
		shown = s
		for v in views.allObjects where v.window != nil && v.part.changed(old, s) {
			v.needsDisplay = true
		}
	}

	/// hits a second of one kind over the last 4 seconds (nil until there's enough)
	private func rate(_ i: Int) -> Double? {
		guard let first = history.first, let last = history.last else { return nil }
		let dt = last.time.timeIntervalSince(first.time)
		guard dt > 1 else { return nil }
		return Double(last.counts[i] &- first.counts[i]) / dt
	}

	/// Ableton Link's beat now, while it drives the beat (nil otherwise; a
	/// nil beat while stopped)
	private static func linkBeat() -> (beat: Int?, text: String)? {
		let link = WHLink.shared
		guard link.drivesBeat else { return nil }
		var pos = 0.0
		guard link.beatPosition(&pos) else { return (nil, "Ableton Link · stopped") }
		let beat = Int(pos.rounded(.down))
		let inBar = ((beat % 4) + 4) % 4, bar = (((beat / 4) % 32) + 32) % 32	// (pos may be just below 0)
		return (beat, String(format: "Ableton Link · %.1f BPM · bar %d · beat %d", link.tempo, bar + 1, inBar + 1))
	}
}

/// One of the meter's moving parts (MeterFeed), drawn in AppKit
private struct MeterLive: NSViewRepresentable {
	enum Part: Equatable {
		case none, bar(Int), levelDb, light(Int), rate(Int), beatText, phrase, phraseText

		/// whether it shows something else from `a` to `b`
		func changed(_ a: MeterFeed.Shown, _ b: MeterFeed.Shown) -> Bool {
			switch self {
			case .none: false
			case .bar(let i): a.bars[i] != b.bars[i]
			case .levelDb: a.levelDb != b.levelDb
			case .light(let i): a.lit[i] != b.lit[i]
			case .rate(let i): a.rates[i] != b.rates[i]
			case .beatText: a.beatText != b.beatText
			case .phrase: a.phraseBox != b.phraseBox || a.phraseOne != b.phraseOne
			case .phraseText: a.phraseText != b.phraseText
			}
		}
	}
	let part: Part

	final class View: NSView {
		var part: Part = .none {
			didSet { if part != oldValue { needsDisplay = true } }
		}

		override var isFlipped: Bool { true }
		override func hitTest(_ point: NSPoint) -> NSView? { nil }	// the meter's tips are its labels'

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if window != nil { MeterFeed.shared.add(self) } else { MeterFeed.shared.remove(self) }
		}

		override func viewDidChangeEffectiveAppearance() {
			super.viewDidChangeEffectiveAppearance()
			needsDisplay = true
		}

		/// as SwiftUI's Color.secondary.opacity(f)
		private func secondary(_ f: CGFloat) -> NSColor {
			let c = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? .gray
			return c.withAlphaComponent(c.alphaComponent * f)
		}

		private func text(_ s: String) {
			guard !s.isEmpty else { return }
			let style = NSMutableParagraphStyle()
			style.lineBreakMode = .byTruncatingTail
			let attrs: [NSAttributedString.Key: Any] = [.font: MeterFeed.font,
				.foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
			(s as NSString).draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
		}

		override func draw(_ dirtyRect: NSRect) {
			let s = MeterFeed.shared.shown
			switch part {
			case .none:
				break
			case .bar(let i):
				secondary(0.2).setFill()
				NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
				let w = CGFloat(min(max(s.bars[i], 0), 1)) * bounds.width
				if w > 0 {
					NSColor.controlAccentColor.setFill()
					NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height), xRadius: 2, yRadius: 2).fill()
				}
			case .levelDb:
				text(s.levelDb)
			case .light(let i):
				(s.lit[i] ? (i == 3 ? NSColor.systemOrange : NSColor.controlAccentColor) : secondary(0.25)).setFill()
				NSBezierPath(ovalIn: bounds).fill()
			case .rate(let i):
				text(s.rates[i])
			case .beatText:
				text(s.beatText)
			case .phrase:
				for i in 0..<8 {
					let color = i == s.phraseBox ? (s.phraseOne ? NSColor.systemOrange : NSColor.controlAccentColor)
						: secondary(i == 0 ? 0.45 : 0.2)	// its first bar a little brighter
					color.setFill()
					NSBezierPath(roundedRect: NSRect(x: CGFloat(i) * 17, y: 0, width: 14, height: bounds.height),
						xRadius: 2, yRadius: 2).fill()
				}
			case .phraseText:
				text(s.phraseText)
			}
		}
	}

	func makeNSView(context: Context) -> View {
		let v = View()
		v.part = part
		return v
	}

	func updateNSView(_ v: View, context: Context) {
		v.part = part
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

	private init() {
		var f = File(rows: Self.standard)
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

	private func changed() {
		if let data = try? JSONEncoder().encode(file) {
			UserDefaults.standard.set(data, forKey: Self.defaultsKey)
		}
		apply()
	}

	private func apply() {
		// every row, so the engine's row levels line up with these;
		// rows it doesn't know (from a newer Whorld) do nothing
		// (Frequency rows lock oscillators: the engine makes them syncs)
		engine?.setModulationRows(rows.map { $0.engineRow() }, syncs: [],
			depth: depth, bypass: bypass, followTempo: followTempo)
	}

	func restoreDefaults() {
		rows = Self.standard
		depth = 1
		bypass = false
		followTempo = false
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
		rows = known
		depth = min(max(f.depth, 0), 1)
		bypass = f.bypass
		followTempo = f.followTempo
		notice = skipped > 0 ? "\(skipped) row\(skipped == 1 ? "" : "s") skipped: from a newer Whorld, with a source, control or parameter this one doesn't have." : nil
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
			depth = min(max(value, 0), 1)
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
private struct ModTablesSection: View {
	@Bindable private var map = ModMap.shared
	private let levels = ModLevels.shared	// not observed here (see ModLevels)
	@State private var selection = Set<ModRowSetting.ID>()

	var body: some View {
		VStack(spacing: 0) {
			rowsTable
			Divider()
			HStack(spacing: 12) {
				Button { add() } label: { Image(systemName: "plus") }
					.help("Add a row (a copy of the selected one, if any)")
				Button { remove() } label: { Image(systemName: "minus") }
					.help("Remove the selected rows")
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
	private func stable<C: View>(_ r: ModRowSetting, @ViewBuilder _ content: @escaping () -> C) -> some View {
		var key = r
		key.amount = 0
		return SameRow(index: map.rows.firstIndex(where: { $0.id == r.id }) ?? -1, row: key, content: content)
			.equatable()
	}

	private var rowsTable: some View {
			Table($map.rows, selection: $selection) {
				TableColumn("On" + ColumnTips.mark) { $r in
					stable(r) {
						Toggle("", isOn: $r.on).labelsHidden()
					}
				}
				.width(46)
				TableColumn("Source" + ColumnTips.mark) { $r in
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
				TableColumn("Live" + ColumnTips.mark) { $r in
					RowLevel(index: map.rows.firstIndex(where: { $0.id == r.id }) ?? -1)
				}
				.width(60)
				TableColumn("Target" + ColumnTips.mark) { $r in
					stable(r) {
						TargetMenu(row: $r)
					}
				}
				.width(min: 140, ideal: 150)
				TableColumn("Amount" + ColumnTips.mark) { $r in
					if r.isAction {
						Text("fires").foregroundStyle(.secondary)
					} else if r.isOscillator {	// what the lock keeps
						PatchOscillator(iParam: WHMappingInfo.target(forTag: r.target))
					} else {
						HStack(spacing: 4) {
							StepSlider(value: r.amount, range: -1...1, step: 0.01, defaultValue: ModRowSetting().amount) { r.amount = $0 }
							Text(String(format: "%+.0f%%", r.amount * 100 + 0))	// + 0: an older -0 shows as 0%
								.monospacedDigit()
								.frame(width: 44, alignment: .trailing)
						}
					}
				}
				.width(min: 140, ideal: 150)
				TableColumn("Curve" + ColumnTips.mark) { $r in
					stable(r) {
						if r.isOscillator {
							Text("—").foregroundStyle(.secondary)
						} else {
							Picker("", selection: $r.curve) {
								Text("Linear").tag(0)
								Text("Soft").tag(1)
								Text("Hard").tag(2)
								Text("Gate").tag(3)
							}
							.labelsHidden()
						}
					}
				}
				.width(min: 70, ideal: 80)
				TableColumn("Polarity" + ColumnTips.mark) { $r in
					stable(r) {
						if r.isAction || r.isOscillator {
							Text("—").foregroundStyle(.secondary)
						} else {
							Picker("", selection: $r.centered) {
								Text("Up").tag(false)
								Text("Centered").tag(true)
							}
							.labelsHidden()
						}
					}
				}
				.width(min: 80, ideal: 90)
				TableColumn("Attack · Release" + ColumnTips.mark) { $r in
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
				TableColumn("Offset" + ColumnTips.mark) { $r in
					stable(r) {
						if r.isTrigger || r.isLFO || r.isOscillator {
							OffsetField(value: $r.offsetMs, earlyAllowed: r.isBeatBased || r.isLFO)
						} else {
							Text("—").foregroundStyle(.secondary)
						}
					}
				}
				.width(64)
				TableColumn("Threshold" + ColumnTips.mark) { $r in
					stable(r) {
						if !r.isOscillator && (r.curve == 3 || (r.isAction && !r.isTrigger)) {
							RowNumber(value: $r.threshold, lo: 0, hi: 1, fine: 0.01, coarse: 0.1,
								defaultValue: ModRowSetting().threshold, decimals: 2, width: 52)
						} else {
							Text("—").foregroundStyle(.secondary)
						}
					}
				}
				.width(92)
			}
			.background(ColumnTips())
			.frame(minHeight: Self.oneRowHeight)	// the window can shrink to one row (the user's request, 2026-11-18)
	}

	/// the table's header and one row (a row holds a regular-size pop-up)
	static let oneRowHeight: CGFloat = 28 + 34

}

/// See ModTablesSection.stable
private struct SameRow<Content: View>: View, Equatable {
	let index: Int
	let row: ModRowSetting
	@ViewBuilder let content: () -> Content

	static func == (a: Self, b: Self) -> Bool { a.index == b.index && a.row == b.row }

	var body: some View { content() }
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
private struct ColumnTips: NSViewRepresentable {
	static let mark = "  ⓘ"
	static let tips: [String: String] = [
		"On": "Turn the row on or off.",
		"Source": "What moves the target: a level, a band, a hit, the beat, or the Beat LFO (a wave locked to the beat: length, shape and phase in the menu beside it).",
		"Live": "The source now, after smoothing and the curve.",
		"Target": "The control the row moves, from the patch's own value (the patch never changes; rows on one control add up); an action, fired on a hit; or a parameter's Frequency, which locks its oscillator to the beat (length and phase beside the source).",
		"Amount": "How far the target moves at full level, as a share of its slider; negative moves it down.",
		"Curve": "Linear; Soft (quiet passages count more); Hard (only loud ones); Gate (all or nothing at the threshold).",
		"Polarity": "Up: from the value upward. Centered: either side of it.",
		"Attack · Release": "How quickly the movement rises and falls, in ms. A hit's pulse fades over its release.",
		"Offset": "Moves beat rows this many ms early (−) or late. Hits can only be late.",
		"Threshold": "For the Gate curve, and actions on a sound: the level, 0 to 1, that sets them off.",
	]

	func makeNSView(context: Context) -> NSView { NSView() }

	func makeCoordinator() -> Coordinator { Coordinator() }

	/// A click on a header's ⓘ shows its column's tip (InfoPopover, as every
	/// ⓘ; the user's request, 2026-11-19: the headers showed it on hover).
	/// Caught before the header, which tracks the mouse itself (a gesture
	/// recognizer there never sees the click end).
	final class Coordinator: NSObject {
		weak var header: NSTableHeaderView?
		private var monitor: Any?

		@MainActor func install(on header: NSTableHeaderView) {
			self.header = header
			guard monitor == nil else { return }
			monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
				MainActor.assumeIsolated { self?.clicked(e) ?? false } ? nil : e
			}
		}

		/// true: it was on an ⓘ, and the tip is showing (or closed again)
		@MainActor private func clicked(_ e: NSEvent) -> Bool {
			guard let header, let table = header.tableView, e.window === header.window else { return false }
			let p = header.convert(e.locationInWindow, from: nil)
			guard header.bounds.contains(p) else { return false }
			let i = header.column(at: p)
			guard i >= 0, i < table.tableColumns.count else { return false }
			let cell = table.tableColumns[i].headerCell
			let title = cell.stringValue
			guard title.hasSuffix(ColumnTips.mark),
				let tip = ColumnTips.tips[String(title.dropLast(ColumnTips.mark.count))],
				let mark = ColumnTips.markRect(cell, in: header.headerRect(ofColumn: i)), mark.contains(p) else { return false }
			InfoPopover.shared.toggle(tip, from: header, rect: mark)
			return true
		}

		deinit {
			if let monitor { NSEvent.removeMonitor(monitor) }
		}
	}

	/// where a header cell draws its title's ⓘ (the title's last glyph), a
	/// little grown to be easy to hit
	static func markRect(_ cell: NSTableHeaderCell, in r: NSRect) -> NSRect? {
		let title = cell.attributedStringValue
		guard title.length > 0 else { return nil }
		let text = cell.titleRect(forBounds: r)
		let font: [NSAttributedString.Key: Any] = [.font: cell.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
		let full = (title.string as NSString).size(withAttributes: font).width
		let icon = ("ⓘ" as NSString).size(withAttributes: font).width
		let x: CGFloat
		switch cell.alignment {
		case .right: x = text.maxX - icon
		case .center: x = text.midX + full / 2 - icon
		default: x = text.minX + full - icon
		}
		return NSRect(x: x - 4, y: r.minY, width: icon + 14, height: r.height)	// more room after: the cell draws a little in from its title rect
	}

	func updateNSView(_ view: NSView, context: Context) {
		let c = context.coordinator
		DispatchQueue.main.async {	// once the table is in the window
			guard let root = view.window?.contentView, let table = Self.table(in: root) else { return }
			for column in table.tableColumns where column.headerToolTip != nil {
				column.headerToolTip = nil	// no hover tip: the ⓘ is clicked
			}
			if let header = table.headerView, c.header !== header {
				c.install(on: header)
			}
		}
	}

	private static func table(in view: NSView) -> NSTableView? {
		if let t = view as? NSTableView { return t }
		for sub in view.subviews {
			if let t = table(in: sub) { return t }
		}
		return nil
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
		.help("The Beat LFO: \(lengthName), \(shapeName), phase \(String(format: "%.0f°", row.lfoPhaseDeg)). One cycle every so many beats, from the one (Reset to 1.1); Ableton Link's beat, or the beat Whorld hears.")
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
				if k == .coarse || (d > 0 ? v < 1 : v <= 1) {
					x = d > 0 ? v * 2 : v / 2
					if d > 0 && v < 1 { x = min(x, 1) }	// halves up to one
				} else {
					x = d > 0 ? v.rounded(.down) + 1 : v.rounded(.up) - 1	// whole numbers
				}
				return min(max(x, lo), hi)
			},
			lo: lo, hi: hi, defaultValue: 1, width: 46, fractions: true)
			.help("The cycle's length, in \(row.lfoInBars ? "bars" : "beats"): any number, or a fraction such as 1/3 (triplets). ↑ ↓ or a swipe step it.")
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
		Picker("", selection: Binding(get: { row.lfoInBars }, set: { bars in
			guard bars != row.lfoInBars else { return }
			row.lfoInBars = bars
			row.lfoBeats = min(max(n * (bars ? 4 : 1), ModRowSetting.minBeats), ModRowSetting.maxBeats)
		})) {
			Text(n == 1 ? "Beat" : "Beats").tag(false)
			Text(n == 1 ? "Bar" : "Bars").tag(true)
		}
		.labelsHidden()
		.fixedSize()
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
		.help(row.isPulse
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
					.help("This parameter's amplitude is 0 in the patch, so its oscillator doesn't move, locked to the beat or not.")
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
		RowNumber(value: $value, lo: earlyAllowed ? -300 : 0, hi: 300, fine: 1, coarse: 10, defaultValue: 0, width: 52)
			.help(earlyAllowed
				? "Milliseconds before (negative) or after (positive) the beat or bar that the row fires, -300 to 300."
				: "Milliseconds after the hit that the row fires, up to 300 (a hit can't be anticipated).")
	}
}

/// A time in milliseconds, 0 to 5000: an attack or release
private struct MsField: View {
	@Binding var value: Double
	let defaultValue: Double

	var body: some View {
		RowNumber(value: $value, lo: 0, hi: 5000, fine: 10, coarse: 100, defaultValue: defaultValue, width: 52)
	}
}

/// A row's number box, as the panels' (NumberField): type a value, or step
/// it with the arrow keys, a swipe up or down or the mouse wheel (`fine`
/// steps, `coarse` with Shift, to either end with Command-Shift);
/// right-click for `defaultValue`. Kept within lo to hi, on the fine step's
/// grid when stepped (250 steps to 260, then with Shift to 360).
private struct RowNumber: View {
	@Binding var value: Double
	let lo: Double
	let hi: Double
	let fine: Double
	let coarse: Double
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
			step: { v, d, k in
				let x = v + Double(d) * (k == .coarse ? coarse : fine)
				return min(max((x / fine).rounded() * fine, lo), hi)	// on the fine step's grid, as KeyStep
			},
			lo: lo, hi: hi, defaultValue: defaultValue, width: width)
	}
}
