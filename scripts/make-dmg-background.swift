#!/usr/bin/env swift
//
// Renders the DMG window background: a headline and three chevrons pointing
// from the app toward the Applications folder. Finder draws the two icons on
// top, at the positions bundle.sh sets — this only paints what goes behind.
//
// Usage: swift scripts/make-dmg-background.swift <output-dir>
//   writes background.png (1x) and background@2x.png

import AppKit
import Foundation

// Must match the Finder window size bundle.sh sets, or the art won't line up.
// This is the *content* area — bundle.sh adds the title bar on top of it,
// since Finder's window `bounds` includes the title bar and a background
// taller than the content area makes the window scroll.
let width: CGFloat = 660
let height: CGFloat = 340

// Icon slot centres, in the same top-left origin Finder uses.
let leftSlot = CGPoint(x: 175, y: 186)
let rightSlot = CGPoint(x: 485, y: 186)

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <output-dir>\n".utf8))
    exit(64)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

func draw(scale: CGFloat) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // AppKit draws bottom-up; everything below is written in Finder's
    // top-left coordinates and flipped here so the two agree.
    func y(_ topDown: CGFloat) -> CGFloat { height - topDown }

    // ---- backdrop: pale blue drifting to warm grey, corner to corner
    let canvas = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.906, green: 0.933, blue: 0.973, alpha: 1), 0.0),
        (NSColor(srgbRed: 0.945, green: 0.945, blue: 0.961, alpha: 1), 0.55),
        (NSColor(srgbRed: 0.969, green: 0.941, blue: 0.945, alpha: 1), 1.0)
    )?.draw(in: canvas, angle: -65)

    func text(
        _ string: String, size: CGFloat, weight: NSFont.Weight,
        color: NSColor, centerY: CGFloat
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
        let bounds = attributed.size()
        attributed.draw(in: NSRect(
            x: 0, y: y(centerY) - bounds.height / 2,
            width: width, height: bounds.height
        ))
    }

    /// Headline with the product name italicised, so "parrot" reads as a name
    /// rather than a stray noun in the sentence.
    func headline(_ string: String, emphasising word: String, centerY: CGFloat) {
        let size: CGFloat = 22
        let regular = NSFont.systemFont(ofSize: size, weight: .semibold)
        // Add italic to the *existing* descriptor rather than building a fresh
        // one — the weight lives in the descriptor's trait dictionary, and
        // starting over drops it back to regular.
        let emphasis = NSFont(
            descriptor: regular.fontDescriptor.withSymbolicTraits(
                regular.fontDescriptor.symbolicTraits.union(.italic)
            ),
            size: size
        ) ?? regular

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributed = NSMutableAttributedString(string: string, attributes: [
            .font: regular,
            .foregroundColor: NSColor(srgbRed: 0.36, green: 0.36, blue: 0.40, alpha: 1),
            .paragraphStyle: style,
        ])
        if let range = string.range(of: word) {
            attributed.addAttribute(.font, value: emphasis, range: NSRange(range, in: string))
        }
        let bounds = attributed.size()
        attributed.draw(in: NSRect(
            x: 0, y: y(centerY) - bounds.height / 2,
            width: width, height: bounds.height
        ))
    }

    headline("Drag parrot into the Applications folder",
             emphasising: "parrot", centerY: 74)

    // ---- three chevrons, fading up toward the destination
    let midX = (leftSlot.x + rightSlot.x) / 2
    let chevronY = y(leftSlot.y)
    let halfHeight: CGFloat = 15
    let reach: CGFloat = 9
    // Wide enough that the three read as separate marks rather than one blob.
    let spacing: CGFloat = 34

    for (index, alpha) in [0.22, 0.38, 0.55].enumerated() {
        let x = midX + CGFloat(index - 1) * spacing
        let chevron = NSBezierPath()
        chevron.move(to: CGPoint(x: x - reach, y: chevronY + halfHeight))
        chevron.line(to: CGPoint(x: x + reach, y: chevronY))
        chevron.line(to: CGPoint(x: x - reach, y: chevronY - halfHeight))
        chevron.lineWidth = 7
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        NSColor(srgbRed: 0.30, green: 0.30, blue: 0.34, alpha: alpha).setStroke()
        chevron.stroke()
    }

    return rep
}

for (name, scale) in [("background.png", CGFloat(1)), ("background@2x.png", CGFloat(2))] {
    guard let rep = draw(scale: scale),
          let png = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("failed rendering \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: outDir.appendingPathComponent(name))
}

print("✓ wrote background.png + background@2x.png")
