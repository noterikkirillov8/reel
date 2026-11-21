import AVFoundation
import AppKit
import Carbon
import SwiftUI

/// One borderless panel for the app's whole life; opening it is just `orderFront`.
final class ReelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class ReelWindow: NSWindow { override var canBecomeKey: Bool { true } }

@main
@MainActor
final class ReelApp: NSObject, NSApplicationDelegate {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("-render") { exit(CLI.render(args)) }
        if args.contains("-make-sample") { exit(CLI.makeSample(args)) }          // before any NSApplication exists
        let app = NSApplication.shared
        let delegate = ReelApp()
        app.delegate = delegate
        app.setActivationPolicy(args.contains("-qa") || args.contains("-intro-preview") ? .prohibited : .accessory)
        app.run()
    }

    private let model = ReelModel()
    private let recorder = Recorder()
    private let countdown = CountdownPanel()
    private var statusItem: NSStatusItem!
    private var panel: ReelPanel!
    private var host: NSHostingView<MenuView>!
    private var monitor: Any?
    private var menuOpen = false
    private var lastResignClose = Date.distantPast
    private var closing: DispatchWorkItem?
    private let intro = IntroController()
    private var openedOnce = false
    private var settings: ReelWindow?
    private var editors: [URL: (ReelWindow, EditorModel)] = [:]
    private var ticker: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if QA.runIfAsked() || IntroPreview.runIfAsked() { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = StatusImage.idle()
            button.target = self
            button.action = #selector(statusClicked)
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        model.onRecord = { [weak self] in self?.hide(); self?.toggleRecording() }
        model.onOpen = { [weak self] url in self?.hide(); self?.openEditor(url) }
        model.onShowIntro = { [weak self] in self?.hide(); self?.intro.show() }
        model.onSettings = { [weak self] in self?.hide(); self?.showSettings() }
        model.onQuit = { NSApp.terminate(nil) }
        model.onHotKey = { [weak self] in self?.registerHotKey() }
        recorder.onFailure = { [weak self] in
            guard let self, self.model.phase == .recording else { return }
            self.finishRecording()
        }
        makePanel()
        registerHotKey()
        if !IntroController.seen { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in MainActor.assumeIsolated { self?.hide(); self?.intro.show() } } }
    }

    @objc func mouseEntered(_ event: NSEvent) { model.refreshRecents() }

    private func registerHotKey() {
        HotKeys.shared.unregister(1)
        guard let k = model.prefs.hotKey else { return }
        let f = NSEvent.ModifierFlags(rawValue: k.modifiers)
        var mods: UInt32 = 0
        if f.contains(.command) { mods |= UInt32(cmdKey) }
        if f.contains(.option) { mods |= UInt32(optionKey) }
        if f.contains(.control) { mods |= UInt32(controlKey) }
        if f.contains(.shift) { mods |= UInt32(shiftKey) }
        HotKeys.shared.register(1, .init(keyCode: UInt32(k.keyCode), modifiers: mods)) { [weak self] in self?.toggleRecording() }
    }

    // MARK: recording

    /// The status item is the stop button while recording.
    @objc private func statusClicked() { model.isRecording ? toggleRecording() : toggle() }

    private func toggleRecording() {
        switch model.phase {
        case .recording: finishRecording()
        case .idle: beginRecording()
        default: break
        }
    }

    private func beginRecording() {
        let p = model.prefs
        model.phase = .countdown(3)
        Task {
            do {
                try await recorder.start(mode: p.mode, fps: p.fps60 ? 60 : 30, mic: p.microphone, macSound: p.macSound, codec: p.codec, countdown: p.countdown ? { [countdown] in await countdown.run() } : nil)
                if recorder.interruption != nil { finishRecording(); return }
                model.phase = .recording
                model.elapsed = 0
                setRecordingImage()
                let t0 = Date()
                ticker = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard let self, self.model.phase == .recording else { return }
                        self.model.elapsed = Date().timeIntervalSince(t0)
                        self.setRecordingImage()
                    }
                }
            } catch RecorderError.cancelled {
                model.phase = .idle
            } catch {
                model.phase = .idle
                KitSound.play(.error)
                showError(error.localizedDescription)
            }
        }
    }

    private func setRecordingImage() { statusItem.button?.image = StatusImage.recording(model.elapsed) }

    private func finishRecording() {
        ticker?.cancel()
        model.phase = .saving
        statusItem.button?.image = StatusImage.idle()
        Task {
            do {
                let folder = try await recorder.stop()
                model.phase = .idle
                KitSound.play(.confirm)
                model.refreshRecents()
                openEditor(folder)
            } catch {
                model.phase = .idle
                KitSound.play(.error)
                showError(error.localizedDescription)
            }
        }
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Reel could not record"
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: editor

    private func openEditor(_ folder: URL) {
        if let (w, _) = editors[folder] { NSApp.activate(); w.makeKeyAndOrderFront(nil); return }
        Task {
            guard let project = try? await Task.detached(operation: { try Project.load(folder) }).value else { showError("Could not open this recording."); return }
            let asset = AVURLAsset(url: project.capture)
            let size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? nil
            let editor = EditorModel(project: project, prefs: model.prefs, sourceSize: size)
            let w = ReelWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = NSColor(KitColor.window)
            w.contentView = NSHostingView(rootView: EditorView(model: editor))
            w.center()
            editors[folder] = (w, editor)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { editor.close(); self?.editors[folder] = nil; self?.model.refreshRecents() }
            }
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            await editor.prepare()
        }
    }

    // MARK: settings

    private func showSettings() {
        if let w = settings { NSApp.activate(); w.makeKeyAndOrderFront(nil); return }
        let w = ReelWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(KitColor.window)
        w.contentView = NSHostingView(rootView: SettingsRoot(model: model))
        w.center()
        settings = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settings = nil }
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: panel

    private func makePanel() {
        panel = ReelPanel(contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: 300),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        host = NSHostingView(rootView: MenuView(model: model, target: Recorder.displayName(), onHeight: { [weak self] h in self?.resize(to: h) }))
        host.sizingOptions = []
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, self.model.shown, !self.menuOpen else { return }
                self.lastResignClose = Date()
                self.hide()
            }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuOpen = false
                if self.panel.isVisible, self.model.shown, !self.panel.isKeyWindow { self.hide() }
            }
        }
        host.frame = NSRect(x: 0, y: 0, width: Layout.width, height: 300)
        host.layoutSubtreeIfNeeded()     // warm up without showing anything
    }

    private func resize(to height: CGFloat) {
        guard height > 1, let panel else { return }
        var f = panel.frame
        guard abs(f.height - height) > 0.5 else { return }
        f.origin.y += f.height - height
        f.size.height = height
        if !panel.isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(f, display: false)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(f, display: true)
            }
        }
        panel.invalidateShadow()
    }

    private func toggle() {
        if intro.isShowing { hide(); intro.show(); return }    // never the intro and the panel together
        if panel.isVisible && model.shown { hide(); return }
        if Date().timeIntervalSince(lastResignClose) < 0.25 { return }
        show()
    }

    private func show() {
        guard let button = statusItem.button, let bw = button.window else { return }
        let b = bw.frame
        let vis = (bw.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = panel.frame.size
        let x = min(max(b.midX - size.width / 2, vis.minX + 8), vis.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: b.minY - 6 - size.height))
        closing?.cancel()
        if !openedOnce { openedOnce = true; model.pulse += 1 }
        model.refreshRecents()
        panel.orderFrontRegardless()
        panel.makeKey()
        model.shown = true
        panel.displayIfNeeded()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func hide() {
        model.shown = false
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.panel.orderOut(nil) } }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}

/// The settings content with the standard entrance from the centre.
struct SettingsRoot: View {
    let model: ReelModel
    @State private var shown = false
    var body: some View {
        SettingsView(model: model).kitPanelEntrance(shown, anchor: .center).onAppear { shown = true }
    }
}
