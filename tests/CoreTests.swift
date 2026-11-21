import AVFoundation
import CoreImage
import Foundation
import ImageIO
import ScreenCaptureKit

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { passes += 1; print("ok   \(name)") } else { failures += 1; print("FAIL \(name) \(detail())") }
}

typealias Fixture = Sample

func ffmpegRun(_ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    p.arguments = ["-y", "-loglevel", "error"] + args
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

func loadImage(_ url: URL) -> CGImage? {
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(s, 0, nil)
}

func rgba(_ image: CGImage) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return data
}

func meanDiff(_ a: CGImage, _ b: CGImage) -> Double {
    guard a.width == b.width, a.height == b.height else { return 999 }
    let x = rgba(a), y = rgba(b)
    var sum = 0
    for i in stride(from: 0, to: x.count, by: 4) { for c in 0..<3 { sum += abs(Int(x[i + c]) - Int(y[i + c])) } }
    return Double(sum) / Double(x.count / 4 * 3)
}

/// Pixels where two frames differ clearly.
func changedPixels(_ a: CGImage, _ b: CGImage) -> Int {
    let x = rgba(a), y = rgba(b)
    var n = 0
    for i in stride(from: 0, to: x.count, by: 4) where abs(Int(x[i]) - Int(y[i])) + abs(Int(x[i + 1]) - Int(y[i + 1])) + abs(Int(x[i + 2]) - Int(y[i + 2])) > 40 { n += 1 }
    return n
}

@main
struct Tests {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        if let i = CommandLine.arguments.firstIndex(of: "--write-fixture"), i + 1 < CommandLine.arguments.count {
            do { try Fixture.make(URL(fileURLWithPath: CommandLine.arguments[i + 1])); print("fixture written") } catch { print("fixture failed: \(error)"); exit(1) }
            return
        }
        zoomMaths()
        cursorMaths()
        followMaths()
        captureFormats()
        for macSound in [true, false] {
            for mic in [true, false] {
                let config = SCStreamConfiguration()
                Recorder.configureAudio(config, macSound: macSound, mic: mic)
                check(config.capturesAudio == macSound && config.captureMicrophone == mic && config.excludesCurrentProcessAudio,
                      "Mac sound \(macSound), mic \(mic): independent inputs, Reel audio excluded")
            }
        }
        areaScreenMatching()
        trimming()
        do { try corruptProject() } catch { check(false, "corrupt project", "\(error)") }
        await pipeline()
        introFlowChecks { check($0, $1) }
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func captureFormats() {
        func verify(_ width: Int, _ height: Int, _ preferred: ExportOptions.Codec, _ available: Bool,
                    _ codec: AVVideoCodecType, _ outputWidth: Int, _ outputHeight: Int) {
            let format = Recorder.captureFormat(size: CGSize(width: width, height: height), preferred: preferred, hevcAvailable: available)
            check(format.codec == codec && format.size == CGSize(width: outputWidth, height: outputHeight),
                  "capture \(width)x\(height), prefer \(preferred), HEVC available \(available): \(codec.rawValue) \(outputWidth)x\(outputHeight)")
        }
        verify(1512, 982, .h264, true, .h264, 1512, 982)
        verify(3024, 1964, .h264, true, .h264, 3024, 1964)
        verify(3024, 1964, .hevc, true, .hevc, 3024, 1964)
        verify(3024, 1964, .hevc, false, .h264, 3024, 1964)
        verify(4096, 2160, .h264, true, .h264, 4096, 2160)
        verify(5120, 1440, .h264, true, .hevc, 5120, 1440)
        verify(5120, 1440, .h264, false, .h264, 4096, 1152)
        verify(6016, 3384, .h264, true, .hevc, 6016, 3384)
        verify(6016, 3384, .hevc, false, .h264, 4096, 2304)
        verify(1440, 5120, .h264, true, .hevc, 1440, 5120)
        verify(1440, 5120, .h264, false, .h264, 1152, 4096)
    }

    @MainActor
    static func areaScreenMatching() {
        let screens: [(id: CGDirectDisplayID, frame: CGRect)] = [
            (11, CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            (22, CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        ]
        let match = AreaPicker.matchingScreen(for: 22, in: screens, id: { $0.id })
        check(match?.frame == screens[1].frame, "area picker matches the second of two same-size screens by display ID")
        check(AreaPicker.matchingScreen(for: 33, in: screens, id: { $0.id }) == nil, "area picker does not substitute another screen for a missing display ID")
    }

    static func zoomMaths() {
        check(Zoom.smooth(0) == 0 && Zoom.smooth(1) == 1 && abs(Zoom.smooth(0.5) - 0.5) < 1e-9, "smooth endpoints")
        var last = -1.0, mono = true
        for i in 0...100 { let v = Zoom.smooth(Double(i) / 100); if v < last { mono = false }; last = v }
        check(mono, "smooth is monotonic")

        let seg = ZoomSegment(start: 1, end: 3, zoom: 2, cx: 0.5, cy: 0.5)
        check(Zoom.envelope(seg, at: 0.9) == 0 && Zoom.envelope(seg, at: 1) == 0 && Zoom.envelope(seg, at: 3.1) == 0, "envelope is zero outside")
        check(abs(Zoom.envelope(seg, at: 1 + Zoom.ease) - 1) < 1e-9 && Zoom.envelope(seg, at: 2) == 1, "envelope holds at 1 after 0.4 s")
        check(Zoom.envelope(seg, at: 1.2) > 0.4 && Zoom.envelope(seg, at: 1.2) < 0.6, "envelope is half way at 0.2 s")
        check(Zoom.viewport([seg], at: 0) == CGRect(x: 0, y: 0, width: 1, height: 1), "no zoom outside a segment")
        check(abs(Zoom.viewport([seg], at: 2).width - 0.5) < 1e-9, "2x shows half the frame")

        // camera clamping: segments aimed at every corner and edge, every level, every moment: the view never leaves the frame
        var inside = true
        for (cx, cy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0), (0.01, 0.5), (0.5, 0.99), (0.5, 0.5)] {
            for z in [1.2, 1.8, 3.0] {
                let s = ZoomSegment(start: 0, end: 4, zoom: z, cx: cx, cy: cy)
                for i in 0...400 {
                    let r = Zoom.viewport([s], at: Double(i) / 100)
                    if r.minX < -1e-9 || r.minY < -1e-9 || r.maxX > 1 + 1e-9 || r.maxY > 1 + 1e-9 { inside = false }
                }
            }
        }
        check(inside, "camera never shows outside the frame")
        let corner = Zoom.clampedRect(cx: 0.02, cy: 0.97, zoom: 3)
        check(corner.minX == 0 && abs(corner.maxY - 1) < 1e-9, "corner click clamps to the corner", "\(corner)")

        let segs = Zoom.generate(Fixture.log())
        check(segs.count == 2, "three clicks make two segments (1.5 s cluster rule)", "got \(segs.count)")
        if segs.count == 2 {
            check(abs(segs[0].start - 0.6) < 1e-9 && abs(segs[0].zoom - 1.8) < 1e-9, "first segment starts 0.4 s before the first click at 1.8x", "\(segs[0])")
            check(abs(segs[0].cx - 0.32) < 1e-9 && abs(segs[0].cy - 0.375) < 1e-9, "cluster is centred on the mean of its clicks")
            check(segs[0].end <= segs[1].start && segs[0].end > 2.6, "first segment is held while the cursor stays near, then ends before the next", "\(segs[0].end) \(segs[1].start)")
            check(abs(segs[1].start - 3.2) < 1e-9 && segs[1].end <= 5.0, "second segment is clipped to the recording")
            check(Zoom.envelope(segs[0], at: 1.0) > 0.999, "full zoom lands on the click")
        }
    }

    static func cursorMaths() {
        let jump = EventLog(duration: 3, width: 100, height: 100, events: [Ev(t: 0, kind: .move, x: 0.1, y: 0.1), Ev(t: 1, kind: .move, x: 0.9, y: 0.9)])
        let track = CursorTrack(jump, smoothing: 0.5)
        var last = 0.0, mono = true, over = false
        for i in 0...300 { let p = track.position(at: Double(i) / 100); if p.x < last - 1e-9 { mono = false }; if p.x > 0.9 + 1e-6 { over = true }; last = p.x }
        check(mono && !over, "cursor spring glides without overshoot")
        check(abs(track.position(at: 0.99).x - 0.1) < 0.01 && abs(track.position(at: 3).x - 0.9) < 0.002, "cursor starts at rest and settles on the target")
        let m = track.position(at: 1.05)
        check(m.x > 0.1 && m.x < 0.9, "cursor is in flight shortly after the jump")
    }

    /// The camera centre of the viewport sequence at 60 fps.
    static func centres(_ seg: ZoomSegment, _ cam: CameraTrack?, from a: Double, to b: Double) -> [CGPoint] {
        stride(from: a, through: b, by: 1.0 / 60).map { let r = Zoom.viewport([seg], at: $0, camera: cam); return CGPoint(x: r.midX, y: r.midY) }
    }

    static func followMaths() {
        func ev(_ pts: [(Double, Double, Double)], duration: Double = 6) -> EventLog {
            EventLog(duration: duration, width: 100, height: 100, events: pts.map { Ev(t: $0.0, kind: .move, x: $0.1, y: $0.2) })
        }
        func cam(_ log: EventLog, _ seg: ZoomSegment, smooth: Double = 0.5) -> CameraTrack { CameraTrack([seg], cursor: CursorTrack(log, smoothing: 0.5), smoothness: smooth) }
        let seg = ZoomSegment(start: 0, end: 6, zoom: 2, cx: 0.5, cy: 0.5)

        // inside the dead zone (55% of a 0.5-wide view = 0.275 wide, so +-0.1375): the camera stays put
        var wp: [(Double, Double, Double)] = []
        for i in 0...300 { let k = Double(i); wp.append((k / 50, 0.5 + 0.10 * sin(k / 20), 0.5 + 0.08 * cos(k / 25))) }
        let wiggle = ev(wp)
        let still = centres(seg, cam(wiggle, seg), from: 1, to: 5.5)
        let drift = still.map { hypot($0.x - 0.5, $0.y - 0.5) }.max() ?? 1
        check(drift < 1e-6, "camera stays still while the cursor moves inside the dead zone", "drift \(drift)")

        // leaves the dead zone and rests off-centre: the camera follows and ends with the cursor back inside it
        let away = ev([(0, 0.5, 0.5), (1.5, 0.5, 0.5), (2.0, 0.72, 0.62), (6, 0.72, 0.62)])
        let c1 = cam(away, seg), cur = CursorTrack(away, smoothing: 0.5)
        let moved = centres(seg, c1, from: 1, to: 5.5)
        let end = moved.last!, rest = cur.position(at: 5.5)
        check(end.x > 0.55, "camera follows when the cursor leaves the dead zone", "\(end)")
        check(abs(rest.x - end.x) <= 0.55 * 0.25 + 0.002 && abs(rest.y - end.y) <= 0.55 * 0.25 + 0.002, "camera brings the cursor back inside the dead zone", "cursor \(rest) camera \(end)")
        var mono = true
        for i in 1..<moved.count where moved[i].x < moved[i - 1].x - 1e-9 { mono = false }
        check(mono, "camera pan toward a resting cursor never reverses")

        // never outside the frame, 1.2x...3x, cursor in every corner
        var inside = true
        for z in [1.2, 1.8, 3.0] {
            for (x, y) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0), (0.5, 0.02)] {
                let s = ZoomSegment(start: 0, end: 6, zoom: z, cx: 0.5, cy: 0.5)
                let c = cam(ev([(0, 0.5, 0.5), (1.5, 0.5, 0.5), (2.0, x, y), (6, x, y)]), s)
                for i in 0...600 {
                    let r = Zoom.viewport([s], at: Double(i) / 100, camera: c)
                    if r.minX < -1e-9 || r.minY < -1e-9 || r.maxX > 1 + 1e-9 || r.maxY > 1 + 1e-9 || abs(r.width - 1 / (1 + (z - 1) * Zoom.envelope(s, at: Double(i) / 100))) > 1e-9 { inside = false }
                }
            }
        }
        check(inside, "following camera never shows outside the frame at 1.2x...3x")

        // no oscillation: after a jump the velocity decays monotonically and the camera never overshoots its settle point
        for sm in [0.0, 0.5, 1.0] {
            let seq = centres(seg, cam(away, seg, smooth: sm), from: 1.5, to: 5.5).map(\.x)
            let speed = zip(seq.dropFirst(), seq).map { $0 - $1 }
            let peak = speed.firstIndex(of: speed.max()!)!
            var decays = true
            for i in (peak + 1)..<speed.count where speed[i] > speed[i - 1] + 1e-7 { decays = false }
            check(decays && speed.allSatisfy { $0 >= -1e-9 } && abs(speed.last!) < 1e-4, "camera velocity settles without oscillation (smoothness \(sm))", "last \(speed.last!)")
        }
        let slow = centres(seg, cam(away, seg, smooth: 1), from: 2.5, to: 2.5)[0].x, fast = centres(seg, cam(away, seg, smooth: 0), from: 2.5, to: 2.5)[0].x
        check(fast > slow, "higher Follow smoothness pans slower")

        // zoom on movement: a long fast travel keeps the zoom, 1.2 s of rest ends it
        var tp: [(Double, Double, Double)] = [(0, 0.2, 0.3), (1.0, 0.2, 0.3)]
        for i in 0...100 { let k = Double(i); tp.append((1.1 + k / 50, 0.2 + 0.6 * k / 100, 0.3 + 0.3 * k / 100)) }
        tp.append((8, 0.8, 0.6))
        var withClick = ev(tp, duration: 8)
        withClick.events.append(Ev(t: 1.0, kind: .down, x: 0.2, y: 0.3)); withClick.events.sort { $0.t < $1.t }
        let plain = Zoom.generate(withClick), moving = Zoom.generate(withClick, followMovement: true)
        check(plain.count == 1 && moving.count == 1 && moving[0].end > plain[0].end + 1, "zoom on movement keeps the zoom while the cursor travels", "plain \(plain[0].end) moving \(moving[0].end)")
        check(abs(moving[0].end - (3.1 + Zoom.restTime + Zoom.ease)) < 0.1, "zoom ends 1.2 s after the cursor rests", "\(moving[0].end)")
    }

    static func corruptProject() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reel-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fresh = Project(folder: folder, log: Sample.log(), settings: ProjectSettings())
        try fresh.save()
        let ok = try Project.load(folder)
        check(!ok.editsLost, "project: a readable project.json loads without a warning")
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: folder.appendingPathComponent("project.json"))
        let bad = try Project.load(folder)
        let kept = try? Data(contentsOf: folder.appendingPathComponent("project.corrupt.json"))
        check(bad.editsLost && kept == garbage && !bad.settings.segments.isEmpty && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path),
              "project: a corrupt project.json is kept as project.corrupt.json, zooms regenerate, the editor is told")
    }

    static func trimming() {
        let base = ProjectSettings()
        let short = base.trimmed(start: 0.4, duration: 0.3)
        check(short.trimStart == 0 && short.trimEnd == nil, "trim: a clip shorter than the minimum never gets a negative start", "\(short.trimStart) \(String(describing: short.trimEnd))")
        let late = base.trimmed(start: 99, duration: 10)
        check(late.trimStart == 9.5, "trim: start stops half a second before the end", "\(late.trimStart)")
        var cut = base; cut.trimStart = 9.8
        let end = cut.trimmed(end: 5, duration: 10)
        check(end.trimEnd == nil, "trim: end never goes past the clip", "\(String(describing: end.trimEnd))")
        var p = Project(folder: URL(fileURLWithPath: "/tmp"), log: EventLog(duration: 10, width: 1, height: 1, events: []), settings: base.trimmed(start: 2, duration: 10).trimmed(end: 8, duration: 10))
        check(p.clampedToTrim(1) == 2 && p.clampedToTrim(5) == 5 && p.clampedToTrim(9) == 8, "trim: stepping stays inside the trim")
        p.settings = base
        check(base.trimmed(end: 10, duration: 10).trimEnd == nil, "trim: end at the clip end means no end")
    }

    static func pipeline() async {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("reel-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do { try Fixture.make(work) } catch { check(false, "fixture"); return }
        do { try await mixedAudioExport(in: work) } catch { check(false, "MP4 keeps Mac and microphone sound", "\(error)") }
        do { try await interruptedRecording(in: work) } catch { check(false, "interrupted recording", "\(error)") }
        do { try await stillRecording(in: work) } catch { check(false, "still recording", "\(error)") }
        guard var project = try? Project.load(work) else { check(false, "project loads"); return }
        check(project.settings.segments.count == 2, "a project with no project.json gets auto zoom segments")
        project.settings.trimStart = 0.5
        project.settings.trimEnd = 4.5
        try? project.save()
        check((try? Project.load(work))?.settings == project.settings, "project settings survive a save and load")

        // 1. camera maths on a real frame: full-zoom frame vs an ffmpeg crop+scale of the same source frame
        let src = work.appendingPathComponent("src-1.2.png")
        check(ffmpegRun(["-ss", "1.2", "-i", work.appendingPathComponent("capture.mov").path, "-frames:v", "1", src.path]), "ffmpeg extracts a source frame")
        guard let srcImage = loadImage(src) else { check(false, "source frame loads"); return }
        var bare = project.settings
        bare.frame = FrameStyle(background: "000000", padding: 0, radius: 0, shadow: false)
        bare.clickRings = false
        let size = CGSize(width: 1920, height: 1080)
        let noCursor = EventLog(duration: 5, width: 1920, height: 1080, events: [])
        let plain = Compositor(source: size, canvas: size, settings: bare, log: noCursor)
        let vp = Zoom.viewport(bare.segments, at: 1.2)
        let crop = String(format: "crop=%d:%d:%d:%d,scale=1920:1080:flags=bilinear", Int((vp.width * 1920).rounded()), Int((vp.height * 1080).rounded()), Int((vp.minX * 1920).rounded()), Int((vp.minY * 1080).rounded()))
        let ref = work.appendingPathComponent("ref.png")
        check(ffmpegRun(["-i", src.path, "-vf", crop, ref.path]), "ffmpeg makes the reference crop")
        if let got = plain.still(srcImage, at: 1.2), let want = loadImage(ref), let full = loadImage(src) {
            let d = meanDiff(got, want)
            check(d < 12, "zoomed frame matches an ffmpeg crop of the click area", "mean diff \(d)")
            check(meanDiff(got, full) > 40, "zoomed frame is not the full frame")
            check(abs(vp.width - 1 / 1.8) < 1e-6, "camera is at 1.8x on the click frame")
        } else { check(false, "plain still") }
        if let before = plain.still(srcImage, at: 0.3), let full = loadImage(src) { check(meanDiff(before, full) < 1, "no zoom before the first segment") }
        if let mid = plain.still(srcImage, at: 0.8), let full = loadImage(src) {
            let d = meanDiff(mid, full)
            let top = plain.still(srcImage, at: 1.2).map { meanDiff($0, full) } ?? 0
            check(d > 5 && d < top, "mid-zoom frame is between full frame and full zoom", "mid \(d), full zoom \(top)")
        }

        // 2. click ring: accent pixels appear after the click and are gone before it
        var ringy = project.settings
        ringy.frame = bare.frame
        let withRings = Compositor(source: size, canvas: size, settings: ringy, log: project.log)
        ringy.clickRings = false
        let noRings = Compositor(source: size, canvas: size, settings: ringy, log: project.log)
        if let a = withRings.still(srcImage, at: 1.15), let b = noRings.still(srcImage, at: 1.15) {
            let extra = changedPixels(a, b)
            check(extra > 150, "click ring is drawn 0.15 s after a click", "changed pixels \(extra)")
        }
        if let a = withRings.still(srcImage, at: 0.7), let b = noRings.still(srcImage, at: 0.7) { check(changedPixels(a, b) < 20, "no ring before the click") }
        if let a = withRings.still(srcImage, at: 1.0 + Ring.life + 0.05), let b = noRings.still(srcImage, at: 1.0 + Ring.life + 0.05), 1.0 + Ring.life + 0.05 < 1.55 {
            check(changedPixels(a, b) < 20, "ring is gone after its life")
        }

        // 3. MP4 export: trim, size, frame count, audio, and the first zoom frame inside the file
        let out = work.appendingPathComponent("out.mp4")
        let t0 = Date()
        do {
            try await Exporter.export(project, options: ExportOptions(), to: out, progress: { _ in }, cancelled: { false })
            let asset = AVURLAsset(url: out)
            // container duration includes AAC/HEVC priming (~4.1 s); the video track range is exact
            let dur = try await asset.loadTracks(withMediaType: .video).first?.load(.timeRange).duration.seconds ?? 0
            check(abs(dur - 4.0) < 0.1, "trim 0.5...4.5 gives a 4.0 s file", "duration \(dur)")
            let v = try await asset.loadTracks(withMediaType: .video).first
            let sz = try await v?.load(.naturalSize)
            check(sz == CGSize(width: 1920, height: 1080), "output is 1920x1080", "\(String(describing: sz))")
            check(abs(Double(try await v?.load(.nominalFrameRate) ?? 0) - 60) < 1, "output keeps 60 fps")
            check(try await asset.loadTracks(withMediaType: .audio).count == 1, "audio track is kept")
            let adur = try await asset.loadTracks(withMediaType: .audio).first?.load(.timeRange).duration.seconds ?? 0
            check(abs(adur - 4.0) < 0.25, "audio is trimmed with the video", "audio \(adur)")
            let frames = try await countFrames(out)
            check(abs(frames - 240) <= 1, "240 frames in 4 s at 60 fps", "frames \(frames)")
            print("     exported 4 s at 1080p60 in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        } catch { check(false, "mp4 export", "\(error)") }

        // the first zoom frame inside the file vs the compositor still on the same source frame (H.264 loss allowed)
        let outFrame = work.appendingPathComponent("out-0.7.png")
        if ffmpegRun(["-ss", "0.7", "-i", out.path, "-frames:v", "1", outFrame.path]), let got = loadImage(outFrame) {
            let full = Compositor(source: size, canvas: size, settings: project.settings, log: project.log)
            if let want = full.still(srcImage, at: 1.2) { let d = meanDiff(got, want); check(d < 8, "frame 0.7 s in the file is the 1.2 s source frame, zoomed, with cursor and ring", "diff \(d)") }
        } else { check(false, "extract frame from output") }

        // 3b. cursor following through the export: the crop centre per frame glides, and the file shows the pan
        var fol = project
        fol.log = Fixture.followLog()
        fol.settings.segments = [ZoomSegment(start: 0.6, end: 4.4, zoom: 2, cx: 0.30, cy: 0.40)]
        fol.settings.trimStart = 0; fol.settings.trimEnd = nil
        try? fol.save()
        let fcam = CameraTrack(fol.settings.segments, cursor: CursorTrack(fol.log, smoothing: fol.settings.cursorSmoothing), smoothness: fol.settings.followSmoothness)
        let cs = centres(fol.settings.segments[0], fcam, from: 1.0, to: 4.0)   // the held part; the 0.4 s ease in and out is the existing envelope
        let steps = zip(cs.dropFirst(), cs).map { hypot($0.x - $1.x, $0.y - $1.y) }
        var xmono = true
        for i in 1..<cs.count where cs[i].x < cs[i - 1].x - 1e-9 { xmono = false }
        check(xmono && cs.last!.x > 0.5 && cs.max { $0.x < $1.x }!.x - cs.first!.x > 0.1, "crop centre moves right when the cursor sweeps across", "last \(cs.last!)")
        check((steps.max() ?? 1) < 0.012, "crop centre step between frames is bounded", "max step \(steps.max() ?? 1)")
        var accel = 0.0
        for i in 1..<steps.count { accel = max(accel, abs(steps[i] - steps[i - 1])) }
        check(accel < 0.0015, "crop centre moves smoothly (no jumps in speed)", "max speed change \(accel)")
        let fout = work.appendingPathComponent("follow.mp4")
        do {
            try await Exporter.export(fol, options: ExportOptions(), to: fout, progress: { _ in }, cancelled: { false })
            let fc = Compositor(source: size, canvas: size, settings: fol.settings, log: fol.log)
            var worst = 0.0
            for t in [1.0, 2.2, 3.0] {
                let f = work.appendingPathComponent("follow-\(t).png"), s = work.appendingPathComponent("follow-src-\(t).png")
                guard ffmpegRun(["-ss", "\(t)", "-i", fout.path, "-frames:v", "1", f.path]), ffmpegRun(["-ss", "\(t)", "-i", work.appendingPathComponent("capture.mov").path, "-frames:v", "1", s.path]),
                      let got = loadImage(f), let src = loadImage(s), let want = fc.still(src, at: t) else { check(false, "follow frame \(t)"); continue }
                worst = max(worst, meanDiff(got, want))
            }
            check(worst < 8, "exported follow frames match the following camera", "worst diff \(worst)")
            if let a = loadImage(work.appendingPathComponent("follow-1.0.png")), let b = loadImage(work.appendingPathComponent("follow-3.0.png")) { check(meanDiff(a, b) > 20, "export shows the pan between 1 s and 3 s") }
        } catch { check(false, "follow export", "\(error)") }

        // 4. HEVC and source resolution
        let hevc = work.appendingPathComponent("hevc.mp4")
        var o2 = ExportOptions(); o2.codec = .hevc; o2.resolution = .source; o2.fps = 30
        do {
            try await Exporter.export(project, options: o2, to: hevc, progress: { _ in }, cancelled: { false })
            let asset = AVURLAsset(url: hevc)
            let fmt = try await asset.loadTracks(withMediaType: .video).first?.load(.formatDescriptions).first
            check(fmt.map { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC } ?? false, "HEVC export writes HEVC")
            let d30 = try await asset.load(.duration).seconds
            check(abs(d30 - 4.0) < 0.2, "30 fps export keeps the trimmed length", "duration \(d30)")
        } catch { check(false, "hevc export", "\(error)") }

        // 5. cancel stops and removes the file
        let cancelOut = work.appendingPathComponent("cancel.mp4")
        let counter = CounterBox()
        do {
            try await Exporter.export(project, options: ExportOptions(), to: cancelOut, progress: { _ in counter.bump() }, cancelled: { counter.n > 20 })
            check(false, "cancel throws")
        } catch is CancellationError {
            check(!FileManager.default.fileExists(atPath: cancelOut.path), "cancel throws and removes the partial file")
        } catch { check(false, "cancel", "\(error)") }

        // 6. GIF
        if Exporter.gifAvailable {
            let gif = work.appendingPathComponent("out.gif")
            var o3 = ExportOptions(); o3.format = .gif
            do {
                try await Exporter.export(project, options: o3, to: gif, progress: { _ in }, cancelled: { false })
                let d = try Data(contentsOf: gif)
                check(d.prefix(6) == Data("GIF89a".utf8), "GIF has a GIF89a header")
                check(d.count > 20_000, "GIF has content", "\(d.count) bytes")
                check(Int(d[6]) | Int(d[7]) << 8 == 800 && Int(d[8]) | Int(d[9]) << 8 == 450, "GIF is 800x450")
            } catch { check(false, "gif export", "\(error)") }
        }
        // 7. an empty trim range is an error, not a crash
        var empty = project; empty.settings.trimStart = 3; empty.settings.trimEnd = 3
        do { try await Exporter.export(empty, options: ExportOptions(), to: work.appendingPathComponent("e.mp4"), progress: { _ in }, cancelled: { false }); check(false, "empty trim throws") }
        catch { check(true, "empty trim range throws") }
    }

    static func mixedAudioExport(in work: URL) async throws {
        let folder = work.appendingPathComponent("Sound")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let project = Project(folder: folder, log: EventLog(duration: 1, width: 128, height: 96, events: []), settings: ProjectSettings())
        guard ffmpegRun(["-f", "lavfi", "-i", "color=s=128x96:r=24:d=1", "-f", "lavfi", "-i", "sine=f=440:r=48000:d=1",
                         "-f", "lavfi", "-i", "sine=f=880:r=48000:d=1", "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "libx264",
                         "-c:a", "aac", "-ac:a:0", "2", project.capture.path]) else { throw RecorderError.failed("No two-tone fixture") }
        var options = ExportOptions(); options.resolution = .source
        let movie = folder.appendingPathComponent("mix.mp4")
        try await Exporter.export(project, options: options, to: movie, progress: { _ in }, cancelled: { false })
        let tracks = try await AVURLAsset(url: movie).loadTracks(withMediaType: .audio)
        let format = try await tracks.first?.load(.formatDescriptions).first
        check(tracks.count == 1 && format?.mediaSubType.rawValue == kAudioFormatMPEG4AAC, "MP4 contains one mixed AAC track")
        let pcm = folder.appendingPathComponent("mix.pcm")
        guard ffmpegRun(["-i", movie.path, "-map", "0:a:0", "-ss", "0.25", "-t", "0.5", "-ac", "1", "-ar", "8000", "-f", "f32le", pcm.path]) else { throw RecorderError.failed("Cannot decode mixed audio") }
        let samples = try Data(contentsOf: pcm).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        for frequency in [440.0, 880.0] {
            var sine = 0.0, cosine = 0.0
            for (index, sample) in samples.enumerated() {
                let phase = 2 * Double.pi * frequency * Double(index) / 8000
                sine += Double(sample) * sin(phase); cosine += Double(sample) * cos(phase)
            }
            check(samples.count == 4000 && hypot(sine, cosine) / 4000 > 0.005, "MP4 preserves \(Int(frequency)) Hz input tone")
        }
    }

    @MainActor
    static func interruptedRecording(in work: URL) async throws {
        let folder = work.appendingPathComponent("Interrupted")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let movie = folder.appendingPathComponent("capture.mov")
        let size = CGSize(width: 128, height: 96)
        let source = work.appendingPathComponent("frames.mov")
        guard ffmpegRun(["-f", "lavfi", "-i", "testsrc2=s=128x96:r=24:d=1", "-c:v", "libx264", "-bf", "0", source.path]) else { throw RecorderError.failed("No synthetic movie") }
        let fixture = AVURLAsset(url: source)
        guard let track = try await fixture.loadTracks(withMediaType: .video).first,
              let format = try await track.load(.formatDescriptions).first else { throw RecorderError.failed("No fixture video") }
        func makeSink(_ url: URL) throws -> CaptureSink {
            try CaptureSink(writer: AVAssetWriter(outputURL: url, fileType: .mov), video: AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format), audio: nil, fps: 24)
        }
        let sink = try makeSink(movie)
        let reader = try AVAssetReader(asset: fixture)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw RecorderError.failed("Fixture could not start") }
        var written = 0
        while written < 12 {
            guard let sample = output.copyNextSampleBuffer() else { throw RecorderError.failed("Missing synthetic frame") }
            guard sample.numSamples > 0, sample.dataBuffer != nil else { continue }
            let deadline = ContinuousClock.now + .seconds(3)
            while !sink.queue.sync(execute: { sink.appendFrame(sample) }) {
                guard ContinuousClock.now < deadline else { throw RecorderError.failed("Synthetic frame was not accepted") }
                try await Task.sleep(for: .milliseconds(2))
            }
            written += 1
        }
        let failure = RecorderError.failed("Synthetic stream interruption")
        try await sink.finishProject(folder: folder, size: size, events: [], interruption: { failure.localizedDescription },
                                     trashEmpty: { _ in throw RecorderError.failed("Attempted to discard written frames") })
        let saved = try Project.load(folder)
        let asset = AVURLAsset(url: saved.capture)
        let duration = try await asset.load(.duration).seconds
        let decoded = work.appendingPathComponent("frames.gray")
        let playable = ffmpegRun(["-xerror", "-i", saved.capture.path, "-pix_fmt", "gray", "-f", "rawvideo", decoded.path])
        let bytes = try Data(contentsOf: decoded).count
        check(playable && bytes == 12 * 128 * 96 && abs(duration - 0.5) < 0.001 && abs(saved.duration - duration) < 0.001 && saved.log.stoppedEarly == true,
              "interrupted recording: saved project, 12 decodable frames, 0.500 s", "playable=\(playable), bytes=\(bytes), duration=\(duration)")

        let empty = work.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let emptySink = try makeSink(empty.appendingPathComponent("capture.mov"))
        var discarded: URL?
        do {
            try await emptySink.finishProject(folder: empty, size: size, events: [], interruption: { failure.localizedDescription }, trashEmpty: { discarded = $0 })
            check(false, "empty start reports failure")
        } catch {
            check(discarded == empty && error.localizedDescription == failure.localizedDescription, "failed start sends only its empty project to Trash (spy)")
        }
    }

    @MainActor
    static func stillRecording(in work: URL) async throws {
        let folder = work.appendingPathComponent("Still")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let source = work.appendingPathComponent("still-frames.mov")
        guard ffmpegRun(["-f", "lavfi", "-i", "testsrc2=s=128x96:r=1:d=2", "-c:v", "mjpeg", source.path]) else { throw RecorderError.failed("No still fixture") }
        let fixture = AVURLAsset(url: source)
        let track = try await fixture.loadTracks(withMediaType: .video).first!
        let format = try await track.load(.formatDescriptions).first!
        let reader = try AVAssetReader(asset: fixture)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        let sink = try CaptureSink(writer: AVAssetWriter(outputURL: folder.appendingPathComponent("capture.mov"), fileType: .mov),
                                   video: AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format), audio: nil, fps: 1)
        guard reader.startReading() else { throw RecorderError.failed("Could not read still fixture") }
        for second in 0..<2 {
            var next = output.copyNextSampleBuffer()
            while let marker = next, marker.numSamples == 0 { next = output.copyNextSampleBuffer() }
            guard let sample = next, sample.presentationTimeStamp.seconds == Double(second) else { throw RecorderError.failed("Missing still frame \(second)") }
            let deadline = ContinuousClock.now + .seconds(3)
            while !sink.queue.sync(execute: { sink.appendFrame(sample) }) {
                guard ContinuousClock.now < deadline else { throw RecorderError.failed("Still frame was not accepted") }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        let stop = CMTime(value: 3, timescale: 1)
        let events = [2.5, 3, 3.1].map { Ev(t: $0, kind: .move, x: 0.5, y: 0.5) }
        try await sink.finishProject(folder: folder, size: CGSize(width: 128, height: 96), events: events, stopTime: stop, interruption: { nil })
        let saved = try Project.load(folder)
        let movie = AVURLAsset(url: saved.capture)
        let duration = try await movie.load(.duration)
        let videoTrack = try await movie.loadTracks(withMediaType: .video).first!
        let range = try await videoTrack.load(.timeRange)
        check(duration == stop && range.end == stop && saved.duration == stop.seconds,
              "still recording: last frame at 1 s, movie and project end at Stop (3 s)", "movie=\(duration.seconds), track=\(range.end.seconds), project=\(saved.duration)")
        check(saved.log.events.map(\.t) == [2.5, 3], "still recording: keeps mouse events through Stop, excludes later events")
    }

    static func countFrames(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        r.add(o); r.startReading()
        var n = 0
        while let sb = o.copyNextSampleBuffer() { if CMSampleBufferGetImageBuffer(sb) != nil { n += 1 } }
        return n
    }
}

final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var n: Int { lock.lock(); defer { lock.unlock() }; return value }
    func bump() { lock.lock(); value += 1; lock.unlock() }
}
