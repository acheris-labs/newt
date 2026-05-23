#!/usr/bin/env swift
// Generates Newt's iconset: a rounded green squircle with the lizard SF
// Symbol centered on it. Usage: swift tools/gen-icon.swift <iconset-dir>

import AppKit
import Foundation

let bgTop    = NSColor(srgbRed: 0.20, green: 0.55, blue: 0.30, alpha: 1)
let bgBottom = NSColor(srgbRed: 0.08, green: 0.28, blue: 0.18, alpha: 1)
let symbolColor = NSColor(srgbRed: 0.95, green: 0.98, blue: 0.92, alpha: 1)

func drawIcon(size: CGFloat) {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // Rounded squircle background with a subtle vertical gradient.
    let radius = size * 0.225
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGraphicsContext.current?.cgContext.saveGState()
    bgPath.addClip()
    let gradient = NSGradient(starting: bgTop, ending: bgBottom)!
    gradient.draw(in: rect, angle: 270)

    // The lizard glyph, sized to fill ~72% of the icon and centered.
    // paletteColors paints the symbol in a single explicit color cleanly,
    // without touching the surrounding background.
    let sizeCfg    = NSImage.SymbolConfiguration(pointSize: size * 0.72, weight: .regular)
    let paletteCfg = NSImage.SymbolConfiguration(paletteColors: [symbolColor])
    let cfg = sizeCfg.applying(paletteCfg)
    guard let lizard = NSImage(systemSymbolName: "lizard.fill",
                               accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else {
        NSGraphicsContext.current?.cgContext.restoreGState()
        return
    }
    let imageSize = lizard.size
    let drawRect = NSRect(
        x: (size - imageSize.width)  / 2,
        y: (size - imageSize.height) / 2,
        width:  imageSize.width,
        height: imageSize.height
    )
    lizard.draw(in: drawRect)
    NSGraphicsContext.current?.cgContext.restoreGState()
}

func makePNG(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 32
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "Newt.iconset"

try? FileManager.default.removeItem(atPath: outDir)
try! FileManager.default.createDirectory(atPath: outDir,
                                         withIntermediateDirectories: true)

let entries: [(name: String, size: Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",   128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",   256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",   512),
    ("icon_512x512@2x.png", 1024),
]

for e in entries {
    let png = makePNG(size: e.size)
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(e.name)"))
}

FileHandle.standardOutput.write(
    "wrote \(outDir) with \(entries.count) images\n".data(using: .utf8)!)
