import CoreGraphics
import Foundation

/// One cursor event. x and y are normalised to the captured area, origin top-left (0...1).
struct Ev: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case move, down, up }
    var t: Double
    var kind: Kind
    var x: Double
    var y: Double
}

/// The cursor log next to the raw capture. Mouse only; keystrokes are never logged.
struct EventLog: Codable, Equatable, Sendable {
    var duration: Double
    var width: Int            // capture size in pixels
    var height: Int
    var events: [Ev]
    var stoppedEarly: Bool?
    var clicks: [Ev] { events.filter { $0.kind == .down } }
}

/// A zoom on the deck's key track. Eased in and out over `Zoom.ease`; the camera aims at (cx, cy).
struct ZoomSegment: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var zoom: Double
    var cx: Double
    var cy: Double
}

struct FrameStyle: Codable, Equatable, Sendable {
    var background = "17181A"       // hex, no gradients in v1
    var padding = 0.06              // fraction of the canvas' short side
    var radius = 14.0               // points on a 1080 p canvas
    var shadow = true
}

struct ProjectSettings: Codable, Equatable, Sendable {
    var trimStart = 0.0
    var trimEnd: Double? = nil      // nil = to the end
    var segments: [ZoomSegment] = []
    var cursorSize = 1.0            // 0.5...3
    var cursorSmoothing = 0.5       // 0...1
    var clickRings = true
    var followCursor = true         // the camera follows the cursor during a zoom
    var followSmoothness = 0.5      // 0...1, higher = slower, glidier pans
    var frame = FrameStyle()

    init() {}

    /// Older project.json files lack the follow keys; they get the defaults instead of failing to load.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        segments = try c.decodeIfPresent([ZoomSegment].self, forKey: .segments) ?? []
        cursorSize = try c.decodeIfPresent(Double.self, forKey: .cursorSize) ?? 1
        cursorSmoothing = try c.decodeIfPresent(Double.self, forKey: .cursorSmoothing) ?? 0.5
        clickRings = try c.decodeIfPresent(Bool.self, forKey: .clickRings) ?? true
        followCursor = try c.decodeIfPresent(Bool.self, forKey: .followCursor) ?? true
        followSmoothness = try c.decodeIfPresent(Double.self, forKey: .followSmoothness) ?? 0.5
        frame = try c.decodeIfPresent(FrameStyle.self, forKey: .frame) ?? FrameStyle()
    }
    private enum Keys: String, CodingKey { case trimStart, trimEnd, segments, cursorSize, cursorSmoothing, clickRings, followCursor, followSmoothness, frame }
}

struct ExportOptions: Codable, Equatable, Sendable {
    enum Format: String, Codable, Sendable { case mp4, gif }
    enum Codec: String, Codable, Sendable { case h264, hevc }
    enum Resolution: String, Codable, Sendable { case hd1080, source }
    var format = Format.mp4
    var codec = Codec.h264
    var resolution = Resolution.hd1080
    var fps = 0                     // 0 = the source rate, at most 60
    var gifFps = 15
    var gifWidth = 800
}

struct Project: Sendable {
    var folder: URL
    var log: EventLog
    var settings: ProjectSettings

    var capture: URL { folder.appendingPathComponent("capture.mov") }
    var duration: Double { log.duration }
    var trimEnd: Double { min(settings.trimEnd ?? log.duration, log.duration) }

    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Reel", isDirectory: true) }

    static func load(_ folder: URL) throws -> Project {
        let log = try JSONDecoder().decode(EventLog.self, from: Data(contentsOf: folder.appendingPathComponent("events.json")))
        var settings: ProjectSettings
        if let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")), let s = try? JSONDecoder().decode(ProjectSettings.self, from: data) {
            settings = s
        } else {
            settings = ProjectSettings()
            settings.segments = Zoom.generate(log)
        }
        return Project(folder: folder, log: log, settings: settings)
    }

    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(log).write(to: folder.appendingPathComponent("events.json"), options: .atomic)
        try enc.encode(settings).write(to: folder.appendingPathComponent("project.json"), options: .atomic)
    }
}

func rgbComponents(hex: String) -> (r: Double, g: Double, b: Double) {
    let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x17181A
    return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
}

/// mm:ss.d, or mm:ss:ff at 30 fps.
func timecode(_ t: Double, frames: Bool = false) -> String {
    let s = max(0, t)
    let m = Int(s) / 60, sec = Int(s) % 60
    if frames { return String(format: "%02d:%02d:%02d", m, sec, Int((s - floor(s)) * 30)) }
    return String(format: "%02d:%02d.%d", m, sec, Int((s - floor(s)) * 10))
}
