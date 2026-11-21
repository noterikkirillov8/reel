import AVFoundation
import CoreImage
import Foundation

enum ExportError: LocalizedError {
    case noVideo, reader(String), writer(String), ffmpeg(String), empty
    var errorDescription: String? {
        switch self {
        case .noVideo: "The capture has no video."
        case .reader(let s): "Could not read the capture: \(s)"
        case .writer(let s): "Could not write the file: \(s)"
        case .ffmpeg(let s): "ffmpeg failed: \(s)"
        case .empty: "Nothing to export: the trim range is empty."
        }
    }
}

private final class Unsafe<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

/// Frame-by-frame render: capture -> Compositor -> AVAssetWriter. Output frames come at a fixed rate whatever the capture's
/// timing was (ScreenCaptureKit only delivers a frame when something changes), so zoom eases stay smooth on a still screen.
enum Exporter {
    static let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
    static var gifAvailable: Bool { FileManager.default.isExecutableFile(atPath: ffmpegPath) }

    static func export(_ project: Project, options: ExportOptions, to out: URL,
                       progress: @escaping @Sendable (Double) -> Void, cancelled: @escaping @Sendable () -> Bool) async throws {
        try? FileManager.default.removeItem(at: out)
        switch options.format {
        case .mp4:
            try await renderMP4(project, options: options, canvas: nil, fps: options.fps, to: out, quality: 0.08, progress: progress, cancelled: cancelled)
        case .gif:
            guard gifAvailable else { throw ExportError.ffmpeg("not found at \(ffmpegPath)") }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reel-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let w = Double(options.gifWidth), h = (w * 9 / 16 / 2).rounded() * 2
            try await renderMP4(project, options: options, canvas: CGSize(width: w, height: h), fps: options.gifFps, to: tmp, quality: 0.3,
                                progress: { progress($0 * 0.9) }, cancelled: cancelled)
            let filter = "split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5"
            try await runFFmpeg(["-i", tmp.path, "-vf", filter, "-loop", "0", out.path], cancelled: cancelled)
            progress(1)
        }
    }

    static func renderMP4(_ project: Project, options: ExportOptions, canvas forced: CGSize?, fps requested: Int, to out: URL, quality: Double,
                          progress: @escaping @Sendable (Double) -> Void, cancelled: @escaping @Sendable () -> Bool) async throws {
        let asset = AVURLAsset(url: project.capture)
        guard let vtrack = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let size = try await vtrack.load(.naturalSize)
        let nominal = Double(try await vtrack.load(.nominalFrameRate))
        let fps = requested > 0 ? requested : Int(min(60, max(nominal.rounded(), 24)))
        let start = project.settings.trimStart, end = project.trimEnd
        let total = Int(((end - start) * Double(fps)).rounded(.down))
        guard total > 0 else { throw ExportError.empty }

        let canvas = forced ?? Compositor.canvasSize(source: size, options.resolution)
        let comp = Compositor(source: size, canvas: canvas, settings: project.settings, log: project.log)

        let reader = try AVAssetReader(asset: asset)
        let vout = AVAssetReaderTrackOutput(track: vtrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(vout)
        var aout: AVAssetReaderAudioMixOutput?
        let audioTracks = options.format == .mp4 ? try await asset.loadTracks(withMediaType: .audio) : []
        if !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
            reader.add(o); aout = o
        }

        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let codec: AVVideoCodecType = options.codec == .hevc ? .hevc : .h264
        var props: [String: Any] = [AVVideoAverageBitRateKey: Int(canvas.width * canvas.height * Double(fps) * quality),
                                    AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps * 2]
        if codec == .h264 { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: Int(canvas.width),
                                                                          AVVideoHeightKey: Int(canvas.height), AVVideoCompressionPropertiesKey: props])
        vin.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(canvas.width), kCVPixelBufferHeightKey as String: Int(canvas.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]])
        writer.add(vin)
        var ain: AVAssetWriterInput?
        if aout != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                                           AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
            a.expectsMediaDataInRealTime = false
            guard writer.canAdd(a) else { throw ExportError.writer("Cannot encode AAC audio for MP4.") }
            writer.add(a); ain = a
        }
        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw ExportError.reader(reader.error?.localizedDescription ?? "start") }

        func abort() { reader.cancelReading(); writer.cancelWriting(); try? FileManager.default.removeItem(at: out) }
        func nextFrame() -> (CVPixelBuffer, Double)? {
            while let sb = vout.copyNextSampleBuffer() {
                if let pb = CMSampleBufferGetImageBuffer(sb) { return (pb, CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
            }
            return nil
        }
        var pendingAudio: CMSampleBuffer?
        var audioDone = aout == nil
        func pumpAudio(until limit: Double) throws {
            guard let aout, let ain else { return }
            while !audioDone, ain.isReadyForMoreMediaData {
                if pendingAudio == nil { pendingAudio = aout.copyNextSampleBuffer() }
                guard let sb = pendingAudio else { ain.markAsFinished(); audioDone = true; return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds, dur = CMSampleBufferGetDuration(sb).seconds
                if pts + dur <= start { pendingAudio = nil; continue }
                if pts - start > limit && limit.isFinite { return }
                if pts >= end { pendingAudio = nil; ain.markAsFinished(); audioDone = true; return }
                pendingAudio = nil
                guard let shifted = Self.shifted(sb, by: start), ain.append(shifted) else {
                    let reason = writer.error?.localizedDescription ?? "audio append"
                    abort(); throw ExportError.writer(reason)
                }
            }
        }

        var current: CVPixelBuffer?
        var upcoming = nextFrame()
        for i in 0..<total {
            if cancelled() { abort(); throw CancellationError() }
            let t = start + Double(i) / Double(fps)
            while let u = upcoming, u.1 <= t + 1e-6 { current = u.0; upcoming = nextFrame() }
            guard let pb = current ?? upcoming?.0 else { abort(); throw ExportError.reader("no frames") }
            while !vin.isReadyForMoreMediaData { try pumpAudio(until: Double(i) / Double(fps) + 3); try await Task.sleep(for: .milliseconds(2)) }
            try pumpAudio(until: Double(i) / Double(fps) + 3)
            guard let pool = adaptor.pixelBufferPool else { abort(); throw ExportError.writer("no pixel buffer pool") }
            var outBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
            guard let outBuffer else { abort(); throw ExportError.writer("out of buffers") }
            comp.ci.render(comp.compose(CIImage(cvPixelBuffer: pb), at: t), to: outBuffer, bounds: CGRect(origin: .zero, size: canvas),
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            guard adaptor.append(outBuffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) else {
                abort(); throw ExportError.writer(writer.error?.localizedDescription ?? "append")
            }
            progress(Double(i + 1) / Double(total) * 0.98)
        }
        vin.markAsFinished()
        while !audioDone {
            try pumpAudio(until: .infinity)
            if !audioDone { try await Task.sleep(for: .milliseconds(2)) }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw ExportError.writer(writer.error?.localizedDescription ?? "finish") }
        progress(1)
    }

    /// A copy of the sample with its time moved earlier by `by` seconds.
    private static func shifted(_ sb: CMSampleBuffer, by seconds: Double) -> CMSampleBuffer? {
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var info = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &info, entriesNeededOut: &count)
        let d = CMTime(seconds: seconds, preferredTimescale: 48000)
        for k in info.indices { info[k].presentationTimeStamp = info[k].presentationTimeStamp - d; if info[k].decodeTimeStamp.isValid { info[k].decodeTimeStamp = info[k].decodeTimeStamp - d } }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count, sampleTimingArray: info, sampleBufferOut: &out)
        return out
    }

    static func runFFmpeg(_ args: [String], cancelled: @escaping @Sendable () -> Bool) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpegPath)
        p.arguments = ["-y", "-loglevel", "error"] + args
        let err = Pipe()
        p.standardError = err; p.standardOutput = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        let box = Unsafe(p)
        let watcher = Task.detached { while !Task.isCancelled { if cancelled() { box.value.terminate(); return }; try? await Task.sleep(for: .milliseconds(100)) } }
        defer { watcher.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { proc in
                let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 { c.resume() } else { c.resume(throwing: cancelled() ? CancellationError() : ExportError.ffmpeg(text)) }
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }
}
