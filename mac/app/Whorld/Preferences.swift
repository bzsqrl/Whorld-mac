// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

import SwiftUI

/// Options from OptionsDef.h, stored in UserDefaults under the Windows
/// names (group_name). MIDI options arrive in Phase 5; the recent-files
/// count is managed by macOS.
enum Preferences {
	static let defaults = UserDefaults.standard

	static func register() {
		defaults.register(defaults: [
			"Input_fWheelSense": 6.25,
			"Export_sImageFolder": "",
			"Export_nImageWidth": 1920,
			"Export_nImageHeight": 1080,
			"Export_bUseViewSize": true,
			"Export_nScaleToFit": 0,
			"Export_bPromptUser": true,
			"Snapshot_bLetterbox": true,
			"Snapshot_iLegacySize": 1,
			"Midi_sInputDevice": "",
			"Render_bMetal": true,
			"General_bReopenLast": true,
			"General_bCheckUpdates": true,
			"Render_nMaxFrameRate": 0,
		])
	}

	/// Live view renderer: Metal (true) or Core Graphics (new in the Mac port)
	static var preferMetal: Bool {
		register()
		return defaults.bool(forKey: "Render_bMetal")
	}

	/// MIDI input device, by name (the Windows option stores an index)
	static var midiInputName: String? {
		register()
		let s = defaults.string(forKey: "Midi_sInputDevice") ?? ""
		return s.isEmpty ? nil : s
	}

	static var wheelSense: Double {
		register()
		return defaults.double(forKey: "Input_fWheelSense")
	}

	/// Live view frame rate limit, or 0 for the display's refresh rate (new in the Mac port)
	static var maxFrameRate: Int {
		register()
		return defaults.integer(forKey: "Render_nMaxFrameRate")
	}

	/// Check GitHub for a newer release once a day (Updates.swift; new in the Mac port)
	static var checkForUpdates: Bool {
		register()
		return defaults.bool(forKey: "General_bCheckUpdates")
	}

	/// Reopen the last playlist and patch at launch (Session; new in the Mac port)
	static var reopenLast: Bool {
		register()
		return defaults.bool(forKey: "General_bReopenLast")
	}

	static var snapshotLetterbox: Bool {
		register()
		return defaults.bool(forKey: "Snapshot_bLetterbox")
	}
}

struct PreferencesView: View {
	@EnvironmentObject private var model: AppModel
	@AppStorage("Input_fWheelSense") private var wheelSense = 6.25
	@AppStorage("Export_sImageFolder") private var imageFolder = ""
	@AppStorage("Export_nImageWidth") private var imageWidth = 1920
	@AppStorage("Export_nImageHeight") private var imageHeight = 1080
	@AppStorage("Export_bUseViewSize") private var useViewSize = true
	@AppStorage("Export_nScaleToFit") private var scaleToFit = 0
	@AppStorage("Export_bPromptUser") private var promptUser = true
	@AppStorage("Snapshot_bLetterbox") private var letterbox = true
	@AppStorage("Snapshot_iLegacySize") private var legacySize = 1

	@AppStorage("Midi_sInputDevice") private var midiInput = ""
	@AppStorage("Render_bMetal") private var useMetal = true
	@AppStorage("General_bReopenLast") private var reopenLast = true
	@AppStorage("General_bCheckUpdates") private var checkUpdates = true
	@AppStorage("Render_nMaxFrameRate") private var maxFrameRate = 0

	var body: some View {
		Form {
			Section("General") {
				Toggle("Reopen the last playlist and patch at launch", isOn: $reopenLast)
				HStack {
					Toggle("Check for updates automatically", isOn: $checkUpdates)
					Spacer()
					Button("Check Now") { UpdateChecker.shared.checkNow() }
				}
				Text("Once a day, Whorld asks GitHub whether a newer version has been released; only Whorld's version number is sent. Updates are never installed by themselves, and never announced in full screen.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Section("Rendering") {
				Picker("Renderer", selection: $useMetal) {
					Text("Metal (GPU)").tag(true)
					Text("Core Graphics (CPU)").tag(false)
				}
				.onChange(of: useMetal) { _, on in model.engine.preferMetal = on }
				Text(WHEngine.metalAvailable
					? "For the live view. Exports always use Core Graphics."
					: "Metal needs a Mac with Apple silicon; the live view uses Core Graphics.")
					.font(.caption)
					.foregroundStyle(.secondary)
				Picker("Frame rate", selection: $maxFrameRate) {
					Text("Display refresh rate").tag(0)
					Text("60 fps").tag(60)
				}
				.onChange(of: maxFrameRate) { _, rate in model.engine.maxFrameRate = rate }
				Text("Rings move a step each frame, so at 120 Hz patches run twice as fast as on a 60 Hz display. 60 fps matches Windows on a typical monitor and uses about half the power.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Section("MIDI") {
				let _ = model.changes.midi.n
				Picker("Input device", selection: $midiInput) {
					Text("None").tag("")
					ForEach(model.engine.midiInputNames, id: \.self) { name in
						Text(name).tag(name)
					}
					if !midiInput.isEmpty && !model.engine.midiInputNames.contains(midiInput) {
						Text(midiInput + " (not connected)").tag(midiInput)
					}
				}
				.onChange(of: midiInput) { _, name in
					model.engine.midiInputName = name.isEmpty ? nil : name
				}
			}
			Section("Input") {
				LabeledContent("Wheel sensitivity") {
					HStack {
						Slider(value: $wheelSense, in: 0.1...10)
						Text(String(format: "%.2f", wheelSense))
							.monospacedDigit()
							.frame(width: 40, alignment: .trailing)
					}
				}
			}
			Section("Export") {
				LabeledContent("Image folder") {
					HStack {
						Text(imageFolder.isEmpty ? "Pictures" : (imageFolder as NSString).abbreviatingWithTildeInPath)
							.lineLimit(1)
							.truncationMode(.middle)
						Button("Choose…", action: chooseFolder)
					}
				}
				Toggle("Use view size", isOn: $useViewSize)
				LabeledContent("Image size") {
					HStack {
						TextField("Width", value: $imageWidth, format: .number.grouping(.never))
							.labelsHidden()
							.multilineTextAlignment(.trailing)
							.frame(width: 72)
						Text("×")
						TextField("Height", value: $imageHeight, format: .number.grouping(.never))
							.labelsHidden()
							.multilineTextAlignment(.trailing)
							.frame(width: 72)
					}
					.disabled(useViewSize)
				}
				Picker("Scale to fit", selection: $scaleToFit) {
					Text("None").tag(0)
					Text("Width").tag(1)
					Text("Height").tag(2)
					Text("Both").tag(3)
				}
				Toggle("Prompt for export options", isOn: $promptUser)
			}
			Section("Snapshot") {
				Toggle("Letterbox", isOn: $letterbox)
					.onChange(of: letterbox) { _, on in model.engine.setSnapshotLetterbox(on) }
				Picker("Legacy snapshot size", selection: $legacySize) {
					Text("640 × 480 (VGA)").tag(0)
					Text("800 × 600 (SVGA)").tag(1)
					Text("1024 × 768 (XGA)").tag(2)
				}
			}
		}
		.formStyle(.grouped)
		.frame(width: 460, height: 700)
		.onAppear { Preferences.register() }
	}

	private func chooseFolder() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.canCreateDirectories = true
		if panel.runModal() == .OK, let url = panel.url {
			imageFolder = url.path
		}
	}
}
