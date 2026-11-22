// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

import SwiftUI
import UniformTypeIdentifiers

/// The main window: the workspace (Workspace.swift).
struct ContentView: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		WorkspaceView(layout: model.layout)
			.background(MainWindowObserver { model.workspaceWindowAppeared($0) })
			.modifier(DocumentTitle())
	}
}

/// The window title, in a modifier of its own: a change to it (the first
/// edit after a save) redraws just this, not the workspace.
private struct DocumentTitle: ViewModifier {
	@EnvironmentObject private var model: AppModel

	func body(content: Content) -> some View {
		content.navigationTitle(model.windowTitle)
			.navigationSubtitle(model.windowSubtitle)
	}
}

/// The output: the stats strip (View > Show Stats) above the render view,
/// with the movie bar overlay; or, in the workspace while the output is
/// detached, the swipe pad in the picture's place, with the strip,
/// taking dropped files. In the workspace's middle, or in the detached
/// output window.
struct OutputView: View {
	@EnvironmentObject private var model: AppModel
	/// in the workspace, panels dropped near its edges (one drop target for
	/// both: an inner one would take every drag over it, panels' too)
	var panelDrop: EdgeDropDelegate? = nil
	/// the workspace's output place while the output is detached
	var pad = false

	var body: some View {
		VStack(spacing: 0) {
			Group {
				if pad {
					SwipePad()
						.frame(minWidth: 120, minHeight: 120)
				} else {
					RenderView(engine: model.engine, renderScale: model.renderScale, smoothUpscaling: model.smoothUpscaling)
						.ignoresSafeArea()
						.frame(minWidth: 320, minHeight: 240)
				}
			}
			.overlay(alignment: .bottom) {
				MovieBar()
			}
			// the Perform Bar, along the bottom edge (the user's request,
			// 2026-11-21; at the top before). Detached, it's on the pad,
			// where you are (the picture may be full screen on another
			// display), not with the picture.
			if model.showStats && (pad || !model.layout.layout.detached) {
				Divider()
				StatsStrip()
			}
		}
			.onDrop(of: panelDrop == nil ? [.fileURL] : [.fileURL, .whorldPanel],
				delegate: OutputDropDelegate(model: model, panels: panelDrop))
	}
}

/// The swipe pad (Mac addition; the user's request, 2026-11-19): while the
/// output is detached (on a second display, full screen, say), its place in
/// the workspace stays, blank, and takes what the picture takes, so the
/// pointer needn't cross to the other display: scrolling zooms (Damping
/// with Shift), or moves a held key's control (the Key Map); a two-finger
/// tap with the key held puts it back; Command-Left and Right step the
/// snapshots; and while the button is down the origin follows the pointer,
/// the pad standing for the whole picture (WHRenderView's handlers).
struct SwipePad: NSViewRepresentable {
	func makeNSView(context: Context) -> SwipePadView { SwipePadView() }
	func updateNSView(_ view: SwipePadView, context: Context) {}
	func sizeThatFits(_ proposal: ProposedViewSize, nsView: SwipePadView, context: Context) -> CGSize? {
		proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
	}
}

final class SwipePadView: NSView {
	private var tracking: NSTrackingArea?

	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let tracking { removeTrackingArea(tracking) }
		let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .inVisibleRect, .activeInKeyWindow], owner: self, userInfo: nil)
		addTrackingArea(t)
		tracking = t
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		needsDisplay = true
	}

	override func draw(_ dirtyRect: NSRect) {
		NSColor.underPageBackgroundColor.setFill()
		bounds.fill()
		let style = NSMutableParagraphStyle()
		style.alignment = .center
		let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
			.foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
		let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
			.foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style]
		let text = NSMutableAttributedString(string: "The picture is detached\n", attributes: title)
		text.append(NSAttributedString(string: "Swipe here to zoom, or hold a Key Map key to change its control. Press and drag to move the origin. Double-click to put the picture back.", attributes: body))
		let w = min(bounds.width - 24, 320)
		guard w > 40 else { return }
		let size = text.boundingRect(with: NSSize(width: w, height: 1000), options: [.usesLineFragmentOrigin]).size
		text.draw(with: NSRect(x: (bounds.width - w) / 2, y: (bounds.height - size.height) / 2, width: w, height: ceil(size.height)),
			options: [.usesLineFragmentOrigin])
	}

	// as WHRenderView's (WHEngine.mm): a wheel reports lines, a trackpad
	// points, 10 to a notch; Shift turns a wheel's scrolling horizontal
	override func scrollWheel(with event: NSEvent) {
		let shift = event.modifierFlags.contains(.shift)
		let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : (shift ? event.scrollingDeltaX : 0)
		let notches = event.hasPreciseScrollingDeltas ? delta / 10 : delta
		guard notches != 0 else { return }
		AppModel.shared.wheel(notches: Double(notches), shift: shift, momentum: event.momentumPhase != [],
			inverted: event.isDirectionInvertedFromDevice, trackpad: event.hasPreciseScrollingDeltas)
	}

	/// the pointer, as a place in the picture (the engine's y points down)
	private func report(_ event: NSEvent) {
		let p = convert(event.locationInWindow, from: nil)
		guard bounds.width > 0, bounds.height > 0 else { return }
		AppModel.shared.engine.setCursorPosition(CGPoint(x: min(max(p.x / bounds.width, 0), 1),
			y: 1 - min(max(p.y / bounds.height, 0), 1)))
	}

	override func mouseMoved(with event: NSEvent) { report(event) }
	override func mouseDragged(with event: NSEvent) { report(event) }

	override func mouseDown(with event: NSEvent) {
		if event.clickCount == 2 {	// the output back in its place (AppModel.outputDoubleClick)
			AppModel.shared.outputDoubleClick()
			return
		}
		report(event)
		AppModel.shared.outputMouse(down: true)
	}

	override func mouseUp(with event: NSEvent) {
		if event.clickCount == 2 { return }
		report(event)
		AppModel.shared.outputMouse(down: false)
	}

	override func rightMouseDown(with event: NSEvent) {
		if AppModel.shared.resetHeldKeyControl() { return }
		super.rightMouseDown(with: event)
	}
}

/// Files dropped on the output open; panels go to the workspace's
/// EdgeDropDelegate.
struct OutputDropDelegate: DropDelegate {
	let model: AppModel
	let panels: EdgeDropDelegate?

	private func panelDelegate(_ info: DropInfo) -> EdgeDropDelegate? {
		info.hasItemsConforming(to: [.whorldPanel]) ? panels : nil
	}

	func validateDrop(info: DropInfo) -> Bool {
		panelDelegate(info) != nil || info.hasItemsConforming(to: [.fileURL])
	}

	func dropUpdated(info: DropInfo) -> DropProposal? {
		if let p = panelDelegate(info) { return p.dropUpdated(info: info) }
		return info.hasItemsConforming(to: [.whorldPanel]) ? DropProposal(operation: .forbidden) : nil
	}

	func dropExited(info: DropInfo) { panels?.dropExited(info: info) }

	func performDrop(info: DropInfo) -> Bool {
		if let p = panelDelegate(info) { return p.performDrop(info: info) }
		guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
		let model = model
		_ = provider.loadObject(ofClass: URL.self) { url, _ in
			guard let url else { return }
			Task { @MainActor in
				switch url.pathExtension.lowercased() {
				case "whp": model.open(url)
				case "whl": if model.confirmDiscardPlaylist() { model.openPlaylist(url) }
				case "whs": model.loadSnapshots([url])
				case "whm": model.playMovie(url)
				default: break
				}
			}
		}
		return true
	}
}

/// View > Show Stats (Mac addition; the user's request, 2026-11-19): a thin
/// strip along the bottom of the output (the top until 2026-11-21), never over the picture, packed in
/// one cluster: the frame statistics, the last control changed by hand,
/// MIDI or OSC (AppModel.showParam and the like), and the quick performance
/// levers, Render quality and Automatic quality, with what Automatic
/// quality has lowered. It replaced the frame-rate overlay and the key
/// readout over the picture.
struct StatsStrip: View {
	static let height: CGFloat = 24

	/// in a hosting view of its own that takes the first click: with the
	/// detached picture's window (or a panel's) in front, a click on the
	/// bar acts at once, not only bringing the Whorld window forward
	var body: some View {
		FirstClickHost(content: AnyView(StatsStripContent().environmentObject(AppModel.shared)))
			.frame(height: Self.height)
	}
}

private struct FirstClickHost: NSViewRepresentable {
	let content: AnyView

	final class Host: NSHostingView<AnyView> {
		override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
	}

	func makeNSView(context: Context) -> Host {
		let v = Host(rootView: content)
		v.sizingOptions = []	// the bar's size is the frame's
		return v
	}

	func updateNSView(_ v: Host, context: Context) {}
}

private struct StatsStripContent: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		HStack(spacing: 8) {
			// Image > Blackout, at the far left (the user's request, 2026-11-21)
			BlackoutButton()
				.layoutPriority(2)
			Divider().frame(height: 14)
			// the live text is AppKit, redrawn by StripFeed: a SwiftUI layout
			// pass every second (or every swipe) would drop the panes' tooltips;
			// each at a fixed width, so nothing moves as the numbers change
			// the frame rate, a button: the rest of the statistics in a
			// pop-up (the user's request, 2026-11-20, the strip as a live
			// Perform Bar)
			StripText(part: .fps)
				.frame(width: StripText.width(.fps) + 8, height: 18)
				.layoutPriority(2)
			Divider().frame(height: 14)
			// the last control changed: narrower, and the first to give way
			// (the user's request, 2026-11-20)
			StripText(part: .readout)
				.frame(minWidth: 0, idealWidth: StripText.width(.readout), maxWidth: StripText.width(.readout))
			Divider().frame(height: 14)
			// the patch's place in the playlist (12/86), its name in the
			// tooltip (shown elsewhere: the user's request, 2026-11-21); a
			// click plays the next (2026-11-20)
			StripText(part: .patch)
				.frame(width: StripText.width(.patch) + 8, height: 18)
				.layoutPriority(2)
			PlaylistTransport()	// Play / Stop (the user's request, 2026-11-20)
				.layoutPriority(2)
			Divider().frame(height: 14)
			GeometryToggle()	// Image > Geometry Only (the user's request, 2026-11-20)
				.layoutPriority(2)
			Divider().frame(height: 14)
			// Automatic quality and Render quality, apart (the user's
			// request, 2026-11-20)
			AutoQualityToggle(feed: StripFeed.shared.autoTag)
				.layoutPriority(2)
			ResolutionMenu(feed: StripFeed.shared.autoTag)
				.layoutPriority(2)
			Divider().frame(height: 14)
			// Audio > Audio Modulation, with the beat, beside Syphon (the
			// user's request, 2026-11-21). Mod and Syphon
			// are labels a click toggles, their dots saying on or off (no
			// checkboxes, for the readout's room)
			Button { ModMap.shared.bypass.toggle() } label: {
				HStack(spacing: 5) {
					Text("Mod").foregroundStyle(ModMap.shared.bypass ? .secondary : .primary)
					StripText(part: .beat)	// off, finding the beat, or locked (flashing on the beat)
						.frame(width: 8, height: 8)
				}
			}
			.buttonStyle(StripToggleStyle())
			.fixedSize()
			.layoutPriority(2)
			.help("Audio modulation on or off (Audio > Audio Modulation, ⌘'). The dot: faint off, hollow finding the beat, filled once it's locked, flashing on each beat.")
			// the locked tempo, BPM: a button of its own while it shows, for
			// Reset to 1.1 (the user's request, 2026-11-20); AppKit, as it
			// comes and goes without a SwiftUI layout
			StripTempo(shown: StripFeed.shared.tempoShown)	// no room held while there's none
				.layoutPriority(2)
			Divider().frame(height: 14)
			// "Syp" and the dot (the user's request, 2026-11-21), like Mod
			Button { model.setSyphonEnabled(!model.syphonEnabled) } label: {
				HStack(spacing: 5) {
					Text("Syp").foregroundStyle(model.syphonEnabled ? .primary : .secondary)
					StripText(part: .syphon)	// off, publishing, or an app receiving
						.frame(width: 8, height: 8)
				}
			}
			.buttonStyle(StripToggleStyle())
			.fixedSize()
			.layoutPriority(2)
			.help("Syphon output on or off (View > Syphon, which also sets its size). Faint off, hollow while no app is receiving, filled once one is.")
			Spacer(minLength: 0)
			// File > Movie > Record Movie (the user's request, 2026-11-22):
			// red with the running time while recording
			RecordButton()
				.layoutPriority(2)
			// View > Detach (the user's request, 2026-11-20): the picture in a
			// window of its own, for a projector; lit while detached, when
			// the bar is on the swipe pad, and a click docks it again
			DetachButton()
				.layoutPriority(2)
			// View > Enter Full Screen (the user's request, 2026-11-20); the
			// strip isn't shown in full screen, so it only enters. With
			// Option, Enter Full Screen on Other Display (2026-11-21).
			Button {
				if NSEvent.modifierFlags.contains(.option) {
					model.fullScreenNextDisplay()
				} else {
					model.toggleFullScreen()
				}
			} label: {
				Image(systemName: "arrow.up.left.and.arrow.down.right")
					.imageScale(.small)
					.padding(.horizontal, 3)	// an easier target
			}
			.buttonStyle(StripToggleStyle())
			.fixedSize()
			.layoutPriority(2)
			.help("Full screen (View > Enter Full Screen, ⌘F; Esc returns). Option-click: full screen on another display (⇧⌘F).")
			// no ⓘ: each item has its own tooltip, and Help describes the
			// bar (the user's request, 2026-11-21)
		}
		.controlSize(.small)
		.font(.caption)
		.padding(.horizontal, 8)
		.frame(height: StatsStrip.height)
		.frame(maxWidth: .infinity)
		.background(Color(nsColor: .windowBackgroundColor))
	}
}

/// What the stats strip shows, set by AppModel; its text views redraw only
/// when their part changes.
@MainActor
final class StripFeed {
	static let shared = StripFeed()

	private(set) var fps = ""		// "60 fps"
	private(set) var fpsWarn = false	// display refreshes missed: drawn orange
	private(set) var statsDetail = ""	// the rest, in the frame rate's pop-up
	private var statsPopover: NSPopover?
	private var statsLabel: NSTextField?
	private(set) var readout = ""
	private(set) var readoutFresh = false	// just changed; dimmed after a few seconds
	/// what Automatic quality has lowered, if anything: SwiftUI text at its
	/// own width, so nothing is held for it; it changes only when Automatic
	/// quality steps (seldom), not every second
	let autoTag = AutoTagFeed()
	private(set) var syphon = 0	// 0 off, 1 publishing with no app receiving, 2 an app receiving
	private(set) var patch = (place: "", name: "", count: 0)	// "12/86", the patch's name, the playlist's length
	/// whether a tempo shows: published, so the bar makes room for it only
	/// then (a layout when the beat locks or is lost, not every second)
	let tempoShown = TempoShownFeed()
	private var views: [WeakView] = []
	private var dimWork: DispatchWorkItem?

	private final class WeakView {
		weak var view: StripText.View?
		init(_ v: StripText.View) { view = v }
	}

	func add(_ v: StripText.View) {
		views.removeAll { $0.view == nil || $0.view === v }
		views.append(WeakView(v))
		if v.part == .beat { startBeat() }
	}

	func remove(_ v: StripText.View) {
		views.removeAll { $0.view == nil || $0.view === v }
		if !views.contains(where: { $0.view?.part == .beat }) {
			beatTimer?.invalidate()
			beatTimer = nil
		}
	}

	// The beat (Mod's dot and the tempo): 0 off, 1 finding the beat,
	// 2 locked; checked 30 times a second while the strip is shown, as the
	// Modulation panel's meter is, to flash on each beat (from the tracker,
	// or Ableton Link's while it drives the beat)
	private(set) var beat = (state: 0, flash: false, tempo: "")
	private var beatTimer: Timer?
	private var lastBeat: Int?
	private var flashUntil = Date.distantPast

	private func startBeat() {
		guard beatTimer == nil else { return }
		let t = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
			MainActor.assumeIsolated { StripFeed.shared.tickBeat() }
		}
		RunLoop.main.add(t, forMode: .common)
		beatTimer = t
		tickBeat()
	}

	private func tickBeat() {
		let now = Date()
		var state = 0, tempo = "", count: Int?
		if !ModMap.shared.bypass {
			let link = WHLink.shared
			var pos = 0.0
			if link.drivesBeat, link.beatPosition(&pos) {
				state = 2
				count = Int(pos.rounded(.down))
				tempo = String(format: "%.0f", link.tempo)
			} else if !link.drivesBeat {
				let r = WHAudioInput.shared.reading()
				state = r.beatLocked.boolValue ? 2 : 1
				count = Int(r.beats)
				if state == 2 { tempo = String(format: "%.0f", r.tempo) }
			} else {
				state = 1	// Link drives the beat, stopped
			}
		}
		if let count, count != lastBeat {
			if lastBeat != nil { flashUntil = now.addingTimeInterval(0.12) }
			lastBeat = count
		}
		let new = (state: state, flash: state == 2 && now < flashUntil, tempo: tempo)
		if new.state != beat.state || new.flash != beat.flash {
			for w in views where w.view?.part == .beat { w.view?.toolTip = StripText.beatTip(new.state) }
			beat = new
			redraw(.beat)
		}
		if new.tempo != beat.tempo {
			if new.tempo.isEmpty != beat.tempo.isEmpty {	// a button only while it shows
				for w in views where w.view?.part == .tempo {
					w.view?.toolTip = new.tempo.isEmpty ? nil : StripText.View.tempoTip
				}
			}
			beat.tempo = new.tempo
			redraw(.tempo)
			if tempoShown.shown == new.tempo.isEmpty { tempoShown.shown = !new.tempo.isEmpty }
		}
	}

	private func redraw(_ part: StripText.Part) {
		for w in views where w.view?.part == part { w.view?.needsDisplay = true }
	}

	func setStats(fps f: String, warn: Bool, detail: String) {
		if f != fps || warn != fpsWarn {
			fps = f
			fpsWarn = warn
			redraw(.fps)
		}
		if detail != statsDetail {
			statsDetail = detail
			statsLabel?.stringValue = detail	// live while the pop-up is open
		}
	}

	/// The frame rate's pop-up: the rest of the statistics, updated each
	/// second while it's open; a click elsewhere (or on the frame rate
	/// again) closes it
	func toggleStatsPopover(from view: NSView) {
		if let p = statsPopover, p.isShown {
			p.performClose(nil)
			return
		}
		let label = NSTextField(wrappingLabelWithString: statsDetail)
		label.font = StripText.font
		label.textColor = .labelColor
		label.isSelectable = false
		label.translatesAutoresizingMaskIntoConstraints = false
		let vc = NSViewController()
		let box = SolidView()	// not see-through: the picture behind would make it hard to read
		box.addSubview(label)
		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
			label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
			label.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
			label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
			label.widthAnchor.constraint(equalToConstant: 310),
		])
		vc.view = box
		let p = NSPopover()
		p.contentViewController = vc
		p.behavior = .transient
		p.animates = false
		statsLabel = label
		statsPopover = p
		// above the bar, which is along the picture's bottom edge (the view is flipped)
		p.show(relativeTo: view.bounds, of: view, preferredEdge: view.isFlipped ? .minY : .maxY)
	}

	private(set) var patchCanStep = false	// a playlist to step through: the name is a button

	func setPatch(place: String, name: String, count: Int) {
		let canStep = count > 0
		guard place != patch.place || name != patch.name || count != patch.count else { return }
		patch = (place, name, count)
		patchCanStep = canStep
		var tip = place.isEmpty ? name : "\(name): patch \(place.replacingOccurrences(of: "/", with: " of ")) in the playlist"
		if canStep { tip += ". Click for the next patch (Image > Next Patch, ⌘↓)." }
		for w in views where w.view?.part == .patch { w.view?.toolTip = tip }
		redraw(.patch)
	}

	func setSyphon(_ state: Int) {
		guard state != syphon else { return }
		syphon = state
		for w in views where w.view?.part == .syphon { w.view?.toolTip = StripText.syphonTip(state) }
		redraw(.syphon)
	}

	func setAuto(_ detail: String, percent: Int) {
		if detail != autoTag.detail { autoTag.detail = detail }
		if percent != autoTag.percent { autoTag.percent = percent }
	}

	/// the readout's tooltip: what it is, and the control's whole name
	private(set) var readoutTip = "The last control you change, in a panel or menu, by MIDI or OSC, or by swiping over the picture, shows here with its value. Modulation doesn't show."

	/// `full`: the control's whole name, for the tooltip, where the readout
	/// shortens it (Ring Growth Amp for Ring Growth Amplitude)
	func setReadout(_ s: String, full: String? = nil) {
		let name = (full ?? s).replacingOccurrences(of: "  ", with: " ")
		let tip = "Last control changed: \(name). In a panel or menu, by MIDI or OSC, or by swiping over the picture; modulation doesn't show."
		readoutTip = tip
		for w in views where w.view?.part == .readout && w.view?.toolTip != tip { w.view?.toolTip = tip }
		if s != readout || !readoutFresh {
			readout = s
			readoutFresh = true
			redraw(.readout)
		}
		dimWork?.cancel()
		let work = DispatchWorkItem { [weak self] in
			MainActor.assumeIsolated {
				self?.readoutFresh = false
				self?.redraw(.readout)
			}
		}
		dimWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
	}
}

/// The window's background color, filled (the frame rate's pop-up)
private final class SolidView: NSView {
	override func draw(_ dirtyRect: NSRect) {
		NSColor.windowBackgroundColor.setFill()
		dirtyRect.fill()
	}
}

/// What Automatic quality has lowered ("curves 1.0 px, 75%"; empty: nothing)
/// and the quality drawn, in percent. Published on their own, changing only
/// when Automatic quality steps (seldom), so the strip lays out only then.
final class TempoShownFeed: ObservableObject {
	@Published var shown = false
}

/// The locked tempo beside Mod's dot, room for it only while it shows
private struct StripTempo: View {
	@ObservedObject var shown: TempoShownFeed

	var body: some View {
		StripText(part: .tempo)
			.frame(width: shown.shown ? StripText.width(.tempo) + 8 : 0, height: 18)
			.padding(.leading, shown.shown ? -6 : -8)	// close to its dot
	}
}

/// Image > Blackout in the Perform Bar: an eye, struck through and red
/// while the picture is out
private struct BlackoutButton: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		let _ = model.changes.main.n
		let on = model.engine.blackout
		Button { model.setBlackout(!on) } label: {
			Image(systemName: on ? "eye.slash.fill" : "eye")
				.imageScale(.small)
				.foregroundStyle(on ? Color.white : Color.primary)
				.frame(width: 18)
				.background(RoundedRectangle(cornerRadius: 3).fill(on ? Color.red : Color.clear).padding(-2))
		}
		.buttonStyle(StripToggleStyle())
		.fixedSize()
		.help((on ? "Blackout: the picture is faded out. Click to fade it back (Image > Blackout, ⌘B)."
			: "Blackout: fade the picture to black over a second (Image > Blackout, ⌘B).")
			+ " Black on screen and in Syphon, not in exports; Whorld keeps running underneath, so the picture returns where it would have been.")
	}
}

/// File > Movie > Record Movie in the Perform Bar: a dot, red with the
/// time recorded while recording; a click starts or stops it. Polls only
/// while recording (the movie bar's reason: each tick lays out the window).
private struct RecordButton: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		let _ = model.changes.media.n	// toggleRecordMovie calls changed()
		let ms = model.movieState
		Button { model.toggleRecordMovie() } label: {
			if ms.io == .writing {
				TimelineView(.periodic(from: .now, by: 0.5)) { _ in
					HStack(spacing: 4) {
						Image(systemName: "record.circle.fill").foregroundStyle(.red)
						Text(Self.time(model.movieState)).monospacedDigit()
					}
					.padding(.horizontal, 3)
				}
			} else {
				Image(systemName: "record.circle")
					.imageScale(.small)
					.padding(.horizontal, 3)
			}
		}
		.buttonStyle(StripToggleStyle())
		.fixedSize()
		.disabled(ms.io == .reading)
		.help(ms.io == .writing
			? "Recording a movie. Click to stop (File > Movie > Stop Recording)."
			: "Record a movie: Whorld's own recording (.whm) of the picture, to play back or export as a video later (File > Movie > Record Movie).")
	}

	/// minutes and seconds recorded
	static func time(_ ms: WHMovieState) -> String {
		let s = ms.frameRate > 0 ? Int(Double(ms.frame) / Double(ms.frameRate)) : 0
		return String(format: "%d:%02d", s / 60, s % 60)
	}
}

/// View > Detach in the Perform Bar, lit while detached
private struct DetachButton: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		let _ = model.changes.menus.n
		let on = model.isDetached
		Button {
			// with Option, Detach to Other Display / Move to Next Display
			// (2026-11-22), as Option on the full-screen button
			if NSEvent.modifierFlags.contains(.option) {
				model.detachNextDisplay()
			} else {
				model.toggleDetach()
			}
		} label: {
			Image(systemName: "macwindow.on.rectangle")
				.imageScale(.small)
				.foregroundStyle(on ? Color.accentColor : Color.primary)
				.padding(.horizontal, 3)
		}
		.buttonStyle(StripToggleStyle())
		.fixedSize()
		.help(on ? "The picture is detached, in its own window. Click to put it back in the Whorld window (View > Detach, ⌘D); Option-click to move it to the next display (⇧⌘D)."
			: "Detach the picture into a window of its own, to move to a projector or second display (View > Detach, ⌘D); Option-click to detach it onto another display (⇧⌘D)")
	}
}

final class AutoTagFeed: ObservableObject {
	@Published var detail = ""
	@Published var percent = 100
}

/// View > Automatic Quality in the Perform Bar (the user's request,
/// 2026-11-20; it was in one menu with Render quality): Auto, a click on or
/// off, bright while on, and orange with a ↓ while it has lowered something
private struct AutoQualityToggle: View {
	@EnvironmentObject private var model: AppModel
	@ObservedObject var feed: AutoTagFeed

	var body: some View {
		let on = model.autoQuality
		let lowered = on && !feed.detail.isEmpty
		Button { model.autoQuality.toggle() } label: {
			Text(lowered ? "Auto ↓" : "Auto")
				.foregroundStyle(lowered ? Color.orange : on ? Color.primary : Color.secondary)
		}
		.buttonStyle(StripToggleStyle())
		.fixedSize()
		.help(lowered ? "Automatic quality has lowered: \(feed.detail). Click to turn it off (View > Automatic Quality, ⌘;)."
			: on ? "Automatic quality is on, and hasn't needed to lower anything. Click to turn it off (⌘;)."
			: "Automatic quality is off. Click to turn it on: when the picture can't keep up, Whorld lowers curve quality, then resolution (⌘;).")
	}
}

/// Render quality in the Perform Bar: Res and the resolution drawn, a menu
/// of the settings; orange while Automatic quality draws it lower
private struct ResolutionMenu: View {
	@EnvironmentObject private var model: AppModel
	@ObservedObject var feed: AutoTagFeed

	var body: some View {
		let set = Int((model.renderScale * 100).rounded())
		let lowered = model.autoQuality && !feed.detail.isEmpty && feed.percent < set
		Menu {
			ForEach(AppModel.renderScales, id: \.value) { s in
				Toggle(s.name, isOn: Binding(get: { model.renderScale == s.value }, set: { _ in model.renderScale = s.value }))
			}
		} label: {
			Text("Res \(lowered ? feed.percent : set)%")
		}
		.menuStyle(.borderlessButton)
		.foregroundStyle(lowered ? Color.orange : Color.primary)
		.fixedSize()
		.help(lowered ? "Resolution: set to \(set)%, drawn at \(feed.percent)% by Automatic quality"
			: "Resolution (Render quality): fewer pixels, scaled up, for heavy patches (Settings > Performance)")
	}
}

/// Image > Geometry Only in the stats strip, as the playlist panel shows it:
/// Full or Geom, a click for the other. Its own view, reading the playlist's
/// change counter, so only it redraws when the mode changes (rarely; see
/// StripText on the tooltips)
private struct GeometryToggle: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		let _ = model.changes.playlist.n
		let geometry = model.engine.geometryMode
		Button { model.setGeometryMode(!geometry) } label: {
			Text(geometry ? "Geom" : "Full")
		}
		.buttonStyle(StripToggleStyle())
		.fixedSize()
		.help(geometry
			? "Geometry mode: playing a patch changes only its shape and motion, keeping colors, Hue, Master, Properties and Global values. Click for Full mode (Image > Geometry Only, ⌥⌘G)."
			: "Full mode: playing a patch changes everything. Click for Geometry mode, where only its shape and motion change (Image > Geometry Only, ⌥⌘G).")
	}
}

/// The playlist in the stats strip (the user's request, 2026-11-20): the
/// previous patch, Play / Stop (auto-advance, the Playlist panel's button,
/// its line filling toward the next patch) and the next patch. Reads the
/// playlist's change counter, so it redraws only when those change.
private struct PlaylistTransport: View {
	@EnvironmentObject private var model: AppModel

	var body: some View {
		let _ = model.changes.playlist.n
		let e = model.engine
		let empty = model.playlistPatches.isEmpty
		let unit = AutoAdvanceUnit(rawValue: e.autoAdvanceUnit) ?? .seconds
		AutoAdvanceButton(strip: true, running: e.autoAdvancing, enabled: !empty,
			unit: unit, length: e.autoAdvanceLength, engine: e,
			setLength: { model.setAutoAdvanceLength($0, unit: $1) }) { model.setAutoAdvance(!e.autoAdvancing) }
			.frame(width: 24, height: 18)
			.padding(.leading, -6)	// close to the patch's name
			.disabled(empty && !e.autoAdvancing)
		.fixedSize()
		.onAppear { feedPatch() }
		.onChange(of: patchKey) { feedPatch() }
	}

	/// the patch playing, for the bar's AppKit text (no SwiftUI layout)
	private var patchKey: String {
		"\(model.playingPatch)/\(model.playlistPatches.count)/\(model.title)"
	}

	private func feedPatch() {
		let n = model.playlistPatches.count
		let i = model.playingPatch
		StripFeed.shared.setPatch(place: i >= 0 && i < n ? "\(i + 1)/\(n)" : "", name: model.title, count: n)
	}
}

/// Mod, Full/Geom and Syphon in the stats strip: a label a click toggles, lit on hover
private struct StripToggleStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View { Lit(configuration: configuration) }

	private struct Lit: View {
		let configuration: Configuration
		@State private var hover = false

		var body: some View {
			configuration.label
				.padding(.horizontal, 4)
				.padding(.vertical, 2)
				.background(RoundedRectangle(cornerRadius: 4)
					.fill(Color.primary.opacity(configuration.isPressed ? 0.18 : hover ? 0.09 : 0)))
				.contentShape(Rectangle())
				.onHover { hover = $0 }
		}
	}
}

/// One of the stats strip's live texts (StripFeed), drawn in AppKit
struct StripText: NSViewRepresentable {
	enum Part { case fps, readout, patch, syphon, beat, tempo }

	static func beatTip(_ state: Int) -> String {
		state == 0 ? "Audio modulation is off" : state == 2 ? "The beat is locked" : "Finding the beat…"
	}

	static func syphonTip(_ state: Int) -> String {
		state == 0 ? "Syphon is off" : state == 2 ? "Publishing as Whorld · an app is receiving"
			: "Publishing as Whorld · no app receiving yet"
	}
	let part: Part

	static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

	/// a part's width: its longest usual text
	static func width(_ part: Part) -> CGFloat {
		let sample = switch part {
		case .fps: "000 fps"
		case .readout: "Ring Growth  -00.000"
		case .patch: "000/000"
		case .syphon, .beat: ""
		case .tempo: "000"
		}
		return ceil((sample as NSString).size(withAttributes: [.font: font]).width) + 2
	}

	final class View: NSView {
		var part: Part = .fps
		/// the frame rate and the tempo are buttons (the tempo while it shows)
		private var clickable: Bool {
			part == .fps || (part == .tempo && !StripFeed.shared.beat.tempo.isEmpty)
				|| (part == .patch && StripFeed.shared.patchCanStep)
		}
		private var button: Bool { part == .tempo || part == .fps || part == .patch }

		override var isFlipped: Bool { true }
		override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
		// the dots: clicks and tips are their button's. The tempo is a
		// button itself while it shows: Reset to 1.1
		override func hitTest(_ point: NSPoint) -> NSView? {
			if button { return clickable ? super.hitTest(point) : nil }
			return part == .beat || part == .syphon ? nil : super.hitTest(point)
		}

		private var hover = false { didSet { if hover != oldValue { needsDisplay = true } } }
		private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }

		override func updateTrackingAreas() {
			super.updateTrackingAreas()
			guard button else { return }
			trackingAreas.forEach(removeTrackingArea)
			addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
				owner: self))
		}

		override func mouseEntered(with event: NSEvent) { hover = clickable }
		override func mouseExited(with event: NSEvent) { hover = false }

		override func mouseDown(with event: NSEvent) {
			guard clickable else { return super.mouseDown(with: event) }
			pressed = true
		}

		override func mouseDragged(with event: NSEvent) {
			guard button else { return super.mouseDragged(with: event) }
			pressed = bounds.contains(convert(event.locationInWindow, from: nil))
		}

		override func mouseUp(with event: NSEvent) {
			guard button else { return super.mouseUp(with: event) }
			let inside = pressed
			pressed = false
			guard inside else { return }
			switch part {
			case .tempo: ModMap.markDownbeat()	// Audio > Reset to 1.1
			case .patch: AppModel.shared.stepPatch(1)	// Image > Next Patch
			default: StripFeed.shared.toggleStatsPopover(from: self)
			}
		}

		static let fpsTip = "Frames drawn a second; orange when display refreshes were missed. Click for the rest of the statistics."

		static let tempoTip = "The tempo, BPM. Click to reset the count to 1.1: the beat nearest now becomes bar 1, beat 1 (Audio > Reset to 1.1, ⌘\\)."

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if window != nil {
				StripFeed.shared.add(self)
				if part == .fps { toolTip = Self.fpsTip }
				if part == .readout { toolTip = StripFeed.shared.readoutTip }
				if part == .syphon { toolTip = StripText.syphonTip(StripFeed.shared.syphon) }
				if part == .beat { toolTip = StripText.beatTip(StripFeed.shared.beat.state) }
				if part == .tempo { toolTip = StripFeed.shared.beat.tempo.isEmpty ? nil : Self.tempoTip }
			} else {
				StripFeed.shared.remove(self)
			}
		}

		override func viewDidChangeEffectiveAppearance() {
			super.viewDidChangeEffectiveAppearance()
			needsDisplay = true
		}

		override func draw(_ dirtyRect: NSRect) {
			let feed = StripFeed.shared
			let font = StripText.font
			let style = NSMutableParagraphStyle()
			style.lineBreakMode = .byTruncatingTail
			func attrs(_ color: NSColor) -> [NSAttributedString.Key: Any] {
				[.font: font, .foregroundColor: color, .paragraphStyle: style]
			}
			let text = NSMutableAttributedString()
			switch part {
			case .patch:
				// the place alone (12/86; –/86 with none from the playlist);
				// the name is in the tooltip
				let n = feed.patch.count
				let place = feed.patch.place.isEmpty ? (n > 0 ? "–/\(n)" : "–") : feed.patch.place
				text.append(NSAttributedString(string: place, attributes: attrs(n > 0 ? .labelColor : .secondaryLabelColor)))
				// a button (Next Patch): lit on hover around the text, at a
				// fixed width so Play after it never moves
				let tw = ceil(text.size().width)
				if hover || pressed {
					NSColor.labelColor.withAlphaComponent(pressed ? 0.18 : 0.09).setFill()
					NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: min(tw + 8, bounds.width), height: bounds.height),
						xRadius: 4, yRadius: 4).fill()
				}
				let h = ceil(font.ascender - font.descender + font.leading)
				text.draw(with: NSRect(x: 4, y: floor((bounds.height - h) / 2), width: bounds.width - 8, height: h),
					options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
				return
			case .readout:
				text.append(NSAttributedString(string: feed.readout,
					attributes: attrs(feed.readoutFresh ? .labelColor : .secondaryLabelColor)))
			case .tempo, .fps:	// lit on hover, as StripToggleStyle; the text inset as its label
				let s = part == .fps ? feed.fps : feed.beat.tempo
				guard !s.isEmpty else { return }
				if hover || pressed {
					NSColor.labelColor.withAlphaComponent(pressed ? 0.18 : 0.09).setFill()
					NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
				}
				let color: NSColor = part == .tempo ? .labelColor : feed.fpsWarn ? .systemOrange : .secondaryLabelColor
				text.append(NSAttributedString(string: s, attributes: attrs(color)))
				let h = ceil(font.ascender - font.descender + font.leading)
				text.draw(with: NSRect(x: 4, y: floor((bounds.height - h) / 2), width: bounds.width - 8, height: h),
					options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
				return
			case .beat:	// a dot: faint off, an outline finding the beat, filled locked, bright on the beat
				let r = bounds.insetBy(dx: 1, dy: 1)
				switch feed.beat.state {
				case 0:
					NSColor.tertiaryLabelColor.setFill()
					NSBezierPath(ovalIn: r).fill()
				case 1:
					let p = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
					p.lineWidth = 1
					NSColor.controlAccentColor.setStroke()
					p.stroke()
				default:
					(feed.beat.flash ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
					NSBezierPath(ovalIn: r).fill()
				}
				return
			case .syphon:	// a dot: faint off, an outline publishing, filled receiving
				let r = bounds.insetBy(dx: 1, dy: 1)
				switch feed.syphon {
				case 0:
					NSColor.tertiaryLabelColor.setFill()
					NSBezierPath(ovalIn: r).fill()
				case 1:
					let p = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
					p.lineWidth = 1
					NSColor.systemGreen.setStroke()
					p.stroke()
				default:
					NSColor.systemGreen.setFill()
					NSBezierPath(ovalIn: r).fill()
				}
				return
			}
			let h = ceil(font.ascender - font.descender + font.leading)
			let r = NSRect(x: 0, y: floor((bounds.height - h) / 2), width: bounds.width, height: h)
			text.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
		}
	}

	func makeNSView(context: Context) -> View {
		let v = View()
		v.part = part
		return v
	}

	func updateNSView(_ v: View, context: Context) {
		if v.part != part {
			v.part = part
			v.needsDisplay = true
		}
	}
}

/// Reports the window it's in, once it's in one.
struct MainWindowObserver: NSViewRepresentable {
	let onWindow: (NSWindow) -> Void

	func makeNSView(context: Context) -> NSView { Observer(onWindow) }
	func updateNSView(_ view: NSView, context: Context) {}

	final class Observer: NSView {
		let onWindow: (NSWindow) -> Void
		init(_ onWindow: @escaping (NSWindow) -> Void) {
			self.onWindow = onWindow
			super.init(frame: .zero)
		}
		required init?(coder: NSCoder) { nil }
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let window { onWindow(window) }
		}
	}
}

/// Hosts the AppKit render view, which drives the engine from its display link.
struct RenderView: NSViewRepresentable {
	let engine: WHEngine
	let renderScale: Double
	let smoothUpscaling: Bool

	func makeNSView(context: Context) -> WHRenderView {
		let view = WHRenderView(frame: .zero)
		view.secondaryClickHandler = {	// a two-finger tap with a key held: that control's default
			MainActor.assumeIsolated { AppModel.shared.resetHeldKeyControl() }
		}
		view.doubleClickHandler = {	// docks or detaches the output (the user's request, 2026-11-20)
			MainActor.assumeIsolated { AppModel.shared.toggleDetach() }
		}
		view.engine = engine
		view.renderScale = renderScale
		view.smoothUpscaling = smoothUpscaling
		view.wheelHandler = { notches, shift, momentum, inverted, trackpad in
			Task { @MainActor in
				AppModel.shared.wheel(notches: notches, shift: shift, momentum: momentum, inverted: inverted, trackpad: trackpad)
			}
		}
		return view
	}

	func updateNSView(_ view: WHRenderView, context: Context) {
		if view.renderScale != renderScale {
			view.renderScale = renderScale
		}
		if view.smoothUpscaling != smoothUpscaling {
			view.smoothUpscaling = smoothUpscaling
		}
	}

	/// The render view takes the size it's offered (no fitting-size measuring).
	func sizeThatFits(_ proposal: ProposedViewSize, nsView: WHRenderView, context: Context) -> CGSize? {
		proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
	}
}
