import Foundation

/// Song metadata + all difficulties, serialised as an AstroDX/simai `maidata.txt`.
public struct Maidata {
    public var title: String
    public var artist: String
    public var designer: String
    public var timing: ChartTiming
    public var charts: [Chart]
    public var extraFields: [(String, String)] = []

    public init(title: String, artist: String, designer: String = "MaiChart Studio", timing: ChartTiming, charts: [Chart]) {
        self.title = title
        self.artist = artist
        self.designer = designer
        self.timing = timing
        self.charts = charts
    }

    /// Produces the maidata text. Lines never start with '&' inside chart bodies.
    public func text() -> String {
        var lines: [String] = []
        lines.append("&title=\(Self.clean(title))")
        lines.append("&artist=\(Self.clean(artist))")
        lines.append("&des=\(Self.clean(designer))")
        lines.append("&first=\(SimaiWriter.format(timing.first, decimals: 4))")
        let whole = timing.tempo.dominantBPM(untilBeat: timing.endBeat)
        lines.append("&wholebpm=\(SimaiWriter.formatBPM(whole))")
        for (k, v) in extraFields { lines.append("&\(k)=\(Self.clean(v))") }
        for chart in charts.sorted(by: { $0.difficulty < $1.difficulty }) {
            let n = chart.difficulty.rawValue
            lines.append("&lv_\(n)=\(chart.level)")
            lines.append("&des_\(n)=\(Self.clean(chart.designer.isEmpty ? designer : chart.designer))")
        }
        for chart in charts.sorted(by: { $0.difficulty < $1.difficulty }) {
            let n = chart.difficulty.rawValue
            lines.append("&inote_\(n)=" + SimaiWriter.write(chart.notes, timing: timing))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// UTF-8 with BOM so AstroDX's encoding sniffer always picks UTF-8 (titles may be Japanese/Filipino/etc.).
    public func data() -> Data {
        var d = Data([0xEF, 0xBB, 0xBF])
        d.append(text().data(using: .utf8)!)
        return d
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "&", with: "＆").trimmingCharacters(in: .whitespaces)
    }
}

public enum SimaiWriter {
    static let wholeTicks = 4 * ticksPerBeat // 384
    static let divisions = [1, 2, 4, 8, 16, 32, 3, 6, 12, 24, 48, 64, 96, 128, 192, 384]

    public static func format(_ v: Double, decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    public static func formatBPM(_ bpm: Double) -> String { format(bpm, decimals: 4) }

    /// Serialises the notes of one chart (body of &inote_N), ending with "E".
    public static func write(_ notes: [ChartNote], timing: ChartTiming) -> String {
        let tempo = timing.tempo
        let lastNoteTick = notes.map { $0.endTick }.max() ?? 0
        let endBeat = max(timing.endBeat, Double(lastNoteTick) / Double(ticksPerBeat) + 1)
        let bars = BarLayout.bars(timeSignatures: timing.timeSignatures, endBeat: endBeat)
        var byTick: [Int: [ChartNote]] = [:]
        for n in notes { byTick[n.tick, default: []].append(n) }

        // tempo change ticks
        var tempoTicks: [(tick: Int, bpm: Double)] = tempo.segments.map { (Int(($0.startBeat * Double(ticksPerBeat)).rounded()), $0.bpm) }
        tempoTicks.sort { $0.tick < $1.tick }

        var out = ""
        var currentBPM: Double? = nil
        var currentDiv: Int? = nil
        let lastBarNeeded = bars.lastIndex { Int(($0.startBeat * Double(ticksPerBeat)).rounded()) <= max(lastNoteTick, 0) } ?? 0

        for (bi, bar) in bars.enumerated() where bi <= lastBarNeeded + 1 {
            let barStart = Int((bar.startBeat * Double(ticksPerBeat)).rounded())
            let barEnd = Int((bar.endBeat * Double(ticksPerBeat)).rounded())
            // split at tempo changes
            var cuts = [barStart]
            for t in tempoTicks where t.tick > barStart && t.tick < barEnd { cuts.append(t.tick) }
            cuts.append(barEnd)
            var line = ""
            for ci in 0..<(cuts.count - 1) {
                let s = cuts[ci], e = cuts[ci + 1]
                let bpm = tempo.bpm(atBeat: Double(s) / Double(ticksPerBeat) + 1e-9)
                let rel = byTick.keys.filter { $0 >= s && $0 < e }.map { $0 - s }
                let div = chooseDivision(span: e - s, offsets: rel)
                let step = wholeTicks / div
                if currentBPM == nil || abs(currentBPM! - bpm) > 1e-9 {
                    line += "(\(formatBPM(bpm)))"
                    currentBPM = bpm
                }
                if currentDiv != div {
                    line += "{\(div)}"
                    currentDiv = div
                }
                var t = s
                while t < e {
                    if let group = byTick[t] {
                        line += group.sorted(by: noteOrder).map { noteString($0, tempo: tempo) }.joined(separator: "/")
                    }
                    line += ","
                    t += step
                }
            }
            out += line + "\n"
        }
        out += "E\n"
        return out
    }

    static func noteOrder(_ a: ChartNote, _ b: ChartNote) -> Bool {
        func key(_ n: ChartNote) -> (Int, Int) {
            if let btn = n.button { return (0, btn) }
            if let t = n.touchArea { return (1, t.index + (t.isCenter ? 100 : 0)) }
            return (2, 0)
        }
        return key(a) < key(b)
    }

    /// Smallest standard division (per whole note) that places every offset exactly.
    static func chooseDivision(span: Int, offsets: [Int]) -> Int {
        let candidates = divisions.sorted()
        for d in candidates {
            let step = wholeTicks / d
            guard wholeTicks % d == 0, span % step == 0 else { continue }
            if offsets.allSatisfy({ $0 % step == 0 }) { return d }
        }
        return 384
    }

    static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? abs(a) : gcd(b, a % b) }

    /// Duration token body: "x:y" when representable at the start tempo, otherwise explicit seconds.
    static func durationToken(startTick: Int, lengthTicks: Int, tempo: TempoMap) -> String {
        let length = max(1, lengthTicks)
        let startBeat = Double(startTick) / Double(ticksPerBeat)
        let endBeat = Double(startTick + length) / Double(ticksPerBeat)
        let constant = tempo.segmentIndex(atBeat: startBeat + 1e-9) == tempo.segmentIndex(atBeat: endBeat - 1e-9)
        if constant {
            let g = gcd(length, wholeTicks)
            return "\(wholeTicks / g):\(length / g)"
        }
        let secs = tempo.time(atBeat: endBeat) - tempo.time(atBeat: startBeat)
        return "#" + format(secs, decimals: 4)
    }

    public static func noteString(_ n: ChartNote, tempo: TempoMap) -> String {
        var s = ""
        switch n.kind {
        case .tap(let b):
            s = "\(Geometry.wrap(b))"
            if n.isBreak { s += "b" }
            if n.isEx { s += "x" }
        case .hold(let b, let len):
            s = "\(Geometry.wrap(b))"
            if n.isBreak { s += "b" }
            if n.isEx { s += "x" }
            s += "h[" + durationToken(startTick: n.tick, lengthTicks: len, tempo: tempo) + "]"
        case .touch(let a):
            s = a.simai
            if n.firework { s += "f" }
        case .touchHold(let a, let len):
            s = a.simai
            if n.firework { s += "f" }
            s += "h[" + durationToken(startTick: n.tick, lengthTicks: len, tempo: tempo) + "]"
        case .slide(let b, let segments, let duration):
            s = "\(Geometry.wrap(b))"
            if n.isBreak { s += "b" }
            if n.isEx { s += "x" }
            s += segments.map { $0.simai }.joined()
            // default delay = one beat at the current tempo; movement starts after it
            let moveStart = n.tick + ticksPerBeat
            let startBeat = Double(n.tick) / Double(ticksPerBeat)
            let moveBeat = Double(moveStart) / Double(ticksPerBeat)
            let endBeat = Double(moveStart + duration) / Double(ticksPerBeat)
            let sameTempo = tempo.segmentIndex(atBeat: startBeat + 1e-9) == tempo.segmentIndex(atBeat: endBeat - 1e-9)
            if sameTempo {
                let g = gcd(max(1, duration), wholeTicks)
                s += "[\(wholeTicks / g):\(max(1, duration) / g)]"
            } else {
                let delay = tempo.time(atBeat: moveBeat) - tempo.time(atBeat: startBeat)
                let dur = tempo.time(atBeat: endBeat) - tempo.time(atBeat: moveBeat)
                s += "[" + format(delay, decimals: 4) + "##" + format(dur, decimals: 4) + "]"
            }
        }
        return s
    }
}
