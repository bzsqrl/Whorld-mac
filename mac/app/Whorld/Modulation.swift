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

/// The Modulation panel (View > Modulation, ⌥⌘7), floating or docked. As
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
				.help("All rows on or off; off, the patches play as they are. Audio > Audio Modulation (⌘'), or Mod in the Perform Bar, OSC /w/mod/on.")
			// its state in words, where you're looking (the design audit,
			// 2026-11-24: off, the rows below looked as live as on)
			(map.bypass
				? Text("Off").fontWeight(.semibold) + Text(": the rows don't move anything (⌘')").foregroundColor(.secondary)
				: Text("On").fontWeight(.semibold))
				.lineLimit(1)
				.fixedSize()
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
struct StepSlider: View {
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

