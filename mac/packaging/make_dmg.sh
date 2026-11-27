#!/bin/sh
# This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
# Copyright 2026 Jeff Matson.
# Written with Claude (Anthropic).
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See the LICENSE file at the repository root.
#
# Builds a universal (Apple silicon + Intel) Release Whorld.app, signs it,
# and packages it with the licenses as build/dist/Whorld.dmg (no version in
# the file or volume name, the user's choice for public releases, 2026-11-27;
# the version is in the read-me and the app).
#   sh mac/packaging/make_dmg.sh
# With a Developer ID Application certificate in the keychain, the app and
# its Syphon.framework are signed with it (the hardened runtime and
# Whorld.entitlements), and the disk image is signed, notarized by Apple
# and stapled, so it opens without Gatekeeper's warning. Notarizing uses
# the keychain profile made by `xcrun notarytool store-credentials`
# (whorld-notary unless WHORLD_NOTARY_PROFILE says otherwise). Without the
# certificate, or with WHORLD_SIGN=adhoc, the app is signed ad hoc and not
# notarized, and the read-me says how to open it the first time.
# Optional: WHORLD_SIGN_IDENTITY (which certificate, if there are several),
# WHORLD_NOTARIZE=0 (sign but don't notarize). The identity is found in the
# keychain, so no name or team identifier is kept in the repository.
# Builds in build/package, apart from build/release (an app running from
# there keeps its signature, and its permissions).
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
out="$repo/build/dist"
derived="$repo/build/package"
xcodebuild -project "$repo/mac/app/Whorld.xcodeproj" -scheme Whorld -configuration Release \
	-derivedDataPath "$derived" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet
app="$derived/Build/Products/Release/Whorld.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
archs=$(lipo -archs "$app/Contents/MacOS/Whorld")
case "$archs" in *arm64*x86_64*|*x86_64*arm64*) ;; *) echo "not universal: $archs" >&2; exit 1;; esac

# The signing identity: the keychain's Developer ID Application certificate,
# unless ad hoc is asked for
identity=""
if [ "${WHORLD_SIGN:-}" != "adhoc" ]; then
	identity=${WHORLD_SIGN_IDENTITY:-$(security find-identity -v -p codesigning |
		sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -n 1)}
fi
if [ -n "$identity" ]; then
	echo "Signing with $identity"
	# inside out: the framework, then the app with the hardened runtime
	codesign --force --options runtime --timestamp --sign "$identity" \
		"$app/Contents/Frameworks/Syphon.framework"
	codesign --force --options runtime --timestamp --sign "$identity" \
		--entitlements "$repo/mac/packaging/Whorld.entitlements" "$app"
else
	echo "No Developer ID Application certificate: signing ad hoc, not notarizing"
	codesign --force --sign - --timestamp=none "$app"
fi
codesign --verify --deep --strict "$app"

stage="$out/stage"
rm -rf "$stage"; mkdir -p "$stage"
ditto "$app" "$stage/Whorld.app"
ln -s /Applications "$stage/Applications"
cp "$repo/LICENSE" "$stage/License.txt"
cp "$repo/mac/third_party/Syphon-Framework/License.txt" "$stage/Syphon License.txt"	# embedded Syphon.framework (BSD)
cp "$repo/mac/third_party/link/LICENSE.md" "$stage/Ableton Link License.txt"	# compiled-in Ableton Link (GPLv2 or later)
mkdir -p "$stage/TouchOSC"
cp "$repo/mac/touchosc/Whorld.tosc" "$stage/TouchOSC/Whorld.tosc"	# OSC remote control layout
if [ -n "$identity" ]; then
	opening="Whorld is signed with an Apple Developer ID and notarized by Apple."
else
	opening="This build is not notarized by Apple, so the first time you open it macOS
says it can't check the app for malicious software. Control-click Whorld in
the Applications folder, choose Open, then Open again. On macOS 15 and
later, if there is no Open button, go to System Settings > Privacy &
Security and click Open Anyway. You only need to do this once."
fi
cat > "$stage/Read Me.txt" <<TXT
Whorld $version for macOS
A port of Whorld, the free sacred-geometry visualizer by Chris Korda.
Requires macOS 14 or later, on Apple silicon or Intel.

To install, drag Whorld to the Applications folder.

$opening
Whorld is free software under the GNU General Public License version 3 or
later (License.txt), and comes with no warranty.
It includes Syphon.framework, copyright 2010 bangnoise (Tom Butterworth) &
vade (Anton Marini), under its own license (Syphon License.txt), and
Ableton's Link library, copyright 2016 Ableton AG, under the GNU GPL
version 2 or later (Ableton Link License.txt).
Source code: https://github.com/bzsqrl/Whorld-mac
TXT

dmg="$out/Whorld.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "Whorld" -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"
rm -rf "$stage"

# The disk image signed, notarized (Apple checks the app inside it) and
# stapled, so Gatekeeper accepts it offline too
if [ -n "$identity" ]; then
	codesign --sign "$identity" --timestamp "$dmg"
	if [ "${WHORLD_NOTARIZE:-1}" != "0" ]; then
		profile=${WHORLD_NOTARY_PROFILE:-whorld-notary}
		echo "Notarizing (usually a few minutes)..."
		result=$(xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json)
		id=$(printf '%s' "$result" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')
		case "$result" in
		*'"status":"Accepted"'*|*'"status" : "Accepted"'*) ;;
		*)
			echo "Notarization failed: $result" >&2
			[ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$profile" >&2
			exit 1;;
		esac
		xcrun stapler staple -q "$dmg"
		xcrun stapler validate -q "$dmg"
		spctl --assess --type open --context context:primary-signature -v "$dmg"
	fi
fi
echo "$dmg ($archs)"
