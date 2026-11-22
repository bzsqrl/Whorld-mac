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

/// Options from OptionsDef.h, stored in UserDefaults under the Windows
/// names (group_name). MIDI options arrive in Phase 5; the recent-files
/// count is managed by macOS.
enum Preferences {
	static let defaults = UserDefaults.standard

	static func register() {
		defaults.register(defaults: [
			"Input_fWheelSense": defaultWheelSense,
			"Input_fSwipeSense": 1.0,
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
			"Playlist_bSaveLayout": true,
			"Playlist_bApplyLayout": true,
			"General_bControlTips": true,
			KeyBadge.defaultsKey: false,
			ParamColumn.oscillatorsKey: true,
			"Render_nMaxFrameRate": 0,
			"Render_fScale": 1.0,
			"Render_bSmoothUpscale": true,
			"Render_fCurveQuality": 1.0,
			"Render_bAutoQuality": false,
			"Rings_bFadeEased": true,
			"Rings_bHueFromPatch": false,
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
	static let defaultWheelSense = 6.25

	/// Trackpad sensitivity (Mac addition, the user's request, 2026-11-19):
	/// how far every two-finger swipe moves a value, over the picture, on a
	/// slider or in a number box, as a multiple of the usual (1)
	static var swipeSense: Double {
		register()
		let v = defaults.double(forKey: "Input_fSwipeSense")
		return (v > 0 ? v : 1) * swipeBase
	}
	/// what ×1 is, of a swipe's first rate (finger travel 1:1 on a slider,
	/// a number box's step every 2 points): half, for finer adjustments
	/// (the user's request, 2026-11-19); the setting scales from here
	static let swipeBase = 0.5

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
	/// the fixed size last chosen, used or not
	static var syphonStoredSize: (width: Int, height: Int) {
		register()
		return (defaults.integer(forKey: "Syphon_nWidth"), defaults.integer(forKey: "Syphon_nHeight"))
	}

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

	/// Settings > Picture > Patch colors on load (Mac addition): true, a
	/// loaded patch starts from its own Hue; false, the hue carries on from
	/// the previous patch (as Windows V2)
	static var hueFromPatch: Bool {
		register()
		return defaults.bool(forKey: "Rings_bHueFromPatch")
	}

	/// Reopen the last playlist and patch at launch (Session; new in the Mac port)
	static var reopenLast: Bool {
		register()
		return defaults.bool(forKey: "General_bReopenLast")
	}

	/// Save Playlist As > Include the panel layout (remembered; Mac addition)
	static var playlistSavesLayout: Bool {
		register()
		return defaults.bool(forKey: "Playlist_bSaveLayout")
	}

	/// Settings > General > Apply playlist layouts (Mac addition): opening a
	/// playlist that has a layout arranges the panels as it says
	static var applyPlaylistLayouts: Bool {
		register()
		return defaults.bool(forKey: "Playlist_bApplyLayout")
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

/// The Whorld folder in Documents, with Patches and Playlists folders in it,
/// made at the first launch (the user's request, 2026-11-22: patches and
/// playlists kept apart). The patch dialogs start in Patches and the playlist
/// dialogs in Playlists, and after that each where its kind was last opened
/// or saved, instead of macOS's one last folder for every dialog. A Mac
/// addition; files already elsewhere stay where they are.
@MainActor
enum WhorldFolders {
	enum Kind: String {
		case patches = "Patches", playlists = "Playlists"
		/// Take Snapshot's and Load Snapshot's (the user's request, 2026-11-22)
		case snapshots = "Snapshots"
		static let all: [Kind] = [.patches, .playlists, .snapshots]
		/// the folder last used for this kind (`Folder_sPatches`, `Folder_sPlaylists`, `Folder_sSnapshots`)
		var lastKey: String { "Folder_s" + rawValue }
	}

	/// the folders made, so a deleted one isn't made again (each kind once:
	/// Snapshots came later); `General_bMadeFolders` stands for the first two
	private static let madeKey = "General_sMadeFolders"
	private static let madeKeyV1 = "General_bMadeFolders"

	/// ~/Documents/Whorld; `General_sWhorldFolder` (no setting shows it) moves
	/// it, for testing
	static var root: URL {
		if let p = Preferences.defaults.string(forKey: "General_sWhorldFolder"), !p.isEmpty {
			return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
		}
		let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
		return docs.appendingPathComponent("Whorld", isDirectory: true)
	}

	static func folder(_ kind: Kind) -> URL { root.appendingPathComponent(kind.rawValue, isDirectory: true) }

	/// At launch: makes each kind's folder, the first time only (an existing
	/// Whorld folder is kept as it is, with the folders added; one added in a
	/// later version is made when it first runs). If that fails, the next
	/// launch tries again.
	static func makeOnce() {
		let d = Preferences.defaults
		var made = Set(d.stringArray(forKey: madeKey) ?? [])
		if d.bool(forKey: madeKeyV1) { made.formUnion([Kind.patches.rawValue, Kind.playlists.rawValue]) }
		let before = made
		for kind in Kind.all where !made.contains(kind.rawValue) {
			do {
				try FileManager.default.createDirectory(at: folder(kind), withIntermediateDirectories: true)
				made.insert(kind.rawValue)
			} catch {
				NSLog("Whorld: can't make the \(kind.rawValue) folder in Documents/Whorld: \(error.localizedDescription)")
			}
		}
		if made != before { d.set(made.sorted(), forKey: madeKey) }
	}

	/// where a dialog for this kind starts: where it was last used, else its
	/// Whorld folder; nil (macOS's choice) if neither is there
	static func start(_ kind: Kind) -> URL? {
		var isDir: ObjCBool = false
		if let p = Preferences.defaults.string(forKey: kind.lastKey),
			FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
			return URL(fileURLWithPath: p, isDirectory: true)
		}
		let f = folder(kind)
		return FileManager.default.fileExists(atPath: f.path, isDirectory: &isDir) && isDir.boolValue ? f : nil
	}

	/// the sample files already copied, as "Patches/name.whp"
	private static let samplesKey = "General_sInstalledSamples"

	/// At launch, after makeOnce: copies the sample patches and playlists
	/// that come with the app (Contents/Resources/Samples, from
	/// mac/app/Samples) into Patches and Playlists (the user's request,
	/// 2026-11-22). Each file once: never over a file of the same name, never
	/// again once it's been deleted, and not into a folder that's gone; a
	/// later version's new samples are copied when it first runs.
	static func installSamples() {
		guard let src = Bundle.main.resourceURL?.appendingPathComponent("Samples", isDirectory: true) else { return }
		let fm = FileManager.default
		var installed = Set(Preferences.defaults.stringArray(forKey: samplesKey) ?? [])
		let before = installed.count
		for kind in [Kind.patches, .playlists] {
			let from = src.appendingPathComponent(kind.rawValue, isDirectory: true)
			let to = folder(kind)
			guard let names = try? fm.contentsOfDirectory(atPath: from.path),
				fm.fileExists(atPath: to.path) else { continue }
			for name in names.sorted() where !name.hasPrefix(".") {
				let id = kind.rawValue + "/" + name
				guard !installed.contains(id) else { continue }
				let dest = to.appendingPathComponent(name)
				if !fm.fileExists(atPath: dest.path) {
					do {
						try fm.copyItem(at: from.appendingPathComponent(name), to: dest)
					} catch {
						NSLog("Whorld: can't copy the sample \(id): \(error.localizedDescription)")
						continue	// tried again next launch
					}
				}
				installed.insert(id)
			}
		}
		if installed.count != before {
			Preferences.defaults.set(installed.sorted(), forKey: samplesKey)
		}
	}

	/// a file of this kind, chosen in a dialog: its folder is where the next starts
	static func used(_ kind: Kind, _ url: URL) {
		Preferences.defaults.set(url.deletingLastPathComponent().path, forKey: kind.lastKey)
	}
}

struct PreferencesView: View {
	@EnvironmentObject private var model: AppModel
	@AppStorage("Input_fWheelSense") private var wheelSense = 6.25
	@AppStorage("Input_fSwipeSense") private var swipeSense = 1.0
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
	@AppStorage("Playlist_bApplyLayout") private var applyPlaylistLayouts = true
	@AppStorage("General_bControlTips") private var controlTips = true
	@AppStorage(KeyBadge.defaultsKey) private var keyBadges = false
	@AppStorage("Render_nMaxFrameRate") private var maxFrameRate = 0
	@AppStorage("Rings_bFadeEased") private var ringFadeEased = true
	@AppStorage("Rings_bHueFromPatch") private var hueFromPatch = false
	@AppStorage("OSC_bEnabled") private var oscEnabled = true
	@AppStorage("OSC_nReceivePort") private var oscReceivePort = 8000
	@AppStorage("OSC_nSendPort") private var oscSendPort = 8001
	@AppStorage("OSC_sHost") private var oscHost = ""

	@AppStorage("Settings_nTab") private var tab = 0	// the tab last shown

	var body: some View {
		// Tabs by task (the user's request, 2026-11-22, from the big-picture
		// review): what Whorld does at launch and in the panels, how the
		// picture looks, how fast it runs, how you play it, and what it
		// saves. Each section says what it's for underneath.
		TabView(selection: $tab) {
			Form { generalTab }
				.formStyle(.grouped)
				.tabItem { Label("General", systemImage: "gearshape") }
				.tag(0)
			Form { pictureTab }
				.formStyle(.grouped)
				.tabItem { Label("Picture", systemImage: "paintpalette") }
				.tag(1)
			Form { performanceTab }
				.formStyle(.grouped)
				.tabItem { Label("Performance", systemImage: "gauge.medium") }
				.tag(2)
			Form { inputTab }
				.formStyle(.grouped)
				.tabItem { Label("Input", systemImage: "hand.point.up.left") }
				.tag(3)
			Form { exportTab }
				.formStyle(.grouped)
				.tabItem { Label("Export", systemImage: "square.and.arrow.up") }
				.tag(4)
		}
		.frame(width: 540, height: 600)
		.background(NoInitialFocus(tab: tab))
		.onAppear { Preferences.register() }
	}

	@ViewBuilder private var generalTab: some View {
			Section {
				Toggle("Reopen the last playlist and patch at launch", isOn: $reopenLast)
				HStack {
					Toggle(isOn: $checkUpdates) {
						InfoLabel("Check for updates automatically", info: "Once a day, Whorld asks GitHub whether a newer version has been released; only Whorld's version number is sent. Updates are never installed by themselves, and never announced in full screen.")
					}
					Spacer()
					Button("Check Now") { UpdateChecker.shared.checkNow() }
				}
			} header: {
				Text("Starting up")
			} footer: {
				Text("What Whorld does when it opens.").font(.caption).foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			Section {
				LabeledContent {
					TextField("Your name", text: $authorName, prompt: Text("optional"))
						.labelsHidden()
						.multilineTextAlignment(.trailing)
						.frame(width: 180)
				} label: {
					InfoLabel("Your name", info: "Suggested as the Author in the Save As dialog for a patch that doesn't name one yet. A patch's existing author is never replaced unless you change it.")
				}
				Toggle(isOn: $applyPlaylistLayouts) {
					InfoLabel("Open playlists with their layout", info: "A playlist saved with its panel layout (Save Playlist As > Include the panel layout) arranges the panels and windows that way when it's opened. It changes the current layout (Window menu).")
				}
				LabeledContent("Whorld folder") {
					HStack {
						Text((WhorldFolders.root.path as NSString).abbreviatingWithTildeInPath)
							.lineLimit(1)
							.truncationMode(.middle)
							.foregroundStyle(.secondary)
						Button("Show in Finder") {
							NSWorkspace.shared.activateFileViewerSelecting([WhorldFolders.root])
						}
					}
				}
			} header: {
				Text("Patches and playlists")
			} footer: {
				Text("Patches and playlists are saved in the Whorld folder's Patches and Playlists folders unless you choose another.").font(.caption).foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			Section {
				Toggle(isOn: $controlTips) {
					InfoLabel("Show tips on control names", info: "Hovering over a control's name in Parameters, Master, Globals or Properties shows a short explanation of what it does, after its Key Map key, if it has one: (S) for Speed.")
				}
				Toggle(isOn: $keyBadges) {
					InfoLabel("Show Key Map keys in panels", info: "Each control in Parameters, Master and Globals that has a key in the Key Map (View > Key Map) shows it before its name: hold that key over the picture and swipe to change the control. They follow the Key Map as you change it.")
				}
			} header: {
				Text("Panels")
			} footer: {
				Text("Help in Parameters, Master, Globals and Properties.").font(.caption).foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
	}

	@ViewBuilder private var pictureTab: some View {
			Section {
				Picker(selection: $hueFromPatch) {
					Text("Continue").tag(false)
					Text("Start from the patch").tag(true)
				} label: {
					InfoLabel("Patch colors", info: "When a patch is loaded. Continue: the hue carries on from the previous patch, as on Windows, so a patch's colors depend on what played before. Start from the patch: colors start from the patch's Hue (Master pane), so a patch looks the same each time it's opened.")
				}
				.onChange(of: hueFromPatch) { _, on in model.engine.setHueFromPatch(on) }
				Picker(selection: $ringFadeEased) {
					Text("Linear").tag(false)
					Text("Eased").tag(true)
				} label: {
					InfoLabel("Ring fade curve", info: "How old rings fade out when Master > Fade is above 0: Linear fades evenly; Eased starts and ends the fade gently.")
				}
				.onChange(of: ringFadeEased) { _, eased in model.engine.setRingFadeEased(eased) }
			} header: {
				Text("Look")
			} footer: {
				Text("How patches look as they change and as rings fade.").font(.caption).foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			Section {
				Picker(selection: $maxFrameRate) {
					Text("Display refresh rate").tag(0)
					Text("60 fps").tag(60)
				} label: {
					InfoLabel("Frame rate", info: "Rings move a step each frame, so at 120 Hz patches run twice as fast as on a 60 Hz display. 60 fps matches Windows on a typical monitor and uses about half the power.")
				}
				.onChange(of: maxFrameRate) { _, rate in model.engine.maxFrameRate = rate }
			} header: {
				Text("Speed")
			} footer: {
				Text("Patches move a step each frame, so the frame rate sets how fast they run.").font(.caption).foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
	}

	@ViewBuilder private var performanceTab: some View {
			Section {
				Picker(selection: $useMetal) {
					Text("Metal (GPU)").tag(true)
					Text("Core Graphics (CPU)").tag(false)
				} label: {
					InfoLabel("Renderer", info: WHEngine.metalAvailable
						? "Draws the live view. Exports use Metal whatever this says, so they come out the same every time."
						: "Draws the live view. Metal needs a Mac with Apple silicon, so this Mac uses Core Graphics, for exports too.")
				}
				.onChange(of: useMetal) { _, on in model.engine.preferMetal = on }
			} header: {
				Text("Drawing")
			} footer: {
				Text("What draws the picture.").font(.caption).foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			Section {
				Picker(selection: $model.renderScale) {
					ForEach(AppModel.renderScales, id: \.value) { s in
						Text(s.name).tag(s.value)
					}
				} label: {
					InfoLabel("Render quality", info: "Lower quality for higher frame rates on heavy patches or a slower Mac: the picture is drawn with fewer pixels (75%, 50% or 33% of the display's) and scaled up to fill the window or screen. Ring sizes and line widths stay the same; edges get coarser. At 50%, the GPU's work is about a third to a half of full resolution's. Syphon gets the smaller frames too, unless its size is fixed; exports aren't affected.")
				}
				Picker(selection: $model.smoothUpscaling) {
					Text("Smooth").tag(true)
					Text("Sharp pixels").tag(false)
				} label: {
					InfoLabel("Upscaling", info: "How a picture drawn below 100% is scaled up. Smooth blends neighboring pixels; Sharp pixels keeps them square and crisp, which suits patches drawn without antialiasing and looks most even at 50%.")
				}
				.disabled(model.renderScale >= 1 && !model.autoQuality)	// automatic quality may scale too
				LabeledContent {
					HStack(spacing: 6) {
						Text("Low").font(.caption).foregroundStyle(.secondary)
						Slider(value: $model.curveQuality, in: 0...1)
							.frame(width: 140)
						Text("High").font(.caption).foregroundStyle(.secondary)
					}
				} label: {
					InfoLabel("Curve quality", info: "How smoothly curved rings are drawn. Curves are drawn as many short straight segments; lower quality uses fewer, which speeds up patches with large curved rings (bloom, typhoon, boomer) and helps where Render quality doesn't, since the work is in the rings, not the pixels. At the lowest setting curves may look slightly faceted, by up to a pixel. Straight-sided patches aren't affected. Exports always use High.")
				}
			} header: {
				Text("Quality")
			} footer: {
				Text("Trading detail for a smoother picture on heavy patches or a slower Mac. Automatic quality, which lowers it only while frames are missed, is View › Automatic Quality (⌘;). Exports always draw at full quality.").font(.caption).foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
	}

	@ViewBuilder private var inputTab: some View {
			Section {
				LabeledContent {
					HStack {
						// halves and doubles evenly: the slider is the power of two
						Slider(value: Binding(get: { log2(swipeSense) }, set: { swipeSense = pow(2, ($0 * 4).rounded() / 4) }),
							in: -2...2)
						Text(String(format: "×%.2f", swipeSense))
							.monospacedDigit()
							.frame(width: 44, alignment: .trailing)
					}
				} label: {
					InfoLabel("Trackpad sensitivity", info: "How far a two-finger swipe moves a value: over the picture (zoom, Damping, or a held key's control), on a slider, and in a number box. ×1 is the usual; ×2 goes twice as far for the same swipe, ×0.5 half as far.")
				}
				LabeledContent {
					HStack {
						Slider(value: $wheelSense, in: 0.1...10)
						Text(String(format: "%.2f", wheelSense))
							.monospacedDigit()
							.frame(width: 36, alignment: .trailing)
					}
				} label: {
					InfoLabel("Wheel sensitivity", info: "How far each click of a mouse wheel moves a control over the picture (zoom, Damping with Shift, or a held key's control). Trackpad swipes have their own setting below.")
				}
			} header: {
				Text("Trackpad and mouse")
			} footer: {
				Text("Swiping over the picture, the swipe pad, sliders and number boxes.").font(.caption).foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			Section {
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
			} header: {
				Text("MIDI")
			} footer: {
				Text("Map controls to MIDI in View › MIDI Mapping.").font(.caption).foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			Section {
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
			} header: {
				Text("OSC")
			} footer: {
				Text("Remote control over the network, from TouchOSC or another app.").font(.caption).foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			.onChange(of: oscEnabled) { model.restartOSC() }
			.onChange(of: oscReceivePort) { model.restartOSC() }
			.onChange(of: oscSendPort) { model.restartOSC() }
	}

	@ViewBuilder private var exportTab: some View {
			Section {
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
			} header: {
				Text("Images and movies")
			} footer: {
				Text("File › Export saves the picture as an image, an image sequence or a video.").font(.caption).foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			Section {
				Toggle("Letterbox", isOn: $letterbox)
					.onChange(of: letterbox) { _, on in model.engine.setSnapshotLetterbox(on) }
				Picker("Legacy snapshot size", selection: $legacySize) {
					Text("640 × 480 (VGA)").tag(0)
					Text("800 × 600 (SVGA)").tag(1)
					Text("1024 × 768 (XGA)").tag(2)
				}
			} header: {
				Text("Snapshots")
			} footer: {
				Text("How a snapshot fits a window of another shape, and the size assumed for snapshots from older versions of Whorld, which don't record one.").font(.caption).foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
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

/// Clears the Settings window's first responder when it opens and when the
/// tab changes: AppKit gives the first text field on the page focus, which
/// selects its text (the author name, an OSC port) as if it were about to be
/// typed over. A field takes focus when it's clicked, as usual.
private struct NoInitialFocus: NSViewRepresentable {
	let tab: Int

	func makeNSView(context: Context) -> Probe { Probe() }

	func updateNSView(_ view: Probe, context: Context) {
		guard view.tab != tab else { return }
		view.tab = tab
		view.clearSoon()
	}

	final class Probe: NSView {
		var tab: Int?
		private var observer: NSObjectProtocol?

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let observer { NotificationCenter.default.removeObserver(observer) }
			observer = nil
			guard let window else { return }
			// the window is kept when closed, so clear again each time it opens
			observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
				object: window, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.clearSoon() }
			}
			clearSoon()
		}

		/// After AppKit has picked the key view for the page
		func clearSoon() {
			DispatchQueue.main.async { [weak self] in
				guard let window = self?.window, window.firstResponder is NSText else { return }
				window.makeFirstResponder(nil)
			}
		}

		deinit {
			if let observer { NotificationCenter.default.removeObserver(observer) }
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

/// Settings > Input > OSC's status line: listening where, and who's connected,
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
