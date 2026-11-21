import AppKit
import Observation
import ServiceManagement
import SwiftUI

let reelAccent = Color(hex: 0xE5484D)

enum CaptureMode: String, CaseIterable { case display, window, area }

/// Settings that persist in UserDefaults and take effect live.
@MainActor
@Observable
final class Prefs {
    private let d = UserDefaults.standard
    var mode: CaptureMode { didSet { d.set(mode.rawValue, forKey: "reelMode") } }
    var fps60: Bool { didSet { d.set(fps60, forKey: "reelFps60") } }
    var microphone: Bool { didSet { d.set(microphone, forKey: "reelMic") } }
    var macSound: Bool { didSet { d.set(macSound, forKey: "reelMacSound") } }
    var countdown: Bool { didSet { d.set(countdown, forKey: "reelCountdown") } }
    var hotKey: KitHotKey? { didSet { d.set(hotKey.flatMap { try? JSONEncoder().encode($0) }, forKey: "reelHotKey") } }
    var tab: String { didSet { d.set(tab, forKey: "reelSettingsTab") } }
    // export defaults
    var format: ExportOptions.Format { didSet { d.set(format.rawValue, forKey: "reelFormat") } }
    var codec: ExportOptions.Codec { didSet { d.set(codec.rawValue, forKey: "reelCodec") } }
    var resolution: ExportOptions.Resolution { didSet { d.set(resolution.rawValue, forKey: "reelResolution") } }
    var gifFps: Int { didSet { d.set(gifFps, forKey: "reelGifFps") } }
    var gifWidth: Int { didSet { d.set(gifWidth, forKey: "reelGifWidth") } }
    // camera defaults for new recordings
    var followCursor: Bool { didSet { d.set(followCursor, forKey: "reelFollowCursor") } }
    var followSmoothness: Double { didSet { d.set(followSmoothness, forKey: "reelFollowSmoothness") } }
    var zoomOnMovement: Bool { didSet { d.set(zoomOnMovement, forKey: "reelZoomOnMovement") } }

    init() {
        let d = UserDefaults.standard
        mode = CaptureMode(rawValue: d.string(forKey: "reelMode") ?? "") ?? .display
        fps60 = d.object(forKey: "reelFps60") as? Bool ?? true
        microphone = d.bool(forKey: "reelMic")
        macSound = d.object(forKey: "reelMacSound") as? Bool ?? true
        countdown = d.object(forKey: "reelCountdown") as? Bool ?? true
        tab = d.string(forKey: "reelSettingsTab") ?? "general"
        format = ExportOptions.Format(rawValue: d.string(forKey: "reelFormat") ?? "") ?? .mp4
        codec = ExportOptions.Codec(rawValue: d.string(forKey: "reelCodec") ?? "") ?? .h264
        resolution = ExportOptions.Resolution(rawValue: d.string(forKey: "reelResolution") ?? "") ?? .hd1080
        gifFps = d.object(forKey: "reelGifFps") as? Int ?? 15
        gifWidth = d.object(forKey: "reelGifWidth") as? Int ?? 800
        followCursor = d.object(forKey: "reelFollowCursor") as? Bool ?? true
        followSmoothness = d.object(forKey: "reelFollowSmoothness") as? Double ?? 0.5
        zoomOnMovement = d.object(forKey: "reelZoomOnMovement") as? Bool ?? true
        hotKey = (d.data(forKey: "reelHotKey").flatMap { try? JSONDecoder().decode(KitHotKey.self, from: $0) })
            ?? KitHotKey(keyCode: 15, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, display: "⌃⌥R")
    }

    /// Settings for a fresh recording: auto zooms plus the camera defaults.
    func newSettings(for log: EventLog) -> ProjectSettings {
        var s = ProjectSettings()
        s.followCursor = followCursor; s.followSmoothness = followSmoothness
        s.segments = Zoom.generate(log, followMovement: zoomOnMovement)
        return s
    }

    var options: ExportOptions {
        var o = ExportOptions()
        o.format = format; o.codec = codec; o.resolution = resolution; o.gifFps = gifFps; o.gifWidth = gifWidth
        return o
    }
}

struct RecentItem: Identifiable, Equatable {
    var id: String { folder.path }
    let folder: URL
    let name: String
    let duration: Double
    let date: Date
    let exports: Int
}

enum Phase: Equatable { case idle, countdown(Int), recording, saving }

@MainActor
@Observable
final class ReelModel {
    var phase = Phase.idle
    var elapsed = 0.0
    var recents: [RecentItem] = []
    var recentsLoaded = false
    var error: String?
    var shown = false
    var pulse = 0                       // bumps on the first open per session: the top hairline lights
    var pulsePreview: Double?           // QA only
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    let prefs = Prefs()

    @ObservationIgnored var onRecord: () -> Void = {}
    @ObservationIgnored var onOpen: (URL) -> Void = { _ in }
    @ObservationIgnored var onShowIntro: () -> Void = {}
    @ObservationIgnored var onSettings: () -> Void = {}
    @ObservationIgnored var onQuit: () -> Void = {}
    @ObservationIgnored var onHotKey: () -> Void = {}

    init(live: Bool = true) { if live { refreshRecents() } }

    var isRecording: Bool { phase == .recording }

    /// Lists ~/Movies/Reel off the main actor; rows update in place.
    func refreshRecents() {
        Task {
            let items = await Task.detached { Self.scan() }.value
            if items != recents { withAnimation(KitMotion.list) { recents = items } }
            recentsLoaded = true
        }
    }

    nonisolated static func scan() -> [RecentItem] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Project.root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [RecentItem] = []
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("events.json")), let log = try? JSONDecoder().decode(EventLog.self, from: data) else { continue }
            let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let exports = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".mp4") || $0.hasSuffix(".gif") }.count
            out.append(RecentItem(folder: dir, name: dir.lastPathComponent, duration: log.duration, date: date, exports: exports))
        }
        return Array(out.sorted { $0.date > $1.date }.prefix(6))
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// QA and the intro fill the board with fake data.
    func load(_ items: [RecentItem]) { recents = items; recentsLoaded = true }
}
