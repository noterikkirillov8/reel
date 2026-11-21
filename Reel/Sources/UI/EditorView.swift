import SwiftUI

struct EditorView: View {
    let model: EditorModel
    @State private var shown: Bool
    @FocusState private var focused: Bool

    init(model: EditorModel, shown: Bool = false) { self.model = model; _shown = State(initialValue: shown) }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if model.project.log.stoppedEarly == true {
                        Label("Recording stopped early (screen locked)", systemImage: "info.circle")
                            .font(KitFont.detail).foregroundStyle(KitColor.text2)
                    }
                    preview
                    transport
                    DeckView(model: model)
                }
                .padding(20)
                Rectangle().fill(KitColor.line).frame(width: 1)
                Inspector(model: model).frame(width: 304)
            }
            if model.exportPhase != .closed {
                Color.black.opacity(0.55).transition(.opacity)
                ExportSheet(model: model).transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .frame(width: 1120, height: 760)
        .background(KitColor.window)
        .kitAccent(reelAccent)
        .kitPanelEntrance(shown, anchor: .center)
        .focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(.space) { model.exportPhase == .closed ? { model.togglePlay(); return .handled }() : .ignored }
        .onKeyPress(.delete) { model.exportPhase == .closed ? { model.deleteSelected(); return .handled }() : .ignored }
        .onAppear { shown = true; focused = true }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(timecode(model.playhead)).font(KitFont.figure(40, .semibold)).foregroundStyle(KitColor.text).monospacedDigit()
            Text("/ \(timecode(model.duration))").font(KitFont.figure(14, .regular)).foregroundStyle(KitColor.text2)
            Spacer()
            Text(model.project.folder.lastPathComponent).font(KitFont.detail).foregroundStyle(KitColor.text2).lineLimit(1)
            Button("Export") { model.openExport() }.buttonStyle(.kitPrimary)
        }
        .frame(height: 48)
    }

    private var preview: some View {
        ZStack {
            KitColor.well
            if let still = model.still {
                Image(decorative: still, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else if model.player != nil {
                PlayerSurface(player: model.player).aspectRatio(16.0 / 9.0, contentMode: .fit)
            } else {
                Text("Preparing preview").font(KitFont.detail).foregroundStyle(KitColor.text2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: KitSpace.radius))
        .overlay(RoundedRectangle(cornerRadius: KitSpace.radius).strokeBorder(KitColor.line, lineWidth: 1))
        .frame(maxHeight: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 8) {
            KitIconButton(symbol: "backward.end.fill", help: "Go to start", outlined: true) { model.seek(model.trimStart) }
            KitIconButton(symbol: model.playing ? "pause.fill" : "play.fill", help: model.playing ? "Pause (space)" : "Play (space)", outlined: true) { model.togglePlay() }
            Spacer()
            Text("Trim").font(KitFont.key).foregroundStyle(KitColor.text2)
            Text("\(timecode(model.trimStart)) to \(timecode(model.trimEnd))").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(KitColor.text2)
            Text(String(format: "%.1f s", model.trimEnd - model.trimStart)).font(.system(size: 12, weight: .regular).monospacedDigit()).foregroundStyle(KitColor.text2)
        }
        .frame(height: 28)
    }
}

// MARK: - Deck: ruler, keys, trim and the needle

struct DeckView: View {
    let model: EditorModel
    static let gutter: CGFloat = 52
    static let rulerH: CGFloat = 30, keysH: CGFloat = 76, trimH: CGFloat = 28
    static let height = rulerH + keysH + trimH + 8
    @Environment(\.kitAccent) private var accent

    var body: some View {
        GeometryReader { geo in
            let trackW = max(geo.size.width - Self.gutter, 10)
            let pps = trackW / max(model.duration, 0.1)
            let x: (Double) -> CGFloat = { t in Self.gutter + CGFloat(t) * pps }
            ZStack(alignment: .topLeading) {
                // lanes
                VStack(spacing: 4) {
                    lane("Time", height: Self.rulerH)
                    lane("Zoom", height: Self.keysH)
                    lane("Trim", height: Self.trimH)
                }
                Ruler(duration: model.duration, pps: pps).frame(width: trackW, height: Self.rulerH).offset(x: Self.gutter)
                // click LEDs on the ruler
                ForEach(Array(model.project.log.clicks.enumerated()), id: \.offset) { _, c in
                    KitLed(on: c.t <= model.playhead, size: 6)
                        .position(x: x(c.t), y: Self.rulerH - 6)
                        .animation(KitMotion.soft, value: c.t <= model.playhead)
                }
                // zoom keys
                ForEach(model.project.settings.segments) { seg in
                    ZoomKey(model: model, seg: seg, x0: x(seg.start), x1: x(seg.end), laneTop: Self.rulerH + 4, laneH: Self.keysH)
                }
                // dim outside the trim
                Group {
                    Rectangle().fill(Color.black.opacity(0.45)).frame(width: max(0, x(model.trimStart) - Self.gutter), height: Self.rulerH + Self.keysH + 4)
                        .offset(x: Self.gutter)
                    Rectangle().fill(Color.black.opacity(0.45)).frame(width: max(0, x(model.duration) - x(model.trimEnd)), height: Self.rulerH + Self.keysH + 4)
                        .offset(x: x(model.trimEnd))
                }
                .allowsHitTesting(false)
                TrimBar(model: model, x: x, pps: pps).offset(y: Self.rulerH + Self.keysH + 8).frame(height: Self.trimH)
                // scrub on the ruler
                Color.clear.frame(width: trackW, height: Self.rulerH).offset(x: Self.gutter).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        if model.playing { model.pause() }
                        model.seek(Double((g.location.x) / pps))
                    })
                    .zIndex(0)
                // needle
                Needle().fill(accent).frame(width: 11, height: Self.height - 4)
                    .offset(x: x(model.playhead) - 5.5)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: Self.height)
    }

    private func lane(_ title: String, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(title).font(KitFont.key).foregroundStyle(KitColor.text2).frame(width: Self.gutter, alignment: .leading).padding(.leading, 2)
            RoundedRectangle(cornerRadius: 5).fill(KitColor.well).overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(KitColor.line, lineWidth: 1))
        }
        .frame(height: height)
    }
}

struct Ruler: View {
    let duration: Double
    let pps: CGFloat
    var body: some View {
        Canvas { ctx, size in
            let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
            let major = steps.first { CGFloat($0) * pps >= 64 } ?? 600
            let minor = major / 5
            var i = 0
            // step by index: adding `minor` again and again drifts (4 s became 3.9999 and read "00:03")
            while Double(i) * minor <= duration + 0.001 {
                let t = Double(i) * minor
                let isMajor = abs(t / major - (t / major).rounded()) < 0.001
                let x = CGFloat(t) * pps
                var p = Path()
                p.move(to: CGPoint(x: x + 0.5, y: size.height)); p.addLine(to: CGPoint(x: x + 0.5, y: size.height - (isMajor ? 9 : 4)))
                ctx.stroke(p, with: .color(isMajor ? KitColor.text2 : KitColor.unlit), lineWidth: 1)
                if isMajor {
                    let whole = Int(t.rounded())
                    let label = major < 1 ? timecode(t + 0.001) : String(format: "%02d:%02d", whole / 60, whole % 60)
                    ctx.draw(Text(label).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(KitColor.text2), at: CGPoint(x: x + 4, y: 8), anchor: .leading)
                }
                i += 1
            }
        }
        .allowsHitTesting(false)
    }
}

/// The playhead: a hairline with a small pointed cap.
struct Needle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX - 5.5, y: 0)); p.addLine(to: CGPoint(x: r.midX + 5.5, y: 0)); p.addLine(to: CGPoint(x: r.midX + 0.75, y: 9))
        p.addLine(to: CGPoint(x: r.midX + 0.75, y: r.maxY)); p.addLine(to: CGPoint(x: r.midX - 0.75, y: r.maxY)); p.addLine(to: CGPoint(x: r.midX - 0.75, y: 9))
        p.closeSubpath()
        return p
    }
}

/// A zoom segment as a raised key: taller means more zoom. Drag up and down to change the level.
struct ZoomKey: View {
    let model: EditorModel
    let seg: ZoomSegment
    let x0: CGFloat, x1: CGFloat, laneTop: CGFloat, laneH: CGFloat
    @State private var dragBase: Double?
    @Environment(\.kitAccent) private var accent

    private var keyH: CGFloat { 22 + CGFloat((seg.zoom - Zoom.levels.lowerBound) / (Zoom.levels.upperBound - Zoom.levels.lowerBound)) * (laneH - 34) }
    private var isSelected: Bool { model.selected == seg.id }

    var body: some View {
        let w = max(x1 - x0, 6)
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 5).fill(KitColor.raised)
            VStack(spacing: 0) {
                Rectangle().fill(accent).frame(height: 2)
                if w > 38 {
                    Text(String(format: "%.1fx", seg.zoom)).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(KitColor.text).padding(.top, 5)
                }
                Spacer(minLength: 0)
                Rectangle().fill(Color.black.opacity(0.35)).frame(height: 3)     // the key's depth
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            RoundedRectangle(cornerRadius: 5).strokeBorder(isSelected ? accent : KitColor.line, lineWidth: isSelected ? 1.5 : 1)
        }
        .frame(width: w, height: keyH)
        .contentShape(Rectangle())
        .position(x: x0 + w / 2, y: laneTop + laneH - 4 - keyH / 2)
        .animation(KitMotion.list, value: seg.zoom)
        .onTapGesture { withAnimation(KitMotion.soft) { model.selected = seg.id } }
        .gesture(DragGesture(minimumDistance: 3).onChanged { g in
            model.selected = seg.id
            if dragBase == nil { dragBase = seg.zoom }
            model.setZoom(seg.id, (dragBase ?? seg.zoom) - Double(g.translation.height) / Double(laneH - 34) * (Zoom.levels.upperBound - Zoom.levels.lowerBound))
        }.onEnded { _ in dragBase = nil })
        .help("Drag up or down to change the zoom, Delete removes it")
        .transition(.kitRow)
    }
}

/// Two handles on a bar: the part between them is what gets exported.
struct TrimBar: View {
    let model: EditorModel
    let x: (Double) -> CGFloat
    let pps: CGFloat
    @State private var base: (Double, Double)?
    @Environment(\.kitAccent) private var accent

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(KitColor.raised).frame(width: max(0, x(model.trimEnd) - x(model.trimStart)), height: DeckView.trimH - 8)
                .offset(x: x(model.trimStart), y: 4)
            handle.offset(x: x(model.trimStart) - 6, y: 2)
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    if base == nil { base = (model.trimStart, model.trimEnd) }
                    model.setTrim(start: (base?.0 ?? 0) + Double(g.translation.width / pps))
                }.onEnded { _ in base = nil })
            handle.offset(x: x(model.trimEnd) - 6, y: 2)
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    if base == nil { base = (model.trimStart, model.trimEnd) }
                    model.setTrim(end: (base?.1 ?? 0) + Double(g.translation.width / pps))
                }.onEnded { _ in base = nil })
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var handle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2).fill(KitColor.text)
            HStack(spacing: 2) { Rectangle().frame(width: 1, height: 8); Rectangle().frame(width: 1, height: 8) }.foregroundStyle(Color.black.opacity(0.35))
        }
        .frame(width: 12, height: DeckView.trimH - 4)
        .overlay(alignment: .bottom) { Rectangle().fill(accent).frame(height: 2) }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .contentShape(Rectangle())
    }
}

// MARK: - Inspector

struct Inspector: View {
    let model: EditorModel

    var body: some View {
        let s = model.project.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                KitSection(title: "Zoom") {
                    if let seg = model.selectedSegment {
                        KitRow(title: "Level") {
                            HStack(spacing: 10) {
                                KitSlider(value: Binding(get: { seg.zoom }, set: { model.setZoom(seg.id, $0) }), range: Zoom.levels, step: 0.05).frame(width: 96)
                                Text(String(format: "%.2fx", seg.zoom)).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(KitColor.text).frame(width: 46, alignment: .trailing).lineLimit(1).fixedSize()
                            }
                        }
                        KitRow(title: "Remove this zoom") { KitIconButton(symbol: "trash", help: "Delete zoom", outlined: true, tint: KitColor.red) { model.deleteSelected() } }
                    } else {
                        KitRow(title: "Select a key on the deck", detail: "\(s.segments.count) zoom\(s.segments.count == 1 ? "" : "s") from your clicks")
                    }
                    KitToggleRow(title: "Follow cursor", detail: "The camera pans with the mouse while zoomed", isOn: Binding(get: { s.followCursor }, set: { model.project.settings.followCursor = $0 }))
                    KitRow(title: "Glide") { slider(Binding(get: { s.followSmoothness }, set: { model.project.settings.followSmoothness = $0 }), 0...1, "\(Int(s.followSmoothness * 100))%") }
                        .disabled(!s.followCursor).opacity(s.followCursor ? 1 : 0.4)
                    KitRow(title: "Start over from clicks") { Button("Reset") { model.regenerate() }.buttonStyle(.kitSecondary) }
                }
                KitSection(title: "Cursor") {
                    KitRow(title: "Size") { slider(Binding(get: { s.cursorSize }, set: { model.project.settings.cursorSize = $0 }), 0.5...3, String(format: "%.1fx", s.cursorSize)) }
                    KitRow(title: "Smooth") { slider(Binding(get: { s.cursorSmoothing }, set: { model.project.settings.cursorSmoothing = $0 }), 0...1, "\(Int(s.cursorSmoothing * 100))%") }
                    KitToggleRow(title: "Click rings", isOn: Binding(get: { s.clickRings }, set: { model.project.settings.clickRings = $0 }))
                }
                KitSection(title: "Frame") {
                    BackgroundRow(hex: Binding(get: { s.frame.background }, set: { model.project.settings.frame.background = $0 }))
                    KitRow(title: "Padding") { slider(Binding(get: { s.frame.padding }, set: { model.project.settings.frame.padding = $0 }), 0...0.15, "\(Int(s.frame.padding * 100))%") }
                    KitRow(title: "Corners") { slider(Binding(get: { s.frame.radius }, set: { model.project.settings.frame.radius = $0 }), 0...32, "\(Int(s.frame.radius))") }
                    KitToggleRow(title: "Shadow", isOn: Binding(get: { s.frame.shadow }, set: { model.project.settings.frame.shadow = $0 }))
                }
            }
            .padding(20)
        }
        .scrollIndicators(.never)
    }

    private func slider(_ value: Binding<Double>, _ range: ClosedRange<Double>, _ label: String) -> some View {
        HStack(spacing: 10) {
            KitSlider(value: value, range: range).frame(width: 96)
            Text(label).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(KitColor.text).frame(width: 46, alignment: .trailing).lineLimit(1).fixedSize()
        }
    }
}

struct BackgroundRow: View {
    @Binding var hex: String
    @State private var text = ""
    static let presets = ["17181A", "000000", "2B2C30", "F2F1ED", "E5484D", "3B4A6B", "2F5D50", "7A5C2E"]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Background").font(KitFont.body).foregroundStyle(KitColor.text)
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.self) { p in
                    let rgb = rgbComponents(hex: p)
                    Button { withAnimation(KitMotion.soft) { hex = p; text = p } } label: {
                        RoundedRectangle(cornerRadius: 4).fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b)).frame(width: 22, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(p.caseInsensitiveCompare(hex) == .orderedSame ? KitColor.text : KitColor.line, lineWidth: p.caseInsensitiveCompare(hex) == .orderedSame ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help("#\(p)")
                }
            }
            HStack(spacing: 8) {
                Text("#").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(KitColor.text2)
                TextField("17181A", text: $text).kitField().frame(width: 96)
                    .onSubmit { commit() }
                    .onChange(of: text) { _, v in if v.count == 6, UInt32(v, radix: 16) != nil { hex = v.uppercased() } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 10)
        .onAppear { text = hex }
    }
    private func commit() { if text.count == 6, UInt32(text, radix: 16) != nil { hex = text.uppercased() } else { text = hex } }
}

// MARK: - Export sheet

struct ExportSheet: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(KitFont.title).foregroundStyle(KitColor.text)
            switch model.exportPhase {
            case .running: running
            case .done(let url, let size): done(url, size)
            case .failed(let message): failed(message)
            default: options
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(KitColor.window)
        .clipShape(RoundedRectangle(cornerRadius: KitSpace.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: KitSpace.panelRadius).strokeBorder(KitColor.line, lineWidth: 1))
    }

    private var options: some View {
        let o = Binding(get: { model.options }, set: { model.options = $0 })
        return VStack(alignment: .leading, spacing: 16) {
            KitSection {
                KitRow(title: "Format") {
                    KitSegmented(selection: o.format, options: Exporter.gifAvailable ? [(.mp4, "MP4"), (.gif, "GIF")] : [(.mp4, "MP4")]).frame(width: 130)
                }
                if model.options.format == .mp4 {
                    KitRow(title: "Size") { KitSegmented(selection: o.resolution, options: [(.hd1080, "1080p"), (.source, "Source")]).frame(width: 150) }
                    KitRow(title: "Codec") { KitSegmented(selection: o.codec, options: [(.h264, "H.264"), (.hevc, "HEVC")]).frame(width: 150) }
                } else {
                    KitRow(title: "Width") { KitSegmented(selection: o.gifWidth, options: [(480, "480"), (800, "800"), (1200, "1200")]).frame(width: 190) }
                    KitRow(title: "Frame rate") { KitSegmented(selection: o.gifFps, options: [(10, "10"), (15, "15"), (24, "24")]).frame(width: 150) }
                }
            }
            HStack {
                Text(String(format: "%@, %.1f s", model.options.format == .gif ? "GIF" : "MP4", model.trimEnd - model.trimStart)).font(.system(size: 11, weight: .regular).monospacedDigit()).foregroundStyle(KitColor.text2)
                Spacer()
                Button("Cancel") { model.closeExport() }.buttonStyle(.kitQuiet)
                Button("Export") { model.startExport() }.buttonStyle(.kitPrimary)
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int((model.progress * 100).rounded()))").font(KitFont.figure(56, .semibold)).foregroundStyle(KitColor.text).kitRollingNumber(Int((model.progress * 100).rounded()))
                Text("%").font(KitFont.figure(20, .regular)).foregroundStyle(KitColor.text2)
            }
            ProgressStrip(value: model.progress)
            HStack { Text("Rendering frame by frame").font(KitFont.detail).foregroundStyle(KitColor.text2); Spacer(); Button("Cancel") { model.cancelExport() }.buttonStyle(.kitSecondary) }
        }
    }

    private func done(_ url: URL, _ size: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) { KitLed(on: true); Text("Saved \(url.lastPathComponent)").font(KitFont.bodyMedium).foregroundStyle(KitColor.text).lineLimit(1) }
            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(KitFont.figure(28, .semibold)).foregroundStyle(KitColor.text)
            HStack {
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.kitSecondary)
                Button("Done") { model.closeExport() }.buttonStyle(.kitPrimary)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) { KitLed(on: true, color: KitColor.red); Text("Export failed").font(KitFont.bodyMedium).foregroundStyle(KitColor.text) }
            Text(message).font(KitFont.detail).foregroundStyle(KitColor.text2).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Back") { withAnimation(KitMotion.list) { model.exportPhase = .options } }.buttonStyle(.kitSecondary) }
        }
    }
}

/// Export progress: a strip of segments that light with the figure.
struct ProgressStrip: View {
    let value: Double
    @Environment(\.kitAccent) private var accent
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<40, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1).fill(Double(i + 1) / 40 <= value + 0.0001 || (i == 0 && value > 0) ? accent : KitColor.well).frame(height: 10)
            }
        }
        .animation(KitMotion.list, value: value)
    }
}
