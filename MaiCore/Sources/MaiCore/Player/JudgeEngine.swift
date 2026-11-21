import Foundation

public enum Judgment: Int, Codable, CaseIterable, Comparable {
    case miss = 0, good, great, perfect, criticalPerfect

    public static func < (a: Judgment, b: Judgment) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .criticalPerfect: return "CRITICAL PERFECT"
        case .perfect: return "PERFECT"
        case .great: return "GREAT"
        case .good: return "GOOD"
        case .miss: return "MISS"
        }
    }
    public var shortLabel: String {
        switch self {
        case .criticalPerfect: return "CRITICAL"
        case .perfect: return "PERFECT"
        case .great: return "GREAT"
        case .good: return "GOOD"
        case .miss: return "MISS"
        }
    }
}

public struct JudgmentEvent: Codable {
    public var noteID: Int
    public var slideIndex: Int?   // nil = the note head / body
    public var judgment: Judgment
    public var offset: Double     // seconds, negative = early (FAST)
    public var time: Double
    public var position: Vec2
    public var isBreak: Bool
}

/// Timing windows (seconds).
public struct JudgeWindows {
    public var tap: [Double] = [0.0167, 0.0333, 0.0833, 0.15]       // CP, P, GREAT, GOOD
    public var touch: [Double] = [0.0333, 0.05, 0.1, 0.15]
    public var slide: [Double] = [0.12, 0.22, 0.36, 0.6]
    public static let standard = JudgeWindows()

    func judge(_ dt: Double, _ w: [Double]) -> Judgment? {
        let a = abs(dt)
        if a <= w[0] { return .criticalPerfect }
        if a <= w[1] { return .perfect }
        if a <= w[2] { return .great }
        if a <= w[3] { return .good }
        return nil
    }
}

/// Real-time judgement and scoring (maimai DX style achievement up to 101%).
public final class JudgeEngine {
    public let chart: PlayChart
    public var windows = JudgeWindows.standard
    /// Seconds added to every input (positive = player hits late and wants it compensated).
    public var inputOffset: Double = 0

    struct NoteState {
        var headDone = false
        var headJudgment: Judgment? = nil
        var headOffset = 0.0
        var holding = false
        var heldTime = 0.0
        var lastHoldCheck: Double? = nil
        var bodyDone = false
        var slideProgress: [Int] = []
        var slideDone: [Bool] = []
        var holdingTouch: Int? = nil
    }

    var states: [NoteState]
    public private(set) var events: [JudgmentEvent] = []
    public private(set) var combo = 0
    public private(set) var maxCombo = 0
    public private(set) var counts: [Judgment: Int] = [:]
    public private(set) var fastCount = 0
    public private(set) var lateCount = 0
    var earned = 0.0, bonusEarned = 0.0
    let maxBase: Double
    let maxBonus: Double
    var nextIndex = 0
    var slideCheckpoints: [[[Vec2]]] = []

    public init(chart: PlayChart) {
        self.chart = chart
        states = chart.notes.map { n in
            var s = NoteState()
            s.slideProgress = Array(repeating: 0, count: n.slides.count)
            s.slideDone = Array(repeating: false, count: n.slides.count)
            if n.headless { s.headDone = true }
            if n.kind != .hold && n.kind != .touchHold { s.bodyDone = true }
            return s
        }
        var base = 0.0, bonus = 0.0
        for n in chart.notes {
            if !n.headless { base += JudgeEngine.weight(n.kind, isBreak: n.isBreak); if n.isBreak { bonus += 1 } }
            for s in n.slides { base += s.isBreak ? 2500 : 1500; if s.isBreak { bonus += 1 } }
        }
        maxBase = max(1, base)
        maxBonus = bonus
        slideCheckpoints = chart.notes.map { n in
            n.slides.map { s in
                let step = 0.16
                var cps: [Vec2] = []
                var d = step
                while d < s.totalLength { cps.append(s.point(atDistance: d)); d += step }
                cps.append(s.point(atDistance: s.totalLength))
                return cps
            }
        }
    }

    static func weight(_ k: PlayNote.Kind, isBreak: Bool) -> Double {
        if isBreak { return 2500 }
        switch k {
        case .tap, .star, .touch: return 500
        case .hold, .touchHold: return 1000
        }
    }

    // MARK: Results

    public var totalObjects: Int { chart.notes.reduce(0) { $0 + ($1.headless ? 0 : 1) + $1.slides.count } }
    public var judgedObjects: Int { events.count }

    /// Achievement percentage (0...101).
    public var achievement: Double {
        100 * earned / maxBase + (maxBonus > 0 ? bonusEarned / maxBonus : 0)
    }

    public var dxScore: Int {
        events.reduce(0) { acc, e in
            switch e.judgment { case .criticalPerfect: return acc + 3; case .perfect: return acc + 2; case .great: return acc + 1; default: return acc }
        }
    }
    public var maxDXScore: Int { totalObjects * 3 }

    public static func rank(_ a: Double) -> String {
        switch a {
        case 100.5...: return "SSS+"
        case 100...: return "SSS"
        case 99.5...: return "SS+"
        case 99...: return "SS"
        case 98...: return "S+"
        case 97...: return "S"
        case 94...: return "AAA"
        case 90...: return "AA"
        case 80...: return "A"
        case 75...: return "BBB"
        case 70...: return "BB"
        case 60...: return "B"
        case 50...: return "C"
        default: return "D"
        }
    }

    public var isFinished: Bool { states.allSatisfy { $0.headDone && $0.bodyDone && $0.slideDone.allSatisfy { $0 } } }
    public var fullCombo: Bool { isFinished && (counts[.miss] ?? 0) == 0 }
    public var allPerfect: Bool { isFinished && events.allSatisfy { $0.judgment >= .perfect } }

    // MARK: Scoring

    func record(_ noteIndex: Int, slide: Int?, _ j: Judgment, offset: Double, time: Double, position: Vec2) {
        let n = chart.notes[noteIndex]
        let isBreak = slide.map { n.slides[$0].isBreak } ?? n.isBreak
        let base: Double = slide != nil ? (isBreak ? 2500 : 1500) : JudgeEngine.weight(n.kind, isBreak: isBreak)
        let rate: Double
        switch j {
        case .criticalPerfect: rate = 1
        case .perfect: rate = isBreak ? 1 : 1
        case .great: rate = 0.8
        case .good: rate = isBreak ? 0.4 : 0.5
        case .miss: rate = 0
        }
        earned += base * rate
        if isBreak {
            switch j {
            case .criticalPerfect: bonusEarned += 1
            case .perfect: bonusEarned += 0.75
            case .great: bonusEarned += 0.4
            case .good: bonusEarned += 0.3
            case .miss: break
            }
        }
        counts[j, default: 0] += 1
        if j == .miss { combo = 0 } else { combo += 1; maxCombo = max(maxCombo, combo) }
        if j != .miss && j != .criticalPerfect {
            if offset < 0 { fastCount += 1 } else if offset > 0 { lateCount += 1 }
        }
        events.append(JudgmentEvent(noteID: n.id, slideIndex: slide, judgment: j, offset: offset, time: time, position: position, isBreak: isBreak))
    }

    // MARK: Input

    /// A finger touched the screen at `p` (unit coordinates) at chart time `t`.
    @discardableResult
    public func touchDown(_ p: Vec2, at rawT: Double) -> JudgmentEvent? {
        let t = rawT + inputOffset
        var best: Int? = nil
        var bestDt = Double.infinity
        let maxWin = max(windows.tap[3], windows.touch[3])
        var i = nextIndex
        while i < chart.notes.count && chart.notes[i].time <= t + maxWin {
            let n = chart.notes[i]
            if !states[i].headDone {
                let dt = t - n.time
                let win = (n.kind == .touch || n.kind == .touchHold) ? windows.touch : windows.tap
                if dt >= -win[3] && dt <= win[3] {
                    let hit: Bool
                    if let b = n.button { hit = SensorLayout.buttonHit(b, p) } else if let a = n.area { hit = SensorLayout.touchHit(a, p) } else { hit = false }
                    if hit && abs(dt) < bestDt { bestDt = abs(dt); best = i }
                }
            }
            i += 1
        }
        guard let bi = best else { return nil }
        let n = chart.notes[bi]
        let dt = t - n.time
        let win = (n.kind == .touch || n.kind == .touchHold) ? windows.touch : windows.tap
        let j = windows.judge(dt, win) ?? .good
        states[bi].headDone = true
        states[bi].headJudgment = j
        states[bi].headOffset = dt
        if n.kind == .hold || n.kind == .touchHold {
            states[bi].holding = true
            states[bi].lastHoldCheck = t
            return nil // judged when the hold ends
        }
        record(bi, slide: nil, j, offset: dt, time: t, position: n.position)
        return events.last
    }

    /// Current finger positions (for holds and slide tracing).
    public func touches(_ points: [Vec2], at rawT: Double) {
        let t = rawT + inputOffset
        for i in chart.notes.indices where chart.notes[i].time <= t + 0.2 {
            let n = chart.notes[i]
            // holds: count time while a finger is on the hold's zone
            if (n.kind == .hold || n.kind == .touchHold) && states[i].holding && !states[i].bodyDone {
                let inside = points.contains { p in
                    if let b = n.button { return SensorLayout.buttonHit(b, p) }
                    if let a = n.area { return SensorLayout.touchHit(a, p) }
                    return false
                }
                if let last = states[i].lastHoldCheck {
                    let from = max(last, n.time), to = min(t, n.time + n.length)
                    if inside && to > from { states[i].heldTime += to - from }
                }
                states[i].lastHoldCheck = t
            }
            // slides: advance along checkpoints
            for (si, s) in n.slides.enumerated() where !states[i].slideDone[si] && t >= s.startTime - 0.25 {
                let cps = slideCheckpoints[i][si]
                var prog = states[i].slideProgress[si]
                var advanced = true
                while advanced && prog < cps.count {
                    advanced = false
                    for k in prog..<min(cps.count, prog + 3) where points.contains(where: { $0.distance(to: cps[k]) < 0.27 }) {
                        prog = k + 1
                        advanced = true
                        break
                    }
                }
                states[i].slideProgress[si] = prog
                if prog >= cps.count {
                    states[i].slideDone[si] = true
                    // an ideal tracer enters the final checkpoint's radius slightly before the path ends
                    let ideal = s.endTime - s.duration * min(0.5, 0.27 / max(0.01, s.totalLength))
                    let dt = t - ideal
                    let j: Judgment
                    if dt < -s.duration * 0.6 - 0.2 { j = .good } else { j = windows.judge(dt, windows.slide) ?? .good }
                    record(i, slide: si, j, offset: dt, time: t, position: s.point(atDistance: s.totalLength))
                }
            }
        }
    }

    /// Advances time: emits misses and finishes holds.
    public func update(_ rawT: Double) {
        let t = rawT + inputOffset
        while nextIndex < chart.notes.count, states[nextIndex].headDone && states[nextIndex].bodyDone && states[nextIndex].slideDone.allSatisfy({ $0 }) {
            nextIndex += 1
        }
        for i in nextIndex..<chart.notes.count {
            let n = chart.notes[i]
            if n.time > t + 0.2 { break }
            if !states[i].headDone {
                let win = (n.kind == .touch || n.kind == .touchHold) ? windows.touch : windows.tap
                if t - n.time > win[3] {
                    states[i].headDone = true
                    states[i].headJudgment = .miss
                    if n.kind == .hold || n.kind == .touchHold {
                        states[i].bodyDone = true
                    }
                    record(i, slide: nil, .miss, offset: win[3], time: t, position: n.position)
                }
            }
            if (n.kind == .hold || n.kind == .touchHold) && states[i].holding && !states[i].bodyDone && t >= n.time + n.length {
                states[i].bodyDone = true
                states[i].holding = false
                let ratio = n.length > 0 ? states[i].heldTime / n.length : 1
                var j = states[i].headJudgment ?? .good
                if ratio < 0.25 { j = .good } else if ratio < 0.6 { j = min(j, .great) } else if ratio < 0.85 { j = min(j, .perfect) }
                record(i, slide: nil, j, offset: states[i].headOffset, time: t, position: n.position)
            }
            for (si, s) in n.slides.enumerated() where !states[i].slideDone[si] && t > s.endTime + windows.slide[3] {
                states[i].slideDone[si] = true
                // partially traced slides still score GOOD
                let cps = slideCheckpoints[i][si].count
                let j: Judgment = states[i].slideProgress[si] * 2 >= cps ? .good : .miss
                record(i, slide: si, j, offset: windows.slide[3], time: t, position: s.point(atDistance: s.totalLength))
            }
        }
    }

    /// Releases every hold that is no longer touched (call when all fingers lift).
    public func releaseAll(at rawT: Double) {
        touches([], at: rawT)
    }

    // MARK: Autoplay

    /// Perfect inputs for the window (lastT, t]: returns the positions to visualise as "virtual fingers".
    public func autoplay(_ rawT: Double) -> [Vec2] {
        let t = rawT + inputOffset
        var fingers: [Vec2] = []
        for i in nextIndex..<chart.notes.count {
            let n = chart.notes[i]
            if n.time > t + 0.001 { break }
            if !states[i].headDone && t >= n.time {
                _ = touchDown(n.position, at: n.time - inputOffset)
            }
            if (n.kind == .hold || n.kind == .touchHold) && t <= n.time + n.length { fingers.append(n.position) }
            for s in n.slides where t >= s.startTime && t <= s.endTime + 0.05 {
                let f = max(0, min(1, (t - s.startTime) / s.duration))
                fingers.append(s.point(atDistance: s.totalLength * f))
            }
        }
        touches(fingers, at: rawT)
        update(rawT)
        return fingers
    }

    /// Slide progress (0...1) of the player's tracing for drawing consumed arrows.
    public func slideProgress(note: Int, slide: Int) -> Double {
        let cps = slideCheckpoints[note][slide].count
        return cps > 0 ? Double(states[note].slideProgress[slide]) / Double(cps) : 0
    }

    public func isJudged(note: Int) -> Bool { states[note].headDone && states[note].bodyDone }
    public func isHolding(note: Int) -> Bool { states[note].holding && !states[note].bodyDone }
    public func headJudged(note: Int) -> Bool { states[note].headDone }
}
