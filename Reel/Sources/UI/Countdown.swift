import SwiftUI

/// The 3-2-1 leader: a big figure, a thin sweep hand going round once a second, ticks on a ring. Cinema, in graphite.
struct CountdownView: View {
    let n: Int
    var sweep: Double                // 0...1 within the current second
    var size: CGFloat = 240

    var body: some View {
        let k = size / 240
        ZStack {
            RoundedRectangle(cornerRadius: 16 * k).fill(KitColor.window)
            RoundedRectangle(cornerRadius: 16 * k).strokeBorder(KitColor.line, lineWidth: 1)
            Canvas { ctx, s in
                let c = CGPoint(x: s.width / 2, y: s.height / 2), r = 92 * k
                for i in 0..<60 {
                    let a = Double(i) / 60 * 2 * .pi - .pi / 2, long = i % 5 == 0
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + cos(a) * (r - (long ? 8 : 4) * k), y: c.y + sin(a) * (r - (long ? 8 : 4) * k)))
                    p.addLine(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
                    ctx.stroke(p, with: .color(Double(i) / 60 <= sweep ? reelAccent : KitColor.unlit), lineWidth: 1)
                }
                let a = sweep * 2 * .pi - .pi / 2
                var hand = Path()
                hand.move(to: CGPoint(x: c.x + cos(sweep * 2 * .pi - .pi / 2) * 64 * k, y: c.y + sin(sweep * 2 * .pi - .pi / 2) * 64 * k)); hand.addLine(to: CGPoint(x: c.x + cos(a) * (r - 10 * k), y: c.y + sin(a) * (r - 10 * k)))
                ctx.stroke(hand, with: .color(reelAccent), lineWidth: 1)
            }
            Text("\(n)").font(KitFont.figure(104 * k, .semibold)).foregroundStyle(KitColor.text).kitRollingNumber(n)
            VStack { Spacer(); HStack(spacing: 6) { KitLed(on: true, color: reelAccent); Text("Recording starts").font(KitFont.key).foregroundStyle(KitColor.text2) }.padding(.bottom, 12 * k) }
        }
        .frame(width: size, height: size)
        .kitAccent(reelAccent)
    }
}

/// The live countdown panel content: counts 3, 2, 1 from `start`.
struct CountdownLive: View {
    let start: Date
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = max(0, ctx.date.timeIntervalSince(start))
            CountdownView(n: max(1, 3 - Int(t)), sweep: t - floor(t))
        }
    }
}

@MainActor
final class CountdownPanel {
    private var panel: NSPanel?

    /// Shows the panel for 3 seconds, then removes it (so it is not in the capture).
    func run() async {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 240), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.level = .screenSaver
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: CountdownLive(start: Date()))
        host.sizingOptions = []
        p.contentView = host
        if let screen = NSScreen.main { p.setFrameOrigin(NSPoint(x: screen.frame.midX - 120, y: screen.frame.midY - 120)) }
        p.orderFrontRegardless()
        panel = p
        try? await Task.sleep(for: .seconds(3))
        p.orderOut(nil)
        panel = nil
        try? await Task.sleep(for: .milliseconds(120))      // let the window server drop it before the first frame
    }
}
