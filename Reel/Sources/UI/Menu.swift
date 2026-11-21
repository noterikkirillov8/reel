import SwiftUI

enum Layout {
    static let width: CGFloat = 360
    static let captureHeight: CGFloat = 214
    static let rowHeight: CGFloat = 52
    static let maxRows = 4
    /// QA: stop animations so a frame can be captured at a fixed progress.
    nonisolated(unsafe) static var frozen = false
}

struct Entrance: ViewModifier {
    var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        if reduce { content.opacity(shown ? 1 : 0).animation(KitMotion.soft, value: shown) } else { content.kitPanelEntrance(shown) }
    }
}

/// The menu bar panel: pick what to record, press Record, jump back into a recent take.
struct MenuView: View {
    let model: ReelModel
    @Bindable var prefs: Prefs
    var target = "Built-in Retina Display"
    var forceHover: String?
    var onHeight: (CGFloat) -> Void = { _ in }

    init(model: ReelModel, target: String = "Built-in Retina Display", forceHover: String? = nil, onHeight: @escaping (CGFloat) -> Void = { _ in }) {
        self.model = model; self.prefs = model.prefs; self.target = target; self.forceHover = forceHover; self.onHeight = onHeight
    }

    var targetHeight: CGFloat {
        let recent: CGFloat = !model.recentsLoaded ? 3 * Layout.rowHeight : (model.recents.isEmpty ? 92 : CGFloat(min(model.recents.count, Layout.maxRows)) * (Layout.rowHeight + 1) - 1)
        return 52 + 1 + Layout.captureHeight + 1 + 28 + recent + 1 + 52
    }

    var body: some View {
        KitPanel(title: "Reel", width: Layout.width) {
            if let hot = prefs.hotKey { KitKeycaps(keys: hot.display) }
        } content: {
            VStack(spacing: 0) {
                capture
                KitDivider()
                recents
            }
        } footer: {
            footer
        }
        .kitAccent(reelAccent)
        .overlay(alignment: .top) { PowerLine(trigger: model.pulse, preview: model.pulsePreview).padding(.top, 52) }
        .modifier(Entrance(shown: model.shown))
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: targetHeight, initial: true) { _, h in onHeight(h) }
    }

    private var capture: some View {
        VStack(alignment: .leading, spacing: 12) {
            KitSegmented(selection: $prefs.mode, options: [(.display, "Display"), (.window, "Window"), (.area, "Area")])
            Text(caption).font(KitFont.detail).foregroundStyle(KitColor.text2).lineLimit(1).frame(height: 14)
            MacSoundRow(isOn: $prefs.macSound)
                .padding(.horizontal, -14).padding(.vertical, -8)
            HStack(spacing: 10) {
                Text("Microphone").font(KitFont.body).foregroundStyle(KitColor.text)
                Spacer()
                KitSwitch(isOn: $prefs.microphone)
            }
            .frame(height: 24)
            // the kit's primary style hugs its label, so this full-width key is drawn in the same look
            Button { model.onRecord() } label: {
                HStack(spacing: 8) {
                    Circle().fill(reelAccent).frame(width: 8, height: 8).overlay(Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: 1))
                    Text("Record").font(KitFont.button).foregroundStyle(Color(hex: 0x1B1B1A))
                }
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(RoundedRectangle(cornerRadius: KitSpace.controlRadius).fill(Color(hex: 0xECEBE7)))
                .contentShape(Rectangle())
            }
            .buttonStyle(RecordPressStyle())
        }
        .padding(KitSpace.l)
        .frame(height: Layout.captureHeight, alignment: .top)
    }

    private var caption: String {
        switch prefs.mode {
        case .display: target
        case .window: "You pick the window when you press Record"
        case .area: "You drag the area when you press Record"
        }
    }

    @ViewBuilder private var recents: some View {
        Text("Recent").font(KitFont.header).foregroundStyle(KitColor.text2)
            .padding(.horizontal, KitSpace.l).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        if !model.recentsLoaded {
            VStack(spacing: 0) { ForEach(0..<3, id: \.self) { _ in SkeletonRow() } }
        } else if model.recents.isEmpty {
            KitEmptyState(symbol: "film", text: "No recordings yet. Press Record.").frame(height: 92)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(model.recents.prefix(Layout.maxRows).enumerated()), id: \.element.id) { i, item in
                    RecentRow(model: model, item: item, forced: forceHover == item.id)
                    if i < min(model.recents.count, Layout.maxRows) - 1 { KitDivider(inset: 70) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button("Settings") { model.onSettings() }.buttonStyle(.kitQuiet)
            Button("Show intro") { model.onShowIntro() }.buttonStyle(.kitQuiet)
            Spacer()
            Button("Quit") { model.onQuit() }.buttonStyle(.kitQuiet)
        }
        .frame(height: 28)
    }
}

struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 5).fill(KitColor.well).frame(width: 40, height: 28)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(KitColor.well).frame(width: 150, height: 9)
                RoundedRectangle(cornerRadius: 2).fill(KitColor.well).frame(width: 90, height: 8)
            }
            Spacer()
        }
        .padding(.horizontal, KitSpace.l).frame(height: Layout.rowHeight)
    }
}

struct RecentRow: View {
    let model: ReelModel
    let item: RecentItem
    var forced = false
    @State private var hover = false

    private var title: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let time = f.string(from: item.date)
        if Calendar.current.isDateInToday(item.date) { return "Today, \(time)" }
        if Calendar.current.isDateInYesterday(item.date) { return "Yesterday, \(time)" }
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: item.date)
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(timecode(item.duration).dropLast(2)).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(KitColor.text2)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(KitFont.bodyMedium).foregroundStyle(KitColor.text).lineLimit(1)
                Text(item.exports == 0 ? "Not exported" : "\(item.exports) export\(item.exports == 1 ? "" : "s")")
                    .font(KitFont.detail).foregroundStyle(KitColor.text2).lineLimit(1)
            }
            Spacer(minLength: KitSpace.s)
            if hover || forced {
                HStack(spacing: 2) {
                    KitIconButton(symbol: "slider.horizontal.3", help: "Edit", outlined: true) { model.onOpen(item.folder) }
                    KitIconButton(symbol: "folder", help: "Show in Finder", outlined: true) { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) }
                }
                .transition(.opacity.combined(with: .offset(x: 4)))
            }
        }
        .padding(.horizontal, KitSpace.l)
        .frame(height: Layout.rowHeight)
        .background((hover || forced) ? KitColor.well : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.onOpen(item.folder) }
        .onHover { h in withAnimation(KitMotion.soft) { hover = h } }
    }
}

/// First open of a session: the hairline under the title lights in the accent from the centre outward.
struct PowerLine: View {
    let trigger: Int
    var preview: Double? = nil
    @State private var width = 0.0
    @State private var alpha = 0.0
    @Environment(\.kitAccent) private var accent

    var body: some View {
        Rectangle().fill(accent).frame(height: 1)
            .scaleEffect(x: preview ?? width, y: 1)
            .opacity(preview == nil ? alpha : 1)
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, _ in
                width = 0; alpha = 1
                withAnimation(.easeOut(duration: 0.25)) { width = 1 }
                Task { try? await Task.sleep(for: .milliseconds(250)); withAnimation(KitMotion.soft) { alpha = 0 } }
            }
    }
}

struct RecordPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.98 : 1).opacity(configuration.isPressed ? 0.9 : 1).animation(KitMotion.press, value: configuration.isPressed)
    }
}
