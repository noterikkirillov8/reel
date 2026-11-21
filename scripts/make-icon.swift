#!/usr/bin/env swift
// Draws Reel's app icon (graphite body, wide R, a row of lamps with the red one lit) into Reel/Resources/Assets.xcassets/AppIcon.appiconset.
// Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("Reel/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
try #"{"info":{"author":"xcode","version":1}}"#.write(to: set.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(px) / 1024
    func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    // Hardware style: a graphite body, one wide-type glyph, one lit element in the accent (the REC lamp).
    let tile = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    hex(0x1B1C1F).setFill()
    NSBezierPath(roundedRect: tile, xRadius: 185 * k, yRadius: 185 * k).fill()
    hex(0x2C2D31).setStroke()
    let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 3 * k, dy: 3 * k), xRadius: 182 * k, yRadius: 182 * k)
    edge.lineWidth = 6 * k; edge.stroke()
    let base = NSFont.systemFont(ofSize: 440 * k, weight: .heavy)
    let desc = base.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.width: 0.5, NSFontDescriptor.TraitKey.weight: NSFont.Weight.heavy.rawValue]])
    let font = NSFont(descriptor: desc, size: 440 * k) ?? base
    let glyph = NSAttributedString(string: "R", attributes: [.font: font, .foregroundColor: hex(0xECEBE7)])
    let gs = glyph.size()
    glyph.draw(at: NSPoint(x: (1024 * k - gs.width) / 2, y: 392 * k))
    // five lamps like a tape deck's transport row, the first one is the lit REC lamp
    let d = 80 * k, gap = 44 * k, left = (1024 * k - (5 * d + 4 * gap)) / 2
    for i in 0..<5 {
        let r = NSRect(x: left + CGFloat(i) * (d + gap), y: 270 * k, width: d, height: d)
        (i == 0 ? hex(0xE5484D) : hex(0x2C2D31)).setFill()
        NSBezierPath(ovalIn: r).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try render(size * scale).write(to: set.appendingPathComponent(name))
        images.append(#"{"filename":"\#(name)","idiom":"mac","scale":"\#(scale)x","size":"\#(size)x\#(size)"}"#)
    }
}
try #"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#
    .write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
