// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// The key map (new in the Mac port): which key, held over the picture,
// makes scrolling move which control (OutputKeys in WhorldApp.swift). Kept
// in Whorld's settings, not in patches or playlists; edited in the Key Map
// window (Window > Key Map...).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A key and the control it moves. Targets are stored by their mapping tag
/// (as playlists store MIDI mappings), so the map survives changes to the
/// order of targets.
struct KeyBinding: Codable, Identifiable, Equatable {
	var id = UUID()
	var key: String		// the character the key types, lowercased; "" for none
	var target: String	// MappingBase target tag, e.g. "RingSpacing", "Speed", "OriginX"
	var prop = 0		// a parameter target's column (WHParamProperty raw value)
	var speed = 1.0		// times the usual step

	init(_ key: String, _ target: String, _ prop: WHParamProperty = .val, speed: Double = 1) {
		self.key = key
		self.target = target
		self.prop = prop.rawValue
		self.speed = speed
	}

	var targetIndex: Int? {
		let i = WHMappingInfo.target(forTag: target)
		return i >= 0 ? i : nil
	}

	/// as the Key Map and the readout show it
	var displayName: String { KeyMap.name(target: target, prop: prop) }

	/// as the Key column shows it
	var keyLabel: String { key.isEmpty ? "—" : key.uppercased() }
}

@MainActor
final class KeyMap: ObservableObject {
	static let shared = KeyMap()
	private static let defaultsKey = "KeyMap_v1"

	@Published var bindings: [KeyBinding] {
		didSet { save() }
	}
	/// the last conflict resolved, for the window to say
	@Published var notice: String?
	/// the row whose key is being captured (the Key Map window); here, not in
	/// the view, because a Table redraws a cell only for its own row's data
	@Published var capturing: KeyBinding.ID?

	private init() {
		if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
			let saved = try? JSONDecoder().decode([KeyBinding].self, from: data) {
			bindings = saved
		} else {
			bindings = Self.standard
		}
	}

	private func save() {
		if let data = try? JSONEncoder().encode(bindings) {
			UserDefaults.standard.set(data, forKey: Self.defaultsKey)
		}
	}

	/// the control a key moves, if it's in the map
	func binding(for key: String) -> KeyBinding? {
		guard !key.isEmpty else { return nil }
		return bindings.first { $0.key == key && $0.targetIndex != nil }
	}

	/// Gives a row a key; a row that had the key loses it (and says so)
	func assign(_ key: String, to id: KeyBinding.ID) {
		notice = nil
		for i in bindings.indices where bindings[i].key == key && bindings[i].id != id {
			notice = "\(key.uppercased()) moved here from \(bindings[i].displayName), which now has no key."
			bindings[i].key = ""
		}
		if let i = bindings.firstIndex(where: { $0.id == id }) {
			bindings[i].key = key
		}
	}

	func restoreDefaults() {
		bindings = Self.standard
		notice = nil
	}

	/// The starting map (approved 2026-11-12): the trial keys kept, the top
	/// letter row ring shape, the home row color (with mnemonic Master keys),
	/// the bottom row Master then background, digits curves and the origin.
	static let standard: [KeyBinding] = [
		KeyBinding("q", "RingSpacing"), KeyBinding("w", "LineWidth"), KeyBinding("e", "RingGrowth"),
		KeyBinding("r", "Rings"), KeyBinding("t", "PolySides"), KeyBinding("y", "StarFactor"),
		KeyBinding("u", "Pinwheel"), KeyBinding("i", "RotateSpeed"), KeyBinding("o", "AspectRatio"),
		KeyBinding("p", "SkewRadius"), KeyBinding("[", "SkewAngle"),
		KeyBinding("a", "ColorSpeed"), KeyBinding("s", "Speed"), KeyBinding("d", "Damping"),
		KeyBinding("f", "Fade"), KeyBinding("g", "Saturation"), KeyBinding("h", "Hue"),
		KeyBinding("j", "Lightness"), KeyBinding("k", "Alpha"), KeyBinding("l", "HueSpan"),
		KeyBinding("z", "Zoom"), KeyBinding("x", "Trail"), KeyBinding("c", "CanvasScale"),
		KeyBinding("v", "Copies"), KeyBinding("b", "Tempo"), KeyBinding("n", "Spread"),
		KeyBinding("m", "BkHue"), KeyBinding(",", "BkLightness"), KeyBinding(".", "BkSaturation"),
		KeyBinding("/", "BkAlpha"),
		KeyBinding("1", "EvenCurve"), KeyBinding("2", "OddCurve"), KeyBinding("3", "EvenShear"),
		KeyBinding("4", "OddShear"), KeyBinding("9", "OriginX"), KeyBinding("0", "OriginY"),
	]

	// MARK: Targets

	/// A control a key can move: every continuous target MIDI can map
	struct Choice: Hashable {
		let target: String
		let prop: Int
	}

	/// the choices, grouped as the Control menu shows them
	static let groups: [(title: String, choices: [Choice])] = {
		let nParams = WHMappingInfo.paramTargetCount
		let nMaster = WHMappingInfo.masterTargetCount
		let params = (0..<nParams).map { WHMappingInfo.targetTag($0) }
		func column(_ p: WHParamProperty) -> [Choice] { params.map { Choice(target: $0, prop: p.rawValue) } }
		let globals = (0..<WHControls.globalCount).map {
			Choice(target: WHMappingInfo.targetTag(WHControls.param(forGlobal: $0)), prop: WHParamProperty.global.rawValue)
		}
		var master = (nParams..<(nParams + nMaster)).map { Choice(target: WHMappingInfo.targetTag($0), prop: 0) }
		let misc = ((nParams + nMaster)..<WHMappingInfo.targetCount)
			.filter { WHMappingInfo.targetIsRange($0) && WHMappingInfo.targetTag($0) != "Patch" }	// not a value
			.map { Choice(target: WHMappingInfo.targetTag($0), prop: 0) }
		master += misc.filter { $0.target == "Hue" }
		return [
			("Parameters", column(.val)),
			("Master", master),
			("Globals", globals),
			("Origin", misc.filter { $0.target != "Hue" }),
			("Amplitude", column(.amp)),
			("Frequency", column(.freq)),
			("Pulse Width", column(.PW)),
		]
	}()

	nonisolated static func name(target: String, prop: Int) -> String {
		let i = WHMappingInfo.target(forTag: target)
		guard i >= 0 else { return target + " (unknown)" }
		if WHMappingInfo.targetHasProperty(i) {
			let p = WHParamProperty(rawValue: prop) ?? .val
			let base = WHControls.paramName(i)
			return p == .val ? base : base + " " + WHControls.paramPropertyName(p.rawValue)
		}
		return WHMappingInfo.targetName(i)
	}

	// MARK: Files

	func export() {
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.json]
		panel.nameFieldStringValue = "Whorld Key Map.json"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		let e = JSONEncoder()
		e.outputFormatting = [.prettyPrinted, .sortedKeys]
		do {
			try e.encode(bindings).write(to: url, options: .atomic)
		} catch {
			NSAlert(error: error).runModal()
		}
	}

	func importMap() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.json]
		guard panel.runModal() == .OK, let url = panel.url else { return }
		guard let data = try? Data(contentsOf: url),
			let map = try? JSONDecoder().decode([KeyBinding].self, from: data) else {
			let a = NSAlert()
			a.messageText = "Can't import \"\(url.lastPathComponent)\"."
			a.informativeText = "It isn't a Whorld key map."
			a.runModal()
			return
		}
		bindings = map
		notice = nil
	}
}

// MARK: The Key Map window

struct KeyMapView: View {
	@ObservedObject private var map = KeyMap.shared
	@State private var selection = Set<KeyBinding.ID>()

	var body: some View {
		VStack(spacing: 0) {
			Table($map.bindings, selection: $selection) {
				TableColumn("Key") { $b in
					KeyCaptureButton(id: b.id, label: b.keyLabel)
				}
				.width(min: 60, ideal: 70, max: 90)
				TableColumn("Control") { $b in
					Picker("", selection: Binding(
						get: { KeyMap.Choice(target: b.target, prop: b.prop) },
						set: { b.target = $0.target; b.prop = $0.prop })) {
						ForEach(KeyMap.groups, id: \.title) { group in
							Section(group.title) {
								ForEach(group.choices, id: \.self) { c in
									Text(KeyMap.name(target: c.target, prop: c.prop)).tag(c)
								}
							}
						}
					}
					.labelsHidden()
				}
				TableColumn("Speed") { $b in
					Picker("", selection: $b.speed) {
						ForEach([0.25, 0.5, 1, 2, 4], id: \.self) { s in
							Text("×\(s.formatted())").tag(s)
						}
					}
					.labelsHidden()
				}
				.width(min: 70, ideal: 80, max: 100)
			}
			Divider()
			VStack(alignment: .leading, spacing: 6) {
				if let notice = map.notice {
					Text(notice).font(.caption).foregroundStyle(.orange)
				}
				Text("Hold a key with the pointer over the picture and scroll (two fingers up or down, or the mouse wheel) to move its control; up increases. Click a key to change it, then press the new key (Esc cancels). Plain keys only: with Shift, Command, Control or Option they're shortcuts.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				HStack {
					Button {
						let b = KeyBinding("", "RingGrowth")
						map.bindings.append(b)
						selection = [b.id]
					} label: { Image(systemName: "plus") }
						.help("Add a key")
					Button {
						map.bindings.removeAll { selection.contains($0.id) }
						selection = []
					} label: { Image(systemName: "minus") }
						.help("Remove the selected keys")
						.disabled(selection.isEmpty)
					Spacer()
					Button("Restore Defaults") { map.restoreDefaults() }
					Button("Import…") { map.importMap() }
					Button("Export…") { map.export() }
				}
			}
			.padding(10)
		}
		.frame(minWidth: 460, minHeight: 360)
		.onDisappear { map.capturing = nil }
	}
}

/// The Key cell: click, then press a key. Plain printable keys only; Esc
/// (or clicking again) cancels.
private struct KeyCaptureButton: View {
	let id: KeyBinding.ID
	let label: String
	@ObservedObject private var map = KeyMap.shared
	@State private var monitor: Any?

	private var capturing: Bool { map.capturing == id }

	private func onKey(_ key: String?) {
		map.capturing = nil
		if let key {
			map.assign(key, to: id)
		}
	}

	var body: some View {
		Button {
			map.capturing = capturing ? nil : id
		} label: {
			Text(capturing ? "Press a key" : label)
				.font(capturing ? .caption : .body.monospaced().weight(.semibold))
				.frame(minWidth: 44)
		}
		.buttonStyle(.bordered)	// looks clickable, and takes the click from the table row
		.tint(capturing ? .accentColor : nil)
		.help(capturing ? "Press the new key, or Esc to cancel" : "Click, then press a key to assign it")
		.onChange(of: capturing) { _, on in on ? start() : stop() }
		.onDisappear { stop() }
	}

	private func start() {
		stop()
		monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
			if e.keyCode == 53 {	// Esc
				MainActor.assumeIsolated { onKey(nil) }
				return nil
			}
			let mods = e.modifierFlags.intersection([.shift, .command, .control, .option])
			guard mods.isEmpty, let c = e.charactersIgnoringModifiers?.lowercased(), c.count == 1,
				let scalar = c.unicodeScalars.first,
				!CharacterSet.whitespacesAndNewlines.contains(scalar), !CharacterSet.controlCharacters.contains(scalar),
				scalar.value < 0xF700	// function and arrow keys
			else {
				NSSound.beep()
				return nil
			}
			MainActor.assumeIsolated { onKey(c) }
			return nil
		}
	}

	private func stop() {
		if let monitor {
			NSEvent.removeMonitor(monitor)
		}
		monitor = nil
	}
}

// MARK: The readout

/// The control and value a held key just moved, shown briefly over the
/// picture (Settings > Control > Show values while adjusting; off by
/// default). A label on each picture view, so it's never in Syphon output
/// or exports, which take the frames themselves.
@MainActor
enum KeyReadout {
	private static var labels: [WeakLabel] = []
	private static var hideWork: DispatchWorkItem?

	private final class WeakLabel {
		weak var label: NSTextField?
		init(_ l: NSTextField) { label = l }
	}

	static var enabled: Bool { UserDefaults.standard.bool(forKey: "Output_bKeyReadout") }

	/// adds a readout label to a picture view, bottom left
	static func attach(to view: NSView) {
		let l = NSTextField(labelWithString: "")
		l.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
		l.textColor = .white
		l.drawsBackground = true
		l.backgroundColor = NSColor.black.withAlphaComponent(0.6)
		l.alphaValue = 0
		l.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(l)
		NSLayoutConstraint.activate([
			l.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
			l.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
		])
		labels.removeAll { $0.label == nil }
		labels.append(WeakLabel(l))
	}

	static func show(_ text: String) {
		guard enabled else { return }
		for w in labels {
			guard let l = w.label else { continue }
			l.stringValue = " " + text + " "
			l.alphaValue = 1
		}
		hideWork?.cancel()
		let work = DispatchWorkItem {
			MainActor.assumeIsolated {
				NSAnimationContext.runAnimationGroup { ctx in
					ctx.duration = 0.4
					for w in labels { w.label?.animator().alphaValue = 0 }
				}
			}
		}
		hideWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
	}
}
