import AppKit

/// The menu bar mark: a film reel (ring and three holes). While recording: a red LED and the running timecode.
enum StatusImage {
    static func idle() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { rect in
            NSColor.black.setStroke(); NSColor.black.setFill()
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 6.4, y: c.y - 6.4, width: 12.8, height: 12.8)); ring.lineWidth = 1.2; ring.stroke()
            for i in 0..<3 {
                let a = Double(i) / 3 * 2 * .pi + .pi / 2
                NSBezierPath(ovalIn: NSRect(x: c.x + cos(a) * 3.4 - 1.35, y: c.y + sin(a) * 3.4 - 1.35, width: 2.7, height: 2.7)).fill()
            }
            NSBezierPath(ovalIn: NSRect(x: c.x - 0.8, y: c.y - 0.8, width: 1.6, height: 1.6)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Not a template: the LED is red in every menu bar; the text follows the bar's colour when it is drawn.
    static func recording(_ seconds: Double, lit: Bool = true) -> NSImage {
        let text = NSAttributedString(string: timecode(seconds).dropLast(2).description, attributes: [.font: wideFont(size: 11), .foregroundColor: NSColor.labelColor])
        let w = ceil(text.size().width)
        return NSImage(size: NSSize(width: 6 + 6 + 5 + w + 4, height: 16), flipped: false) { rect in
            NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: lit ? 1 : 0.3).setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: rect.midY - 3, width: 6, height: 6)).fill()
            text.draw(at: NSPoint(x: 15, y: (rect.height - text.size().height) / 2))
            return true
        }
    }

    static func wideFont(size: CGFloat) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let desc = base.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.width: 0.4, NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue]])
        return NSFont(descriptor: desc, size: size) ?? base
    }
}
