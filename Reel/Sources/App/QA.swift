import AppKit
import ImageIO
import SwiftUI

/// `Reel -qa <dir>`: renders the real views with fake data to PNGs, then quits. Nothing is shown on screen:
/// the process is `.prohibited` and no window is ever ordered.
@MainActor
enum QA {
    static var mismatches = 0

    static func runIfAsked() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-qa"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Layout.frozen = true
        NSApp.setActivationPolicy(.prohibited)

        func capture(_ host: NSView, dark: Bool, name: String, size: NSSize? = nil) {
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }

        // fake recordings, fictional names
        func item(_ n: String, _ hoursAgo: Double, _ dur: Double, _ exports: Int) -> RecentItem {
            RecentItem(folder: URL(fileURLWithPath: "/tmp/reel-qa/\(n)"), name: n, duration: dur, date: Date().addingTimeInterval(-hoursAgo * 3600), exports: exports)
        }
        let recents = [item("a", 0.3, 47.2, 0), item("b", 3, 128.5, 2), item("c", 20, 12.8, 1), item("d", 70, 305, 1)]
        let originalMode = ReelModel(live: false).prefs.mode

        func scene(_ name: String, dark: Bool = true, items: [RecentItem] = recents, loaded: Bool = true, hover: String? = nil, mode: CaptureMode = .display, tweak: (ReelModel) -> Void = { _ in }) {
            let model = ReelModel(live: false)
            model.prefs.mode = mode
            model.shown = true
            if loaded { model.load(items) }
            tweak(model)
            let view = MenuView(model: model, forceHover: hover)
            let host = NSHostingView(rootView: view.padding(24).background(dark ? Color(hex: 0x3A3B3E) : Color(hex: 0xC9C8C3)).environment(\.colorScheme, dark ? .dark : .light))
            capture(host, dark: dark, name: name)
            let measured = host.fittingSize.height - 48
            if abs(measured - view.targetHeight) > 0.5 { mismatches += 1; print("height mismatch in \(name): layout \(measured), computed \(view.targetHeight)") }
        }
        scene("01-menu")
        scene("02-menu-hover", hover: recents[1].id)
        scene("03-menu-window-mode", mode: .window)
        scene("04-menu-empty", items: [])
        scene("05-menu-skeleton", loaded: false)
        scene("06-menu-one-recording", items: [recents[0]])
        scene("07-menu-light", dark: false, hover: recents[1].id)
        scene("08-menu-power-line") { $0.pulsePreview = 0.5 }
        ReelModel(live: false).prefs.mode = originalMode          // QA must not leave a changed preference behind
        UserDefaults.standard.set(originalMode.rawValue, forKey: "reelMode")

        statusItems(dir)
        countdown(dir, capture)

        // the editor, from a synthetic capture (needs ffmpeg)
        let qaRoot = FileManager.default.temporaryDirectory.appendingPathComponent("reel-qa-\(UUID().uuidString)")
        let work = qaRoot.appendingPathComponent("2026-11-20 14.02.31")
        defer { try? FileManager.default.removeItem(at: qaRoot) }
        if let project = try? { try Sample.make(work); return try Project.load(work) }() {
            let prefs = ReelModel(live: false).prefs
            func png(_ t: Double) -> CGImage? {
                let out = work.appendingPathComponent("f\(t).png")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: Exporter.ffmpegPath)
                p.arguments = ["-y", "-loglevel", "error", "-ss", "\(t)", "-i", work.appendingPathComponent("capture.mov").path, "-frames:v", "1", out.path]
                try? p.run(); p.waitUntilExit()
                return CGImageSourceCreateWithURL(out as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            }
            func editor(_ name: String, at t: Double, dark: Bool = true, tweak: (EditorModel) -> Void = { _ in }) {
                let m = EditorModel(project: project, prefs: prefs, sourceSize: CGSize(width: 1920, height: 1080))
                m.playhead = t
                tweak(m)
                if let src = png(t) { m.still = m.live.compositor.still(src, at: t) }
                let host = NSHostingView(rootView: EditorView(model: m, shown: true).environment(\.colorScheme, dark ? .dark : .light))
                capture(host, dark: dark, name: name, size: NSSize(width: 1120, height: 760))
            }
            editor("10-editor-start", at: 0.3)
            editor("11-editor-zoomed", at: 1.2) { $0.selected = $0.project.settings.segments.first?.id }
            editor("12-editor-mid-zoom", at: 0.8)
            editor("13-editor-second-zoom", at: 3.9) { $0.selected = $0.project.settings.segments.last?.id; $0.project.settings.frame.background = "3B4A6B" }
            editor("14-editor-trimmed", at: 1.2) { $0.setTrim(start: 0.5); $0.setTrim(end: 4.5); $0.project.settings.frame.padding = 0.1 }
            editor("15-editor-light", at: 1.2, dark: false)
            editor("16-editor-interrupted", at: 1.2) { $0.project.log.stoppedEarly = true }
            editor("20-export-options", at: 1.2) { $0.exportPhase = .options }
            editor("21-export-gif", at: 1.2) { $0.exportPhase = .options; $0.options.format = .gif }
            editor("22-export-running", at: 1.2) { $0.exportPhase = .running; $0.progress = 0.62 }
            editor("23-export-done", at: 1.2) { $0.exportPhase = .done(URL(fileURLWithPath: "/tmp/Reel 2026-11-20 14.02.mp4"), 4_300_000) }
            editor("24-export-failed", at: 1.2) { $0.exportPhase = .failed("Could not write the file: the disk is full.") }
            editor("25-export-light", at: 1.2, dark: false) { $0.exportPhase = .options }
        } else { print("could not build the synthetic capture (is ffmpeg installed?)") }

        // settings, every tab
        for (name, tab, dark) in [("30-settings-general", SettingsTab.general, true), ("31-settings-recording", .recording, true), ("32-settings-export", .export, true),
                                  ("33-settings-about", .about, true), ("34-settings-general-light", .general, false)] {
            let model = ReelModel(live: false)
            capture(NSHostingView(rootView: SettingsView(model: model, tab: tab).environment(\.colorScheme, dark ? .dark : .light)), dark: dark, name: name, size: NSSize(width: 520, height: 560))
        }
        print(mismatches == 0 ? "panel heights match layout" : "\(mismatches) height mismatches")
        NSApp.terminate(nil)
        return true
    }

    /// The menu bar image idle and recording, dark and light bar, 4x.
    private static func statusItems(_ dir: URL) {
        let scale: CGFloat = 4
        let tile = NSSize(width: 520 * scale, height: 56 * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(tile.width), pixelsHigh: Int(tile.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (half, dark) in [(0, true), (1, false)] {
            let bar = NSRect(x: CGFloat(half) * tile.width / 2, y: 0, width: tile.width / 2, height: tile.height)
            (dark ? NSColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1) : NSColor(srgbRed: 0.85, green: 0.85, blue: 0.83, alpha: 1)).setFill()
            bar.fill()
            var x = bar.minX + 20 * scale
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            for img in [StatusImage.idle(), StatusImage.recording(0), StatusImage.recording(7), StatusImage.recording(83)] {
                let r = NSRect(x: x, y: (tile.height - img.size.height * scale) / 2, width: img.size.width * scale, height: img.size.height * scale)
                appearance.performAsCurrentDrawingAppearance {
                    if img.isTemplate {
                        let tinted = NSImage(size: img.size, flipped: false) { rr in
                            img.draw(in: rr); (dark ? NSColor.white : NSColor.black).setFill(); rr.fill(using: .sourceIn); return true
                        }
                        tinted.draw(in: r)
                    } else { img.draw(in: r) }
                }
                x += r.width + 24 * scale
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("09-menu-bar-image.png"))
    }

    /// 3, 2, 1 at three sweep positions.
    private static func countdown(_ dir: URL, _ capture: (NSView, Bool, String, NSSize?) -> Void) {
        for (n, sweep) in [(3, 0.12), (2, 0.5), (1, 0.85)] {
            capture(NSHostingView(rootView: CountdownView(n: n, sweep: sweep).padding(24).background(Color(hex: 0x3A3B3E)).environment(\.colorScheme, .dark)), true, "08-countdown-\(n)", nil)
        }
    }
}
