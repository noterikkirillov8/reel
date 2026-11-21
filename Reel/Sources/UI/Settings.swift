import SwiftUI

enum SettingsTab: String { case general, recording, export, about }

struct MacSoundRow: View {
    @Binding var isOn: Bool

    var body: some View {
        KitToggleRow(title: "Record Mac sound", detail: "Includes notification sounds", symbol: "speaker.wave.2", isOn: $isOn)
    }
}

struct SettingsView: View {
    let model: ReelModel
    @Bindable var prefs: Prefs
    var tabOverride: SettingsTab?
    @State private var selection: SettingsTab = .general

    init(model: ReelModel, tab: SettingsTab? = nil) {
        self.model = model; self.prefs = model.prefs; self.tabOverride = tab
        _selection = State(initialValue: tab ?? SettingsTab(rawValue: model.prefs.tab) ?? .general)
    }

    var body: some View {
        KitSettings(title: "Reel settings", tabs: [(.general, "General"), (.recording, "Recording"), (.export, "Export"), (.about, "About")],
                    selection: $selection) { tab in
            switch tab {
            case .general: general
            case .recording: recording
            case .export: export
            case .about:
                KitAboutView(name: "Reel", tagline: "Record your screen for demos. Clicks become smooth zooms.",
                             repoURL: URL(string: "https://github.com/noterikkirillov8/reel"))
            }
        }
        .kitAccent(reelAccent)
        .onChange(of: selection) { _, t in if tabOverride == nil { prefs.tab = t.rawValue } }
    }

    @ViewBuilder private var general: some View {
        KitSection(title: "Startup") {
            KitToggleRow(title: "Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            KitRow(title: "Start and stop recording", detail: "Works from any app") {
                KitHotKeyField(hotKey: $prefs.hotKey).onChange(of: prefs.hotKey) { _, _ in model.onHotKey() }
            }
            KitRow(title: "Intro") { Button("Show intro") { model.onShowIntro() }.buttonStyle(.kitSecondary) }
        }
        KitSoundSection()
    }

    @ViewBuilder private var recording: some View {
        KitSection(title: "Capture", footer: "The cursor is hidden in the capture and drawn later from a mouse log. Keystrokes are never logged.") {
            KitRow(title: "Frame rate") { KitSegmented(selection: $prefs.fps60, options: [(true, "60 fps"), (false, "30 fps")]).frame(width: 160) }
            MacSoundRow(isOn: $prefs.macSound)
            KitToggleRow(title: "Microphone", detail: "Off unless you turn it on", isOn: $prefs.microphone)
            KitToggleRow(title: "3, 2, 1 countdown", isOn: $prefs.countdown)
        }
        KitSection(title: "Camera", footer: "Defaults for new recordings. Each recording can change them in the editor.") {
            KitToggleRow(title: "Follow cursor", detail: "The camera pans with the mouse while zoomed", isOn: $prefs.followCursor)
            KitRow(title: "Follow smoothness") { KitSlider(value: $prefs.followSmoothness).frame(width: 96) }
            KitToggleRow(title: "Zoom on movement", detail: "Stay zoomed while the mouse travels; zoom out after it rests 1.2 s", isOn: $prefs.zoomOnMovement)
        }
        KitSection(title: "Where recordings go", footer: "Each take is a folder with the raw capture, the mouse log and your edits.") {
            KitRow(title: "Folder", detail: "~/Movies/Reel") { Button("Show") { NSWorkspace.shared.open(Project.root) }.buttonStyle(.kitSecondary) }
        }
    }

    @ViewBuilder private var export: some View {
        KitSection(title: "Defaults") {
            KitRow(title: "Format") { KitSegmented(selection: $prefs.format, options: Exporter.gifAvailable ? [(.mp4, "MP4"), (.gif, "GIF")] : [(.mp4, "MP4")]).frame(width: 130) }
            KitRow(title: "Size") { KitSegmented(selection: $prefs.resolution, options: [(.hd1080, "1080p"), (.source, "Source")]).frame(width: 150) }
            KitRow(title: "Codec") { KitSegmented(selection: $prefs.codec, options: [(.h264, "H.264"), (.hevc, "HEVC")]).frame(width: 150) }
        }
        if Exporter.gifAvailable {
            KitSection(title: "GIF", footer: "GIFs are made with ffmpeg from /opt/homebrew/bin.") {
                KitRow(title: "Width") { KitSegmented(selection: $prefs.gifWidth, options: [(480, "480"), (800, "800"), (1200, "1200")]).frame(width: 190) }
                KitRow(title: "Frame rate") { KitSegmented(selection: $prefs.gifFps, options: [(10, "10"), (15, "15"), (24, "24")]).frame(width: 150) }
            }
        }
    }
}
