import AVFoundation
import Foundation

/// `Reel -render <project folder> <out.mp4|out.gif> [--source] [--hevc] [--fps N] [--no-rings] [--trim a b]`
/// Runs before any NSApplication or window exists: no UI, no Screen Recording, just the render pipeline.
enum CLI {
    /// `Reel -make-sample <dir>`: the synthetic 5 s capture and mouse log (needs ffmpeg).
    static func makeSample(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "-make-sample"), i + 1 < args.count else { return 2 }
        do { try Sample.make(URL(fileURLWithPath: args[i + 1])); print("sample written to \(args[i + 1])"); return 0 } catch { print("failed: \(error)"); return 1 }
    }

    static func render(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "-render"), i + 2 < args.count else { print("usage: Reel -render <project folder> <out.mp4|out.gif>"); return 2 }
        let folder = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
        guard var project = try? Project.load(folder) else { print("cannot read project at \(folder.path)"); return 1 }
        var o = ExportOptions()
        o.format = out.pathExtension.lowercased() == "gif" ? .gif : .mp4
        if args.contains("--source") { o.resolution = .source }
        if args.contains("--hevc") { o.codec = .hevc }
        if let f = args.firstIndex(of: "--fps"), f + 1 < args.count { o.fps = Int(args[f + 1]) ?? 0 }
        if args.contains("--no-rings") { project.settings.clickRings = false }
        if let t = args.firstIndex(of: "--trim"), t + 2 < args.count, let a = Double(args[t + 1]), let b = Double(args[t + 2]) { project.settings.trimStart = a; project.settings.trimEnd = b }
        let done = DispatchSemaphore(value: 0)
        let result = Box<Int32>(0)
        let started = Date()
        let snapshot = project, opts = o
        Task.detached {
            do {
                try await Exporter.export(snapshot, options: opts, to: out, progress: { p in if Int(p * 100) % 25 == 0 { FileHandle.standardError.write(Data("\(Int(p * 100))%\n".utf8)) } }, cancelled: { false })
                print(String(format: "wrote %@ in %.1f s", out.path, Date().timeIntervalSince(started)))
            } catch { print("render failed: \(error.localizedDescription)"); result.value = 1 }
            done.signal()
        }
        done.wait()
        return result.value
    }
}
