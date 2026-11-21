import AVFoundation
import AppKit
@preconcurrency import ScreenCaptureKit
import VideoToolbox

// The live capture path. It needs Screen Recording permission (asked by macOS the first time you record) and has not been
// verified on a real screen yet; everything after the capture (zoom, render, export) is tested from synthetic input.

enum RecorderError: LocalizedError {
    case permission, nothingToCapture, cancelled, failed(String)
    var errorDescription: String? {
        switch self {
        case .permission: "Reel needs Screen Recording. Allow it in System Settings, Privacy and Security, then try again."
        case .nothingToCapture: "No display or window to record."
        case .cancelled: "Cancelled."
        case .failed(let s): s
        }
    }
}

/// Receives frames on ScreenCaptureKit's queue and writes them. Only touches its own writer, so it is safe off the main actor.
final class CaptureSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let macAudio: AVAssetWriterInput?
    let queue = DispatchQueue(label: "reel.capture", qos: .userInteractive)
    private let frameDuration: CMTime
    private var first: CMTime?
    private var end: CMTime?
    private var lastFrame: CMSampleBuffer?
    private var closed = false
    var onWriteFailure: @Sendable (String) -> Void = { _ in }

    convenience init(url: URL, size: CGSize, codec: AVVideoCodecType, fps: Int, mic: Bool, macSound: Bool) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(size.width * size.height * Double(fps) * 0.12), AVVideoExpectedSourceFrameRateKey: fps]])
        let audio = mic ? AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]) : nil
        let macAudio = macSound ? AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]) : nil
        try self.init(writer: writer, video: video, audio: audio, macAudio: macAudio, fps: fps)
    }

    init(writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput?, macAudio: AVAssetWriterInput? = nil, fps: Int) throws {
        self.writer = writer; self.video = video; self.audio = audio; self.macAudio = macAudio
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        super.init()
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
        for input in [video, macAudio, audio].compactMap({ $0 }) {
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.failed("Cannot write the recording format.") }
            writer.add(input)
        }
        guard writer.startWriting() else { throw RecorderError.failed(writer.error?.localizedDescription ?? "Could not start the file.") }
    }

    @discardableResult
    func appendFrame(_ sample: CMSampleBuffer) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed, video.isReadyForMoreMediaData else { return false }
        let pts = sample.presentationTimeStamp
        if first == nil { writer.startSession(atSourceTime: pts); first = pts }
        guard video.append(sample) else { writeFailed(); return false }
        lastFrame = sample
        end = pts + (sample.duration.isNumeric && sample.duration > .zero ? sample.duration : frameDuration)
        return true
    }

    private func writeFailed() {
        closed = true
        onWriteFailure(writer.error?.localizedDescription ?? "Could not write the recording.")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !closed, sb.isValid else { return }
        if writer.status == .failed { writeFailed(); return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            appendFrame(sb)
        case .audio, .microphone:
            let audio = type == .audio ? macAudio : self.audio
            guard let audio, let first, end != nil, sb.presentationTimeStamp >= first, audio.isReadyForMoreMediaData else { return }
            if !audio.append(sb) { writeFailed() }
        default: break
        }
    }

    @MainActor
    func finishProject(folder: URL, size: CGSize, events: [Ev], stopTime: CMTime? = nil, interruption: () -> String?,
                       trashEmpty: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) async throws {
        let times = queue.sync { () -> (CMTime, CMTime)? in
            closed = true
            defer { lastFrame = nil }
            guard let first, var end else {
                if writer.status == .writing { writer.cancelWriting() }
                return nil
            }
            if writer.status == .writing {
                if let stopTime, stopTime > first, let lastFrame {
                    let timing = CMSampleTimingInfo(duration: .zero, presentationTimeStamp: stopTime, decodeTimeStamp: .invalid)
                    if stopTime <= end { end = stopTime }
                    else if let heldFrame = try? CMSampleBuffer(copying: lastFrame, withNewTiming: [timing]), video.append(heldFrame) { end = stopTime }
                }
                writer.endSession(atSourceTime: end)
                video.markAsFinished(); audio?.markAsFinished(); macAudio?.markAsFinished()
            }
            return (first, end)
        }
        guard let (first, end) = times else {
            try trashEmpty(folder)
            throw RecorderError.failed(interruption() ?? "No frames were captured.")
        }
        if writer.status == .writing { await writer.finishWriting() }
        var duration = (end - first).seconds
        let writerFailed = writer.status != .completed
        if writerFailed {
            let asset = AVURLAsset(url: writer.outputURL)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let range = try? await track.load(.timeRange), range.duration.isNumeric, range.duration > .zero else {
                throw RecorderError.failed(writer.error?.localizedDescription ?? "Could not finish the recording.")
            }
            duration = range.duration.seconds
        }
        let evs = events.filter { $0.t <= first.seconds + duration }.map { Ev(t: max(0, $0.t - first.seconds), kind: $0.kind, x: $0.x, y: $0.y) }.sorted { $0.t < $1.t }
        let stoppedShort = stopTime.map { end < $0 } ?? false
        let log = EventLog(duration: duration, width: Int(size.width), height: Int(size.height), events: evs, stoppedEarly: (writerFailed || stoppedShort || interruption() != nil) ? true : nil)
        try Project(folder: folder, log: log, settings: Prefs().newSettings(for: log)).save()
    }
}

@MainActor
final class Recorder: NSObject, SCStreamDelegate {
    private var stream: SCStream?
    private var sink: CaptureSink?
    private var folder: URL?
    private var region = CGRect.zero              // global, top-left origin, points
    private var events: [Ev] = []
    private var monitors: [Any] = []
    private var size = CGSize.zero
    private(set) var interruption: String?
    private var streamStopped = false
    var onFailure: () -> Void = {}

    /// Display name for the menu caption.
    static func displayName() -> String { (NSScreen.main?.localizedName ?? "Display") }

    nonisolated static func captureFormat(size: CGSize, preferred: ExportOptions.Codec, hevcAvailable: @autoclosure () -> Bool) -> (codec: AVVideoCodecType, size: CGSize) {
        let longest = max(size.width, size.height)
        if (preferred == .hevc || longest > 4096) && hevcAvailable() { return (.hevc, size) }
        guard longest > 4096 else { return (.h264, size) }
        func fitted(_ pixels: CGFloat) -> CGFloat { max(2, (pixels * 2048 / longest).rounded() * 2) }
        return (.h264, CGSize(width: fitted(size.width), height: fitted(size.height)))
    }

    static func configureAudio(_ config: SCStreamConfiguration, macSound: Bool, mic: Bool) {
        config.capturesAudio = macSound
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000; config.channelCount = 2
        config.captureMicrophone = mic
    }

    func start(mode: CaptureMode, fps: Int, mic: Bool, macSound: Bool, codec: ExportOptions.Codec, countdown: (() async -> Void)? = nil) async throws {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) } catch { throw RecorderError.permission }
        let mouse = Self.cgMouse()
        let display = content.displays.first { $0.frame.contains(mouse) } ?? (mode == .area ? nil : content.displays.first)
        guard let display else { throw RecorderError.nothingToCapture }
        let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }

        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        switch mode {
        case .display:
            filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            region = display.frame
        case .window:
            guard let w = Self.pickWindow(content.windows.filter { $0.isOnScreen && $0.windowLayer == 0 && ($0.title?.isEmpty == false) && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }) else { throw RecorderError.cancelled }
            filter = SCContentFilter(desktopIndependentWindow: w)
            region = w.frame
        case .area:
            guard let r = await AreaPicker.pick(on: display) else { throw RecorderError.cancelled }
            filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            config.sourceRect = CGRect(x: r.minX - display.frame.minX, y: r.minY - display.frame.minY, width: r.width, height: r.height)
            region = r
        }
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        let pixels = CGSize(width: (region.width * scale / 2).rounded() * 2, height: (region.height * scale / 2).rounded() * 2)
        let format = Self.captureFormat(size: pixels, preferred: codec, hevcAvailable: VTCopySupportedPropertyDictionaryForEncoder(
            width: Int32(pixels.width), height: Int32(pixels.height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, encoderIDOut: nil, supportedPropertiesOut: nil) == noErr)
        size = format.size
        config.width = Int(size.width); config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = false
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        Self.configureAudio(config, macSound: macSound, mic: mic)

        let f = Project.root.appendingPathComponent(ReelRecorderNaming.name(), isDirectory: true)
        try FileManager.default.createDirectory(at: Project.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: false)
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        let sink: CaptureSink
        do { sink = try CaptureSink(url: f.appendingPathComponent("capture.mov"), size: size, codec: format.codec, fps: fps, mic: mic, macSound: macSound) }
        catch { try FileManager.default.trashItem(at: f, resultingItemURL: nil); throw error }
        self.sink = sink; folder = f; stream = s; interruption = nil; streamStopped = false
        sink.onWriteFailure = { [weak self, weak sink] text in
            Task { @MainActor in
                guard let self, let sink, self.sink === sink else { return }
                self.interruption = text; self.onFailure()
            }
        }
        events = []
        do {
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            if macSound { try s.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue) }
            if mic { try s.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue) }
        } catch { interruption = error.localizedDescription; streamStopped = true; return }
        record(.move, at: NSEvent.mouseLocation, time: ProcessInfo.processInfo.systemUptime)
        startMonitors()
        await countdown?()
        do { try await s.startCapture() } catch { interruption = error.localizedDescription; streamStopped = true }
    }

    /// Stops, finishes the file, writes the mouse log. Returns the project folder.
    func stop() async throws -> URL {
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        stopMonitors()
        guard let s = stream, let sink, let folder else { throw RecorderError.failed("Not recording.") }
        defer { stream = nil; self.sink = nil; self.folder = nil }
        if !streamStopped {
            do { try await s.stopCapture() } catch { interruption = error.localizedDescription }
        }
        try await sink.finishProject(folder: folder, size: size, events: events, stopTime: interruption == nil ? stopTime : nil, interruption: { self.interruption })
        return folder
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let text = error.localizedDescription
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.streamStopped = true; self.interruption = text; self.onFailure()
        }
    }

    // MARK: mouse log (mouse only, never keys)

    private func startMonitors() {
        let masks: [NSEvent.EventTypeMask] = [[.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged], [.leftMouseDown, .rightMouseDown, .otherMouseDown], [.leftMouseUp, .rightMouseUp, .otherMouseUp]]
        let kinds: [Ev.Kind] = [.move, .down, .up]
        for (mask, kind) in zip(masks, kinds) {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
                let p = NSEvent.mouseLocation, t = e.timestamp
                MainActor.assumeIsolated { self?.record(kind, at: p, time: t) }
            }) { monitors.append(m) }
        }
    }

    private func stopMonitors() { monitors.forEach { NSEvent.removeMonitor($0) }; monitors = [] }

    private func record(_ kind: Ev.Kind, at p: NSPoint, time: Double) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let x = (p.x - region.minX) / region.width, y = ((height - p.y) - region.minY) / region.height
        events.append(Ev(t: time, kind: kind, x: min(max(x, 0), 1), y: min(max(y, 0), 1)))
    }

    private static func cgMouse() -> CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
    }

    private static func pickWindow(_ windows: [SCWindow]) -> SCWindow? {
        let menu = NSMenu(title: "Window")
        var chosen: SCWindow?
        let target = MenuPick { chosen = $0 }
        for w in windows.sorted(by: { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }) {
            let item = NSMenuItem(title: "\(w.owningApplication?.applicationName ?? "App"): \(w.title ?? "")", action: #selector(MenuPick.pick(_:)), keyEquivalent: "")
            item.target = target; item.representedObject = w
            menu.addItem(item)
        }
        if menu.items.isEmpty { return nil }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return chosen
    }
}

@MainActor
final class MenuPick: NSObject {
    let done: (SCWindow) -> Void
    init(_ done: @escaping (SCWindow) -> Void) { self.done = done }
    @objc func pick(_ item: NSMenuItem) { if let w = item.representedObject as? SCWindow { done(w) } }
}

enum ReelRecorderNaming {
    static func name() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f.string(from: Date()) }
}

/// Drag a rectangle on the chosen display. Esc cancels.
@MainActor
enum AreaPicker {
    static func matchingScreen<Screen>(for displayID: CGDirectDisplayID, in screens: [Screen], id: (Screen) -> CGDirectDisplayID?) -> Screen? {
        screens.first { id($0) == displayID }
    }

    static func pick(on display: SCDisplay) async -> CGRect? {
        guard let screen = matchingScreen(for: display.displayID, in: NSScreen.screens, id: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }) else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<CGRect?, Never>) in
            let w = AreaPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.backgroundColor = NSColor.black.withAlphaComponent(0.35)
            w.isOpaque = false; w.level = .screenSaver; w.isReleasedWhenClosed = false
            let view = PickView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.finish = { rect in
                view.finish = nil
                NSCursor.pop()
                w.orderOut(nil)
                guard let rect, rect.width > 40, rect.height > 40 else { c.resume(returning: nil); return }
                // view is bottom-left in points; the display frame is top-left
                c.resume(returning: CGRect(x: display.frame.minX + rect.minX, y: display.frame.minY + (screen.frame.height - rect.maxY), width: rect.width, height: rect.height))
            }
            w.contentView = view
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(view)
            NSCursor.crosshair.push()
        }
    }
}

private final class AreaPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { (contentView as? PickView)?.finish?(nil) }
}

final class PickView: NSView {
    var finish: ((CGRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSRect = .zero
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil) }
    override func mouseDragged(with e: NSEvent) {
        guard let s = start else { return }
        let p = convert(e.locationInWindow, from: nil)
        current = NSRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y)); needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) { finish?(current) }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { finish?(nil) } }
    override func draw(_ dirtyRect: NSRect) {
        guard current.width > 0 else { return }
        NSColor.clear.setFill(); current.fill(using: .copy)
        NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1).setStroke()
        let p = NSBezierPath(rect: current); p.lineWidth = 1.5; p.stroke()
    }
}
