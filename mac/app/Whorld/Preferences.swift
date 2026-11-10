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
			"General_sAuthorName": "",
			"Render_nMaxFrameRate": 0,
			"Rings_bFadeEased": false,
			"OSC_bEnabled": true,
			"OSC_nReceivePort": 8000,
			"OSC_nSendPort": 8001,
			"OSC_sHost": "",
			"Syphon_bEnabled": false,
			"Syphon_bFixedSize": false,
			"Syphon_nWidth": 1920,
			"Syphon_nHeight": 1080,
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

	/// OSC remote control (new in the Mac port): on, the port Whorld listens
	/// on, the port it sends to, and a host it always sends to ("" for none;
	/// it also answers every device that has sent it something lately)
	static var osc: (enabled: Bool, receivePort: Int, sendPort: Int, host: String) {
		register()
		return (defaults.bool(forKey: "OSC_bEnabled"), defaults.integer(forKey: "OSC_nReceivePort"),
			defaults.integer(forKey: "OSC_nSendPort"),
			(defaults.string(forKey: "OSC_sHost") ?? "").trimmingCharacters(in: .whitespaces))
	}

	/// Syphon output (new in the Mac port): on, and a fixed size in pixels
	/// (nil: the output's own size)
	static var syphon: (enabled: Bool, fixedSize: (width: Int, height: Int)?) {
		register()
		let fixed = defaults.bool(forKey: "Syphon_bFixedSize")
		return (defaults.bool(forKey: "Syphon_bEnabled"),
			fixed ? (defaults.integer(forKey: "Syphon_nWidth"), defaults.integer(forKey: "Syphon_nHeight")) : nil)
	}

	/// Ring fade curve (new in the Mac port): eased (an S-curve) or linear.
	/// How far rings fade is the patch's Fade (Master pane).
	static var ringFadeEased: Bool {
		register()
		return defaults.bool(forKey: "Rings_bFadeEased")
	}

	/// Reopen the last playlist and patch at launch (Session; new in the Mac port)
	static var reopenLast: Bool {
		register()
		return defaults.bool(forKey: "General_bReopenLast")
	}

	/// Settings > General > Your name (Mac addition): suggested as the Author
	/// of patches that have none, when saving or naming the author
	static var authorName: String {
		register()
		return (defaults.string(forKey: "General_sAuthorName") ?? "").trimmingCharacters(in: .whitespaces)
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
	@AppStorage("General_sAuthorName") private var authorName = ""
	@AppStorage("Render_nMaxFrameRate") private var maxFrameRate = 0
	@AppStorage("Rings_bFadeEased") private var ringFadeEased = false
	@AppStorage("OSC_bEnabled") private var oscEnabled = true
	@AppStorage("OSC_nReceivePort") private var oscReceivePort = 8000
	@AppStorage("OSC_nSendPort") private var oscSendPort = 8001
	@AppStorage("OSC_sHost") private var oscHost = ""
	@AppStorage("Syphon_bEnabled") private var syphonEnabled = false
	@AppStorage("Syphon_bFixedSize") private var syphonFixedSize = false
	@AppStorage("Syphon_nWidth") private var syphonWidth = 1920
	@AppStorage("Syphon_nHeight") private var syphonHeight = 1080

	var body: some View {
		// two columns, so everything shows without scrolling
		HStack(alignment: .top, spacing: 0) {
			Form {
				leftColumn
			}
			.formStyle(.grouped)
			Form {
				rightColumn
			}
			.formStyle(.grouped)
		}
		.frame(width: 860, height: 600)
		.onAppear { Preferences.register() }
	}

	@ViewBuilder private var leftColumn: some View {
			Section("General") {
				Toggle("Reopen the last playlist and patch at launch", isOn: $reopenLast)
				HStack {
					Toggle(isOn: $checkUpdates) {
						InfoLabel("Check for updates automatically", info: "Once a day, Whorld asks GitHub whether a newer version has been released; only Whorld's version number is sent. Updates are never installed by themselves, and never announced in full screen.")
					}
					Spacer()
					Button("Check Now") { UpdateChecker.shared.checkNow() }
				}
				LabeledContent {
					TextField("Your name", text: $authorName, prompt: Text("optional"))
						.labelsHidden()
						.multilineTextAlignment(.trailing)
						.frame(width: 180)
				} label: {
					InfoLabel("Your name", info: "Suggested as the Author when you save a patch that doesn't name one yet, or use File > Patch Author…. A patch's existing author is never replaced unless you change it.")
				}
			}
			Section("Rendering") {
				Picker(selection: $useMetal) {
					Text("Metal (GPU)").tag(true)
					Text("Core Graphics (CPU)").tag(false)
				} label: {
					InfoLabel("Renderer", info: WHEngine.metalAvailable
						? "Draws the live view. Exports always use Core Graphics."
						: "Draws the live view. Metal needs a Mac with Apple silicon, so this Mac uses Core Graphics. Exports always use Core Graphics.")
				}
				.onChange(of: useMetal) { _, on in model.engine.preferMetal = on }
				Picker(selection: $maxFrameRate) {
					Text("Display refresh rate").tag(0)
					Text("60 fps").tag(60)
				} label: {
					InfoLabel("Frame rate", info: "Rings move a step each frame, so at 120 Hz patches run twice as fast as on a 60 Hz display. 60 fps matches Windows on a typical monitor and uses about half the power.")
				}
				.onChange(of: maxFrameRate) { _, rate in model.engine.maxFrameRate = rate }
				Picker(selection: $ringFadeEased) {
					Text("Linear").tag(false)
					Text("Eased").tag(true)
				} label: {
					InfoLabel("Ring fade curve", info: "How old rings fade out when Master > Fade is above 0: Linear fades evenly; Eased starts and ends the fade gently.")
				}
				.onChange(of: ringFadeEased) { _, eased in model.engine.setRingFadeEased(eased) }
			}
			Section("Syphon") {
				Toggle(isOn: $syphonEnabled) {
					InfoLabel("Syphon output", info: "Sends Whorld's output to other apps on this Mac (Resolume, MadMapper, OBS, TouchDesigner…), where it's listed as Whorld, with transparency where the patch has any.")
					SyphonStatus()
				}
				LabeledContent {
					HStack {
						Picker("Size", selection: $syphonFixedSize) {
							Text("Same as the output").tag(false)
							Text("Fixed").tag(true)
						}
						.labelsHidden()
						.fixedSize()
						if syphonFixedSize {
							SizeFields(width: $syphonWidth, height: $syphonHeight)
						}
					}
				} label: {
					InfoLabel("Size", info: "Same as the output: the frames Whorld shows, at their size. Fixed: each frame drawn again at that size in pixels, the picture scaled to fit, with more of the pattern on the longer side; it's drawn only while an app is receiving.")
				}
				.disabled(!syphonEnabled)
			}
			.onChange(of: syphonEnabled) { model.applySyphon() }
			.onChange(of: syphonFixedSize) { model.applySyphon() }
			.onChange(of: syphonWidth) { model.applySyphon() }
			.onChange(of: syphonHeight) { model.applySyphon() }
			Section("Snapshots") {
				Toggle("Letterbox", isOn: $letterbox)
					.onChange(of: letterbox) { _, on in model.engine.setSnapshotLetterbox(on) }
				Picker("Legacy snapshot size", selection: $legacySize) {
					Text("640 × 480 (VGA)").tag(0)
					Text("800 × 600 (SVGA)").tag(1)
					Text("1024 × 768 (XGA)").tag(2)
				}
			}
	}

	@ViewBuilder private var rightColumn: some View {
			Section("Control") {
				let _ = model.changes.midi.n
				Picker("MIDI input", selection: $midiInput) {
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
				LabeledContent("Wheel sensitivity") {
					HStack {
						Slider(value: $wheelSense, in: 0.1...10)
						Text(String(format: "%.2f", wheelSense))
							.monospacedDigit()
							.frame(width: 36, alignment: .trailing)
					}
				}
				Toggle(isOn: $oscEnabled) {
					InfoLabel("OSC remote control", info: "Every control MIDI can map has an OSC address, such as /w/m/sp for Speed; see Help > Whorld Help. Whorld answers each device that has sent it something in the last 30 seconds, on the send port, with the values as they change and the frame statistics (/w/stat/...). \"Also send to\" adds a fixed address, for a monitor that never sends.\n\nTouchOSC: open Whorld.tosc, and set a connection to this Mac's address, send port \(oscReceivePort), receive port \(oscSendPort).")
					OSCStatus()
				}
				Group {
					LabeledContent("Ports") {
						HStack(spacing: 6) {
							Text("receive").foregroundStyle(.secondary)
							IntField(value: $oscReceivePort, width: 56)
							Text("send").foregroundStyle(.secondary)
								.padding(.leading, 4)
							IntField(value: $oscSendPort, width: 56)
						}
					}
					LabeledContent("Also send to") {
						TextField("Also send to", text: $oscHost, prompt: Text("host (optional)"))
							.labelsHidden()
							.multilineTextAlignment(.trailing)
							.frame(width: 160)
							.onSubmit { model.restartOSC() }
					}
				}
				.disabled(!oscEnabled)
			}
			.onChange(of: oscEnabled) { model.restartOSC() }
			.onChange(of: oscReceivePort) { model.restartOSC() }
			.onChange(of: oscSendPort) { model.restartOSC() }
			Section("Export") {
				LabeledContent("Image folder") {
					HStack {
						Text(imageFolder.isEmpty ? "Pictures" : (imageFolder as NSString).abbreviatingWithTildeInPath)
							.lineLimit(1)
							.truncationMode(.middle)
						Button("Choose…", action: chooseFolder)
					}
				}
				LabeledContent("Image size") {
					HStack {
						Toggle("Same as the view", isOn: $useViewSize)
							.toggleStyle(.checkbox)
						if !useViewSize {
							SizeFields(width: $imageWidth, height: $imageHeight)
						}
					}
				}
				Picker("Scale to fit", selection: $scaleToFit) {
					Text("None").tag(0)
					Text("Width").tag(1)
					Text("Height").tag(2)
					Text("Both").tag(3)
				}
				Toggle("Ask for export options each time", isOn: $promptUser)
			}
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

/// A setting's title followed by an InfoButton with its explanation.
private struct InfoLabel: View {
	let title: String
	let info: String

	init(_ title: String, info: String) {
		self.title = title
		self.info = info
	}

	var body: some View {
		HStack(spacing: 4) {
			Text(title)
			InfoButton(text: info)
		}
	}
}

/// An info icon that explains a setting: as a tooltip on hover, and in a
/// popover on click (to read at leisure, or where tooltips are slow to show).
private struct InfoButton: View {
	let text: String
	@State private var shown = false

	var body: some View {
		Button {
			shown.toggle()
		} label: {
			Image(systemName: "info.circle")
				.foregroundStyle(.secondary)
		}
		.buttonStyle(.borderless)
		.help(text)
		.accessibilityLabel("About this setting")
		.popover(isPresented: $shown, arrowEdge: .bottom) {
			Text(text)
				.font(.callout)
				.fixedSize(horizontal: false, vertical: true)
				.frame(width: 300, alignment: .leading)
				.padding(12)
		}
	}
}

/// A whole-number field, right-aligned
private struct IntField: View {
	@Binding var value: Int
	var width: CGFloat = 64

	var body: some View {
		TextField("", value: $value, format: .number.grouping(.never))
			.labelsHidden()
			.multilineTextAlignment(.trailing)
			.frame(width: width)
	}
}

/// Width × height in pixels
private struct SizeFields: View {
	@Binding var width: Int
	@Binding var height: Int

	var body: some View {
		HStack(spacing: 4) {
			IntField(value: $width, width: 52)
			Text("×")
			IntField(value: $height, width: 52)
		}
	}
}

/// Settings > Syphon's status line, checked once a second while Settings is
/// open.
private struct SyphonStatus: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		TimelineView(.periodic(from: .now, by: 1)) { _ in
			let e = model.engine
			Text(!e.syphonRunning ? "Off"
				: e.syphonHasClients ? "Publishing as Whorld · an app is receiving"
				: "Publishing as Whorld · no app receiving yet")
				.font(.caption)
				.foregroundStyle(.secondary)
		}
	}
}

/// Settings > OSC's status line: listening where, and who's connected,
/// checked once a second while Settings is open.
private struct OSCStatus: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		TimelineView(.periodic(from: .now, by: 1)) { _ in
			let e = model.engine
			let ips = WHEngine.localIPv4Addresses.joined(separator: ", ")
			let text: String = {
				if let err = model.oscError { return "Not running: " + err }
				guard e.oscRunning else { return "Off" }
				let here = "Listening on " + (ips.isEmpty ? "this Mac" : ips) + ", port \(Preferences.osc.receivePort)"
				let clients = e.oscClients
				return here + (clients.isEmpty ? " · no devices yet" : " · sending to " + clients.joined(separator: ", "))
			}()
			Text(text)
				.font(.caption)
				.foregroundStyle(model.oscError == nil ? Color.secondary : Color.red)
				.textSelection(.enabled)
		}
	}
}
