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
		let params = WHControls.paramDisplayOrder.filter { $0 < nParams }.map { WHMappingInfo.targetTag($0) }
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

	/// The Control menu (the user's request, 2026-11-18, as the Modulation
	/// panel's Target menu): a submenu for each parameter with its columns
	/// (Value, Amplitude, Frequency, Pulse Width, Global, in the Parameters
	/// panel's order), then Master and Origin as they are
	static let menu: (params: [(name: String, choices: [(label: String, choice: Choice)])],
		others: [(title: String, choices: [Choice])]) = {
		let nParams = WHMappingInfo.paramTargetCount
		var byParam: [String: [Choice]] = [:]
		var others: [(title: String, choices: [Choice])] = []
		for g in groups {
			var rest: [Choice] = []
			for c in g.choices {
				let i = WHMappingInfo.target(forTag: c.target)
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
		let order: [WHParamProperty] = [.val, .amp, .freq, .PW, .global]
		let params = WHControls.paramDisplayOrder.filter { $0 < nParams }.compactMap { i -> (name: String, choices: [(label: String, choice: Choice)])? in
			guard let cs = byParam[WHMappingInfo.targetTag(i)] else { return nil }
			let sorted = cs.sorted { a, b in
				(order.firstIndex(of: WHParamProperty(rawValue: a.prop) ?? .val) ?? 0) < (order.firstIndex(of: WHParamProperty(rawValue: b.prop) ?? .val) ?? 0)
			}
			return (WHControls.paramName(i), sorted.map { (WHControls.paramPropertyName($0.prop), $0) })
		}
		return (params, others)
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

// MARK: The Key Map panel

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
					ControlMenu(binding: $b)
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
				// how the keys work is behind the ⓘ by the panel's title (PanelID.summary),
				// clicking a key the Key cell's; Restore Defaults, Import and
				// Export are in File > Key Map (the user's request, 2026-11-18)
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
				}
			}
			.padding(8)	// as the Playlist panel's foot
		}
		.onDisappear { map.capturing = nil }	// (its size: PanelID.keymap.floatingMinSize, floating)
	}
}

/// The Control cell: Parameters, a submenu each (KeyMap.menu), then Master
/// and Origin, with a check on the key's control
private struct ControlMenu: View {
	@Binding var binding: KeyBinding

	private var current: KeyMap.Choice { KeyMap.Choice(target: binding.target, prop: binding.prop) }

	var body: some View {
		let menu = KeyMap.menu
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
						item(KeyMap.name(target: c.target, prop: c.prop), c)
					}
				}
			}
		} label: {
			Text(binding.displayName)
		}
	}

	private func item(_ label: String, _ c: KeyMap.Choice) -> some View {
		Toggle(label, isOn: Binding(get: { current == c }, set: { _ in
			binding.target = c.target
			binding.prop = c.prop
		}))
	}
}

/// The Key cell: click, then press a key. Plain printable keys only; Esc,
/// a click anywhere else (or on the button again), or switching to another
/// app cancels.
private struct KeyCaptureButton: View {
	let id: KeyBinding.ID
	let label: String
	@ObservedObject private var map = KeyMap.shared
	@State private var monitor: Any?
	@State private var clickMonitor: Any?
	@State private var resignObserver: Any?
	@State private var anchor = ViewAnchor()	// the button's view, to tell clicks on it from clicks elsewhere

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
		.background(ViewAnchor.Probe(anchor: anchor))
		.tint(capturing ? .accentColor : nil)
		.help(capturing ? "Press the new key (a plain key, no Shift, Command, Control or Option), or Esc to cancel" : "Click, then press a key to assign it")
		.onChange(of: capturing) { _, on in on ? start() : stop() }
		.onDisappear { stop() }
	}

	private func start() {
		stop()
		// A click anywhere else in the app cancels, before the click goes on
		// (so a click on another row's Key button starts that one instead);
		// a click on this button is left to the button, which toggles.
		clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { e in
			let w = e.window, p = e.locationInWindow
			MainActor.assumeIsolated {
				if !anchor.contains(window: w, point: p) {
					onKey(nil)
				}
			}
			return e
		}
		resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
			MainActor.assumeIsolated { onKey(nil) }
		}
		monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
			if e.keyCode == 53 {	// Esc
				MainActor.assumeIsolated { onKey(nil) }
				return nil
			}
			let mods = e.modifierFlags.intersection([.shift, .command, .control, .option])
			guard mods.isEmpty, !KeyCheatSheet.keyCodes.contains(e.keyCode),	// the key left of 1 shows the cheat sheet
				let c = e.charactersIgnoringModifiers?.lowercased(), c.count == 1,
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
		if let clickMonitor {
			NSEvent.removeMonitor(clickMonitor)
		}
		clickMonitor = nil
		if let resignObserver {
			NotificationCenter.default.removeObserver(resignObserver)
		}
		resignObserver = nil
	}
}

/// Holds a SwiftUI view's backing NSView, to hit-test events against it
@MainActor
final class ViewAnchor {
	weak var view: NSView?

	/// whether a point in a window's coordinates is on the view
	func contains(window: NSWindow?, point: NSPoint) -> Bool {
		guard let v = view, let window, v.window === window else { return false }
		return v.bounds.contains(v.convert(point, from: nil))
	}

	/// an empty view the size of the one it's behind
	struct Probe: NSViewRepresentable {
		let anchor: ViewAnchor
		func makeNSView(context: Context) -> NSView {
			let v = NSView()
			anchor.view = v
			return v
		}
		func updateNSView(_ v: NSView, context: Context) { anchor.view = v }
	}
}
