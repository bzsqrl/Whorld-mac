// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

import AppKit

// Update checking (new in the Mac port; Windows Whorld has none). Whorld
// asks GitHub's public releases list whether a newer release is out and, if
// so, shows its notes with a button that opens the release page; installing
// is up to the user, as the first time. Only Whorld's version is sent (in
// the User-Agent). Someone running a beta is offered betas; someone running
// a full release only full releases.

/// A release version as the repository's tags write it, without the "v":
/// 0.1.0, or 0.1.0-beta.2 (semantic versioning: a prerelease comes before
/// the release of the same number).
struct ReleaseVersion: Comparable, CustomStringConvertible {
	let core: [Int]	// major, minor, patch
	let pre: [String]	// "beta", "2"; empty for a full release

	init?(_ text: String) {
		var s = Substring(text.trimmingCharacters(in: .whitespaces))
		if s.hasPrefix("v") { s = s.dropFirst() }
		let parts = s.split(separator: "-", maxSplits: 1)
		guard let first = parts.first else { return nil }
		let nums = first.split(separator: ".").map { Int($0) }
		guard (1...3).contains(nums.count), nums.allSatisfy({ $0 != nil }) else { return nil }
		core = nums.map { $0! } + Array(repeating: 0, count: 3 - nums.count)
		pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
	}

	var isPrerelease: Bool { !pre.isEmpty }

	/// "0.1.0-beta.2"
	var description: String {
		core.map(String.init).joined(separator: ".") + (pre.isEmpty ? "" : "-" + pre.joined(separator: "."))
	}

	/// "0.1 beta 2", as the release titles and the About box put it
	var displayName: String {
		var c = core
		if c.count == 3 && c[2] == 0 { c.removeLast() }
		return ([c.map(String.init).joined(separator: ".")] + pre).joined(separator: " ")
	}

	static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
		if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
		if a.pre.isEmpty || b.pre.isEmpty { return !a.pre.isEmpty && b.pre.isEmpty }
		for (x, y) in zip(a.pre, b.pre) where x != y {
			switch (Int(x), Int(y)) {
			case let (i?, j?): return i < j
			case (_?, nil): return true	// numbers before words
			case (nil, _?): return false
			default: return x < y
			}
		}
		return a.pre.count < b.pre.count
	}
}

@MainActor
final class UpdateChecker {
	static let shared = UpdateChecker()

	struct Release {
		let version: ReleaseVersion
		let title: String
		let notes: String	// Markdown
		let page: URL
	}

	private static let releasesURL = URL(string: "https://api.github.com/repos/bzsqrl/Whorld-mac/releases?per_page=30")!
	private static let dayInSeconds: TimeInterval = 24 * 60 * 60
	private var checking = false
	private var pending: Release?	// found while full screen: shown on leaving it

	/// This build's version: Info.plist's WhorldReleaseVersion, set to the
	/// release's tag when one is made. WHORLD_UPDATE_TEST_VERSION=<version>
	/// pretends to be another (for testing).
	static var current: ReleaseVersion? {
		let env = ProcessInfo.processInfo.environment["WHORLD_UPDATE_TEST_VERSION"]
		return (env ?? Bundle.main.object(forInfoDictionaryKey: "WhorldReleaseVersion") as? String).flatMap(ReleaseVersion.init)
	}

	/// At launch: if automatic checks are on and the last was a day or more
	/// ago, check a few seconds later, after the window and any files are up.
	func checkAtLaunch() {
		guard Preferences.checkForUpdates else { return }
		let last = Preferences.defaults.double(forKey: "Update_fLastCheck")
		guard Date().timeIntervalSince1970 - last >= Self.dayInSeconds else { return }
		DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check(manual: false) }
	}

	/// Whorld > Check for Updates…: says so if there's nothing new, and
	/// offers a version even if it was skipped.
	func checkNow() { check(manual: true) }

	/// Leaving full screen: an update found meanwhile.
	func showPending() {
		guard let r = pending else { return }
		pending = nil
		offer(r, manual: false)
	}

	private func check(manual: Bool) {
		guard !checking, let current = Self.current else { return }
		checking = true
		var req = URLRequest(url: Self.releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
		req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		req.setValue("Whorld-mac/\(current)", forHTTPHeaderField: "User-Agent")
		URLSession.shared.dataTask(with: req) { data, response, error in
			let status = (response as? HTTPURLResponse)?.statusCode ?? 0
			let releases = status == 200 ? data.flatMap(Self.parse) : nil
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					self.finish(releases, current: current, manual: manual,
						failure: error?.localizedDescription ?? (releases == nil ? "GitHub answered \(status)." : nil))
				}
			}
		}.resume()
	}

	/// Published releases (not drafts) from the API's JSON.
	nonisolated private static func parse(_ data: Data) -> [Release]? {
		guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
		return list.compactMap { r in
			guard r["draft"] as? Bool != true,
				let tag = r["tag_name"] as? String, let v = ReleaseVersion(tag),
				let page = (r["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
			let title = (r["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Whorld for macOS \(v.displayName)"
			return Release(version: v, title: title, notes: r["body"] as? String ?? "", page: page)
		}
	}

	private func finish(_ releases: [Release]?, current: ReleaseVersion, manual: Bool, failure: String?) {
		checking = false
		guard let releases else {
			if manual {
				alert("Whorld couldn't check for updates.", failure ?? "")
			}
			return
		}
		Preferences.defaults.set(Date().timeIntervalSince1970, forKey: "Update_fLastCheck")
		let skipped = Preferences.defaults.string(forKey: "Update_sSkipVersion")
		let newer = releases
			.filter { $0.version > current && (current.isPrerelease || !$0.version.isPrerelease) }
			.filter { manual || $0.version.description != skipped }
			.max { $0.version < $1.version }
		guard let newer else {
			if manual {
				alert("Whorld is up to date.", "Version \(current.displayName) is the newest\(current.isPrerelease ? "" : " release").")
			}
			return
		}
		if AppModel.shared.isFullScreen && !manual {	// don't interrupt a performance
			pending = newer
			return
		}
		offer(newer, manual: manual)
	}

	private func offer(_ r: Release, manual: Bool) {
		let a = NSAlert()
		a.messageText = "\(r.title) is available."
		a.informativeText = "You have version \(Self.current?.displayName ?? "?"). Download it from GitHub, then install it as before: open the DMG and drag Whorld to Applications."
		a.addButton(withTitle: "Download…")
		a.addButton(withTitle: "Later")
		a.addButton(withTitle: "Skip This Version")
		let notes = Self.summary(r.notes)
		if !notes.isEmpty {
			let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 170))
			scroll.hasVerticalScroller = true
			scroll.borderType = .bezelBorder
			let text = NSTextView(frame: scroll.bounds)
			text.isEditable = false
			text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
			text.textContainerInset = NSSize(width: 4, height: 4)
			text.string = notes
			text.autoresizingMask = [.width]
			scroll.documentView = text
			a.accessoryView = scroll
		}
		NSApp.activate(ignoringOtherApps: true)
		switch a.runModal() {
		case .alertFirstButtonReturn:
			NSWorkspace.shared.open(r.page)
		case .alertThirdButtonReturn:
			Preferences.defaults.set(r.version.description, forKey: "Update_sSkipVersion")
		default:
			break
		}
	}

	private func alert(_ message: String, _ info: String) {
		let a = NSAlert()
		a.messageText = message
		a.informativeText = info
		a.runModal()
	}

	/// The notes' "New in …" section, or their opening, as plain text.
	static func summary(_ markdown: String) -> String {
		var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
		if let start = lines.firstIndex(where: { $0.hasPrefix("### New in") }) {
			let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.endIndex
			lines = Array(lines[(start + 1)..<end])
		} else {
			lines = Array(lines.prefix(12))
		}
		var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
		// plain text: links keep their words; emphasis and code marks go
		text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
		for mark in ["**", "`"] {
			text = text.replacingOccurrences(of: mark, with: "")
		}
		text = text.replacingOccurrences(of: #"(?m)^- "#, with: "• ", options: .regularExpression)
		return text
	}
}
