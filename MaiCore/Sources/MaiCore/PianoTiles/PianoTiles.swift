import Foundation

/// A falling tile in the 4-lane Piano Tiles game.
public struct Tile: Identifiable, Codable, Equatable {
    public struct Sound: Codable, Equatable {
        public var pitch: Int
        public var velocity: Int
        public var channel: Int
        public var program: Int
        public var isDrum: Bool
        /// Offset from the tap in seconds (accompaniment notes follow the tap).
        public var delay: Double
        public var duration: Double
    }
    public var id: Int
    public var lane: Int
    public var time: Double
    public var duration: Double
    /// True for long (hold) tiles.
    public var isLong: Bool
    /// Partner tile hit at the same moment (at most two tiles at once).
    public var partner: Int?
    /// Notes played when this tile is tapped.
    public var sounds: [Sound]
    public var pitch: Int
}

public enum PianoTilesBuilder {
    public struct Options {
        public var lanes = 4
        public var maxSimultaneous = 2
        /// Minimum time between tile rows (seconds) — keeps it playable.
        public var minGap = 0.11
        /// Tiles at least this many beats long become hold tiles.
        public var longTileBeats = 1.0
        /// When true, every note of the score (accompaniment too) is triggered by the taps.
        public var playAccompaniment = true
        public var includeDrums = false
        public var seed: UInt64 = 7
        public init() {}
    }

    public static func build(score: Score, options: Options = Options()) -> [Tile] {
        let features = FeatureExtractor.features(from: score)
        let tempo = score.tempo
        let base = tempo.time(atBeat: 0)
        func t(_ b: Double) -> Double { tempo.time(atBeat: b) - base }
        var rng = SeededRandom(seed: options.seed)
        // rows = melody onsets (+ chord partner when a strong harmony/bass onset coincides)
        struct Row { var beat: Double; var dur: Double; var pitch: Int; var second: Int? }
        var rows: [Row] = []
        var lastTime = -10.0
        for m in features.melody {
            let tm = t(m.beat)
            if tm - lastTime < options.minGap { continue }
            let coinciding = features.harmony.filter { abs($0.beat - m.beat) < 1.0 / 32 && $0.pitch < m.pitch - 2 }
            var second: Int? = nil
            if options.maxSimultaneous >= 2, let h = coinciding.min(by: { $0.pitch < $1.pitch }),
               coinciding.count >= 2 || m.strength > 0.75 {
                second = h.pitch
            }
            rows.append(Row(beat: m.beat, dur: m.duration, pitch: m.pitch, second: second))
            lastTime = tm
        }
        // limit pairs so two-finger chords stay comfortable (not two in a row when fast)
        for i in rows.indices where rows[i].second != nil {
            let prevGap = i > 0 ? t(rows[i].beat) - t(rows[i - 1].beat) : 10
            let nextGap = i + 1 < rows.count ? t(rows[i + 1].beat) - t(rows[i].beat) : 10
            if prevGap < 0.22 || nextGap < 0.22 { rows[i].second = nil }
        }
        // lane assignment following the melodic contour; pairs use two different lanes
        var tiles: [Tile] = []
        var prevLane = 1
        var prevPitch = rows.first?.pitch ?? 60
        let allNotes = score.notes.filter { options.includeDrums || !$0.isDrum }.sorted { $0.startBeat < $1.startBeat }
        var noteCursor = 0
        for (ri, r) in rows.enumerated() {
            let start = t(r.beat)
            let nextStart = ri + 1 < rows.count ? t(rows[ri + 1].beat) : start + 2
            var lane: Int
            let iv = r.pitch - prevPitch
            if iv > 0 { lane = min(options.lanes - 1, prevLane + (iv > 4 ? 2 : 1)) }
            else if iv < 0 { lane = max(0, prevLane - (iv < -4 ? 2 : 1)) }
            else { lane = prevLane }
            if lane == prevLane && nextStart - start < 0.35 && ri > 0 {
                lane = prevLane == 0 ? 1 : (prevLane == options.lanes - 1 ? options.lanes - 2 : prevLane + (rng.chance(0.5) ? 1 : -1))
            }
            // tile length: musical duration, but never overlapping the next row
            let durSec = max(0.12, min(t(r.beat + r.dur) - start, nextStart - start - 0.02))
            let isLong = r.dur >= options.longTileBeats && durSec >= 0.35
            // sounds for this tap
            var sounds: [Tile.Sound] = []
            while noteCursor < allNotes.count && t(allNotes[noteCursor].startBeat) < start - 0.03 { noteCursor += 1 }
            var k = noteCursor
            let windowEnd = options.playAccompaniment ? nextStart - 0.03 : start + 0.03
            while k < allNotes.count && t(allNotes[k].startBeat) < windowEnd {
                let n = allNotes[k]
                let isMelodyNote = abs(n.startBeat - r.beat) < 1.0 / 32 && n.pitch == r.pitch
                if options.playAccompaniment || isMelodyNote || (r.second != nil && n.pitch == r.second) {
                    sounds.append(Tile.Sound(pitch: n.pitch, velocity: n.velocity, channel: n.channel, program: n.program, isDrum: n.isDrum,
                                             delay: max(0, t(n.startBeat) - start), duration: max(0.05, t(n.endBeat) - t(n.startBeat))))
                }
                k += 1
            }
            if !sounds.contains(where: { $0.pitch == r.pitch && $0.delay < 0.03 }) {
                sounds.insert(Tile.Sound(pitch: r.pitch, velocity: 100, channel: 0, program: 0, isDrum: false, delay: 0, duration: durSec), at: 0)
            }
            let id = tiles.count
            if let second = r.second {
                // the chord partner gets its own lane and the SAME length
                var lane2 = lane >= 2 ? lane - 2 : lane + 2
                if lane2 >= options.lanes { lane2 = options.lanes - 1 }
                if lane2 == lane { lane2 = (lane + 1) % options.lanes }
                let melodySounds = sounds
                tiles.append(Tile(id: id, lane: lane, time: start, duration: durSec, isLong: isLong, partner: id + 1, sounds: melodySounds, pitch: r.pitch))
                let partnerSounds = [Tile.Sound(pitch: second, velocity: 90, channel: 0, program: 0, isDrum: false, delay: 0, duration: durSec)]
                tiles.append(Tile(id: id + 1, lane: lane2, time: start, duration: durSec, isLong: isLong, partner: id, sounds: partnerSounds, pitch: second))
            } else {
                tiles.append(Tile(id: id, lane: lane, time: start, duration: durSec, isLong: isLong, partner: nil, sounds: sounds, pitch: r.pitch))
            }
            prevLane = lane
            prevPitch = r.pitch
        }
        return tiles
    }
}

/// Piano Tiles judgement (time-based) — kept platform independent for testing.
public final class TilesJudge {
    public enum Result: String { case perfect = "PERFECT", great = "GREAT", good = "GOOD", miss = "MISS" }
    public let tiles: [Tile]
    public private(set) var results: [Int: Result] = [:]
    public private(set) var score = 0
    public private(set) var combo = 0
    public private(set) var maxCombo = 0
    var holding: [Int: Double] = [:]

    public init(tiles: [Tile]) { self.tiles = tiles }

    /// Tap in a lane at time t. Returns the tile that was hit.
    public func tap(lane: Int, at t: Double) -> (tile: Tile, result: Result)? {
        let candidates = tiles.filter { $0.lane == lane && results[$0.id] == nil && abs($0.time - t) <= 0.18 }
        guard let tile = candidates.min(by: { abs($0.time - t) < abs($1.time - t) }) else { return nil }
        let dt = abs(tile.time - t)
        let r: Result = dt <= 0.05 ? .perfect : (dt <= 0.1 ? .great : .good)
        if tile.isLong { holding[tile.id] = t } else { finish(tile.id, r) }
        if tile.isLong { results[tile.id] = r; combo += 1; maxCombo = max(maxCombo, combo) }
        return (tile, r)
    }

    public func release(lane: Int, at t: Double) {
        for (id, _) in holding where tiles[id].lane == lane {
            holding[id] = nil
            let tile = tiles[id]
            let held = min(t, tile.time + tile.duration) - tile.time
            let ratio = held / max(0.01, tile.duration)
            score += Int(Double(tile.isLong ? 300 : 100) * min(1, ratio))
        }
    }

    func finish(_ id: Int, _ r: Result) {
        results[id] = r
        switch r {
        case .perfect: score += 100; combo += 1
        case .great: score += 70; combo += 1
        case .good: score += 40; combo += 1
        case .miss: combo = 0
        }
        maxCombo = max(maxCombo, combo)
    }

    public func update(_ t: Double) {
        for tile in tiles where results[tile.id] == nil && t - tile.time > 0.18 { finish(tile.id, .miss) }
        for (id, _) in holding where t >= tiles[id].time + tiles[id].duration { release(lane: tiles[id].lane, at: t) }
    }

    public var isFinished: Bool { results.count == tiles.count && holding.isEmpty }
}
