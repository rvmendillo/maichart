import Foundation

public struct Vec2: Equatable, Codable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, k: Double) -> Vec2 { Vec2(a.x * k, a.y * k) }
    public var length: Double { (x * x + y * y).squareRoot() }
    public func distance(to b: Vec2) -> Double { (self - b).length }
    /// Angle in degrees clockwise from 12 o'clock.
    public var clockAngle: Double {
        var a = atan2(x, -y) * 180 / Double.pi
        if a < 0 { a += 360 }
        return a
    }
    public static func polar(angle deg: Double, radius r: Double) -> Vec2 {
        let a = deg * Double.pi / 180
        return Vec2(r * sin(a), -r * cos(a))
    }
}

/// Sensor layout of the touch panel in unit coordinates (judgement ring radius = 1).
public enum SensorLayout {
    public static let centerRadius = 0.27
    public static let innerRadius = 0.68
    public static let outerRadius = 1.25

    public static func position(_ a: TouchArea) -> Vec2 {
        a.isCenter ? Vec2(0, 0) : Vec2.polar(angle: a.angle, radius: a.radius)
    }

    /// Sensor area containing point p (nil when outside the panel).
    public static func area(at p: Vec2) -> TouchArea? {
        let r = p.length
        if r < centerRadius { return .c }
        if r > outerRadius { return nil }
        let ang = p.clockAngle
        // nearest button sector and nearest gap sector
        let bIndex = Geometry.wrap(Int(((ang - 22.5) / 45).rounded()) + 1)
        let dIndex = Geometry.wrap(Int((ang / 45).rounded()) + 1)
        var dB = abs(ang - Geometry.buttonAngle(bIndex)).truncatingRemainder(dividingBy: 360); if dB > 180 { dB = 360 - dB }
        if r < innerRadius {
            // inner ring: B sectors are wide, E diamonds sit between them
            return dB <= 15 ? .b(bIndex) : .e(dIndex)
        }
        return dB <= 13 ? .a(bIndex) : .d(dIndex)
    }

    /// Is the point inside the generous hit zone of a button (outer ring around the button)?
    public static func buttonHit(_ b: Int, _ p: Vec2) -> Bool {
        let r = p.length
        guard r > 0.5 && r < 1.45 else { return false }
        var d = abs(p.clockAngle - Geometry.buttonAngle(b)).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return d <= 22.5
    }

    /// Hit test for touch notes: close to the area's centre (or inside the area).
    public static func touchHit(_ a: TouchArea, _ p: Vec2) -> Bool {
        if a.isCenter { return p.length < 0.36 }
        if area(at: p) == a { return true }
        return p.distance(to: position(a)) < 0.24
    }
}

public struct PlaySlide: Codable {
    public var startTime: Double   // movement start (star tap + delay)
    public var duration: Double
    public var points: [Vec2]      // polyline of the path
    public var cumulative: [Double]
    public var isBreak: Bool
    public var isEach: Bool
    public var shapes: String      // e.g. "-5" for display/debug
    /// Index of the polyline drawn as "fan" side branches (w slides) - optional extras
    public var extraBranches: [[Vec2]] = []

    public var endTime: Double { startTime + duration }
    public var totalLength: Double { cumulative.last ?? 0 }

    public func point(atDistance d: Double) -> Vec2 {
        guard points.count > 1 else { return points.first ?? Vec2(0, 0) }
        let dd = max(0, min(totalLength, d))
        var lo = 0, hi = cumulative.count - 1
        while lo < hi - 1 { let m = (lo + hi) / 2; if cumulative[m] <= dd { lo = m } else { hi = m } }
        let seg = cumulative[hi] - cumulative[lo]
        let f = seg > 0 ? (dd - cumulative[lo]) / seg : 0
        return points[lo] + (points[hi] - points[lo]) * f
    }

    /// Unit tangent of the path at a distance (for star/arrow orientation).
    public func direction(atDistance d: Double) -> Vec2 {
        let a = point(atDistance: d - 0.01), b = point(atDistance: d + 0.01)
        let v = b - a
        let l = v.length
        return l > 0 ? v * (1 / l) : Vec2(0, -1)
    }
}

public struct PlayNote: Identifiable, Codable {
    public enum Kind: String, Codable { case tap, hold, star, touch, touchHold }
    public var id: Int
    public var kind: Kind
    public var time: Double
    public var length: Double
    public var button: Int?
    public var area: TouchArea?
    public var isBreak: Bool
    public var isEx: Bool
    public var isEach: Bool
    public var firework: Bool
    public var headless: Bool
    public var slides: [PlaySlide]

    public var endTime: Double {
        var e = time + length
        for s in slides { e = max(e, s.endTime) }
        return e
    }

    public var position: Vec2 {
        if let a = area { return SensorLayout.position(a) }
        return Vec2.polar(angle: Geometry.buttonAngle(button ?? 1), radius: 1)
    }
}

public struct PlayChart: Codable {
    public var notes: [PlayNote]
    public var bpmChanges: [Double]
    public var finishTime: Double

    /// Builds a playable chart from parsed simai (times relative to chart start).
    public init(_ parsed: SimaiParsedChart) {
        var out: [PlayNote] = []
        var id = 0
        for n in parsed.notes {
            let each = n.eachCount > 1 && !n.forceBrokenEach
            var slides: [PlaySlide] = []
            if case .button(let b) = n.location {
                for s in n.slides {
                    let (pts, extra) = SlideGeometry.path(start: b, segments: s.segments)
                    var cum: [Double] = [0]
                    for i in 1..<max(1, pts.count) { cum.append(cum[i - 1] + pts[i].distance(to: pts[i - 1])) }
                    slides.append(PlaySlide(startTime: n.time + s.delay, duration: max(0.01, s.duration), points: pts, cumulative: cum,
                                            isBreak: s.isBreak, isEach: each, shapes: s.segments.map { $0.simai }.joined(), extraBranches: extra))
                }
            }
            let kind: PlayNote.Kind
            switch n.location {
            case .button:
                if !n.slides.isEmpty || n.isStar { kind = .star } else if n.holdLength != nil { kind = .hold } else { kind = .tap }
            case .sensor:
                kind = n.holdLength != nil ? .touchHold : .touch
            }
            out.append(PlayNote(id: id, kind: kind, time: n.time, length: kind == .hold || kind == .touchHold ? (n.holdLength ?? 0) : 0,
                                button: n.location.buttonIndex, area: n.location.area, isBreak: n.isBreak, isEx: n.isEx, isEach: each,
                                firework: n.firework, headless: n.headless, slides: slides))
            id += 1
        }
        notes = out.sorted { $0.time < $1.time }
        bpmChanges = parsed.bpmChanges.map { $0.bpm }
        finishTime = max(parsed.finishTime, notes.map { $0.endTime }.max() ?? 0)
    }
}

/// Approximate maimai slide shapes as polylines.
public enum SlideGeometry {
    static func ring(_ b: Int) -> Vec2 { Vec2.polar(angle: Geometry.buttonAngle(b), radius: 1) }

    static func arc(center: Vec2, radius: Double, from a0: Double, to a1: Double, clockwise: Bool, steps: Int = 48) -> [Vec2] {
        var sweep = a1 - a0
        if clockwise { while sweep <= 0 { sweep += 360 } } else { while sweep >= 0 { sweep -= 360 } }
        let n = max(2, Int(abs(sweep) / 360 * Double(steps)) + 1)
        return (0...n).map { i in center + Vec2.polar(angle: a0 + sweep * Double(i) / Double(n), radius: radius) }
    }

    /// Clockwise flag for ring slides (`>`, `<`, `^`), following SimaiSharp's rules.
    static func ringClockwise(_ shape: String, start: Int, end: Int) -> Bool {
        let si = start - 1, ei = end - 1
        switch shape {
        case ">": return (si + 2) % 8 >= 4 ? false : true
        case "<": return (si + 2) % 8 >= 4 ? true : false
        default:
            let diff = ei - si
            let rotation = diff >= 0 ? (diff > 4 ? -1 : 1) : (diff < -4 ? 1 : -1)
            return rotation > 0
        }
    }

    public static func path(start: Int, segments: [SlideSegment]) -> ([Vec2], [[Vec2]]) {
        var pts: [Vec2] = [ring(start)]
        var extra: [[Vec2]] = []
        var cur = start
        for seg in segments {
            let e = seg.end
            let p0 = ring(cur), p1 = ring(e)
            let a0 = Geometry.buttonAngle(cur), a1 = Geometry.buttonAngle(e)
            var part: [Vec2] = []
            switch seg.shape {
            case "-":
                part = [p0, p1]
            case ">", "<", "^":
                part = arc(center: Vec2(0, 0), radius: 1, from: a0, to: cur == e && seg.shape != "^" ? a0 + (ringClockwise(seg.shape, start: cur, end: e) ? 359.9 : -359.9) : a1,
                           clockwise: ringClockwise(seg.shape, start: cur, end: e))
            case "v":
                part = [p0, Vec2(0, 0), p1]
            case "V":
                // grand V: straight to the first vertex on the ring, then to the target
                let mid = seg.vertices.count >= 2 ? seg.vertices[0] : Geometry.wrap(cur + 2)
                part = [p0, ring(mid), p1]
            case "p", "q":
                // curl around a small inner circle (p = counter-clockwise, q = clockwise)
                let cw = seg.shape == "q"
                let r = 0.45
                let entry = a0 + (cw ? 70 : -70)
                let exit = a1 + (cw ? -70 : 70)
                part = [p0] + arc(center: Vec2(0, 0), radius: r, from: entry, to: exit, clockwise: cw) + [p1]
            case "pp", "qq":
                // larger loop through an offset circle
                let cw = seg.shape == "qq"
                let c = Vec2.polar(angle: a0 + (cw ? 112.5 : -112.5), radius: 0.45)
                let r = 0.55
                let startAng = (p0 - c).clockAngle
                let endAng = (p1 - c).clockAngle
                part = [p0] + arc(center: c, radius: r, from: startAng, to: endAng, clockwise: cw) + [p1]
            case "s", "z":
                // zigzag through the centre
                let perp = a0 + (seg.shape == "s" ? 90 : -90)
                let q1 = Vec2.polar(angle: perp, radius: 0.42) + p0 * 0.12
                let q2 = Vec2.polar(angle: perp + 180, radius: 0.42) + p1 * 0.12
                part = [p0, q1, q2, p1]
            case "w":
                // fan: judged along the centre branch, side branches drawn
                part = [p0, p1]
                extra.append([p0, ring(Geometry.wrap(e - 1))])
                extra.append([p0, ring(Geometry.wrap(e + 1))])
            default:
                part = [p0, p1]
            }
            pts.append(contentsOf: part.dropFirst())
            cur = e
        }
        return (pts, extra)
    }
}
