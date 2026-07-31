#!/usr/bin/env swift
//
// Renders the app icon from the same Lucide bird used in the menu bar.
//
// The menu-bar glyph is a thin template stroke, which would be invisible as an
// app icon, so this draws it in white on a rounded-slate tile at the standard
// macOS icon proportions. A designed icon should replace this; it exists so the
// bundle doesn't ship with a blank generic-application icon.
//
// Usage: swift scripts/make-icon.swift <output.icns>

import AppKit
import Foundation

let birdSVG = """
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="1.6" \
stroke-linecap="round" stroke-linejoin="round">\
<path d="M16 7h.01"/>\
<path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
<path d="m20 7 2 .5-2 .5"/>\
<path d="M10 18v3"/>\
<path d="M14 17.75V21"/>\
<path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
</svg>
"""

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns>\n".utf8))
    exit(64)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

guard let svgData = birdSVG.data(using: .utf8),
      let bird = NSImage(data: svgData)
else {
    FileHandle.standardError.write(Data("couldn't parse the bird SVG\n".utf8))
    exit(1)
}

/// Draw one square icon at `size` points.
func renderIcon(size: CGFloat) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // macOS icons sit in a rounded square inset from the canvas edge, with a
    // corner radius of ~22.37% of the tile — matching Big Sur's grid.
    let inset = size * 0.085
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = tile.width * 0.2237
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    // Near-black. The top lift is deliberately slight — just enough to keep
    // the tile from reading as a flat cutout against the light installer
    // background, without turning into a visible grey band.
    NSGradient(
        starting: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1),
        ending: NSColor(srgbRed: 0.015, green: 0.015, blue: 0.02, alpha: 1)
    )?.draw(in: tilePath, angle: -90)

    // Bird centred at ~54% of the tile, optically nudged up a touch.
    let glyph = tile.width * 0.54
    let rect = NSRect(
        x: tile.midX - glyph / 2,
        y: tile.midY - glyph / 2 + tile.height * 0.02,
        width: glyph, height: glyph
    )
    bird.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)

    return rep
}

// iconutil expects this exact set of names in an .iconset directory.
let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("parrot-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for variant in variants {
    guard let rep = renderIcon(size: variant.pixels),
          let png = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("failed rendering \(variant.name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(iconutil.terminationStatus)
}

print("✓ wrote \(outputURL.path)")
