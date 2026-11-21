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
			// detached, the strip is on the pad, where you are (the picture
			// may be full screen on another display), not with the picture
			if model.showStats && (pad || !model.layout.layout.detached) {
				StatsStrip()
				Divider()
			}
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
/// strip along the top of the output, never over the picture, packed in
/// one cluster: the frame statistics, the last control changed by hand,
/// MIDI or OSC (AppModel.showParam and the like), and the quick performance
/// levers, Render quality and Automatic quality, with what Automatic
/// quality has lowered. It replaced the frame-rate overlay and the key
/// readout over the picture.
struct StatsStrip: View {
	@EnvironmentObject private var model: AppModel
	static let height: CGFloat = 24

	var body: some View {
		HStack(spacing: 8) {
			// the live text is AppKit, redrawn by StripFeed: a SwiftUI layout
			// pass every second (or every swipe) would drop the panes' tooltips;
			// each at a fixed width, so nothing moves as the numbers change
			StripText(part: .stats)
				.frame(minWidth: 90, idealWidth: StripText.width(.stats), maxWidth: StripText.width(.stats))
				.layoutPriority(1)	// a narrow picture shortens the readout first
			Divider().frame(height: 14)
			StripText(part: .readout)
				.frame(minWidth: 0, idealWidth: StripText.width(.readout), maxWidth: StripText.width(.readout))
			Divider().frame(height: 14)
			// Audio > Audio Modulation, with the beat: the most live of the
			// levers, so first (the user's request, 2026-11-19). Mod and Syphon
			// are labels a click toggles, their dots saying on or off (no
			// checkboxes, for the readout's room)
			Button { ModMap.shared.bypass.toggle() } label: {
				HStack(spacing: 5) {
					Text("Mod").foregroundStyle(ModMap.shared.bypass ? .secondary : .primary)
					StripText(part: .beat)	// off, finding the beat, or locked (flashing on the beat)
						.frame(width: 8, height: 8)
					StripText(part: .tempo)	// the locked tempo, BPM
						.frame(width: StripText.width(.tempo), height: 14)
				}
			}
			.buttonStyle(StripToggleStyle())
			.fixedSize()
			.layoutPriority(2)
			.help("Audio modulation on or off (Audio > Audio Modulation, ⌘'). The dot: faint off, hollow finding the beat, filled once it's locked, flashing on each beat; then the tempo.")
			Divider().frame(height: 14)
			GeometryToggle()	// Image > Geometry Only (the user's request, 2026-11-20)
				.layoutPriority(2)
			Divider().frame(height: 14)
			QualityMenu(feed: StripFeed.shared.autoTag)
				.layoutPriority(2)
			Divider().frame(height: 14)
			Button { model.setSyphonEnabled(!model.syphonEnabled) } label: {
				HStack(spacing: 5) {
					Text("Syphon").foregroundStyle(model.syphonEnabled ? .primary : .secondary)
					StripText(part: .syphon)	// off, publishing, or an app receiving
						.frame(width: 8, height: 8)
				}
			}
			.buttonStyle(StripToggleStyle())
			.fixedSize()
			.layoutPriority(2)
			.help("Syphon output on or off (View > Syphon, which also sets its size). The dot: faint off, hollow while no app is receiving, filled once one is.")
			Spacer(minLength: 0)
			// View > Enter Full Screen (the user's request, 2026-11-20); the
			// strip isn't shown in full screen, so it only enters
			Button { model.toggleFullScreen() } label: {
				Image(systemName: "arrow.up.left.and.arrow.down.right")
					.imageScale(.small)
					.padding(.horizontal, 3)	// an easier target
			}
			.buttonStyle(StripToggleStyle())
			.fixedSize()
			.layoutPriority(2)
			.help("Full screen (View > Enter Full Screen, ⇧⌘F; Esc returns)")
			InfoButton(text: Self.info, small: true)
				.layoutPriority(2)
		}
		.controlSize(.small)
		.font(.caption)
		.padding(.horizontal, 8)
		.frame(height: Self.height)
		.frame(maxWidth: .infinity)
		.background(Color(nsColor: .windowBackgroundColor))
	}

	static let info = "Frames drawn a second, display refreshes missed in the last second (orange when any are), and the time to draw a frame (on the CPU, then on the GPU with Metal). The rings drawn, the display's rate and the renderer are in the statistics' tooltip.\n\nNext, the last control you changed, with its value: in a panel or a menu, by MIDI or OSC, or by swiping over the picture (Zoom, Damping with Shift, or a held key's control; see the Key Map). Modulation and patches loading don't change it.\n\nClick Mod to turn audio modulation on and off (Audio > Audio Modulation, Command-'). Its dot: faint while it's off, hollow while it's finding the beat, filled and flashing on each beat once it's locked, with the tempo beside it.\n\nClick Full or Geom to switch the patch mode (Image > Geometry Only, Option-Command-G): in Geom, playing a patch changes only its shape and motion.\n\nThe Quality menu sets Render quality (Settings > Display explains it) and Automatic quality (View > Automatic Quality, Command-;); its title says which is in charge, Quality or Auto, and the quality drawn. Automatic quality: when the picture can't keep up with the display, Whorld lowers Curve quality first, then Render quality down to 50%, a step at a time, and raises them again once there's room to spare, never above your settings; exports aren't affected. While it has lowered something, the title is orange with a ↓ (Auto ↓75%), and its tooltip says what.\n\nClick Syphon to send the picture to other apps on this Mac, or stop (View > Syphon also sets its size). Its dot: faint while it's off, hollow while no app is receiving, filled once one is.\n\nThe arrows at the right end enter full screen (View > Enter Full Screen, Shift-Command-F).\n\nView > Show Stats (Option-Command-9) hides the strip."
}

/// What the stats strip shows, set by AppModel; its text views redraw only
/// when their part changes.
@MainActor
final class StripFeed {
	static let shared = StripFeed()

	private(set) var stats = ""		// before and after "n missed", which
	private(set) var missed = ""	// is drawn orange when n > 0
	private(set) var statsTail = ""
	private(set) var statsTip = ""
	private(set) var readout = ""
	private(set) var readoutFresh = false	// just changed; dimmed after a few seconds
	/// what Automatic quality has lowered, if anything: SwiftUI text at its
	/// own width, so nothing is held for it; it changes only when Automatic
	/// quality steps (seldom), not every second
	let autoTag = AutoTagFeed()
	private(set) var syphon = 0	// 0 off, 1 publishing with no app receiving, 2 an app receiving
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
			beat.tempo = new.tempo
			redraw(.tempo)
		}
	}

	private func redraw(_ part: StripText.Part) {
		for w in views where w.view?.part == part { w.view?.needsDisplay = true }
	}

	func setStats(_ s: String, missed m: String, _ tail: String, tip: String) {
		guard s != stats || m != missed || tail != statsTail || tip != statsTip else { return }
		stats = s
		missed = m
		statsTail = tail
		if tip != statsTip {
			statsTip = tip
			for w in views where w.view?.part == .stats { w.view?.toolTip = tip }
		}
		redraw(.stats)
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

	/// `full`: the control's whole name, for the tooltip, where the readout
	/// shortens it (Ring Growth Amp for Ring Growth Amplitude)
	func setReadout(_ s: String, full: String? = nil) {
		let tip = full ?? s
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

/// What Automatic quality has lowered ("curves 1.0 px, 75%"; empty: nothing)
/// and the quality drawn, in percent. Published on their own, changing only
/// when Automatic quality steps (seldom), so the strip lays out only then.
final class AutoTagFeed: ObservableObject {
	@Published var detail = ""
	@Published var percent = 100
}

/// The stats strip's Quality menu (the user's request, 2026-11-19): Render
/// quality and Automatic quality in one, its title what's in effect:
/// "Quality 100%", "Auto 100%", or "Auto ↓75%" in orange while Automatic
/// quality has lowered something
private struct QualityMenu: View {
	@EnvironmentObject private var model: AppModel
	@ObservedObject var feed: AutoTagFeed

	var body: some View {
		let lowered = model.autoQuality && !feed.detail.isEmpty
		let percent = lowered ? feed.percent : Int((model.renderScale * 100).rounded())
		let title = (model.autoQuality ? "Auto " : "Quality ") + (lowered ? "↓" : "") + "\(percent)%"
		Menu {
			Toggle("Automatic", isOn: $model.autoQuality)
			Divider()
			ForEach(AppModel.renderScales, id: \.value) { s in
				Toggle(s.name, isOn: Binding(get: { model.renderScale == s.value }, set: { _ in model.renderScale = s.value }))
			}
		} label: {
			Text(title)
		}
		.menuStyle(.borderlessButton)
		.foregroundStyle(lowered ? Color.orange : Color.primary)
		.fixedSize()
		.help(lowered ? "Automatic quality has lowered: \(feed.detail)"
			: model.autoQuality ? "Automatic quality is on, and hasn't needed to lower anything (⌘;)" : "Render quality; Automatic quality is off (⌘;)")
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
	enum Part { case stats, readout, syphon, beat, tempo }

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
		case .stats: "000 fps · 00 missed · 00.0/00.0 ms"
		case .readout: "Rotate Speed Freq  -00.000"
		case .syphon, .beat: ""
		case .tempo: "000"
		}
		return ceil((sample as NSString).size(withAttributes: [.font: font]).width) + 2
	}

	final class View: NSView {
		var part: Part = .stats

		override var isFlipped: Bool { true }
		// the dots and the tempo: clicks and tips are their button's
		override func hitTest(_ point: NSPoint) -> NSView? {
			part == .beat || part == .tempo || part == .syphon ? nil : super.hitTest(point)
		}

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if window != nil {
				StripFeed.shared.add(self)
				if part == .stats { toolTip = StripFeed.shared.statsTip }
				if part == .syphon { toolTip = StripText.syphonTip(StripFeed.shared.syphon) }
				if part == .beat { toolTip = StripText.beatTip(StripFeed.shared.beat.state) }
				if part == .tempo { toolTip = "The tempo, BPM" }
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
			case .stats:
				guard !feed.stats.isEmpty else { break }
				let warn = !feed.missed.hasPrefix("0 ")
				text.append(NSAttributedString(string: feed.stats, attributes: attrs(.secondaryLabelColor)))
				text.append(NSAttributedString(string: feed.missed, attributes: attrs(warn ? .systemOrange : .secondaryLabelColor)))
				text.append(NSAttributedString(string: feed.statsTail, attributes: attrs(.secondaryLabelColor)))
			case .readout:
				text.append(NSAttributedString(string: feed.readout,
					attributes: attrs(feed.readoutFresh ? .labelColor : .secondaryLabelColor)))
			case .tempo:
				text.append(NSAttributedString(string: feed.beat.tempo, attributes: attrs(.secondaryLabelColor)))
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
