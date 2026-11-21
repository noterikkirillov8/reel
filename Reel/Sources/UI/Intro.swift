import AppKit
import Observation
import SwiftUI

// MARK: - Generic stage pieces (spotlight, ghost cursor)

/// The stage dims to 45% except a crisp pool of light cut exactly to the focused element's rounded rect
/// (4 pt padding, 1 pt edge softening), with a 1 px accent hairline. The pool is clipped to the stage.
struct Spotlight: View {
    let rect: CGRect?
    let reduce: Bool
    var stage = CGSize(width: 640, height: 300)
    var radius: CGFloat = 8
    @Environment(\.kitAccent) private var accent
    var body: some View {
        let r = rect ?? CGRect(x: stage.width / 2, y: stage.height / 2, width: 0, height: 0)
        ZStack {
            SpotShape(x: r.minX - 4, y: r.minY - 4, w: r.width + 8, h: r.height + 8, radius: radius + 4, stage: stage)
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .blur(radius: 1)
            SpotShape(x: r.minX - 4, y: r.minY - 4, w: r.width + 8, h: r.height + 8, radius: radius + 4, stage: stage, ring: true)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        }
        .frame(width: stage.width, height: stage.height)
        .clipped()
        .opacity(rect == nil ? 0 : 1)
        .animation(reduce ? nil : KitMotion.list, value: r)
        .animation(KitMotion.soft, value: rect == nil)
        .allowsHitTesting(false)
    }
}

struct SpotShape: Shape {
    var x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    var radius: CGFloat = 12
    var stage = CGSize(width: 640, height: 300)
    var ring = false
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(x, y), .init(w, h)) }
        set { x = newValue.first.first; y = newValue.first.second; w = newValue.second.first; h = newValue.second.second }
    }
    func path(in _: CGRect) -> Path {
        var p = Path()
        let hole = CGRect(x: x, y: y, width: max(w, 0), height: max(h, 0)).intersection(CGRect(origin: .zero, size: stage))
        if !ring { p.addRect(CGRect(x: -4, y: -4, width: stage.width + 8, height: stage.height + 8)) }   // overshoot so the blur never lightens the stage edge
        if !hole.isNull { p.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius)) }
        return p
    }
}


struct GhostCursor: View {
    var pressed: Bool
    var body: some View {
        Path { p in
            p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: 17)); p.addLine(to: CGPoint(x: 4.5, y: 13))
            p.addLine(to: CGPoint(x: 7.5, y: 19.5)); p.addLine(to: CGPoint(x: 10, y: 18.5)); p.addLine(to: CGPoint(x: 7, y: 12))
            p.addLine(to: CGPoint(x: 12.5, y: 12)); p.closeSubpath()
        }
        .fill(KitColor.text)
        .overlay(Path { p in
            p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: 17)); p.addLine(to: CGPoint(x: 4.5, y: 13))
            p.addLine(to: CGPoint(x: 7.5, y: 19.5)); p.addLine(to: CGPoint(x: 10, y: 18.5)); p.addLine(to: CGPoint(x: 7, y: 12))
            p.addLine(to: CGPoint(x: 12.5, y: 12)); p.closeSubpath()
        }.stroke(KitColor.window, lineWidth: 1))
        .frame(width: 13, height: 20, alignment: .topLeading)
        .scaleEffect(pressed ? 0.85 : 1, anchor: .topLeading)
        .offset(x: 6, y: 9)    // the arrow tip sits on the position
    }
}


// MARK: - Scripted demo (real views, fake data, a keyframe timeline)

enum DemoData {
    static let log: EventLog = {
        var ev: [Ev] = []
        for (t, x, y) in [(1.4, 0.3, 0.4), (3.1, 0.32, 0.42), (5.0, 0.7, 0.5), (8.2, 0.5, 0.6), (9.6, 0.52, 0.62)] {
            ev.append(Ev(t: t, kind: .down, x: x, y: y)); ev.append(Ev(t: t + 0.08, kind: .up, x: x, y: y))
        }
        return EventLog(duration: 12, width: 1920, height: 1080, events: ev)
    }()
    static func project() -> Project {
        var s = ProjectSettings()
        s.segments = [ZoomSegment(start: 1.0, end: 3.5, zoom: 1.8, cx: 0.31, cy: 0.41), ZoomSegment(start: 4.6, end: 7.0, zoom: 2.2, cx: 0.7, cy: 0.5),
                      ZoomSegment(start: 7.8, end: 10.8, zoom: 1.5, cx: 0.51, cy: 0.61)]
        return Project(folder: URL(fileURLWithPath: "/tmp/field-notes-demo"), log: log, settings: s)
    }
}

@MainActor
@Observable
final class Demo {
    var cursor: CGPoint?
    var pressed = false
    var focus: CGRect?           // the pool of light, in stage coordinates
    var barSeconds = 0
    var recOn = false
    var keysShown = false
    var t = 0.0                  // local scene time, fed by the intro clock; the pure scenes draw from it
    let editor: EditorModel?
    @ObservationIgnored let scene: Int
    @ObservationIgnored private let frames: [Keyframe]
    @ObservationIgnored private var done = 0
    @ObservationIgnored private var pressUntil = 0.0

    struct Keyframe { let t: Double; let run: @MainActor (Demo) -> Void }

    init(scene: Int) {
        self.scene = scene
        frames = Self.script(scene).sorted { $0.t < $1.t }
        editor = (scene == 2 || scene == 3) ? EditorModel(project: DemoData.project(), prefs: Prefs()) : nil
        reset()
    }

    func reset() {
        cursor = nil; pressed = false; focus = nil; barSeconds = 0; recOn = false; keysShown = false; t = 0; done = 0
        if scene == 2 { editor?.playhead = 0; editor?.selected = nil }
        if scene == 3 { editor?.exportPhase = .running; editor?.progress = 0 }
    }

    /// Runs every keyframe not yet run up to `time`. The intro clock calls this; QA frames call it once with the frame time.
    func step(to time: Double) {
        t = time
        while done < frames.count, frames[done].t <= time { frames[done].run(self); done += 1 }
        if pressed, time >= pressUntil { withAnimation(KitMotion.press) { pressed = false } }
    }
    func jump(to time: Double) { step(to: time) }

    func move(_ p: CGPoint?) { withAnimation(KitMotion.list) { cursor = p } }
    func light(_ r: CGRect?) { withAnimation(KitMotion.list) { focus = r } }
    func click() {
        withAnimation(KitMotion.press) { pressed = true }
        pressUntil = t + 0.16
    }

    // stage geometry
    static let screen = CGRect(x: 140, y: 26, width: 360, height: 225)
    static let deckOrigin = CGPoint(x: 28, y: 94)
    static let deckWidth: CGFloat = 584
    static func deckX(_ t: Double) -> CGFloat { deckOrigin.x + DeckView.gutter + CGFloat(t / 12) * (deckWidth - DeckView.gutter) }

    static func script(_ scene: Int) -> [Keyframe] {
        switch scene {
        case 0:
            return [Keyframe(t: 0.1) { d in d.light(CGRect(x: 200, y: 30, width: 240, height: 240)) },
                    Keyframe(t: 3.4) { d in d.light(CGRect(x: 170, y: 70, width: 300, height: 130)) }]
        case 1:
            return [Keyframe(t: 0.1) { d in d.light(screen) },
                    Keyframe(t: 1.1) { d in d.light(CGRect(x: screen.minX + 0.5 * 360, y: screen.minY + 0.35 * 225, width: 150, height: 100)) },
                    Keyframe(t: 3.0) { d in d.light(CGRect(x: 140, y: 270, width: 360, height: 24)) }]
        case 2:
            var kfs = [Keyframe(t: 0.1) { d in d.light(CGRect(x: deckOrigin.x, y: deckOrigin.y, width: deckWidth, height: DeckView.height)) }]
            for i in 1...14 { kfs.append(Keyframe(t: 0.2 + Double(i) * 0.1) { d in d.editor?.playhead = Double(i) * 0.5 }) }
            let keyX = (deckX(4.6) + deckX(7.0)) / 2, keyY = deckOrigin.y + DeckView.rulerH + 4 + DeckView.keysH - 4 - 36
            kfs.append(Keyframe(t: 1.8) { d in d.move(CGPoint(x: keyX, y: keyY)) })
            kfs.append(Keyframe(t: 2.4) { d in d.click(); d.editor?.selected = d.editor?.project.settings.segments[1].id })
            for (i, z) in [2.4, 2.6, 2.8].enumerated() {
                kfs.append(Keyframe(t: 2.8 + Double(i) * 0.25) { d in
                    if let e = d.editor, let id = e.selected { e.setZoom(id, z) }
                    d.move(CGPoint(x: keyX, y: keyY - CGFloat(z - 2.2) * 28))
                })
            }
            kfs.append(Keyframe(t: 3.7) { d in d.light(CGRect(x: deckX(4.6) - 4, y: deckOrigin.y + DeckView.rulerH, width: deckX(7.0) - deckX(4.6) + 8, height: DeckView.keysH + 8)) })
            return kfs
        case 3:
            var kfs = [Keyframe(t: 0.1) { d in d.light(CGRect(x: 120, y: 40, width: 400, height: 230)) }]
            for i in 1...20 { kfs.append(Keyframe(t: 0.3 + Double(i) * 0.13) { d in d.editor?.progress = min(1, Double(i) / 20) }) }
            kfs.append(Keyframe(t: 3.1) { d in
                withAnimation(KitMotion.list) { d.editor?.exportPhase = .done(URL(fileURLWithPath: "/tmp/Reel 2026-11-20 14.02.mp4"), 4_300_000) }
                d.light(CGRect(x: 120, y: 120, width: 400, height: 110))
            })
            return kfs
        default:
            return [Keyframe(t: 0.1) { d in d.light(CGRect(x: 200, y: 40, width: 240, height: 100)) },
                    Keyframe(t: 0.5) { d in withAnimation(KitMotion.press) { d.recOn = true } },
                    Keyframe(t: 1.3) { d in d.barSeconds = 1 }, Keyframe(t: 2.3) { d in d.barSeconds = 2 }, Keyframe(t: 3.3) { d in d.barSeconds = 3 },
                    Keyframe(t: 2.0) { d in withAnimation(KitMotion.list) { d.keysShown = true }; d.light(CGRect(x: 150, y: 150, width: 340, height: 120)) }]
        }
    }
}

// MARK: - Intro model

@MainActor
@Observable
final class IntroModel {
    static let titles = ["3, 2, 1, recording", "Clicks become smooth zooms", "Tune it on the deck", "Export an MP4 or a GIF", "Always in the menu bar"]
    static let lines = [
        "Press the hot key. A short countdown gives you time to get ready, then Reel records.",
        "Every click zooms in and eases back out. The cursor is drawn afterwards, so it stays sharp.",
        "Drag a key up for more zoom, delete the ones you do not want, trim the ends.",
        "1080p or full size, H.264 or HEVC. Rendering runs frame by frame, with a progress strip.",
        "A red light and a timecode show while you record. Click it to stop. macOS asks for Screen Recording the first time.",
    ]
    static let sceneSeconds = 4.8

    var scene: Int
    var demos: [Int: Demo] = [:]
    @ObservationIgnored var flow = IntroFlow(durations: Array(repeating: IntroModel.sceneSeconds, count: IntroModel.titles.count))
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored private var timer: Timer?

    init(scene: Int = 0, preview: Demo? = nil) {
        self.scene = scene
        if let preview { demos[scene] = preview }
    }

    var isLast: Bool { scene == Self.titles.count - 1 }

    /// The one clock: a 30 Hz timer drives auto-advance and every keyframe of the current scene.
    func start() {
        flow = IntroFlow(durations: flow.durations, now: CACurrentMediaTime())
        demos[0] = Demo(scene: 0)
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    func tick() {
        let now = CACurrentMediaTime()
        flow.tick(now: now)
        sync()
        demos[scene]?.step(to: flow.time(now: now))
    }

    func next() { flow.next(now: CACurrentMediaTime()); sync() }
    func back() { flow.back(now: CACurrentMediaTime()); sync() }
    /// Skip and Get started.
    func finish() { flow.close(); sync() }

    private func sync() {
        if flow.closed { stop(); onClose(); return }
        guard flow.scene != scene else { return }
        demos[flow.scene] = Demo(scene: flow.scene)
        withAnimation(KitMotion.list) { scene = flow.scene }
    }
}

// MARK: - Views

struct IntroView: View {
    let intro: IntroModel
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let demo = intro.demos[intro.scene] {
                    IntroStage(demo: demo, scene: intro.scene)
                        .id(intro.scene)
                        .transition(reduce ? .opacity : .asymmetric(insertion: .offset(x: 24).combined(with: .opacity),
                                                                    removal: .offset(x: -24).combined(with: .opacity)))
                }
            }
            .frame(width: 640, height: 300)
            .background(KitColor.well)
            .clipped()
            .overlay(alignment: .bottom) { KitDivider() }

            VStack(spacing: 6) {
                Text(IntroModel.titles[intro.scene]).font(.system(size: 17, weight: .semibold)).foregroundStyle(KitColor.text)
                Text(IntroModel.lines[intro.scene]).font(KitFont.body).foregroundStyle(KitColor.text2).multilineTextAlignment(.center).padding(.horizontal, 48)
            }
            .id(intro.scene)
            .transition(.opacity)
            .frame(maxWidth: .infinity, minHeight: 78)
            .padding(.top, KitSpace.m)

            Spacer(minLength: 0)
            HStack {
                Button("Skip") { intro.finish() }.buttonStyle(.kitQuiet).focusable(false)
                Spacer()
                HStack(spacing: 8) { ForEach(0..<IntroModel.titles.count, id: \.self) { KitLed(on: $0 == intro.scene) } }
                Spacer()
                if intro.isLast { Button("Get started") { intro.finish() }.buttonStyle(.kitPrimary).focusable(false) }
                else { Button("Next") { intro.next() }.buttonStyle(.kitSecondary).focusable(false) }
            }
            .padding(.horizontal, KitSpace.l)
            .frame(height: 60)
        }
        .frame(width: 640, height: 440)
        .background(KitColor.window)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KitColor.line, lineWidth: 1))
        .kitAccent(reelAccent)
    }
}

struct IntroStage: View {
    let demo: Demo
    let scene: Int
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                switch scene {
                case 0: LeaderScene(t: demo.t)
                case 1: ZoomScene(t: demo.t)
                case 2: DeckScene(demo: demo)
                case 3: if let e = demo.editor { ExportSheet(model: e).frame(width: 640, height: 300) }
                default: MenuBarScene(demo: demo)
                }
            }
            .frame(width: 640, height: 300)
            .allowsHitTesting(false)
            Spotlight(rect: demo.focus, reduce: reduce)
            if let c = demo.cursor, !reduce, scene == 2 {
                GhostCursor(pressed: demo.pressed).position(c).transition(.opacity)
                    .animation(KitMotion.list, value: c)
            }
        }
        .frame(width: 640, height: 300, alignment: .topLeading)
    }
}

/// Scene 1: the leader. 3, 2, 1 with the sweep hand, then the red light and the running timecode.
struct LeaderScene: View {
    let t: Double
    var body: some View {
        let rec = t >= 3.3
        ZStack {
            if !rec {
                CountdownView(n: max(1, 3 - Int(max(0, t - 0.3))), sweep: max(0, t - 0.3) - floor(max(0, t - 0.3)), size: 240)
                    .transition(.opacity)
            } else {
                VStack(spacing: 14) {
                    HStack(spacing: 10) { KitLed(on: true, color: reelAccent, size: 10); Text("REC").font(KitFont.figure(20, .semibold)).foregroundStyle(KitColor.text) }
                    Text(timecode(t - 3.3)).font(KitFont.figure(64, .semibold)).foregroundStyle(KitColor.text).monospacedDigit()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(KitMotion.list, value: rec)
        .frame(width: 640, height: 300)
    }
}

/// Scene 2: a fake screen filmed by the real camera maths. A click, a ring, and the view eases in.
struct ZoomScene: View {
    let t: Double
    static let seg = ZoomSegment(start: 1.0, end: 3.8, zoom: 1.8, cx: 0.7, cy: 0.64)
    static let clickAt = 1.4

    static func cursor(_ t: Double) -> CGPoint {
        let u = Zoom.smooth((t - 0.3) / 1.1), v = Zoom.smooth((t - 1.8) / 1.4)
        return CGPoint(x: 0.22 + 0.48 * u + 0.05 * v, y: 0.30 + 0.34 * u - 0.04 * v)
    }

    var body: some View {
        let W = Demo.screen.width, H = Demo.screen.height
        let vp = Zoom.viewport([Self.seg], at: t)
        let e = Zoom.envelope(Self.seg, at: t)
        let map: (CGPoint) -> CGPoint = { p in CGPoint(x: (p.x - vp.minX) / vp.width * W, y: (p.y - vp.minY) / vp.height * H) }
        let zoom = 1 / vp.width
        ZStack(alignment: .topLeading) {
            FakeApp().frame(width: W, height: H)
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(x: -vp.minX * zoom * W, y: -vp.minY * zoom * H)
                .frame(width: W, height: H, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(KitColor.line, lineWidth: 1))
            if let u = Ring.progress(Self.clickAt, at: t) {
                let at = map(CGPoint(x: 0.7, y: 0.64)), r = (8 + 22 * (1 - pow(1 - u, 3))) * zoom
                Circle().strokeBorder(reelAccent.opacity(1 - u), lineWidth: 2).background(Circle().fill(reelAccent.opacity((1 - u) * 0.14)))
                    .frame(width: r * 2, height: r * 2).position(at)
            }
            GhostCursor(pressed: t - Self.clickAt > 0 && t - Self.clickAt < 0.14).scaleEffect(zoom > 1.3 ? 1.2 : 1, anchor: .topLeading).position(map(Self.cursor(t)))
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .position(x: Demo.screen.midX, y: Demo.screen.midY)
        .overlay(alignment: .bottom) {
            HStack(spacing: 14) {
                Text("Zoom").font(KitFont.key).foregroundStyle(KitColor.text2)
                Text(String(format: "%.1fx", zoom)).font(KitFont.figure(20, .semibold)).foregroundStyle(KitColor.text).monospacedDigit().frame(width: 60, alignment: .leading)
                KitMeter(value: e, segments: 24, warn: nil, danger: nil).frame(width: 180)
            }
            .frame(height: 24).padding(.bottom, 8)
        }
        .frame(width: 640, height: 300)
    }
}

/// The app being "recorded": a few quiet shapes, one button that gets clicked.
struct FakeApp: View {
    var body: some View {
        GeometryReader { g in
            let W = g.size.width, H = g.size.height
            ZStack(alignment: .topLeading) {
                KitColor.window
                Rectangle().fill(KitColor.well).frame(width: W * 0.2, height: H)
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(i == 1 ? KitColor.text2 : KitColor.unlit).frame(width: W * (i == 1 ? 0.13 : 0.1), height: 5).offset(x: 12, y: 40 + CGFloat(i) * 18)
                }
                HStack(spacing: 5) { ForEach(0..<3, id: \.self) { _ in Circle().fill(KitColor.unlit).frame(width: 6, height: 6) } }.offset(x: 12, y: 12)
                Text("Field notes").font(.system(size: 13, weight: .semibold)).foregroundStyle(KitColor.text).offset(x: W * 0.25, y: 16)
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(KitColor.unlit).frame(width: W * [0.5, 0.42, 0.46, 0.3][i], height: 5).offset(x: W * 0.25, y: 48 + CGFloat(i) * 14)
                }
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(0..<7, id: \.self) { i in RoundedRectangle(cornerRadius: 1.5).fill(i == 4 ? reelAccent : KitColor.unlit).frame(width: 12, height: CGFloat([22, 34, 18, 40, 52, 30, 24][i])) }
                }.offset(x: W * 0.25, y: H * 0.45)
                Text("Publish").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.black)
                    .frame(width: 70, height: 22).background(RoundedRectangle(cornerRadius: 5).fill(KitColor.text))
                    .position(x: W * 0.7, y: H * 0.64)
            }
        }
    }
}

/// Scene 3: the real deck with the needle running, a key picked and pulled up.
struct DeckScene: View {
    let demo: Demo
    var body: some View {
        if let e = demo.editor {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(timecode(e.playhead)).font(KitFont.figure(40, .semibold)).foregroundStyle(KitColor.text).monospacedDigit()
                    Text("/ \(timecode(e.duration))").font(KitFont.figure(14, .regular)).foregroundStyle(KitColor.text3)
                }
                .frame(height: 48)
                DeckView(model: e).frame(width: Demo.deckWidth)
            }
            .padding(.horizontal, 28).padding(.top, 30)
            .frame(width: 640, height: 300, alignment: .topLeading)
        }
    }
}

/// Scene 4: the menu bar mark, drawn big. It turns into the red light and the timecode.
struct MenuBarScene: View {
    let demo: Demo
    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                if !demo.recOn {
                    ReelMark().transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    HStack(spacing: 14) {
                        KitLed(on: true, color: reelAccent, size: 18)
                        Text(String(format: "00:%02d", demo.barSeconds)).font(KitFont.figure(46, .semibold)).foregroundStyle(KitColor.text).kitRollingNumber(demo.barSeconds)
                    }
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(height: 64)
            .animation(KitMotion.press, value: demo.recOn)
            HStack(spacing: 12) {
                KitKeycaps(keys: "⌃⌥R")
                Text("starts and stops recording from anywhere").font(KitFont.body).foregroundStyle(KitColor.text2)
            }
            .opacity(demo.keysShown ? 1 : 0)
            .offset(y: demo.keysShown ? 0 : 8)
        }
        .padding(.top, 60)
        .frame(width: 640, height: 300, alignment: .top)
    }
}

/// The menu bar mark: a film reel, ring and three holes.
struct ReelMark: View {
    var size: CGFloat = 60
    var body: some View {
        ZStack {
            Circle().strokeBorder(KitColor.text, lineWidth: size * 0.085).frame(width: size, height: size)
            ForEach(0..<3, id: \.self) { i in
                let a = Double(i) / 3 * 2 * .pi + .pi / 2
                Circle().fill(KitColor.text).frame(width: size * 0.2, height: size * 0.2).offset(x: cos(a) * size * 0.26, y: -sin(a) * size * 0.26)
            }
            Circle().fill(KitColor.text).frame(width: size * 0.11, height: size * 0.11)
        }
    }
}
// MARK: - Window

@MainActor
final class IntroController {
    static let seenKey = "reelIntroSeen"
    static var seen: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    private let presenter = IntroPresenter()
    private var intro: IntroModel?
    var isShowing: Bool { presenter.isShowing }

    func show() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)    // seen as soon as it is shown: a failed intro never repeats
        if presenter.isShowing { presenter.focus(); return }
        let m = IntroModel()
        intro = m
        m.onClose = { [weak self] in self?.presenter.close() }
        presenter.onClose = { [weak m] in m?.finish() }
        presenter.onNext = { [weak m] in m?.next() }
        presenter.onBack = { [weak m] in m?.back() }
        presenter.show(IntroView(intro: m), size: CGSize(width: 640, height: 440))
        m.start()
    }
}
