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
// (WHAudioInput) and a live meter of what the analysis hears; the routing
// rows come in Phase 9.4. Everything here is a setting, the same for every
// patch and playlist.

import AppKit
import SwiftUI

/// The audio input's settings, kept in Whorld's settings.
enum AudioSettings {
	static let inputKey = "Audio_sInputUID"	// "" none, "default", or a device uid
	static let firstKey = "Audio_nChannelFirst"
	static let countKey = "Audio_nChannelCount"	// 0: all channels, mixed
	static let gainKey = "Audio_fGainDb"
	static let autoLevelKey = "Audio_bAutoLevel"
	static let hitThresholdKey = "Audio_fHitThreshold"

	static func register() {
		UserDefaults.standard.register(defaults: [
			inputKey: "", firstKey: 0, countKey: 0, gainKey: 0.0, autoLevelKey: false, hitThresholdKey: 4.0,
		])
	}

	/// At launch: the analysis settings, then the input chosen last time.
	@MainActor static func apply() {
		register()
		let d = UserDefaults.standard
		let input = WHAudioInput.shared
		input.gainDb = d.double(forKey: gainKey)
		input.autoLevel = d.bool(forKey: autoLevelKey)
		input.hitThreshold = d.double(forKey: hitThresholdKey)
		selectInput()
	}

	@MainActor static func selectInput() {
		let d = UserDefaults.standard
		WHAudioInput.shared.selectDevice(d.string(forKey: inputKey) ?? "",
			channelFirst: d.integer(forKey: firstKey), count: d.integer(forKey: countKey))
	}

	/// Development aid until the routing rows' window (Phase 9.4): with
	/// WHORLD_MOD_TEST=1 in the environment, Bass widens the lines and each
	/// kick pulses the zoom.
	@MainActor static func installTestRows(_ engine: WHEngine) {
		guard ProcessInfo.processInfo.environment["WHORLD_MOD_TEST"] == "1" else { return }
		let bass = WHModRow()
		bass.source = "Bass"
		bass.target = WHMappingInfo.target(forTag: "LineWidth")
		bass.amount = 0.3
		bass.attack = 0.01
		bass.releaseTime = 0.15
		let kick = WHModRow()
		kick.source = "Kick"
		kick.target = WHMappingInfo.target(forTag: "Zoom")
		kick.amount = 0.08
		kick.releaseTime = 0.25
		engine.setModulationRows([bass, kick], depth: 1, bypass: false)
	}
}

/// Window > Modulation...
struct ModulationView: View {
	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			AudioInputSection()
				.padding(16)
			Divider()
			Spacer(minLength: 0)
		}
		.frame(minWidth: 620, minHeight: 300)
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
					Text(String(format: "%+.1f dB", gainDb))
						.monospacedDigit()
						.frame(width: 64, alignment: .trailing)
					Toggle("Auto-level", isOn: $autoLevel)
						.help("Follows the music's recent peak, so quiet and loud material both use the whole range.")
				}
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
					light("Hit", lit: now < flashUntil[0])
					light("Kick", lit: now < flashUntil[1])
					light("Hats", lit: now < flashUntil[2])
				}
			}
			.onChange(of: [r.hits, r.kicks, r.hats]) { _, counts in
				for i in 0..<3 where counts[i] != lastCounts[i] {
					flashUntil[i] = Date().addingTimeInterval(0.12)
				}
				lastCounts = counts
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

	private func light(_ name: String, lit: Bool) -> some View {
		HStack(spacing: 6) {
			Circle()
				.fill(lit ? Color.accentColor : Color.secondary.opacity(0.25))
				.frame(width: 12, height: 12)
			Text(name).font(.caption)
		}
	}
}
