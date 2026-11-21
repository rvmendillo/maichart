import Foundation

public struct DrumHit: Codable, Equatable {
    public enum Kind: Int, Codable, CaseIterable {
        case kick, snare, clap, closedHat, openHat, crash, ride, tom, perc
    }
    public var beat: Double
    public var kind: Kind
    public var strength: Double

    public init(beat: Double, kind: Kind, strength: Double) {
        self.beat = beat
        self.kind = kind
        self.strength = strength
    }

    /// General MIDI percussion key map.
    public static func kind(forGMKey key: Int) -> Kind {
        switch key {
        case 35, 36: return .kick
        case 38, 40: return .snare
        case 37: return .snare
        case 39: return .clap
        case 42, 44: return .closedHat
        case 46: return .openHat
        case 49, 52, 55, 57: return .crash
        case 51, 53, 59: return .ride
        case 41, 43, 45, 47, 48, 50: return .tom
        default: return .perc
        }
    }
}

public struct PitchedNote: Codable, Equatable {
    public var beat: Double
    public var duration: Double
    public var pitch: Int
    public var strength: Double

    public init(beat: Double, duration: Double, pitch: Int, strength: Double) {
        self.beat = beat
        self.duration = duration
        self.pitch = pitch
        self.strength = strength
    }

    public var end: Double { beat + duration }
}

/// Everything the chart generator needs to know about a song.
public struct SongFeatures: Codable {
    public enum Source: String, Codable { case midi, musicXML, audio, omr }

    public var title: String
    public var artist: String
    public var source: Source
    /// Tempo map in absolute audio seconds (beat 0 = first downbeat of the song grid).
    public var tempo: TempoMap
    public var timeSignatures: [TimeSignature]
    public var endBeat: Double
    public var melody: [PitchedNote]
    public var harmony: [PitchedNote]
    public var bass: [PitchedNote]
    public var drums: [DrumHit]
    /// Activity per beat (index = floor(beat)), normalised 0...1.
    public var beatEnergy: [Double]
    /// Optional explicit section starts (beats) e.g. from MIDI markers or audio novelty.
    public var sectionStarts: [Double]

    public init(title: String, artist: String, source: Source, tempo: TempoMap, timeSignatures: [TimeSignature], endBeat: Double,
                melody: [PitchedNote], harmony: [PitchedNote], bass: [PitchedNote], drums: [DrumHit], beatEnergy: [Double], sectionStarts: [Double] = []) {
        self.title = title
        self.artist = artist
        self.source = source
        self.tempo = tempo
        self.timeSignatures = timeSignatures
        self.endBeat = endBeat
        self.melody = melody
        self.harmony = harmony
        self.bass = bass
        self.drums = drums
        self.beatEnergy = beatEnergy
        self.sectionStarts = sectionStarts
    }

    public func energy(atBeat b: Double) -> Double {
        guard !beatEnergy.isEmpty else { return 0.5 }
        let i = max(0, min(beatEnergy.count - 1, Int(b.rounded(.down))))
        return beatEnergy[i]
    }

    public func bars() -> [Bar] { BarLayout.bars(timeSignatures: timeSignatures, endBeat: max(1, endBeat)) }
}

// MARK: - Extraction from symbolic scores

public enum FeatureExtractor {
    /// Builds features from a symbolic score (MIDI / MusicXML / OMR).
    public static func features(from score: Score, source: SongFeatures.Source = .midi, artist: String = "") -> SongFeatures {
        let pitched = score.pitchedNotes
        let drumsRaw = score.drumNotes
        let drums = drumsRaw.map { DrumHit(beat: $0.startBeat, kind: DrumHit.kind(forGMKey: $0.pitch), strength: Double($0.velocity) / 127) }

        let (melody, melodyTracks) = extractMelody(pitched, score: score)
        let melodySet = Set(melody.map { MelodyKey(beat: $0.beat, pitch: $0.pitch) })
        var harmony: [PitchedNote] = []
        for n in pitched where !melodySet.contains(MelodyKey(beat: n.startBeat, pitch: n.pitch)) {
            harmony.append(PitchedNote(beat: n.startBeat, duration: n.durationBeats, pitch: n.pitch, strength: Double(n.velocity) / 127))
        }
        let bass = extractBass(pitched, excludingTracks: melodyTracks)
        let end = max(score.endBeat, 1)
        let energy = beatEnergy(notes: score.notes, endBeat: end)
        var sections = score.markers.map { $0.beat }
        sections.append(contentsOf: crashSections(drums))
        sections = Array(Set(sections.map { ($0 * 4).rounded() / 4 })).sorted()
        return SongFeatures(title: score.title, artist: artist.isEmpty ? score.composer : artist, source: source, tempo: score.tempo,
                            timeSignatures: score.timeSignatures, endBeat: end, melody: melody, harmony: harmony,
                            bass: bass, drums: drums, beatEnergy: energy, sectionStarts: sections)
    }

    struct MelodyKey: Hashable { var beat: Double; var pitch: Int }

    static func programMelodyAffinity(_ p: Int) -> Double {
        switch p {
        case 0...7: return 0.55        // pianos
        case 8...15: return 0.6        // chromatic percussion (bells, mallets)
        case 16...23: return 0.35      // organs
        case 24...31: return 0.45      // guitars
        case 32...39: return -1.0      // basses
        case 40...41: return 0.7       // violin, viola
        case 42...47: return 0.15      // cello, contrabass, harp, timpani
        case 48...51: return 0.2       // string ensembles
        case 52...54: return 0.95      // choir / voice
        case 55: return 0.1            // orchestra hit
        case 56...63: return 0.7       // brass
        case 64...71: return 0.75      // reeds
        case 72...79: return 0.8       // pipes / flutes
        case 80...87: return 0.95      // synth leads
        case 88...95: return 0.05      // pads
        case 96...103: return 0.15     // fx
        case 104...111: return 0.55    // ethnic
        default: return 0.1
        }
    }

    static func nameAffinity(_ name: String) -> Double {
        let n = name.lowercased()
        let strong = ["melody", "melodie", "vocal", "voice", "vox", "lead", "sing", "main", "solo", "theme", "メロ", "ボーカル", "旋律", "rh", "right"]
        let weak = ["bass", "drum", "perc", "pad", "chord", "accomp", "backing", "lh", "left", "string", "harmony", "arp"]
        if strong.contains(where: { n.contains($0) }) { return 0.6 }
        if weak.contains(where: { n.contains($0) }) { return -0.5 }
        return 0
    }

    /// Picks the melodic line: per two-bar window the most melodic active track, then its skyline.
    static func extractMelody(_ notes: [MusicNote], score: Score) -> ([PitchedNote], Set<Int>) {
        guard !notes.isEmpty else { return ([], []) }
        // group by (track, channel) so single-track multi-channel files still separate parts
        struct Part: Hashable { var track: Int; var channel: Int }
        var parts: [Part: [MusicNote]] = [:]
        for n in notes { parts[Part(track: n.track, channel: n.channel), default: []].append(n) }
        var partScore: [Part: Double] = [:]
        for (p, ns) in parts {
            let count = Double(ns.count)
            let avgPitch = ns.reduce(0.0) { $0 + Double($1.pitch) } / count
            // monophony: fraction of onsets that are not chords
            var onsets: [Double: Int] = [:]
            for n in ns { onsets[(n.startBeat * 48).rounded() / 48, default: 0] += 1 }
            let mono = Double(onsets.values.filter { $0 == 1 }.count) / Double(max(1, onsets.count))
            let program = ns.first?.program ?? 0
            let name = score.tracks.first { $0.index == p.track }?.name ?? ""
            var s = programMelodyAffinity(program) + nameAffinity(name)
            s += 0.5 * mono
            s += max(-0.6, min(0.5, (avgPitch - 60) / 24))
            s += min(0.4, log2(1 + count) / 20)
            if count < 8 { s -= 1 }
            partScore[p] = s
        }
        let endBeat = notes.map { $0.endBeat }.max() ?? 0
        let window = 8.0 // beats
        var chosen: [MusicNote] = []
        var usedTracks = Set<Int>()
        var w = 0.0
        var previous: Part? = nil
        while w < endBeat {
            var best: Part? = nil
            var bestScore = -Double.infinity
            for (p, ns) in parts {
                let inWin = ns.filter { $0.startBeat >= w && $0.startBeat < w + window }
                guard inWin.count >= 2 else { continue }
                var s = partScore[p] ?? 0
                if p == previous { s += 0.35 } // continuity
                let avg = inWin.reduce(0.0) { $0 + Double($1.pitch) } / Double(inWin.count)
                s += max(-0.4, min(0.3, (avg - 62) / 30))
                if s > bestScore { bestScore = s; best = p }
            }
            if let b = best {
                chosen.append(contentsOf: parts[b]!.filter { $0.startBeat >= w && $0.startBeat < w + window })
                usedTracks.insert(b.track)
                previous = b
            }
            w += window
        }
        return (skyline(chosen), usedTracks)
    }

    /// Highest note per onset, truncated so the line stays monophonic.
    public static func skyline(_ notes: [MusicNote]) -> [PitchedNote] {
        let sorted = notes.sorted { ($0.startBeat, -$0.pitch) < ($1.startBeat, -$1.pitch) }
        var line: [PitchedNote] = []
        var i = 0
        while i < sorted.count {
            let t = sorted[i].startBeat
            var top = sorted[i]
            var j = i + 1
            while j < sorted.count && sorted[j].startBeat - t < 1.0 / 48 {
                if sorted[j].pitch > top.pitch { top = sorted[j] }
                j += 1
            }
            // skip notes that are clearly accompaniment under a still-sounding melody note
            if let last = line.last, last.end > t + 0.05, top.pitch < last.pitch - 9, t - last.beat < 0.5 {
                i = j
                continue
            }
            if var last = line.popLast() {
                if last.end > t { last.duration = max(1.0 / 16, t - last.beat) }
                line.append(last)
            }
            line.append(PitchedNote(beat: top.startBeat, duration: top.durationBeats, pitch: top.pitch, strength: Double(top.velocity) / 127))
            i = j
        }
        return line
    }

    static func extractBass(_ notes: [MusicNote], excludingTracks: Set<Int>) -> [PitchedNote] {
        // lowest note per onset among notes below middle C
        let low = notes.filter { $0.pitch < 55 }.sorted { ($0.startBeat, $0.pitch) < ($1.startBeat, $1.pitch) }
        var out: [PitchedNote] = []
        var lastBeat = -1.0
        for n in low where n.startBeat - lastBeat > 1.0 / 48 {
            out.append(PitchedNote(beat: n.startBeat, duration: n.durationBeats, pitch: n.pitch, strength: Double(n.velocity) / 127))
            lastBeat = n.startBeat
        }
        return out
    }

    static func beatEnergy(notes: [MusicNote], endBeat: Double) -> [Double] {
        let n = max(1, Int(endBeat.rounded(.up)) + 1)
        var e = [Double](repeating: 0, count: n)
        for note in notes {
            let w = Double(note.velocity) / 127 * (note.isDrum ? 0.8 : 1.0)
            let a = max(0, Int(note.startBeat))
            let b = min(n - 1, Int((note.endBeat - 1e-6).rounded(.down)))
            // onset weight + sustain weight
            e[a] += w
            if b > a { for k in (a + 1)...b { e[k] += w * 0.25 } }
        }
        // smooth over a bar and normalise to 0...1 using robust percentiles
        let sm = DSP.movingAverage(e.map { Float($0) }, radius: 2).map { Double($0) }
        let sortedE = sm.sorted()
        let lo = sortedE[Int(Double(sortedE.count - 1) * 0.05)]
        let hi = max(lo + 1e-6, sortedE[Int(Double(sortedE.count - 1) * 0.95)])
        return sm.map { max(0, min(1, ($0 - lo) / (hi - lo))) }
    }

    static func crashSections(_ drums: [DrumHit]) -> [Double] {
        drums.filter { $0.kind == .crash && $0.strength > 0.6 }.map { $0.beat }
    }
}
