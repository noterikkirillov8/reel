import Foundation

/// Synthetic input for tests, QA and the README: no screen needed.
enum Sample {
    /// A 5 s session: three clicks (two close together, one later), the cursor gliding between them.
    static func log() -> EventLog {
        var ev: [Ev] = []
        func lerp(_ a: Double, _ b: Double, _ u: Double) -> Double { a + (b - a) * u }
        var t = 0.0
        while t < 5.0 {
            let x: Double, y: Double
            switch t {
            case ..<0.9: let u = t / 0.9; (x, y) = (lerp(0.2, 0.30, u), lerp(0.3, 0.35, u))
            case ..<1.5: let u = (t - 0.9) / 0.6; (x, y) = (lerp(0.30, 0.34, u), lerp(0.35, 0.40, u))
            case ..<2.0: (x, y) = (0.34, 0.40)
            case ..<3.0: let u = (t - 2.0) / 1.0; (x, y) = (lerp(0.34, 0.78, u), lerp(0.40, 0.64, u))
            default: (x, y) = (0.78, 0.64)
            }
            ev.append(Ev(t: t, kind: .move, x: x, y: y))
            t += 1.0 / 60
        }
        for (ct, x, y) in [(1.0, 0.30, 0.35), (1.6, 0.34, 0.40), (3.6, 0.78, 0.64)] {
            ev.append(Ev(t: ct, kind: .down, x: x, y: y)); ev.append(Ev(t: ct + 0.08, kind: .up, x: x, y: y))
        }
        return EventLog(duration: 5.0, width: 1920, height: 1080, events: ev.sorted { $0.t < $1.t })
    }

    /// A 5 s session for cursor following: one click at 1.0 s, then the cursor sweeps across the frame (1.4 s...2.6 s) and rests.
    static func followLog() -> EventLog {
        var ev: [Ev] = []
        var t = 0.0
        while t < 5.0 {
            let u = Zoom.smooth((t - 1.4) / 1.2)
            ev.append(Ev(t: t, kind: .move, x: 0.30 + 0.45 * u, y: 0.40 + 0.20 * u))
            t += 1.0 / 60
        }
        ev.append(Ev(t: 1.0, kind: .down, x: 0.30, y: 0.40)); ev.append(Ev(t: 1.08, kind: .up, x: 0.30, y: 0.40))
        return EventLog(duration: 5.0, width: 1920, height: 1080, events: ev.sorted { $0.t < $1.t })
    }

    /// Writes folder/{capture.mov, events.json}: ffmpeg testsrc2 (5 s, 1920x1080, 60 fps) plus a sine track.
    static func make(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Exporter.ffmpegPath)
        p.arguments = ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=1920x1080:r=60:d=5", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=5",
                       "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "30", "-c:a", "aac", "-shortest", folder.appendingPathComponent("capture.mov").path]
        try p.run(); p.waitUntilExit()
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(log()).write(to: folder.appendingPathComponent("events.json"))
    }
}

