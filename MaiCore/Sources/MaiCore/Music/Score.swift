import Foundation

/// A piecewise-constant tempo map. Beat 0 occurs at `segments[0].startTime` seconds.
public struct TempoMap: Codable, Equatable {
    public struct Segment: Codable, Equatable {
        public var startBeat: Double
        public var bpm: Double
        public var startTime: Double
    }

    public private(set) var segments: [Segment]

    public init(bpm: Double, offset: Double = 0) {
        segments = [Segment(startBeat: 0, bpm: max(1, bpm), startTime: offset)]
    }

    /// `changes` must contain beat positions (quarter notes) and BPM values. Beat 0 is at `offset` seconds.
    public init(changes: [(beat: Double, bpm: Double)], offset: Double = 0) {
        var sorted = changes.filter { $0.bpm > 0 }.sorted { $0.beat < $1.beat }
        if sorted.isEmpty { sorted = [(0, 120)] }
        if sorted[0].beat > 0 { sorted.insert((0, sorted[0].bpm), at: 0) }
        var segs: [Segment] = []
        for c in sorted {
            let beat = max(0, c.beat)
            if let last = segs.last {
                if abs(last.startBeat - beat) < 1e-9 {
                    segs[segs.count - 1].bpm = c.bpm
                    continue
                }
                if abs(last.bpm - c.bpm) < 1e-9 { continue }
                let t = last.startTime + (beat - last.startBeat) * 60 / last.bpm
                segs.append(Segment(startBeat: beat, bpm: c.bpm, startTime: t))
            } else {
                segs.append(Segment(startBeat: beat, bpm: c.bpm, startTime: offset))
            }
        }
        segments = segs
    }

    public var offset: Double { segments[0].startTime }
    public var initialBPM: Double { segments[0].bpm }
    public var isConstant: Bool { segments.count == 1 }

    public func segmentIndex(atBeat b: Double) -> Int {
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].startBeat <= b + 1e-9 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public func time(atBeat b: Double) -> Double {
        let s = segments[segmentIndex(atBeat: b)]
        return s.startTime + (b - s.startBeat) * 60 / s.bpm
    }

    public func beat(atTime t: Double) -> Double {
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].startTime <= t + 1e-12 { lo = mid } else { hi = mid - 1 }
        }
        let s = segments[lo]
        return s.startBeat + (t - s.startTime) * s.bpm / 60
    }

    public func bpm(atBeat b: Double) -> Double { segments[segmentIndex(atBeat: b)].bpm }

    public func secondsPerBeat(atBeat b: Double) -> Double { 60 / bpm(atBeat: b) }

    /// A copy whose beat 0 happens at a different time.
    public func withOffset(_ newOffset: Double) -> TempoMap {
        var m = self
        let delta = newOffset - offset
        for i in m.segments.indices { m.segments[i].startTime += delta }
        return m
    }

    /// Re-anchors the map so that `beat` becomes beat 0.
    public func rebased(toBeat beat: Double) -> TempoMap {
        let changes = segments.map { (max(0, $0.startBeat - beat), $0.bpm) }
        // keep only the effective tempo at the new origin plus later changes
        var effective: [(beat: Double, bpm: Double)] = [(0, bpm(atBeat: beat))]
        for c in changes where c.0 > 0 { effective.append((c.0, c.1)) }
        return TempoMap(changes: effective, offset: time(atBeat: beat))
    }

    /// The BPM that covers the most time (used for &wholebpm).
    public func dominantBPM(untilBeat end: Double) -> Double {
        var best = initialBPM, bestDur = -1.0
        var durations: [Double: Double] = [:]
        for (i, s) in segments.enumerated() {
            let e = i + 1 < segments.count ? segments[i + 1].startBeat : max(end, s.startBeat)
            let dur = max(0, e - s.startBeat) * 60 / s.bpm
            durations[s.bpm, default: 0] += dur
        }
        for (b, d) in durations where d > bestDur { best = b; bestDur = d }
        return best
    }
}

public struct TimeSignature: Codable, Equatable {
    public var beat: Double       // position in quarter-note beats
    public var numerator: Int
    public var denominator: Int

    public init(beat: Double, numerator: Int, denominator: Int) {
        self.beat = beat
        self.numerator = max(1, numerator)
        self.denominator = max(1, denominator)
    }

    /// Bar length in quarter-note beats.
    public var beatsPerBar: Double { Double(numerator) * 4 / Double(denominator) }
}

public struct Bar: Equatable {
    public var index: Int
    public var startBeat: Double
    public var length: Double
    public var numerator: Int
    public var denominator: Int
    public var endBeat: Double { startBeat + length }
}

public enum BarLayout {
    /// Expands time signatures into concrete bars covering [0, endBeat).
    public static func bars(timeSignatures: [TimeSignature], endBeat: Double) -> [Bar] {
        var sigs = timeSignatures.sorted { $0.beat < $1.beat }
        if sigs.isEmpty || sigs[0].beat > 1e-9 { sigs.insert(TimeSignature(beat: 0, numerator: 4, denominator: 4), at: 0) }
        var bars: [Bar] = []
        var beat = 0.0
        var sigIndex = 0
        var idx = 0
        while beat < endBeat - 1e-9 || bars.isEmpty {
            while sigIndex + 1 < sigs.count && sigs[sigIndex + 1].beat <= beat + 1e-6 { sigIndex += 1 }
            let s = sigs[sigIndex]
            var len = s.beatsPerBar
            if sigIndex + 1 < sigs.count {
                let nextStart = sigs[sigIndex + 1].beat
                if beat + len > nextStart + 1e-6 { len = max(0.25, nextStart - beat) }
            }
            bars.append(Bar(index: idx, startBeat: beat, length: len, numerator: s.numerator, denominator: s.denominator))
            beat += len
            idx += 1
            if idx > 100_000 { break }
        }
        return bars
    }
}

/// A single pitched or percussive note.
public struct MusicNote: Codable, Equatable, Hashable {
    public var pitch: Int
    public var startBeat: Double
    public var durationBeats: Double
    public var velocity: Int
    public var channel: Int
    public var track: Int
    public var program: Int
    public var isDrum: Bool

    public init(pitch: Int, startBeat: Double, durationBeats: Double, velocity: Int = 100, channel: Int = 0,
                track: Int = 0, program: Int = 0, isDrum: Bool = false) {
        self.pitch = pitch
        self.startBeat = startBeat
        self.durationBeats = durationBeats
        self.velocity = velocity
        self.channel = channel
        self.track = track
        self.program = program
        self.isDrum = isDrum
    }

    public var endBeat: Double { startBeat + durationBeats }
}

public struct TrackInfo: Codable, Equatable {
    public var index: Int
    public var name: String
    public var channel: Int
    public var program: Int
    public var isDrum: Bool
    public var noteCount: Int

    public init(index: Int, name: String, channel: Int, program: Int, isDrum: Bool, noteCount: Int) {
        self.index = index
        self.name = name
        self.channel = channel
        self.program = program
        self.isDrum = isDrum
        self.noteCount = noteCount
    }
}

/// Raw controller/program/pitch-bend events kept for faithful synthesis.
public struct ControlEvent: Codable, Equatable {
    public enum Kind: Codable, Equatable {
        case controller(number: Int, value: Int)
        case program(Int)
        case pitchBend(Int) // 0...16383, centre 8192
        case channelPressure(Int)
    }
    public var beat: Double
    public var channel: Int
    public var kind: Kind

    public init(beat: Double, channel: Int, kind: Kind) {
        self.beat = beat
        self.channel = channel
        self.kind = kind
    }
}

/// Unified symbolic music representation (from MIDI, MusicXML, OMR or audio transcription).
public struct Score: Codable, Equatable {
    public var title: String
    public var composer: String
    public var tempo: TempoMap
    public var timeSignatures: [TimeSignature]
    public var notes: [MusicNote]
    public var tracks: [TrackInfo]
    public var controls: [ControlEvent]
    /// Lyric/marker text by beat (for section hints).
    public var markers: [(beat: Double, text: String)] {
        get { markerBeats.enumerated().map { ($0.element, markerTexts[$0.offset]) } }
        set { markerBeats = newValue.map { $0.beat }; markerTexts = newValue.map { $0.text } }
    }
    private var markerBeats: [Double] = []
    private var markerTexts: [String] = []

    public init(title: String = "", composer: String = "", tempo: TempoMap, timeSignatures: [TimeSignature] = [],
                notes: [MusicNote], tracks: [TrackInfo] = [], controls: [ControlEvent] = []) {
        self.title = title
        self.composer = composer
        self.tempo = tempo
        self.timeSignatures = timeSignatures
        self.notes = notes.sorted { ($0.startBeat, $0.pitch) < ($1.startBeat, $1.pitch) }
        self.tracks = tracks
        self.controls = controls
    }

    public static func == (a: Score, b: Score) -> Bool {
        a.title == b.title && a.tempo == b.tempo && a.timeSignatures == b.timeSignatures && a.notes == b.notes
    }

    public var endBeat: Double { notes.map { $0.endBeat }.max() ?? 0 }
    public var durationSeconds: Double { tempo.time(atBeat: endBeat) - tempo.time(atBeat: 0) }
    public var pitchedNotes: [MusicNote] { notes.filter { !$0.isDrum } }
    public var drumNotes: [MusicNote] { notes.filter { $0.isDrum } }

    public func bars() -> [Bar] { BarLayout.bars(timeSignatures: timeSignatures, endBeat: max(endBeat, 1)) }

    /// Shifts all musical content so that it starts later by `beats` (used to add lead-in time).
    public func delayed(byBeats beats: Double) -> Score {
        var s = self
        s.notes = notes.map { var n = $0; n.startBeat += beats; return n }
        s.controls = controls.map { var c = $0; if c.beat > 0 { c.beat += beats }; return c }
        let changes = tempo.segments.map { (beat: $0.startBeat == 0 ? 0 : $0.startBeat + beats, bpm: $0.bpm) }
        s.tempo = TempoMap(changes: changes, offset: tempo.offset)
        s.timeSignatures = timeSignatures.map { var t = $0; if t.beat > 0 { t.beat += beats }; return t }
        if beats > 0, let first = timeSignatures.first(where: { $0.beat <= 1e-9 }) {
            // keep bar grid aligned: lead-in should be a whole number of bars of the first signature
            _ = first
        }
        s.markers = markers.map { ($0.beat + beats, $0.text) }
        return s
    }
}
