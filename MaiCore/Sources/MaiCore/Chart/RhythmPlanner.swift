import Foundation

/// A quantised moment in the song where something musically relevant starts.
public struct RhythmSlot: Equatable {
    public var tick: Int
    public var melodyPitch: Int?
    public var melodyStrength: Double = 0
    /// Length of the melody note in ticks (until its end or the next melody onset).
    public var melodyLength: Int = 0
    public var drums: Set<DrumHit.Kind> = []
    public var drumStrength: Double = 0
    public var harmonyCount: Int = 0
    public var harmonyPitches: [Int] = []
    /// Longest harmony/chord note starting here (ticks).
    public var harmonyLength: Int = 0
    /// Re:MASTER-only stream fill (between two musical events).
    public var isFill: Bool = false
    public var bassOnset: Bool = false
    public var metric: Double = 0
    public var intensity: Double = 0.5
    public var importance: Double = 0
    /// True at the first slot of a detected section.
    public var sectionStart: Bool = false
    /// Lowest difficulty that contains this slot.
    public var level: Difficulty = .remaster

    public var hasMelody: Bool { melodyPitch != nil }
    /// Big musical hits (crashes, section downbeats) – candidates for BREAK notes and EACH.
    public var isAccent: Bool {
        drums.contains(.crash) || (sectionStart && (drums.contains(.kick) || drums.contains(.snare)) && metric >= 0.99)
    }
    /// Backbeat snare/clap on a beat.
    public var isBackbeat: Bool { (drums.contains(.snare) || drums.contains(.clap)) && metric >= 0.55 }
}

public struct DifficultyProfile {
    public var difficulty: Difficulty
    public var targetNPS: Double
    public var minGapSeconds: Double
    public var minGapBeats: Double
    /// Share of available musical events this level may use at most.
    public var maxShare: Double
    /// Maximum consecutive notes at the minimum gap (stream length).
    public var maxStream: Int

    public static func profile(for d: Difficulty, bpm: Double, intensity: Double) -> DifficultyProfile {
        let fast = bpm >= 170
        let k = max(0.5, min(1.6, intensity))
        switch d {
        case .easy:
            return DifficultyProfile(difficulty: d, targetNPS: 1.0 * k, minGapSeconds: 0.42, minGapBeats: fast ? 2 : 1, maxShare: 0.3, maxStream: 99)
        case .basic:
            return DifficultyProfile(difficulty: d, targetNPS: 1.75 * k, minGapSeconds: 0.27, minGapBeats: fast ? 1 : 0.5, maxShare: 0.45, maxStream: 4)
        case .advanced:
            return DifficultyProfile(difficulty: d, targetNPS: 2.7 * k, minGapSeconds: 0.19, minGapBeats: 0.5, maxShare: 0.6, maxStream: 8)
        case .expert:
            return DifficultyProfile(difficulty: d, targetNPS: 3.9 * k, minGapSeconds: 0.12, minGapBeats: 0.25, maxShare: 0.74, maxStream: 4)
        case .master:
            return DifficultyProfile(difficulty: d, targetNPS: 5.5 * k, minGapSeconds: 0.08, minGapBeats: 0.25, maxShare: 0.88, maxStream: 12)
        case .remaster:
            return DifficultyProfile(difficulty: d, targetNPS: 7.6 * k, minGapSeconds: 0.062, minGapBeats: 1.0 / 6.0, maxShare: 1.0, maxStream: 32)
        }
    }
}

/// Builds rhythm slots from song features and distributes them over difficulties so that
/// every lower difficulty is a strict subset of the next higher one.
public enum RhythmPlanner {
    /// Quantises an arbitrary beat position to the most plausible grid (16ths or triplets).
    static func quantize(_ beats: [Double]) -> [Double] {
        guard !beats.isEmpty else { return [] }
        // decide binary vs ternary per beat using the events inside that beat
        var byBeat: [Int: [Double]] = [:]
        for b in beats { byBeat[Int(b.rounded(.down)), default: []].append(b) }
        var mode: [Int: Int] = [:] // 4 = sixteenths, 3 = triplet eighths, 6 = triplet sixteenths, 8 = 32nds
        for (k, list) in byBeat {
            var best = 4, bestErr = Double.infinity
            for div in [4, 3, 6, 8] {
                var err = 0.0
                for b in list {
                    let f = (b - Double(k)) * Double(div)
                    err += abs(f - f.rounded())
                }
                // prefer simpler grids
                let penalty = div == 4 ? 0 : (div == 3 ? 0.06 : (div == 6 ? 0.12 : 0.18))
                err = err / Double(list.count) + penalty
                if err < bestErr { bestErr = err; best = div }
            }
            mode[k] = best
        }
        return beats.map { b in
            let k = Int(b.rounded(.down))
            let div = Double(mode[k] ?? 4)
            return (b * div).rounded() / div
        }
    }

    static func metricWeight(tick: Int, bars: [Bar]) -> Double {
        let beat = Double(tick) / Double(ticksPerBeat)
        guard let bar = bars.last(where: { $0.startBeat <= beat + 1e-9 }) else { return 0.3 }
        let pos = beat - bar.startBeat
        let posTicks = Int((pos * Double(ticksPerBeat)).rounded())
        if posTicks == 0 { return 1.0 }
        let half = Int((bar.length / 2 * Double(ticksPerBeat)).rounded())
        if bar.numerator % 2 == 0 && posTicks == half { return 0.78 }
        if posTicks % ticksPerBeat == 0 { return 0.58 }
        if posTicks % (ticksPerBeat / 2) == 0 { return 0.38 }
        if posTicks % (ticksPerBeat / 3) == 0 { return 0.3 }
        if posTicks % (ticksPerBeat / 4) == 0 { return 0.22 }
        if posTicks % (ticksPerBeat / 6) == 0 { return 0.16 }
        return 0.1
    }

    public static func buildSlots(_ f: SongFeatures, startBeat: Double = 0) -> [RhythmSlot] {
        let bars = f.bars()
        var slots: [Int: RhythmSlot] = [:]
        func slot(_ tick: Int) -> RhythmSlot { slots[tick] ?? RhythmSlot(tick: tick) }

        let mq = quantize(f.melody.map { $0.beat })
        for (i, n) in f.melody.enumerated() {
            let t = Int((mq[i] * Double(ticksPerBeat)).rounded())
            if mq[i] < startBeat { continue }
            var s = slot(t)
            if s.melodyPitch == nil || n.strength > s.melodyStrength {
                s.melodyPitch = n.pitch
                s.melodyStrength = n.strength
                s.melodyLength = max(ticksPerBeat / 8, Int((n.duration * Double(ticksPerBeat)).rounded()))
            }
            slots[t] = s
        }
        let dq = quantize(f.drums.map { $0.beat })
        for (i, d) in f.drums.enumerated() {
            if dq[i] < startBeat { continue }
            let t = Int((dq[i] * Double(ticksPerBeat)).rounded())
            var s = slot(t)
            s.drums.insert(d.kind)
            s.drumStrength = max(s.drumStrength, d.strength)
            slots[t] = s
        }
        let hq = quantize(f.harmony.map { $0.beat })
        for (i, h) in f.harmony.enumerated() {
            if hq[i] < startBeat { continue }
            let t = Int((hq[i] * Double(ticksPerBeat)).rounded())
            var s = slot(t)
            s.harmonyCount += 1
            if s.harmonyPitches.count < 6 { s.harmonyPitches.append(h.pitch) }
            s.harmonyLength = max(s.harmonyLength, Int((h.duration * Double(ticksPerBeat)).rounded()))
            slots[t] = s
        }
        let bq = quantize(f.bass.map { $0.beat })
        for (i, _) in f.bass.enumerated() {
            if bq[i] < startBeat { continue }
            let t = Int((bq[i] * Double(ticksPerBeat)).rounded())
            if var s = slots[t] { s.bassOnset = true; slots[t] = s }
        }
        var list = slots.values.sorted { $0.tick < $1.tick }
        // melody lengths: clip to the next melody onset
        var lastMelodyIndex: Int? = nil
        for i in list.indices where list[i].hasMelody {
            if let j = lastMelodyIndex {
                let gap = list[i].tick - list[j].tick
                list[j].melodyLength = max(1, min(list[j].melodyLength, gap))
            }
            lastMelodyIndex = i
        }
        let sectionTicks = Set(f.sectionStarts.map { Int(($0 * Double(ticksPerBeat)).rounded()) })
        for i in list.indices {
            let beat = Double(list[i].tick) / Double(ticksPerBeat)
            list[i].metric = metricWeight(tick: list[i].tick, bars: bars)
            list[i].intensity = f.energy(atBeat: beat)
            list[i].sectionStart = sectionTicks.contains(list[i].tick)
            list[i].importance = importance(list[i], previous: i > 0 ? list[i - 1] : nil)
        }
        return list
    }

    static func importance(_ s: RhythmSlot, previous: RhythmSlot?) -> Double {
        var v = 0.0
        if let p = s.melodyPitch {
            v += 0.95 + 0.3 * s.melodyStrength
            v += min(0.35, Double(s.melodyLength) / Double(ticksPerBeat) * 0.12)
            if let prev = previous?.melodyPitch, abs(p - prev) >= 5 { v += 0.12 } // leaps are memorable
        }
        for k in s.drums {
            switch k {
            case .kick: v += 0.5
            case .snare: v += 0.55
            case .clap: v += 0.55
            case .crash: v += 0.8
            case .openHat: v += 0.22
            case .closedHat: v += 0.1
            case .ride: v += 0.12
            case .tom: v += 0.35
            case .perc: v += 0.14
            }
        }
        v *= 0.75 + 0.35 * s.drumStrength.clamped(0, 1) * (s.drums.isEmpty ? 0 : 1) + (s.drums.isEmpty ? 0.35 : 0)
        if s.harmonyCount > 0 { v += 0.12 + 0.04 * Double(min(3, s.harmonyCount)) }
        if s.bassOnset { v += 0.08 }
        v += 0.6 * s.metric
        if s.sectionStart { v += 0.4 }
        v *= 0.72 + 0.56 * s.intensity
        return v
    }

    /// Assigns `level` (lowest difficulty containing the slot) to every slot, bottom-up and nested.
    /// Slots that never make it into Re:MASTER are removed.
    public static func distribute(_ input: [RhythmSlot], tempo: TempoMap, intensity: Double, remasterBoost: Double,
                                  rng: inout SeededRandom) -> [RhythmSlot] {
        guard !input.isEmpty else { return [] }
        var slots = input
        let times = slots.map { tempo.time(atBeat: Double($0.tick) / Double(ticksPerBeat)) }
        let firstPlayable = (times.first ?? 0) // allow notes from the first slot onwards
        _ = firstPlayable
        let duration = max(1, (times.last ?? 0) - (times.first ?? 0))
        let bpm = tempo.dominantBPM(untilBeat: Double(slots.last!.tick) / Double(ticksPerBeat))
        var chosen = Set<Int>() // indices
        var levelOf = [Int: Difficulty]()
        // jitter breaks ties so that equal-importance slots don't always resolve the same way
        let jitter = slots.map { _ in rng.unit() * 0.02 }
        for d in Difficulty.allCases {
            var p = DifficultyProfile.profile(for: d, bpm: bpm, intensity: intensity)
            if d == .remaster { p.targetNPS *= remasterBoost }
            let target = min(Int(p.targetNPS * duration), Int(Double(slots.count) * p.maxShare))
            let order = slots.indices.filter { !chosen.contains($0) }
                .sorted { slots[$0].importance + jitter[$0] > slots[$1].importance + jitter[$1] }
            var sortedChosen = chosen.sorted()
            func gridOK(_ i: Int) -> Bool {
                let t = slots[i].tick
                switch d {
                case .easy: return t % ticksPerBeat == 0
                case .basic: return t % (ticksPerBeat / 2) == 0
                case .advanced: return t % (ticksPerBeat / 2) == 0 || t % (ticksPerBeat / 3) == 0
                case .expert: return t % (ticksPerBeat / 4) == 0 || t % (ticksPerBeat / 3) == 0
                case .master: return t % (ticksPerBeat / 4) == 0 || t % (ticksPerBeat / 6) == 0
                case .remaster: return true
                }
            }
            func gapOK(_ i: Int) -> Bool {
                if !gridOK(i) { return false }
                let minBeat = p.minGapBeats * Double(ticksPerBeat)
                // neighbours in the chosen set
                var lo = 0, hi = sortedChosen.count
                while lo < hi { let m = (lo + hi) / 2; if sortedChosen[m] < i { lo = m + 1 } else { hi = m } }
                if lo > 0 {
                    let j = sortedChosen[lo - 1]
                    if Double(slots[i].tick - slots[j].tick) < minBeat - 0.5 || times[i] - times[j] < p.minGapSeconds - 1e-6 { return false }
                }
                if lo < sortedChosen.count {
                    let j = sortedChosen[lo]
                    if Double(slots[j].tick - slots[i].tick) < minBeat - 0.5 || times[j] - times[i] < p.minGapSeconds - 1e-6 { return false }
                }
                // stream length limit at the densest spacing
                if p.maxStream < 99 {
                    var run = 1
                    let dense = max(minBeat, 0.25 * Double(ticksPerBeat)) + 0.5
                    var k = lo - 1, prev = i
                    while k >= 0, Double(slots[prev].tick - slots[sortedChosen[k]].tick) <= dense { run += 1; prev = sortedChosen[k]; k -= 1 }
                    k = lo; prev = i
                    while k < sortedChosen.count, Double(slots[sortedChosen[k]].tick - slots[prev].tick) <= dense { run += 1; prev = sortedChosen[k]; k += 1 }
                    if run > p.maxStream { return false }
                }
                return true
            }
            func insert(_ i: Int) {
                chosen.insert(i)
                levelOf[i] = d
                var lo = 0, hi = sortedChosen.count
                while lo < hi { let m = (lo + hi) / 2; if sortedChosen[m] < i { lo = m + 1 } else { hi = m } }
                sortedChosen.insert(i, at: lo)
            }
            var count = chosen.count
            for i in order where count < target {
                if gapOK(i) { insert(i); count += 1 }
            }
            // coverage pass: avoid long empty stretches when music is playing
            let maxEmpty: Double
            switch d {
            case .easy: maxEmpty = 8
            case .basic: maxEmpty = 6
            case .advanced: maxEmpty = 4
            default: maxEmpty = 3
            }
            var gapStart = 0
            for idx in 0...sortedChosen.count {
                let endTick = idx < sortedChosen.count ? slots[sortedChosen[idx]].tick : slots.last!.tick + 1
                let startTick = idx > 0 ? slots[sortedChosen[idx - 1]].tick : slots.first!.tick - 1
                if Double(endTick - startTick) / Double(ticksPerBeat) > maxEmpty {
                    // add the best slot in the middle of the gap
                    let candidates = slots.indices.filter { slots[$0].tick > startTick + ticksPerBeat && slots[$0].tick < endTick - ticksPerBeat && !chosen.contains($0) }
                    if let best = candidates.max(by: { slots[$0].importance < slots[$1].importance }), slots[best].importance > 0.45, gapOK(best) {
                        insert(best)
                    }
                }
                gapStart = idx
            }
            _ = gapStart
        }
        var out: [RhythmSlot] = []
        for i in slots.indices {
            if let l = levelOf[i] { slots[i].level = l; out.append(slots[i]) }
        }
        return out
    }
}

extension RhythmPlanner {
    /// Adds Re:MASTER-only 16th "stream fills" between 8th-note events in energetic passages,
    /// continuing the melodic motion so runs become circle/zigzag streams.
    public static func addRemasterFills(_ slots: [RhythmSlot], tempo: TempoMap, amount: Double, rng: inout SeededRandom) -> [RhythmSlot] {
        guard amount > 0, slots.count > 2 else { return slots }
        var out: [RhythmSlot] = []
        var streak = 0
        let half = ticksPerBeat / 2
        for i in 0..<slots.count {
            out.append(slots[i])
            guard i + 1 < slots.count else { break }
            let a = slots[i], b = slots[i + 1]
            let beat = Double(a.tick) / Double(ticksPerBeat)
            let bpm = tempo.bpm(atBeat: beat)
            let sixteenth = 60 / bpm / 4
            let gap = b.tick - a.tick
            let musical = (a.hasMelody || !a.drums.isEmpty || a.harmonyCount > 0) && (b.hasMelody || !b.drums.isEmpty || b.harmonyCount > 0)
            let eighthGap = gap == half && a.tick % half == 0 && sixteenth >= 0.068
            let quarterGap = gap == ticksPerBeat && a.tick % ticksPerBeat == 0 && a.intensity > 0.72 && sixteenth * 2 >= 0.1
            // keep accents and backbeats spacious so they can become EACH pairs
            let keepClear = a.isAccent || b.isAccent || b.isBackbeat || a.isBackbeat || (b.metric >= 0.99 && b.harmonyCount >= 2)
            let eligible = (eighthGap || quarterGap) && a.intensity > 0.58 && b.intensity > 0.5 && musical && !keepClear
            if eligible && streak < 6 && rng.chance(min(0.9, (eighthGap ? 0.55 : 0.3) * amount)) {
                var f = RhythmSlot(tick: a.tick + gap / 2)
                if let pa = a.melodyPitch, let pb = b.melodyPitch {
                    f.melodyPitch = pa == pb ? pa + (rng.chance(0.5) ? 2 : -2) : (pa + pb) / 2
                    f.melodyStrength = 0.4
                    f.melodyLength = gap / 2
                } else if !b.drums.isEmpty {
                    f.drums = [.closedHat]
                    f.drumStrength = 0.4
                }
                f.metric = 0.2
                f.intensity = a.intensity
                f.importance = 0.2
                f.level = .remaster
                f.isFill = true
                out.append(f)
                streak += 1
            } else {
                streak = 0
            }
        }
        return out
    }
}

extension Double {
    @inline(__always) func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.max(lo, Swift.min(hi, self)) }
}
