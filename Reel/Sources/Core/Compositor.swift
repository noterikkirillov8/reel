import CoreGraphics
import CoreImage
import Foundation

/// Draws one output frame: background, shadow, the source cropped by the camera and rounded, cursor, click rings.
/// Used for the live preview, the exporter and the QA stills, so all three show the same picture.
final class Compositor: @unchecked Sendable {
    static let accent = (r: 0xE5 / 255.0, g: 0x48 / 255.0, b: 0x4D / 255.0)

    let source: CGSize          // pixels
    let canvas: CGSize
    let settings: ProjectSettings
    let content: CGRect         // inside the canvas, CI coordinates (origin bottom-left)
    let ci: CIContext
    private let track: CursorTrack
    private let camera: CameraTrack?
    private let log: EventLog
    private let backdrop: CIImage
    private let mask: CIImage
    private let sprite: CIImage
    private let spriteHeight = 192.0
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func canvasSize(source: CGSize, _ resolution: ExportOptions.Resolution) -> CGSize {
        switch resolution {
        case .hd1080: return CGSize(width: 1920, height: 1080)
        case .source: return CGSize(width: (source.width / 2).rounded() * 2, height: (source.height / 2).rounded() * 2)
        }
    }

    init(source: CGSize, canvas: CGSize, settings: ProjectSettings, log: EventLog, context: CIContext? = nil) {
        self.source = source; self.canvas = canvas; self.settings = settings; self.log = log
        ci = context ?? CIContext(options: [.cacheIntermediates: false])
        track = CursorTrack(log, smoothing: settings.cursorSmoothing)
        camera = settings.followCursor && !log.events.isEmpty ? CameraTrack(settings.segments, cursor: track, smoothness: settings.followSmoothness) : nil

        let pad = settings.frame.padding * min(canvas.width, canvas.height)
        let avail = CGRect(origin: .zero, size: canvas).insetBy(dx: pad, dy: pad)
        let fit = min(avail.width / source.width, avail.height / source.height)
        let w = (source.width * fit).rounded(), h = (source.height * fit).rounded()
        content = CGRect(x: ((canvas.width - w) / 2).rounded(), y: ((canvas.height - h) / 2).rounded(), width: w, height: h)

        let k = canvas.height / 1080
        let radius = settings.frame.radius * k * 2
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        func bitmap() -> CGContext {
            CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        let path = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let bg = bitmap()
        let c = rgbComponents(hex: settings.frame.background)
        bg.setFillColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        bg.fill(CGRect(origin: .zero, size: canvas))
        if settings.frame.shadow {
            bg.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 44 * k, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
            bg.setFillColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
            bg.addPath(path); bg.fillPath()
        }
        backdrop = CIImage(cgImage: bg.makeImage()!)
        let m = bitmap()
        m.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        m.addPath(path); m.fillPath()
        mask = CIImage(cgImage: m.makeImage()!)
        sprite = CIImage(cgImage: Self.cursorImage(height: 192))
    }

    /// The arrow: white with a 1 px dark outline, tip at the top-left of the image.
    static func cursorImage(height: Int) -> CGImage {
        let h = CGFloat(height), s = h / 22, w = 15 * s
        let ctx = CGContext(data: nil, width: Int(w.rounded(.up)), height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 1.2 * s + x * s, y: h - 1.2 * s - y * s) }
        let path = CGMutablePath()
        path.move(to: p(0, 0)); path.addLine(to: p(0, 17)); path.addLine(to: p(4.5, 13)); path.addLine(to: p(7.5, 19.5))
        path.addLine(to: p(10, 18.5)); path.addLine(to: p(7, 12)); path.addLine(to: p(12.5, 12)); path.closeSubpath()
        ctx.setLineJoin(.round)
        ctx.addPath(path); ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.setStrokeColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        ctx.setLineWidth(1.6 * s); ctx.drawPath(using: .fillStroke)
        return ctx.makeImage()!
    }

    /// Canvas position of a point given in normalised capture coordinates, for camera `vp`.
    func map(_ x: Double, _ y: Double, _ vp: CGRect) -> CGPoint {
        CGPoint(x: content.minX + (x - vp.minX) / vp.width * content.width,
                y: content.minY + (1 - (y - vp.minY) / vp.height) * content.height)
    }

    /// The finished frame at source time `t`, as an image the size of the canvas.
    func compose(_ src: CIImage, at t: Double) -> CIImage {
        let vp = Zoom.viewport(settings.segments, at: t, camera: camera)
        let crop = CGRect(x: vp.minX * source.width, y: (1 - vp.maxY) * source.height, width: vp.width * source.width, height: vp.height * source.height)
        let s = content.width / crop.width
        var img = src.clampedToExtent().cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: content.minX, y: content.minY))
        let unit = s * source.height / 1080            // canvas px per "1080 p source px"

        if settings.clickRings {
            for c in log.clicks {
                guard let u = Ring.progress(c.t, at: t) else { continue }
                if let ring = ringImage(progress: u, unit: unit) {
                    let at = map(c.x, c.y, vp)
                    img = ring.image.transformed(by: CGAffineTransform(translationX: at.x - ring.half, y: at.y - ring.half)).composited(over: img)
                }
            }
        }
        if !log.events.isEmpty {
            let pos = track.position(at: t)
            let down = log.clicks.last { $0.t <= t }.map { t - $0.t < 0.14 } ?? false
            let height = 24 * unit * settings.cursorSize * (down ? 0.86 : 1)
            let k = height / spriteHeight, at = map(pos.x, pos.y, vp)
            img = sprite.transformed(by: CGAffineTransform(scaleX: k, y: k))
                .transformed(by: CGAffineTransform(translationX: at.x, y: at.y - height))
                .composited(over: img)
        }
        return img.cropped(to: content)
            .applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: backdrop, kCIInputMaskImageKey: mask])
            .cropped(to: CGRect(origin: .zero, size: canvas))
    }

    private func ringImage(progress u: Double, unit: Double) -> (image: CIImage, half: Double)? {
        let eased = 1 - pow(1 - u, 3)
        let r = (14 + 38 * eased) * unit, line = max(1.5, 3.2 * unit * (1 - 0.5 * u)), alpha = pow(1 - u, 1.3)
        let size = Int((r + line + 3).rounded(.up)) * 2
        guard size > 4, let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let a = Self.accent, rect = CGRect(x: CGFloat(size) / 2 - r, y: CGFloat(size) / 2 - r, width: r * 2, height: r * 2)
        ctx.setFillColor(red: a.r, green: a.g, blue: a.b, alpha: alpha * 0.14); ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(red: a.r, green: a.g, blue: a.b, alpha: alpha); ctx.setLineWidth(line); ctx.strokeEllipse(in: rect)
        guard let image = ctx.makeImage() else { return nil }
        return (CIImage(cgImage: image), Double(size) / 2)
    }

    /// A still for QA and tests.
    func still(_ source: CGImage, at t: Double) -> CGImage? {
        ci.createCGImage(compose(CIImage(cgImage: source), at: t), from: CGRect(origin: .zero, size: canvas), format: .RGBA8, colorSpace: srgb)
    }
}
