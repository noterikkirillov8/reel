import CoreGraphics
import Foundation

/// The camera maths. Everything is normalised to the captured frame (0...1, origin top-left) so it is resolution independent.
enum Zoom {
    static let ease = 0.4               // seconds to ease in or out
    static let defaultLevel = 1.8
    static let levels = 1.2...3.0
    static let clusterGap = 1.5         // clicks closer than this share one zoom
    static let nearRadius = 0.15        // the cursor "stays near" while inside this distance of the focus
    static let minHold = 1.0
    static let deadZone = 0.55          // the camera moves only when the cursor leaves this share of the zoomed view
    static let restTime = 1.2           // "zoom on movement": zoom out after the cursor rests this long

    /// Smootherstep: zero slope at both ends, so the camera never starts or stops with a jerk.
    static func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// 0...1: rises over the first `ease` seconds of the segment and falls over the last `ease`.
    static func envelope(_ s: ZoomSegment, at t: Double) -> Double {
        guard t > s.start, t < s.end else { return 0 }
        let e = min(ease, (s.end - s.start) / 2)
        return smooth(min((t - s.start) / e, (s.end - t) / e))
    }

    /// The visible part of the frame at zoom `z` aimed at (cx, cy), shifted so it never leaves the frame.
    static func clampedRect(cx: Double, cy: Double, zoom z: Double) -> CGRect {
        let z = max(z, 1), w = 1 / z
        let x = min(max(cx - w / 2, 0), 1 - w), y = min(max(cy - w / 2, 0), 1 - w)
        return CGRect(x: x, y: y, width: w, height: w)
    }

    /// The camera at time t: the segment with the strongest envelope wins; with none active the whole frame shows.
    static func viewport(_ segments: [ZoomSegment], at t: Double, camera: CameraTrack? = nil) -> CGRect {
        var best: (e: Double, s: ZoomSegment)?
        for s in segments {
            let e = envelope(s, at: t)
            if e > 0, e > (best?.e ?? 0) { best = (e, s) }
        }
        guard let (e, s) = best else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let z = 1 + (s.zoom - 1) * e
        let f = camera?.focus(s, at: t) ?? CGPoint(x: s.cx, y: s.cy)
        return clampedRect(cx: 0.5 + (f.x - 0.5) * e, cy: 0.5 + (f.y - 0.5) * e, zoom: z)
    }

    /// One segment per cluster of clicks. Full zoom arrives on the first click and is held while the cursor stays near.
    /// With `followMovement` the hold lasts while the cursor keeps moving (however far) and ends `restTime` after it rests.
    static func generate(_ log: EventLog, level: Double = defaultLevel, followMovement: Bool = false) -> [ZoomSegment] {
        let clicks = log.clicks.sorted { $0.t < $1.t }
        var clusters: [[Ev]] = []
        for c in clicks {
            if let last = clusters.last?.last, c.t - last.t <= clusterGap { clusters[clusters.count - 1].append(c) } else { clusters.append([c]) }
        }
        let moves = log.events.filter { $0.kind == .move }.sorted { $0.t < $1.t }
        var out: [ZoomSegment] = []
        for cl in clusters {
            let cx = cl.map(\.x).reduce(0, +) / Double(cl.count), cy = cl.map(\.y).reduce(0, +) / Double(cl.count)
            let last = cl.last!.t
            var near = last
            for m in moves where m.t > last {
                if hypot(m.x - cx, m.y - cy) > nearRadius { break }
                near = m.t
            }
            var hold = max(last + minHold, near + 0.3)
            if followMovement {
                var anchor = (x: cl.last!.x, y: cl.last!.y), lastMove = last
                for m in moves where m.t > last {
                    if m.t - lastMove > restTime { break }
                    if hypot(m.x - anchor.x, m.y - anchor.y) > 0.01 { anchor = (m.x, m.y); lastMove = m.t }
                }
                hold = max(last + minHold, lastMove + restTime)
            }
            var seg = ZoomSegment(start: max(0, cl[0].t - ease), end: min(hold + ease, log.duration), zoom: level, cx: cx, cy: cy)
            if var prev = out.last, prev.end > seg.start { prev.end = seg.start; out[out.count - 1] = prev }
            if seg.end - seg.start < 2 * ease { seg.end = min(seg.start + 2 * ease, log.duration) }
            out.append(seg)
        }
        return out
    }
}

/// The cursor drawn from the log: a critically damped spring follows the logged position, so it glides and never overshoots.
struct CursorTrack: Sendable {
    private let step = 1.0 / 240
    private var xs: [Double] = [], ys: [Double] = []
    let raw: [Ev]

    init(_ log: EventLog, smoothing: Double) {
        raw = log.events.sorted { $0.t < $1.t }
        guard let first = raw.first else { return }
        let omega = 60 - 50 * min(max(smoothing, 0), 1)       // 10 (floaty) ... 60 (tight)
        var px = first.x, py = first.y, vx = 0.0, vy = 0.0, k = 0
        let n = Int(log.duration / step) + 2
        xs.reserveCapacity(n); ys.reserveCapacity(n)
        for i in 0..<n {
            let t = Double(i) * step
            while k + 1 < raw.count, raw[k + 1].t <= t { k += 1 }
            let tx = raw[k].x, ty = raw[k].y
            // semi-implicit Euler on x'' = w^2 (target - x) - 2 w x'
            vx += (omega * omega * (tx - px) - 2 * omega * vx) * step; px += vx * step
            vy += (omega * omega * (ty - py) - 2 * omega * vy) * step; py += vy * step
            xs.append(px); ys.append(py)
        }
    }

    func position(at t: Double) -> CGPoint {
        guard !xs.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let f = min(max(t / step, 0), Double(xs.count - 1)), i = Int(f), u = f - Double(i), j = min(i + 1, xs.count - 1)
        return CGPoint(x: xs[i] + (xs[j] - xs[i]) * u, y: ys[i] + (ys[j] - ys[i]) * u)
    }
}

/// Where the camera aims during each zoom segment when it follows the cursor. A critically damped spring (slower than the
/// cursor's) chases the point that keeps the smoothed cursor on the edge of the dead zone, so it stays still while the cursor
/// moves inside the inner part of the view and glides when the cursor leaves it. Normalised 0...1; clamping stays in `Zoom.clampedRect`.
struct CameraTrack: Sendable {
    private let step = 1.0 / 240
    private var runs: [UUID: (start: Double, xs: [Double], ys: [Double])] = [:]

    init(_ segments: [ZoomSegment], cursor: CursorTrack, smoothness: Double) {
        let omega = 12 - 9 * min(max(smoothness, 0), 1)       // 3 (slow glide) ... 12 (quick)
        for s in segments {
            let n = Int((s.end - s.start) / step) + 2, half = Zoom.deadZone / s.zoom / 2
            var px = s.cx, py = s.cy, vx = 0.0, vy = 0.0
            var xs: [Double] = [], ys: [Double] = []
            xs.reserveCapacity(n); ys.reserveCapacity(n)
            for i in 0..<n {
                let t = s.start + Double(i) * step
                var tx = px, ty = py
                if t < s.start + Zoom.ease { tx = s.cx; ty = s.cy }            // land on the click first
                else {
                    let c = cursor.position(at: t), r = Zoom.clampedRect(cx: px, cy: py, zoom: s.zoom)
                    let ex = c.x - r.midX, ey = c.y - r.midY
                    tx = r.midX + (abs(ex) > half ? ex - half * (ex < 0 ? -1 : 1) : 0)
                    ty = r.midY + (abs(ey) > half ? ey - half * (ey < 0 ? -1 : 1) : 0)
                }
                vx += (omega * omega * (tx - px) - 2 * omega * vx) * step; px += vx * step
                vy += (omega * omega * (ty - py) - 2 * omega * vy) * step; py += vy * step
                xs.append(px); ys.append(py)
            }
            runs[s.id] = (s.start, xs, ys)
        }
    }

    func focus(_ s: ZoomSegment, at t: Double) -> CGPoint? {
        guard let r = runs[s.id], !r.xs.isEmpty else { return nil }
        let f = min(max((t - r.start) / step, 0), Double(r.xs.count - 1)), i = Int(f), u = f - Double(i), j = min(i + 1, r.xs.count - 1)
        return CGPoint(x: r.xs[i] + (r.xs[j] - r.xs[i]) * u, y: r.ys[i] + (r.ys[j] - r.ys[i]) * u)
    }
}

enum Ring {
    static let life = 0.55
    /// 0...1 progress of a click ring started at `start`, nil when not visible.
    static func progress(_ start: Double, at t: Double) -> Double? {
        let u = (t - start) / life
        return u >= 0 && u <= 1 ? u : nil
    }
}
