import AVFoundation
import AppKit
import CoreImage
import Observation
import SwiftUI

/// The compositor the live preview reads; swapped whenever a setting changes.
final class LiveCompositor: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Compositor
    init(_ c: Compositor) { value = c }
    var compositor: Compositor { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); value = newValue; lock.unlock() } }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

enum ExportPhase: Equatable { case closed, options, running, done(URL, Int), failed(String) }

@MainActor
@Observable
final class EditorModel {
    var project: Project { didSet { if project.settings != oldValue.settings { settingsChanged() } } }
    var playhead = 0.0
    var playing = false
    var selected: UUID?
    var still: CGImage?                     // QA draws this instead of the live player
    var exportPhase = ExportPhase.closed
    var progress = 0.0
    var options: ExportOptions
    let prefs: Prefs
    let sourceSize: CGSize
    let previewCanvas = CGSize(width: 1280, height: 720)
    @ObservationIgnored var player: AVPlayer?
    @ObservationIgnored let live: LiveCompositor
    @ObservationIgnored private var saver: Task<Void, Never>?
    @ObservationIgnored private var cancel = CancelFlag()
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored var onClose: () -> Void = {}

    init(project: Project, prefs: Prefs, sourceSize: CGSize? = nil) {
        self.project = project
        self.prefs = prefs
        self.options = prefs.options
        let size = sourceSize ?? CGSize(width: project.log.width, height: project.log.height)
        self.sourceSize = size
        live = LiveCompositor(Compositor(source: size, canvas: CGSize(width: 1280, height: 720), settings: project.settings, log: project.log))
    }

    var duration: Double { project.duration }
    var trimStart: Double { project.settings.trimStart }
    var trimEnd: Double { project.trimEnd }
    var selectedSegment: ZoomSegment? { project.settings.segments.first { $0.id == selected } }

    // MARK: settings

    private func settingsChanged() {
        live.compositor = Compositor(source: sourceSize, canvas: previewCanvas, settings: project.settings, log: project.log, context: live.compositor.ci)
        refresh()
        saver?.cancel()
        let snapshot = project
        saver = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { await Task.detached { try? snapshot.save() }.value }
        }
    }

    func setZoom(_ id: UUID, _ level: Double) {
        guard let i = project.settings.segments.firstIndex(where: { $0.id == id }) else { return }
        project.settings.segments[i].zoom = min(max((level * 20).rounded() / 20, Zoom.levels.lowerBound), Zoom.levels.upperBound)
    }

    func deleteSelected() {
        guard let id = selected else { return }
        withAnimation(KitMotion.list) { project.settings.segments.removeAll { $0.id == id }; selected = nil }
    }

    func regenerate() {
        withAnimation(KitMotion.list) { project.settings.segments = Zoom.generate(project.log, followMovement: prefs.zoomOnMovement); selected = nil }
    }

    func setTrim(start: Double? = nil, end: Double? = nil) {
        let s = project.settings.trimmed(start: start, end: end, duration: duration)
        project.settings = s
        playhead = min(max(playhead, s.trimStart), project.trimEnd)
        seek(playhead)
    }

    // MARK: playback

    func prepare() async {
        let asset = AVURLAsset(url: project.capture)
        let item = AVPlayerItem(asset: asset)
        let live = self.live
        let canvas = previewCanvas
        if let comp = try? await AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
            let c = live.compositor
            request.finish(with: c.compose(request.sourceImage, at: request.compositionTime.seconds), context: c.ci)
        }) {
            let m = comp.mutableCopy() as! AVMutableVideoComposition
            m.renderSize = canvas
            item.videoComposition = m
        }
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        player = p
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.playing else { return }
                if t.seconds >= self.trimEnd { self.pause(); self.seek(self.trimStart) } else { self.playhead = t.seconds }
            }
        }
        seek(max(playhead, trimStart))
    }

    func togglePlay() { playing ? pause() : play() }
    func play() {
        guard let player else { return }
        if playhead >= trimEnd - 0.05 { seek(trimStart) }
        playing = true
        player.play()
    }
    /// Arrow keys: one frame, or a second with Shift. Stays inside the trim.
    func step(_ seconds: Double) {
        pause()
        seek(project.clampedToTrim(playhead + seconds))
    }
    func pause() { playing = false; player?.pause() }
    func seek(_ t: Double) {
        playhead = min(max(t, 0), duration)
        player?.seek(to: CMTime(seconds: playhead, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    /// Re-renders the frame on screen after a setting changed.
    func refresh() { if !playing { player?.seek(to: CMTime(seconds: playhead, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) } }

    func close() { pause(); if let observer { player?.removeTimeObserver(observer) }; observer = nil; player = nil; try? project.save() }

    // MARK: export

    func openExport() { options = prefs.options; if !Exporter.gifAvailable { options.format = .mp4 }; withAnimation(KitMotion.panelIn) { exportPhase = .options } }

    func startExport() {
        pause()
        let out = project.folder.appendingPathComponent("Reel \(Self.stamp()).\(options.format == .gif ? "gif" : "mp4")")
        let snapshot = project, opts = options
        cancel = CancelFlag()
        let flag = cancel
        progress = 0
        withAnimation(KitMotion.list) { exportPhase = .running }
        prefs.format = opts.format; prefs.codec = opts.codec; prefs.resolution = opts.resolution
        Task {
            let step = Box(0.0)
            do {
                try await Task.detached {
                    try await Exporter.export(snapshot, options: opts, to: out, progress: { p in
                        guard p - step.value >= 0.01 || p >= 1 else { return }
                        step.value = p
                        Task { @MainActor in self.progress = p }
                    }, cancelled: { flag.isSet })
                }.value
                let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                progress = 1
                KitSound.play(.confirm)
                withAnimation(KitMotion.list) { exportPhase = .done(out, size) }
            } catch is CancellationError {
                withAnimation(KitMotion.list) { exportPhase = .options }
            } catch {
                KitSound.play(.error)
                withAnimation(KitMotion.list) { exportPhase = .failed(error.localizedDescription) }
            }
        }
    }

    func cancelExport() { cancel.set() }
    func closeExport() { withAnimation(KitMotion.panelOut) { exportPhase = .closed } }

    static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f.string(from: Date())
    }
}

final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

// MARK: - Player surface

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> PlayerNSView { PlayerNSView() }
    func updateNSView(_ v: PlayerNSView, context: Context) { v.layer_.player = player }
}

final class PlayerNSView: NSView {
    let layer_ = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer_.videoGravity = .resizeAspect
        layer?.addSublayer(layer_)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); layer_.frame = bounds }
}
