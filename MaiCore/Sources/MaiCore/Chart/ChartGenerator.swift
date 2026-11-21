import Foundation

public struct GeneratorOptions: Codable, Equatable {
    public var seed: UInt64 = 1
    /// 0 = no slides, 1 = plenty. Defaults low: charts focus on quantised taps.
    public var slideAmount: Double = 0.25
    /// Touch notes (A/B/D/E sensors with closing timers + centre touch holds).
    public var touchAmount: Double = 0.7
    public var eachAmount: Double = 0.65
    public var breakAmount: Double = 0.5
    /// Density multiplier for Re:MASTER (1 = default, 1.3 = extra dense but still playable).
    public var remasterBoost: Double = 1.15
    /// Adds 16th-note stream fills between 8th-note events in energetic Re:MASTER passages
    /// (on the beat grid, but not tied to a specific sound). Off by default: every note follows a real sound.
    public var streamFills: Bool = false
    public var mirror: Bool = false
    public var designer: String = "MaiChart Studio"
    public var difficulties: [Difficulty] = Difficulty.allCases
    /// Notes earlier than this (seconds of audio) are not charted.
    public var minimumNoteTime: Double = 1.2

    public init() {}
}

public struct GeneratedChartSet {
    public var maidata: Maidata
    public var timing: ChartTiming
    public var charts: [Chart]
    public var reports: [Difficulty: PlayabilityReport]
    public var stats: [Difficulty: LevelEstimator.Stats]

    public func chart(_ d: Difficulty) -> Chart? { charts.first { $0.difficulty == d } }
}

/// Generates a hierarchical family of charts. Re:MASTER is planned first; every lower
/// difficulty keeps a subset of the same notes on the same buttons (direct practice),
/// simplifying EACH, touch, slides and density as it goes down.
public final class ChartGenerator {
    struct Planned {
        var tick: Int
        var level: Difficulty
        var notes: [ChartNote]
        var accent: Bool
        var importance: Double
    }

    let features: SongFeatures
    let options: GeneratorOptions
    var rng: SeededRandom
    var tempo: TempoMap = TempoMap(bpm: 120)
    var slots: [RhythmSlot] = []
    var bars: [Bar] = []

    public init(features: SongFeatures, options: GeneratorOptions = GeneratorOptions()) {
        self.features = features
        self.options = options
        rng = SeededRandom(seed: options.seed ^ SeededRandom.hash(features.title))
    }

    public static func generate(_ features: SongFeatures, options: GeneratorOptions = GeneratorOptions(),
                                title: String? = nil, artist: String? = nil) -> GeneratedChartSet {
        ChartGenerator(features: features, options: options).run(title: title, artist: artist)
    }

    // MARK: - Pipeline

    func run(title: String?, artist: String?) -> GeneratedChartSet {
        let shifted = chartFeatures()
        tempo = shifted.tempo
        bars = shifted.bars()
        let raw = RhythmPlanner.buildSlots(shifted)
        let playable = raw.filter { tempo.time(atBeat: Double($0.tick) / Double(ticksPerBeat)) >= options.minimumNoteTime }
        let intensity = songIntensity(shifted)
        slots = RhythmPlanner.distribute(playable, tempo: tempo, intensity: intensity, remasterBoost: options.remasterBoost, rng: &rng)
        if options.streamFills {
            slots = RhythmPlanner.addRemasterFills(slots, tempo: tempo, amount: max(0.4, options.remasterBoost - 0.85) * 2.2, rng: &rng)
        }
        let planned = planTopLevel()
        if ProcessInfo.processInfo.environment["MAICHART_DEBUG"] != nil {
            var per: [Difficulty: Int] = [:]
            for sl in slots { per[sl.level, default: 0] += 1 }
            print("debug: fills \(slots.filter { $0.isFill }.count) plannedFills \(planned.filter { p in slots.contains { $0.isFill && $0.tick == p.tick } }.count) intensity>0.58 \(slots.filter { $0.intensity > 0.58 }.count) raw slots \(raw.count) playable \(playable.count) distributed \(slots.count) planned \(planned.count) perLevel \(Difficulty.allCases.map { "\($0.displayName)=\(per[$0] ?? 0)" })")
        }
        var levels: [Difficulty: [ChartNote]] = [:]
        var keptAbove: Set<Int>? = nil // ticks present in the next higher difficulty (nesting guarantee)
        for d in Difficulty.allCases.reversed() {
            var notes = derive(planned, for: d)
            if let allowed = keptAbove { notes = notes.filter { allowed.contains($0.tick) } }
            notes = repair(notes, difficulty: d)
            keptAbove = Set(notes.map { $0.tick })
            levels[d] = notes
        }
        var charts: [Chart] = []
        var reports: [Difficulty: PlayabilityReport] = [:]
        var stats: [Difficulty: LevelEstimator.Stats] = [:]
        var previousLevel = 0.0
        for d in Difficulty.allCases {
            var notes = levels[d] ?? []
            if options.mirror { notes = notes.map { mirrored($0) } }
            var (lvStr, lv) = LevelEstimator.estimate(notes, tempo: tempo, difficulty: d)
            if lv <= previousLevel && !notes.isEmpty {
                lv = min(15, previousLevel + (d == .remaster ? 0.3 : 0.6))
                lvStr = LevelEstimator.display(lv)
            }
            previousLevel = lv
            guard options.difficulties.contains(d) else { continue }
            charts.append(Chart(difficulty: d, level: lvStr, levelValue: lv, designer: options.designer, notes: notes))
            reports[d] = PlayabilityChecker.check(notes, tempo: tempo, difficulty: d)
            stats[d] = LevelEstimator.stats(notes, tempo: tempo)
        }
        let timing = ChartTiming(tempo: tempo, timeSignatures: shifted.timeSignatures, endBeat: shifted.endBeat)
        let maidata = Maidata(title: title ?? features.title, artist: artist ?? features.artist,
                              designer: options.designer, timing: timing, charts: charts)
        return GeneratedChartSet(maidata: maidata, timing: timing, charts: charts, reports: reports, stats: stats)
    }

    /// Re-anchors the song so that chart time 0 is a bar line at or after audio time 0.
    func chartFeatures() -> SongFeatures {
        let f = features
        let barLen = (f.timeSignatures.sorted { $0.beat < $1.beat }.first?.beatsPerBar) ?? 4
        // earliest bar line (possibly before beat 0 when the audio has a pickup) that is >= 0 s
        var start = 0.0
        while f.tempo.time(atBeat: start - barLen) >= -1e-6 && start - barLen >= -64 { start -= barLen }
        while f.tempo.time(atBeat: start) < -1e-6 { start += barLen }
        let tm = f.tempo.rebased(toBeat: start)
        func sh(_ b: Double) -> Double { b - start }
        var out = f
        out.tempo = tm
        out.melody = f.melody.map { var n = $0; n.beat = sh(n.beat); return n }.filter { $0.beat >= 0 }
        out.harmony = f.harmony.map { var n = $0; n.beat = sh(n.beat); return n }.filter { $0.beat >= 0 }
        out.bass = f.bass.map { var n = $0; n.beat = sh(n.beat); return n }.filter { $0.beat >= 0 }
        out.drums = f.drums.map { var n = $0; n.beat = sh(n.beat); return n }.filter { $0.beat >= 0 }
        out.timeSignatures = f.timeSignatures.map { var t = $0; t.beat = max(0, sh(t.beat)); return t }
        out.endBeat = sh(f.endBeat)
        let k = Int(start.rounded())
        if k > 0 { out.beatEnergy = Array(f.beatEnergy.dropFirst(min(k, f.beatEnergy.count))) }
        else if k < 0 { out.beatEnergy = [Double](repeating: f.beatEnergy.first ?? 0.5, count: -k) + f.beatEnergy }
        out.sectionStarts = f.sectionStarts.map(sh).filter { $0 >= 0 }
        return out
    }

    func songIntensity(_ f: SongFeatures) -> Double {
        let dur = max(10, f.tempo.time(atBeat: f.endBeat) - f.tempo.time(atBeat: 0))
        let events = Double(f.melody.count + f.drums.count / 2 + f.harmony.count / 4)
        let eventRate = events / dur
        let bpm = f.tempo.dominantBPM(untilBeat: f.endBeat)
        let k = 0.75 + 0.16 * min(2.0, eventRate / 4) + 0.14 * min(1.0, max(0, (bpm - 100) / 100))
        return max(0.7, min(1.3, k))
    }

    func time(_ tick: Int) -> Double { tempo.time(atBeat: Double(tick) / Double(ticksPerBeat)) }

    // MARK: - Geometry helpers

    static func button(side: Int, row: Int) -> Int {
        // side 1 = right (1..4 from top), side 0 = left (8..5 from top)
        let r = max(0, min(3, row))
        return side == 1 ? r + 1 : 8 - r
    }

    static func sideRow(_ b: Int) -> (side: Int, row: Int) {
        let w = Geometry.wrap(b)
        return w <= 4 ? (1, w - 1) : (0, 8 - w)
    }

    /// Moves `steps` rows up (negative) or down (positive) along the ring, crossing over at the top/bottom.
    static func moveVertically(_ b: Int, by steps: Int) -> Int {
        var (side, row) = sideRow(b)
        var s = steps
        while s != 0 {
            if s < 0 {
                if row == 0 { side = 1 - side } else { row -= 1 }
                s += 1
            } else {
                if row == 3 { side = 1 - side } else { row += 1 }
                s -= 1
            }
        }
        return button(side: side, row: row)
    }

    // MARK: - Top level planning (Re:MASTER layout)

    func planTopLevel() -> [Planned] {
        var planned: [Planned] = []
        guard !slots.isEmpty else { return planned }
        var sim = HandSimulator(model: HandModel.model(for: .remaster))
        var heldButtons: [Int: Double] = [:]
        var lastButton = rng.chance(0.5) ? 2 : 7
        var lastPitch: Int? = nil
        var lastTime = -10.0
        var lastDir = 1
        var runCount = 0
        var touchRingPos = rng.int(1...8)
        var touchDir = rng.chance(0.5) ? 1 : -1
        var lastEach: (tick: Int, a: Int, b: Int)? = nil
        var eachStreak = 0
        var lastSlideTick = -100_000
        var lastBreakTick = -100_000
        var lastTouchHoldTick = -100_000
        var lastHoldButton: (Int, Int)? = nil // button, tick
        var orientation = rng.chance(0.5) ? 1 : -1
        var phraseMemory: [String: [Int]] = [:]
        var currentPhraseKey = ""
        var currentPhraseButtons: [Int] = []
        var echo: [Int]? = nil
        var echoTransform = 0
        var phraseIndex = -1
        let lastTick = slots.last!.tick

        func localRange(_ tick: Int) -> (Int, Int) {
            let w = 4 * ticksPerBeat
            let ps = slots.filter { abs($0.tick - tick) <= w }.compactMap { $0.melodyPitch }
            guard let lo = ps.min(), let hi = ps.max() else { return (60, 72) }
            return hi - lo < 5 ? (lo - 3, hi + 3) : (lo, hi)
        }
        func rowFor(pitch: Int, tick: Int) -> Int {
            let (lo, hi) = localRange(tick)
            let x = Double(pitch - lo) / Double(max(1, hi - lo))
            return max(0, min(3, Int((3 - 3 * x).rounded())))
        }
        func phraseKey(at index: Int) -> String {
            let tick = slots[index].tick
            let span = 8 * ticksPerBeat
            let start = (tick / span) * span
            var parts: [String] = []
            var prevPitch: Int? = nil
            for s in slots where s.tick >= start && s.tick < start + span {
                var c = "r"
                if let p = s.melodyPitch, let pp = prevPitch { c = p > pp ? "u" : (p < pp ? "d" : "s") }
                if s.melodyPitch != nil { prevPitch = s.melodyPitch }
                parts.append("\(s.tick - start)\(c)\(s.hasMelody ? "m" : "x")")
            }
            return parts.joined(separator: ",")
        }
        func held(at t: Double) -> Set<Int> { Set(heldButtons.filter { $0.value > t + 1e-6 }.keys) }
        /// Finds a playable placement for buttons near the targets (1 or 2 notes).
        func place(_ targets: [Int], at t: Double) -> ([Int], HandSimulator.Placement)? {
            let h = held(at: t)
            func candidates(_ b: Int) -> [Int] {
                var c = [b]
                for k in 1...3 { c.append(Geometry.wrap(b + k)); c.append(Geometry.wrap(b - k)) }
                c.append(Geometry.mirror(b))
                return c.filter { !h.contains($0) }
            }
            if targets.count == 1 {
                for c in candidates(targets[0]) {
                    let p = sim.evaluate(angles: [Geometry.buttonAngle(c)], at: t)
                    if p.feasible && p.minSlack >= 0 { return ([c], p) }
                }
                return nil
            }
            let a = targets[0], b = targets[1]
            for (ca, cb) in [(a, b), (a, Geometry.mirror(a)), (a, Geometry.wrap(a + 4))] where ca != cb && !h.contains(ca) && !h.contains(cb) {
                let p = sim.evaluate(angles: [Geometry.buttonAngle(ca), Geometry.buttonAngle(cb)], at: t)
                if p.feasible && p.minSlack >= 0 { return ([ca, cb], p) }
            }
            return nil
        }
        func placeAngles(_ angles: [Double], at t: Double) -> HandSimulator.Placement? {
            let p = sim.evaluate(angles: angles, at: t)
            return p.feasible && p.minSlack >= 0 ? p : nil
        }

        for (i, s) in slots.enumerated() {
            let t = time(s.tick)
            let dt = t - lastTime
            let nextTick = i + 1 < slots.count ? slots[i + 1].tick : lastTick + 4 * ticksPerBeat
            let gapTicks = nextTick - s.tick
            let nextGapSeconds = time(nextTick) - t
            let pIndex = s.tick / (8 * ticksPerBeat)
            if pIndex != phraseIndex {
                if !currentPhraseKey.isEmpty && phraseMemory[currentPhraseKey] == nil && currentPhraseButtons.count >= 4 {
                    phraseMemory[currentPhraseKey] = currentPhraseButtons
                }
                phraseIndex = pIndex
                currentPhraseKey = phraseKey(at: i)
                currentPhraseButtons = []
                if let prev = phraseMemory[currentPhraseKey] {
                    echo = prev
                    echoTransform = rng.weightedIndex([0.2, 0.5, 0.15, 0.15]) // same, mirror, rotate+, rotate-
                } else {
                    echo = nil
                }
                if rng.chance(0.4) { orientation = -orientation }
                if s.sectionStart || rng.chance(0.3) { touchDir = -touchDir }
            }
            let accent = s.isAccent
            let intense = s.intensity > 0.62

            // ---- musical target button
            var target = lastButton
            var inRun = false
            if let p = s.melodyPitch {
                if let lp = lastPitch {
                    let iv = p - lp
                    let mag = abs(iv)
                    let step = mag == 0 ? 0 : (mag <= 2 ? 1 : (mag <= 5 ? 2 : (mag <= 9 ? 3 : 4)))
                    let dir = iv > 0 ? -1 : 1 // rising pitch moves up the screen
                    if dt < 0.17 && step == 1 && (dir == lastDir || runCount == 0) {
                        runCount += 1
                        inRun = true
                        // circle run: keep rotating around the ring
                        target = Geometry.wrap(lastButton + (Geometry.isRightSide(lastButton) ? -dir : dir) * orientation)
                    } else if dt < 0.21 {
                        runCount = 0
                        let side = 1 - Self.sideRow(lastButton).side
                        target = Self.button(side: side, row: rowFor(pitch: p, tick: s.tick))
                        if target == lastButton { target = Geometry.mirror(target) }
                    } else {
                        runCount = 0
                        if step == 0 {
                            target = dt >= 0.3 && rng.chance(0.5) ? lastButton : Geometry.mirror(lastButton)
                        } else {
                            target = Self.moveVertically(lastButton, by: dir * step)
                            // occasionally hand over to the other side for variety
                            if dt > 0.35 && rng.chance(0.18) { target = Geometry.mirror(target) }
                        }
                    }
                    lastDir = dir
                } else {
                    target = Self.button(side: rng.chance(0.5) ? 1 : 0, row: rowFor(pitch: p, tick: s.tick))
                }
            } else {
                runCount = 0
                let (lside, lrow) = Self.sideRow(lastButton)
                let side = dt < 0.3 ? 1 - lside : (rng.chance(0.6) ? 1 - lside : lside)
                var row = lrow
                if s.drums.contains(.kick) { row = rng.chance(0.6) ? 3 : 2 }
                else if s.drums.contains(.snare) || s.drums.contains(.clap) { row = rng.chance(0.5) ? 2 : 1 }
                else if s.drums.contains(.crash) { row = 0 }
                else { row = max(0, min(3, row + rng.int(-1...1))) }
                target = Self.button(side: side, row: row)
            }
            if let e = echo, currentPhraseButtons.count < e.count, !inRun {
                let src = e[currentPhraseButtons.count]
                switch echoTransform {
                case 0: target = src
                case 1: target = Geometry.mirror(src)
                case 2: target = Geometry.wrap(src + 1)
                default: target = Geometry.wrap(src - 1)
                }
            }

            // ---- decide what to place
            var notes: [ChartNote] = []
            var angles: [Double] = []
            var ends: [Double?] = []
            var placement: HandSimulator.Placement? = nil
            let melodyLenBeats = Double(s.melodyLength) / Double(ticksPerBeat)
            let gapBeats = Double(gapTicks) / Double(ticksPerBeat)
            let canSustain = s.hasMelody && melodyLenBeats >= 1.0 && gapBeats >= 0.75
            let isLast = i == slots.count - 1
            let spacious = dt >= 0.14 && nextGapSeconds >= 0.14
            let wantsBreak = isLast || (accent && (s.sectionStart || s.metric >= 0.99) && s.tick - lastBreakTick >= 16 * ticksPerBeat
                                        && rng.chance(0.35 + 0.6 * options.breakAmount))
            var eachChance = 0.0
            if spacious {
                if accent { eachChance += 0.85 }
                if s.harmonyCount >= 2 && s.metric >= 0.55 { eachChance += 0.3 }
                if s.isBackbeat && s.hasMelody { eachChance += 0.3 }
                if s.metric >= 0.99 && s.drums.contains(.kick) && s.hasMelody { eachChance += 0.25 }
                if intense { eachChance += 0.1 }
                if eachStreak >= 2 { eachChance *= 0.35 }
                eachChance *= options.eachAmount
            }
            let breakFirst = wantsBreak
            let drumTouch = !breakFirst && options.touchAmount > 0 && !s.hasMelody && (!s.drums.isEmpty || s.harmonyCount > 0)
                && rng.chance(options.touchAmount * ((s.drums.contains(.snare) || s.drums.contains(.clap)) ? 0.75 : (intense ? 0.5 : 0.3)))
            let melodicTouch = !breakFirst && options.touchAmount > 0 && s.hasMelody && !inRun && !canSustain && dt >= 0.18
                && rng.chance(options.touchAmount * (s.drums.isEmpty ? 0.16 : 0.1))
            let accentTouch = !breakFirst && options.touchAmount > 0 && accent && s.sectionStart && rng.chance(0.5 * options.touchAmount)

            // 1) slides (sparse)
            if !breakFirst && canSustain && melodyLenBeats >= 1.75 && nextGapSeconds > 0.75 && s.tick - lastSlideTick >= 12 * ticksPerBeat
                && rng.chance(options.slideAmount * 0.9) {
                let durTicks = max(ticksPerBeat / 2, Int((melodyLenBeats - 1).rounded(.down)) * ticksPerBeat)
                let dur = min(durTicks, gapTicks - ticksPerBeat - ticksPerBeat / 4)
                if dur >= ticksPerBeat / 2, let (bs, p) = place([target], at: t) {
                    let shape = slideShape(from: bs[0])
                    notes = [ChartNote(tick: s.tick, kind: .slide(button: bs[0], segments: [shape], duration: dur))]
                    angles = [Geometry.buttonAngle(bs[0])]
                    ends = [time(s.tick + ticksPerBeat + dur)]
                    placement = p
                    lastSlideTick = s.tick
                }
            }
            // 2) centre touch hold during long calm notes
            let sustainBeats = max(s.hasMelody ? min(melodyLenBeats, gapBeats) : 0,
                                   s.metric >= 0.78 ? Double(s.harmonyLength) / Double(ticksPerBeat) : 0)
            if notes.isEmpty && !breakFirst && sustainBeats >= 1.5 && options.touchAmount > 0.2 && !inRun
                && s.tick - lastTouchHoldTick >= 12 * ticksPerBeat && rng.chance((intense ? 0.25 : 0.45) * options.touchAmount) {
                let len = min(4 * ticksPerBeat, max(ticksPerBeat, (Int(sustainBeats * 0.9 * 4) * ticksPerBeat) / 4))
                if let p = placeAngles([-1], at: t) {
                    notes = [ChartNote(tick: s.tick, kind: .touchHold(area: .c, length: len))]
                    angles = [-1]
                    ends = [time(s.tick + len)]
                    placement = p
                    lastTouchHoldTick = s.tick
                }
            }
            // 3) touch notes (closing-timer notes on A/B/D/E, firework centre for big accents)
            if notes.isEmpty && (drumTouch || melodicTouch || accentTouch) {
                if accentTouch && rng.chance(0.5), let p = placeAngles([-1], at: t) {
                    notes = [ChartNote(tick: s.tick, kind: .touch(area: .c), firework: true)]
                    angles = [-1]; ends = [nil]; placement = p
                } else {
                    var area: TouchArea
                    if melodicTouch {
                        // touch on the inner ring at the melodic target's angle
                        area = rng.chance(0.6) ? .b(target) : .e(Geometry.wrap(target + (Geometry.isRightSide(target) ? 1 : 0)))
                    } else {
                        touchRingPos = Geometry.wrap(touchRingPos + touchDir * (rng.chance(0.7) ? 1 : 2))
                        let hat = s.drums.contains(.closedHat) || s.drums.contains(.ride)
                        let ring = hat ? (rng.chance(0.6) ? "E" : "B") : (rng.chance(0.6) ? "B" : (rng.chance(0.5) ? "E" : (rng.chance(0.5) ? "A" : "D")))
                        area = touchArea(ring, touchRingPos)
                    }
                    let pair = (accent || (s.drums.contains(.clap) && intense)) && spacious && rng.chance(options.eachAmount * 0.6)
                    if pair {
                        let other = mirrorArea(area)
                        if other != area, let p = placeAngles([area.angle, other.angle], at: t) {
                            notes = [ChartNote(tick: s.tick, kind: .touch(area: area), firework: accent && s.sectionStart),
                                     ChartNote(tick: s.tick, kind: .touch(area: other))]
                            angles = [area.angle, other.angle]; ends = [nil, nil]; placement = p
                        }
                    }
                    if notes.isEmpty, let p = placeAngles([area.angle], at: t) {
                        notes = [ChartNote(tick: s.tick, kind: .touch(area: area), firework: accent && s.sectionStart)]
                        angles = [area.angle]; ends = [nil]; placement = p
                    }
                }
            }
            // 4) taps / holds / EACH
            if notes.isEmpty {
                var holdLen = 0
                if canSustain {
                    let chance = melodyLenBeats >= 2 ? 0.75 : 0.45
                    if rng.chance(chance) {
                        holdLen = min(Int(melodyLenBeats * Double(ticksPerBeat) * 0.95), gapTicks - ticksPerBeat / 4)
                        holdLen = (holdLen / (ticksPerBeat / 4)) * (ticksPerBeat / 4)
                        if holdLen < ticksPerBeat / 2 { holdLen = 0 }
                    }
                }
                if holdLen > 0, let lh = lastHoldButton, lh.0 == target, s.tick - lh.1 <= 4 * ticksPerBeat {
                    target = Self.moveVertically(target, by: rng.chance(0.5) ? 1 : -1) // avoid hold jacks
                }
                var wantEach = rng.chance(min(0.95, eachChance))
                if holdLen > 0 && wantEach && !rng.chance(0.45) { wantEach = false }
                if wantEach {
                    var partner: Int
                    if let le = lastEach, s.tick - le.tick <= 2 * ticksPerBeat, rng.chance(0.55) {
                        // moving pair: follow the previous EACH up/down the ring
                        let shift = rng.chance(0.5) ? 1 : -1
                        target = Self.moveVertically(le.a, by: shift)
                        partner = Geometry.mirror(target)
                    } else {
                        switch rng.weightedIndex([0.62, 0.18, 0.2]) {
                        case 0: partner = Geometry.mirror(target)
                        case 1: partner = Geometry.wrap(target + 4)
                        default: partner = Geometry.wrap(target + (Geometry.isRightSide(target) ? 1 : -1))
                        }
                    }
                    if partner == target { partner = Geometry.mirror(target) }
                    if let (bs, p) = place([target, partner], at: t) {
                        if holdLen > 0 {
                            notes = bs.map { ChartNote(tick: s.tick, kind: .hold(button: $0, length: holdLen)) } // equal lengths
                            ends = bs.map { _ in time(s.tick + holdLen) }
                        } else {
                            notes = bs.map { ChartNote(tick: s.tick, kind: .tap(button: $0), isBreak: wantsBreak) }
                            ends = [nil, nil]
                        }
                        angles = bs.map { Geometry.buttonAngle($0) }
                        placement = p
                        lastEach = (s.tick, bs[0], bs[1])
                    }
                }
                if notes.isEmpty, let (bs, p) = place([target], at: t) {
                    let b = bs[0]
                    if holdLen > 0 {
                        notes = [ChartNote(tick: s.tick, kind: .hold(button: b, length: holdLen), isBreak: wantsBreak && accent)]
                        ends = [time(s.tick + holdLen)]
                        lastHoldButton = (b, s.tick)
                    } else {
                        notes = [ChartNote(tick: s.tick, kind: .tap(button: b), isBreak: wantsBreak)]
                        ends = [nil]
                    }
                    angles = [Geometry.buttonAngle(b)]
                    placement = p
                }
            }
            guard let pl = placement, !notes.isEmpty else { continue }
            sim.commit(pl, angles: angles, at: t, ends: ends)
            for (k, n) in notes.enumerated() where n.isHoldLike || n.isSlide {
                if let b = n.button, let e = ends[k] { heldButtons[b] = e }
            }
            eachStreak = notes.count == 2 ? eachStreak + 1 : 0
            if notes.contains(where: { $0.isBreak }) { lastBreakTick = s.tick }
            planned.append(Planned(tick: s.tick, level: s.level, notes: notes, accent: accent, importance: s.importance))
            if let b = notes.first(where: { $0.button != nil })?.button { lastButton = b; currentPhraseButtons.append(b) }
            if s.hasMelody { lastPitch = s.melodyPitch }
            lastTime = t
        }
        return planned
    }

    func touchArea(_ ring: String, _ i: Int) -> TouchArea {
        switch ring {
        case "A": return .a(i)
        case "D": return .d(i)
        case "E": return .e(i)
        default: return .b(i)
        }
    }

    func slideShape(from b: Int) -> SlideSegment {
        switch rng.weightedIndex([0.34, 0.3, 0.16, 0.1, 0.1]) {
        case 0:
            return SlideSegment(shape: "-", vertices: [Geometry.wrap(b + rng.pick([3, 4, 5]))])
        case 1:
            let off = rng.pick([2, 3, 4])
            let cw = rng.chance(0.5)
            // '>' means clockwise for buttons 1,2,7,8 and counter-clockwise for 3,4,5,6
            let topHalf = b <= 2 || b >= 7
            let shape = (cw == topHalf) ? ">" : "<"
            return SlideSegment(shape: shape, vertices: [Geometry.wrap(b + (cw ? off : -off))])
        case 2:
            return SlideSegment(shape: "v", vertices: [Geometry.wrap(b + rng.pick([2, 3, 5, 6]))])
        case 3:
            return SlideSegment(shape: rng.chance(0.5) ? "p" : "q", vertices: [Geometry.wrap(b + rng.pick([2, 3, 4, 5, 6]))])
        default:
            return SlideSegment(shape: "^", vertices: [Geometry.wrap(b + rng.pick([2, 3, -2, -3]))])
        }
    }

    func mirrored(_ n: ChartNote) -> ChartNote {
        var m = n
        switch n.kind {
        case .tap(let b): m.kind = .tap(button: Geometry.mirror(b))
        case .hold(let b, let l): m.kind = .hold(button: Geometry.mirror(b), length: l)
        case .slide(let b, let segs, let d):
            let ms = segs.map { seg -> SlideSegment in
                let swap: [String: String] = [">": "<", "<": ">", "p": "q", "q": "p", "pp": "qq", "qq": "pp", "s": "z", "z": "s"]
                return SlideSegment(shape: swap[seg.shape] ?? seg.shape, vertices: seg.vertices.map { Geometry.mirror($0) })
            }
            m.kind = .slide(button: Geometry.mirror(b), segments: ms, duration: d)
        case .touch(let a): m.kind = .touch(area: mirrorArea(a))
        case .touchHold(let a, let l): m.kind = .touchHold(area: mirrorArea(a), length: l)
        }
        return m
    }

    func mirrorArea(_ a: TouchArea) -> TouchArea {
        switch a {
        case .a(let i): return .a(Geometry.mirror(i))
        case .b(let i): return .b(Geometry.mirror(i))
        case .c: return .c
        case .d(let i): return .d(Geometry.wrap(10 - i))
        case .e(let i): return .e(Geometry.wrap(10 - i))
        }
    }

    // MARK: - Lower difficulties

    func derive(_ planned: [Planned], for d: Difficulty) -> [ChartNote] {
        var out: [ChartNote] = []
        var lastSide = 1
        for p in planned where p.level <= d {
            var group = p.notes
            if group.count == 2 {
                let keepBoth: Bool
                switch d {
                case .remaster, .master: keepBoth = true
                case .expert: keepBoth = p.accent || group.allSatisfy { $0.isHoldLike } || p.importance > 2.3
                case .advanced: keepBoth = p.accent && group.contains { $0.isBreak }
                default: keepBoth = false
                }
                if !keepBoth { group = [group[0]] }
            }
            group = group.map { n -> ChartNote in
                var m = n
                switch n.kind {
                case .touch(let a):
                    let keep: Bool
                    switch d {
                    case .remaster, .master: keep = true
                    case .expert: keep = a.isCenter || p.accent || (p.tick / ticksPerBeat) % 2 == 0
                    case .advanced: keep = a.isCenter && p.accent
                    default: keep = false
                    }
                    if !keep {
                        m.kind = .tap(button: a.isCenter ? (lastSide == 1 ? 8 : 1) : a.nearestButton)
                        m.firework = false
                    }
                case .touchHold(_, let l):
                    if d < .expert {
                        let b = lastSide == 1 ? 7 : 2
                        m.kind = d == .easy && l < ticksPerBeat ? .tap(button: b) : .hold(button: b, length: l)
                    }
                case .slide(let b, let segs, let dur):
                    let simple = segs.count == 1 && ["-", ">", "<", "^", "v"].contains(segs[0].shape)
                    if d >= .expert && simple { break }
                    if d == .advanced && segs.count == 1 && ["-", ">", "<"].contains(segs[0].shape) && dur >= ticksPerBeat { break }
                    if d >= .basic {
                        m.kind = .hold(button: b, length: min(2 * ticksPerBeat, ticksPerBeat + dur))
                    } else {
                        m.kind = .tap(button: b)
                    }
                case .hold(let b, let l):
                    if d == .easy && l < ticksPerBeat { m.kind = .tap(button: b) }
                default: break
                }
                return m
            }
            if group.count == 2 {
                let lens = group.map { n -> Int? in
                    switch n.kind { case .hold(_, let l), .touchHold(_, let l): return l; default: return nil }
                }
                if let a = lens[0], let b = lens[1], a != b {
                    let l = min(a, b)
                    group = group.map { var n = $0; n.kind = withLength(n.kind, l); return n }
                } else if (lens[0] == nil) != (lens[1] == nil) {
                    group = group.map { n in
                        var m = n
                        if case .hold(let b, _) = n.kind { m.kind = .tap(button: b) }
                        return m
                    }
                }
                if group[0].button != nil && group[0].button == group[1].button { group = [group[0]] }
            }
            if let b = group.first?.button { lastSide = Geometry.isRightSide(b) ? 1 : 0 }
            out.append(contentsOf: group)
        }
        return out
    }

    func withLength(_ k: ChartNote.Kind, _ l: Int) -> ChartNote.Kind {
        switch k {
        case .hold(let b, _): return .hold(button: b, length: l)
        case .touchHold(let a, _): return .touchHold(area: a, length: l)
        default: return k
        }
    }

    /// Makes a difficulty humanly playable using the shared hand simulator: notes that a hand
    /// cannot reach in time are nudged towards that hand, otherwise removed.
    func repair(_ input: [ChartNote], difficulty d: Difficulty) -> [ChartNote] {
        var sim = HandSimulator(model: HandModel.model(for: d))
        var heldButtons: [Int: Double] = [:]
        var out: [ChartNote] = []
        let groups = Dictionary(grouping: input, by: { $0.tick }).sorted { $0.key < $1.key }
        for (tick, g0) in groups {
            let t = time(tick)
            heldButtons = heldButtons.filter { $0.value > t + 1e-6 }
            var g = Array(g0.prefix(2))
            // no tapping a button that is being held
            g = g.compactMap { n in
                guard let b = n.button, heldButtons[b] != nil else { return n }
                for c in [Geometry.wrap(b + 1), Geometry.wrap(b - 1), Geometry.mirror(b)] where heldButtons[c] == nil {
                    var m = n; m.kind = rebutton(n.kind, c); return m
                }
                return nil
            }
            if g.count == 2, let a = g[0].button, a == g[1].button { g = [g[0]] }
            var p = sim.evaluate(angles: g.map { $0.angle }, at: t)
            if !p.feasible && g.count == 2 {
                g = [g[0]]
                p = sim.evaluate(angles: g.map { $0.angle }, at: t)
            }
            if !p.feasible || g.isEmpty { continue }
            if p.minSlack < 0 {
                // try nudging each late note towards its hand's previous position
                var fixed = g
                for k in fixed.indices where p.slack[k] < 0 {
                    guard let b = fixed[k].button else { continue }
                    let h = p.hands[k]
                    let prev = nearestButton(toAngle: sim.hands[h].angle)
                    var options: [Int] = []
                    var step = b
                    while step != prev && options.count < 4 {
                        step = Geometry.wrap(step + (Geometry.wrap(prev - step + 8) <= 4 ? 1 : -1))
                        options.append(step)
                    }
                    options += [prev, Geometry.wrap(prev + 1), Geometry.wrap(prev - 1)]
                    for c in options where heldButtons[c] == nil && !fixed.enumerated().contains(where: { $0.offset != k && $0.element.button == c }) {
                        var trial = fixed
                        trial[k].kind = rebutton(fixed[k].kind, c)
                        let tp = sim.evaluate(angles: trial.map { $0.angle }, at: t)
                        if tp.feasible && tp.slack[k] >= 0 { fixed = trial; break }
                    }
                }
                var fp = sim.evaluate(angles: fixed.map { $0.angle }, at: t)
                if fp.minSlack < 0 && fixed.count == 2 {
                    // keep the more comfortable note of the pair
                    let keep = fp.slack[0] >= fp.slack[1] ? 0 : 1
                    fixed = [fixed[keep]]
                    fp = sim.evaluate(angles: fixed.map { $0.angle }, at: t)
                }
                if !fp.feasible || fp.minSlack < 0 { continue }
                g = fixed
                p = fp
            }
            // simultaneous holds must have identical lengths
            if g.count == 2, g.allSatisfy({ $0.isHoldLike }) {
                let l = min(g[0].occupiedLength, g[1].occupiedLength)
                g = g.map { var n = $0; n.kind = withLength(n.kind, l); return n }
            }
            sim.commit(p, angles: g.map { $0.angle }, at: t, ends: g.map { $0.occupiedLength > 0 ? time($0.endTick) : nil })
            for n in g where n.isHoldLike || n.isSlide { if let b = n.button { heldButtons[b] = time(n.endTick) } }
            out.append(contentsOf: g)
        }
        return out
    }

    func nearestButton(toAngle a: Double) -> Int {
        if a < 0 { return 1 }
        var best = 1, bestD = Double.infinity
        for b in 1...8 {
            let d = HandModel.steps(a, Geometry.buttonAngle(b))
            if d < bestD { bestD = d; best = b }
        }
        return best
    }

    func rebutton(_ k: ChartNote.Kind, _ b: Int) -> ChartNote.Kind {
        switch k {
        case .tap: return .tap(button: b)
        case .hold(_, let l): return .hold(button: b, length: l)
        case .slide(let old, let segs, let d):
            let shift = b - old
            return .slide(button: b, segments: segs.map { SlideSegment(shape: $0.shape, vertices: $0.vertices.map { Geometry.wrap($0 + shift) }) }, duration: d)
        default: return k
        }
    }
}
