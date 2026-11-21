import Foundation

/// Two-hand ergonomic model used to keep generated charts humanly playable.
public struct HandModel {
    public var base: Double      // seconds needed to re-hit the same spot with one hand
    public var perStep: Double   // extra seconds per button step travelled
    public var maxSimultaneous: Int = 2

    public static func model(for d: Difficulty) -> HandModel {
        switch d {
        case .easy: return HandModel(base: 0.40, perStep: 0.05)
        case .basic: return HandModel(base: 0.26, perStep: 0.045)
        case .advanced: return HandModel(base: 0.17, perStep: 0.035)
        case .expert: return HandModel(base: 0.115, perStep: 0.028)
        case .master: return HandModel(base: 0.088, perStep: 0.022)
        case .remaster: return HandModel(base: 0.068, perStep: 0.018)
        }
    }

    /// Required time for one hand to move between two angles (degrees, -1 = centre).
    public func required(from a: Double, to b: Double) -> Double {
        base + perStep * HandModel.steps(a, b)
    }

    /// Distance in "button steps" (45°) between two angles; centre counts as 2 steps from the rim.
    public static func steps(_ a: Double, _ b: Double) -> Double {
        if a < 0 && b < 0 { return 0 }
        if a < 0 || b < 0 { return 2 }
        var d = abs(a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return d / 45
    }

    /// Natural hand for an angle: right hand for 0..180 (buttons 1-4), left for 180..360.
    public static func naturalHand(_ angle: Double) -> Int? {
        if angle < 0 { return nil }
        let a = angle.truncatingRemainder(dividingBy: 360)
        if abs(a) < 1e-6 || abs(a - 180) < 1e-6 { return nil } // top/bottom centre: either hand
        return a < 180 ? 1 : 0
    }
}

public struct PlayabilityReport: CustomStringConvertible {
    public var tooManySimultaneous = 0
    public var handSpeedViolations = 0
    public var busyHandViolations = 0
    public var overlappingSameButton = 0
    public var unequalEachHolds = 0
    public var maxSimultaneous = 0

    public var isPlayable: Bool {
        tooManySimultaneous == 0 && handSpeedViolations == 0 && busyHandViolations == 0 && overlappingSameButton == 0
    }

    public var description: String {
        "simul>2: \(tooManySimultaneous), speed: \(handSpeedViolations), busyHand: \(busyHandViolations), overlap: \(overlappingSameButton), unequalEachHolds: \(unequalEachHolds)"
    }
}

/// Greedy two-hand simulator shared by the checker and the generator's repair pass,
/// so "playable" means the same thing everywhere.
public struct HandSimulator {
    public struct Hand { public var angle: Double; public var lastTime: Double = -10; public var busyUntil: Double = -10 }
    public var model: HandModel
    public var hands: [Hand] = [Hand(angle: 292.5), Hand(angle: 67.5)] // left, right

    public init(model: HandModel) { self.model = model }

    public struct Placement {
        public var hands: [Int]      // hand per note (same order as the group)
        public var slack: [Double]   // seconds of spare time per note (negative = too fast)
        public var feasible: Bool    // enough free hands
        public var minSlack: Double { slack.min() ?? 0 }
    }

    /// Chooses the best assignment of the notes to free hands without mutating state.
    public func evaluate(angles: [Double], at t: Double) -> Placement {
        let free = [0, 1].filter { hands[$0].busyUntil <= t + 0.03 }
        guard angles.count <= free.count, !angles.isEmpty else {
            return Placement(hands: [], slack: [], feasible: angles.isEmpty)
        }
        func slack(_ h: Int, _ a: Double) -> Double {
            (t - hands[h].lastTime) - model.required(from: hands[h].angle, to: a)
        }
        var best: Placement? = nil
        var bestScore = -Double.infinity
        let perms: [[Int]] = angles.count == 1 ? free.map { [$0] } : [[free[0], free[1]], [free[1], free[0]]]
        for p in perms {
            let sl = zip(p, angles).map { slack($0.0, $0.1) }
            var score = sl.min() ?? 0
            for (h, a) in zip(p, angles) where HandModel.naturalHand(a) == h { score += 0.03 }
            if score > bestScore { bestScore = score; best = Placement(hands: p, slack: sl, feasible: true) }
        }
        return best!
    }

    public mutating func commit(_ placement: Placement, angles: [Double], at t: Double, ends: [Double?]) {
        for (k, h) in placement.hands.enumerated() {
            hands[h].angle = angles[k]
            hands[h].lastTime = t
            if let e = ends[k] { hands[h].busyUntil = e; hands[h].lastTime = e }
        }
    }
}

public enum PlayabilityChecker {
    /// Simulates both hands over the chart and counts ergonomic violations.
    public static func check(_ notes: [ChartNote], tempo: TempoMap, difficulty: Difficulty, tolerance: Double = 0.004) -> PlayabilityReport {
        var r = PlayabilityReport()
        var sim = HandSimulator(model: HandModel.model(for: difficulty))
        let groups = Dictionary(grouping: notes, by: { $0.tick }).sorted { $0.key < $1.key }
        func t(_ tick: Int) -> Double { tempo.time(atBeat: Double(tick) / Double(ticksPerBeat)) }
        var heldButtons: [Int: Double] = [:]
        for (tick, group) in groups {
            let time = t(tick)
            r.maxSimultaneous = max(r.maxSimultaneous, group.count)
            if group.count > sim.model.maxSimultaneous { r.tooManySimultaneous += 1; continue }
            let holdLens = group.compactMap { n -> Int? in
                switch n.kind {
                case .hold(_, let l), .touchHold(_, let l): return l
                default: return nil
                }
            }
            if holdLens.count == 2 && holdLens[0] != holdLens[1] { r.unequalEachHolds += 1 }
            for n in group {
                if let b = n.button, let until = heldButtons[b], until > time + 1e-6 { r.overlappingSameButton += 1 }
            }
            let angles = group.map { $0.angle }
            let p = sim.evaluate(angles: angles, at: time)
            if !p.feasible { r.busyHandViolations += 1; continue }
            if p.minSlack < -tolerance { r.handSpeedViolations += 1 }
            sim.commit(p, angles: angles, at: time, ends: group.map { $0.occupiedLength > 0 ? t($0.endTick) : nil })
            for n in group { if let b = n.button, n.isHoldLike { heldButtons[b] = t(n.endTick) } }
        }
        return r
    }
}

/// Estimates an arcade-style level from chart density and complexity.
public enum LevelEstimator {
    public struct Stats {
        public var objects: Int
        public var avgNPS: Double
        public var peakNPS: Double
        public var eachRatio: Double
        public var touchRatio: Double
        public var holdRatio: Double
        public var slideCount: Int
        public var breakCount: Int
    }

    public static func stats(_ notes: [ChartNote], tempo: TempoMap) -> Stats {
        guard !notes.isEmpty else { return Stats(objects: 0, avgNPS: 0, peakNPS: 0, eachRatio: 0, touchRatio: 0, holdRatio: 0, slideCount: 0, breakCount: 0) }
        let times = Set(notes.map { $0.tick }).map { tempo.time(atBeat: Double($0) / Double(ticksPerBeat)) }.sorted()
        let span = max(4, (times.last! - times.first!))
        var objects = 0, slides = 0, holds = 0, touches = 0, breaks = 0
        for n in notes {
            objects += 1
            switch n.kind {
            case .slide: slides += 1; objects += 1
            case .hold, .touchHold: holds += 1
            default: break
            }
            if n.isTouch { touches += 1 }
            if n.isBreak { breaks += 1 }
        }
        let byTick = Dictionary(grouping: notes, by: { $0.tick })
        let eachNotes = byTick.values.filter { $0.count > 1 }.reduce(0) { $0 + $1.count }
        // peak density over 2 s windows
        var peak = 0.0
        var j = 0
        for i in 0..<times.count {
            while times[i] - times[j] > 2.0 { j += 1 }
            peak = max(peak, Double(i - j + 1) / 2.0)
        }
        let hits = Double(times.count) + Double(slides)
        return Stats(objects: objects, avgNPS: hits / span, peakNPS: peak,
                     eachRatio: Double(eachNotes) / Double(notes.count), touchRatio: Double(touches) / Double(notes.count),
                     holdRatio: Double(holds) / Double(notes.count), slideCount: slides, breakCount: breaks)
    }

    /// Returns (display string, internal value).
    public static func estimate(_ notes: [ChartNote], tempo: TempoMap, difficulty: Difficulty) -> (String, Double) {
        let s = stats(notes, tempo: tempo)
        let density = 0.6 * s.avgNPS + 0.4 * s.peakNPS * 0.75
        let complexity = 1 + 0.25 * s.eachRatio + 0.2 * s.touchRatio + 0.08 * min(1, Double(s.slideCount) / 20)
        let d = density * complexity
        // piecewise linear calibration (hit density -> level), tuned against typical arcade charts
        let table: [(Double, Double)] = [(0, 1), (0.9, 2), (1.4, 3.5), (1.9, 5), (2.4, 6.3), (2.9, 7.4), (3.4, 8.4), (3.9, 9.3),
                                         (4.5, 10.3), (5.1, 11.2), (5.8, 12.1), (6.5, 12.8), (7.2, 13.4), (8.0, 13.8), (9.0, 14.3), (10.2, 14.8), (12, 15)]
        var level = 15.0
        for k in 0..<(table.count - 1) where d <= table[k + 1].0 {
            let (x0, y0) = table[k], (x1, y1) = table[k + 1]
            level = y0 + (y1 - y0) * (d - x0) / (x1 - x0)
            break
        }
        let range: ClosedRange<Double>
        switch difficulty {
        case .easy: range = 1...4.5
        case .basic: range = 2...7.6
        case .advanced: range = 4...10.6
        case .expert: range = 6.5...12.9
        case .master: range = 9...14.9
        case .remaster: range = 10...15
        }
        level = min(range.upperBound, max(range.lowerBound, level))
        level = (level * 10).rounded() / 10
        return (display(level), level)
    }

    public static func display(_ v: Double) -> String {
        let whole = Int(v.rounded(.down))
        let frac = v - Double(whole)
        if whole >= 7 && frac >= 0.65 { return "\(whole)+" }
        return "\(whole)"
    }
}
