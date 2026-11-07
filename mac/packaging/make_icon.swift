// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson. The icon design is redrawn from Whorld's
// res/Whorld.ico, copyleft Chris Korda.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.
//
// Draws the app icon as vectors at every iconset size and builds the .icns:
//   xcrun swiftc mac/packaging/make_icon.swift -o /tmp/make_icon && /tmp/make_icon mac/app/Whorld/AppIcon.icns
// The design is the Windows icon's three nested pentagons (red, yellow,
// green, point down, round joins, on black), placed on the macOS icon grid
// (an 824-pixel rounded square inside a 1024 canvas).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func pentagon(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    for i in 0..<5 {  // point down in a y-down design space
        let a = CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / 5
        let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

func render(_ px: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    // y-down so the design matches the Windows icon
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 20, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape); ctx.clip()
    // Design space is the original 256-pixel icon, scaled onto the tile.
    ctx.translateBy(x: tile.minX, y: tile.minY); ctx.scaleBy(x: tile.width / 256, y: tile.height / 256)
    ctx.setLineJoin(.round)
    let rings: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [  // radius, width, r, g, b
        (196, 34, 1, 0, 0), (113, 26, 1, 1, 0), (47, 20, 0, 1, 0)]
    for (r, w, cr, cg, cb) in rings {
        ctx.addPath(pentagon(128, 126, r))
        ctx.setLineWidth(w); ctx.setStrokeColor(CGColor(srgbRed: cr, green: cg, blue: cb, alpha: 1)); ctx.strokePath()
    }
    return ctx.makeImage()!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let dst = CGImageDestinationCreateWithURL(set.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, render(base * scale), nil)
        CGImageDestinationFinalize(dst)
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]
try! p.run(); p.waitUntilExit()
if CommandLine.arguments.count > 2 {  // optional preview PNG
    try? FileManager.default.removeItem(atPath: CommandLine.arguments[2])
    try! FileManager.default.copyItem(at: set.appendingPathComponent("icon_512x512@2x.png"), to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
exit(p.terminationStatus)
