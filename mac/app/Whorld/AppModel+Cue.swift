// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Cue, then go (Mac addition, the user's design, 2026-11-25): a marker in
// the playlist, apart from the playing patch, moved without changing the
// picture, for browsing a long playlist by feel; Go plays it, now or on
// the next beat, bar or 4 bars (Launch Timing, an app setting), and the
// cue moves on to the patch after it. Keys (OutputKeys): Option-Up and
// Option-Down one entry, with Shift ten, Shift-Option-Command-Up and
// -Down the first and last, Option-Command-G a number, Option-/ a random patch; Return Go, Command-Return Go Now.

import AppKit

/// When Go plays the cued patch: at once, or on the beat's next beat, bar
/// or 4 bars (Ableton Link's while it drives the beat, else the beat
/// tracker's); at once whenever there's no beat to wait for
enum LaunchTiming: Int, CaseIterable {
	case now = 0, beat, bar, fourBars

	static let key = "Playlist_nLaunchTiming"

	static var current: LaunchTiming {
		LaunchTiming(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .now
	}

	var title: String {
		switch self {
		case .now: "Now"
		case .beat: "Beat"
		case .bar: "Bar"
		case .fourBars: "4 Bars"
		}
	}

	/// beats between launch points
	var period: Int {
		switch self {
		case .now: 0
		case .beat: 1
		case .bar: 4
		case .fourBars: 16
		}
	}
}

/// The pads (MIDI's Pad 1 to 16; part 2, the user's design, 2026-11-25):
/// a bank of 8, 16, 32 or 64 entries, and whether a pad plays its patch
/// (on Launch Timing) or only cues it; app settings
enum PadSettings {
	static let sizeKey = "Playlist_nBankSize", cuesKey = "Playlist_bPadsCue"
	static let sizes = [8, 16, 32, 64]
	static var size: Int {
		let n = UserDefaults.standard.integer(forKey: sizeKey)
		return sizes.contains(n) ? n : 16
	}
	static var padsCue: Bool { UserDefaults.standard.bool(forKey: cuesKey) }
}

/// The beat as Go waits on it: a count that rises each beat, and the
/// place within 4 bars (0 to 15)
enum CueBeat {
	static func now() -> (count: Int, place: Int)? {
		let link = WHLink.shared
		if link.drivesBeat {
			var pos = 0.0
			guard link.beatPosition(&pos) else { return nil }	// stopped
			let b = Int(pos.rounded(.down))
			return (b, ((b % 16) + 16) % 16)
		}
		let r = WHAudioInput.shared.reading()
		guard r.beatLocked.boolValue, r.beatInBar >= 0 else { return nil }
		return (Int(r.beats), Int(r.barInPhrase % 4) * 4 + Int(r.beatInBar))
	}
}

extension AppModel {
	// MARK: The cue

	/// cues an entry (clamped), or none with -1; said in the readout
	func cue(_ index: Int) {
		let n = playlistPatches.count
		guard n > 0 else { return }
		cuedPatch = min(max(index, 0), n - 1)
		showCue()
	}

	/// from the cue (none: the playing patch) by `step` entries, wrapping
	/// for single steps, stopping at the ends for tens
	func cueStep(_ step: Int) {
		let n = playlistPatches.count
		guard n > 0 else { return }
		let from = cuedPatch >= 0 ? cuedPatch : (playingPatch >= 0 ? playingPatch : (step > 0 ? -1 : n))
		if abs(step) == 1 {
			cue(((from + step) % n + n) % n)
		} else {
			cue(min(max(from + step, 0), n - 1))
		}
	}

	/// Image > Random Patch (Command-/; the user's request, 2026-11-25): a
	/// random entry played now, never the playing one; Command plays, as
	/// Command-Up and -Down, where Option cues
	func playRandomPatch() {
		let n = playlistPatches.count
		guard n > 0 else { return }
		let others = (0..<n).filter { $0 != playingPatch }
		playPatch(others.randomElement() ?? 0)
	}

	/// a random entry, never the playing one or the cued one
	func cueRandom() {
		let n = playlistPatches.count
		guard n > 0 else { return }
		let others = (0..<n).filter { $0 != playingPatch && $0 != cuedPatch }
		cue(others.randomElement() ?? 0)
	}

	/// the cue with the number being typed (Option-Command-G), in the readout
	func showCue(typing: String? = nil) {
		if let typing {
			let n = Int(typing) ?? 0
			let name = n >= 1 && n <= playlistPatches.count ? " · " + Self.patchName(playlistPatches[n - 1]) : ""
			StripFeed.shared.setReadout("Cue #\(typing)_" + name)
			return
		}
		guard cuedPatch >= 0, cuedPatch < playlistPatches.count else { return }
		StripFeed.shared.setReadout("Cued \(cuedPatch + 1) · " + Self.patchName(playlistPatches[cuedPatch]))
	}

	static func patchName(_ path: String) -> String {
		let last = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
		return (last as NSString).deletingPathExtension
	}

	/// the cue for the overlay: "Cued 47 · name", and when Go waits, on
	/// what; the pads' bank too, once one's been used
	var cueLine: String? {
		var parts: [String] = []
		if cuedPatch >= 0, cuedPatch < playlistPatches.count {
			var s = "Cued \(cuedPatch + 1) · " + Self.patchName(playlistPatches[cuedPatch])
			if pendingLaunch >= 0, let wait = launchWait {
				s += " · on the \(LaunchTiming.current == .fourBars ? "4 bars" : LaunchTiming.current.title.lowercased()) in \(wait)"
			}
			parts.append(s)
		}
		if bankShown, let b = bankText { parts.append(b) }
		return parts.isEmpty ? nil : parts.joined(separator: " · ")
	}

	// MARK: Pads and banks (MIDI)

	/// "Bank 3 (33–48)": the pads' bank, its entries numbered from 1
	var bankText: String? {
		let n = playlistPatches.count, size = PadSettings.size
		guard n > 0 else { return nil }
		let first = cueBank * size + 1, last = min((cueBank + 1) * size, n)
		return "Bank \(cueBank + 1) (\(first)–\(last))"
	}

	/// whether an entry is in the pads' bank (the Playlist shades it)
	func inBank(_ index: Int) -> Bool {
		bankShown && index / PadSettings.size == cueBank
	}

	/// cue, then go's MIDI and OSC targets (MidiManager Post::CUE): 0 Go,
	/// 1 Go Now, 2 Cue Next, 3 Cue Previous, 4 Bank Up, 5 Bank Down,
	/// 16 + n Pad n + 1
	func cueCommand(_ k: Int) {
		switch k {
		case 0: go()
		case 1: go(now: true)
		case 2: cueStep(1)
		case 3: cueStep(-1)
		case 4: bankStep(1)
		case 5: bankStep(-1)
		case 16..<32: pad(k - 16)
		default: break
		}
	}

	/// the next or previous bank, stopping at the ends
	func bankStep(_ step: Int) {
		let n = playlistPatches.count, size = PadSettings.size
		guard n > 0 else { return }
		cueBank = min(max(cueBank + step, 0), (n - 1) / size)
		bankShown = true
		if let b = bankText { StripFeed.shared.setReadout(b) }
	}

	/// pad n (0 to 15): the bank's nth entry, played on Launch Timing, or
	/// only cued (PadSettings)
	func pad(_ n: Int) {
		let size = PadSettings.size
		guard n < size else { return }
		let i = cueBank * size + n
		guard i < playlistPatches.count else { return }
		bankShown = true
		cue(i)
		if !PadSettings.padsCue { go() }
	}

	/// beats until a waiting Go plays, if there's a beat
	var launchWait: Int? {
		let p = LaunchTiming.current.period
		guard p > 0, let b = CueBeat.now() else { return nil }
		return p - b.place % p
	}

	// MARK: Go

	/// plays the cued patch (none: the one after the playing one), now or
	/// on Launch Timing's next beat, bar or 4 bars; `now` regardless
	func go(now: Bool = false) {
		let n = playlistPatches.count
		guard n > 0 else { return }
		if cuedPatch < 0 || cuedPatch >= n {
			cuedPatch = playingPatch >= 0 ? (playingPatch + 1) % n : 0
		}
		let timing = LaunchTiming.current
		guard !now, timing != .now, let b = CueBeat.now() else {
			launch(cuedPatch)
			return
		}
		pendingLaunch = cuedPatch
		launchFrom = b.count
		StripFeed.shared.setReadout("Go \(cuedPatch + 1) on the " + (timing == .fourBars ? "4 bars" : timing.title.lowercased()))
		LaunchClock.shared.start()
	}

	/// the waiting Go called off (the playlist changed, Go Now)
	func cancelLaunch() {
		pendingLaunch = -1
		LaunchClock.shared.stop()
	}

	/// a waiting Go's tick: plays when the beat reaches the launch point
	/// (or at once if the beat's lost)
	func launchTick() {
		guard pendingLaunch >= 0 else { return LaunchClock.shared.stop() }
		let p = LaunchTiming.current.period
		guard p > 0, let b = CueBeat.now() else { return launch(pendingLaunch) }
		if b.count != launchFrom, b.place % p == 0 { launch(pendingLaunch) }
	}

	private func launch(_ index: Int) {
		cancelLaunch()
		let n = playlistPatches.count
		guard index >= 0, index < n else { return }
		if playPatch(index) {
			cuedPatch = (index + 1) % n	// on to the next (the user's choice)
		}
	}
}

/// Ticks a waiting Go, 120 times a second, only while one waits
@MainActor
final class LaunchClock {
	static let shared = LaunchClock()
	private var timer: Timer?

	func start() {
		guard timer == nil else { return }
		let t = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
			MainActor.assumeIsolated { AppModel.shared.launchTick() }
		}
		RunLoop.main.add(t, forMode: .common)
		timer = t
	}

	func stop() {
		timer?.invalidate()
		timer = nil
	}
}
