import AppKit
import SwiftUI

/// `Reel -intro-preview <dir>`: start, middle and end frame of every intro scene, off-screen only.
@MainActor
enum IntroPreview {
    static func runIfAsked() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-intro-preview"), i + 1 < args.count else { return false }
        NSApp.setActivationPolicy(.prohibited)
        Layout.frozen = true
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func shoot(_ view: AnyView, size: NSSize? = nil, name: String) {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        for scene in 0..<IntroModel.titles.count {
            var frames: [(String, Double)] = [("start", 0.2), ("middle", 2.2), ("end", 4.4)]
            if scene == 0 { frames = [("start", 0.2), ("three", 0.9), ("two", 1.8), ("one", 2.8), ("rec", 4.4)] }
            for (label, t) in frames {
                let demo = Demo(scene: scene)
                demo.jump(to: t)
                let intro = IntroModel(scene: scene, preview: demo)
                shoot(AnyView(IntroView(intro: intro).padding(24).background(Color(hex: 0x2A2B2E))), name: "intro-\(scene + 1)-\(label)")
            }
        }
        NSApp.terminate(nil)
        return true
    }
}
