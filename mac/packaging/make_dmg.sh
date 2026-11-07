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
# Builds a universal (Apple silicon + Intel) Release Whorld.app, signs it
# ad hoc, and packages it with the license as build/dist/Whorld-<version>.dmg.
#   sh mac/packaging/make_dmg.sh
# The app isn't notarized (that needs an Apple Developer ID), so on first
# launch users Control-click > Open; see the read-me in the disk image.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
out="$repo/build/dist"
derived="$repo/build/release"
xcodebuild -project "$repo/mac/app/Whorld.xcodeproj" -scheme Whorld -configuration Release \
	-derivedDataPath "$derived" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet
app="$derived/Build/Products/Release/Whorld.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")

# Ad-hoc signature over the whole bundle, then check it and the architectures.
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
archs=$(lipo -archs "$app/Contents/MacOS/Whorld")
case "$archs" in *arm64*x86_64*|*x86_64*arm64*) ;; *) echo "not universal: $archs" >&2; exit 1;; esac

stage="$out/stage"
rm -rf "$stage"; mkdir -p "$stage"
ditto "$app" "$stage/Whorld.app"
ln -s /Applications "$stage/Applications"
cp "$repo/LICENSE" "$stage/License.txt"
cat > "$stage/Read Me.txt" <<TXT
Whorld $version for macOS
A port of Whorld, the free sacred-geometry visualizer by Chris Korda.
Requires macOS 14 or later, on Apple silicon or Intel.

To install, drag Whorld to the Applications folder.

This build is not notarized by Apple, so the first time you open it macOS
says it can't check the app for malicious software. Control-click Whorld in
the Applications folder, choose Open, then Open again. On macOS 15 and
later, if there is no Open button, go to System Settings > Privacy &
Security and click Open Anyway. You only need to do this once.

Whorld is free software under the GNU General Public License version 3 or
later (License.txt), and comes with no warranty.
Source code: https://github.com/bzsqrl/Whorld-mac
TXT

dmg="$out/Whorld-$version.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "Whorld $version" -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"
rm -rf "$stage"
echo "$dmg ($archs)"
