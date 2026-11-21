import Foundation

/// Offline renderer: Score -> stereo float audio using the SoundFont synthesizer.
public enum MIDIRenderer {
    public struct Options {
        public var sampleRate: Double = 44100
        /// Silence added before the music (seconds). Gives charts room before the first note.
        public var leadIn: Double = 0
        /// Extra time after the last note for releases/reverb.
        public var tail: Double = 2.5
        /// Target peak after normalisation (nil = no normalisation). 0.891 = -1 dBFS.
        public var normalizePeak: Float? = 0.84
        /// Force every melodic channel to this GM program (nil = keep the score's instruments).
        public var instrumentOverride: Int? = nil
        public var reverb = true
        public init() {}
    }

    public struct Event {
        public enum Kind { case noteOn(Int, Int), noteOff(Int), cc(Int, Int), program(Int), bend(Int), pressure(Int), drum(Bool) }
        public var time: Double
        public var channel: Int
        public var kind: Kind
        var order: Int
    }

    /// Converts a score into time-ordered synth events (seconds from score beat 0).
    public static func events(for score: Score, instrumentOverride: Int? = nil) -> [Event] {
        var evs: [Event] = []
        let tempo = score.tempo
        let base = tempo.time(atBeat: 0)
        func t(_ beat: Double) -> Double { tempo.time(atBeat: beat) - base }
        // initial programs per channel from the first note on that channel
        var firstProgram: [Int: Int] = [:]
        var drumChannels = Set<Int>()
        for n in score.notes {
            let ch = n.isDrum ? (n.channel == 9 ? 9 : n.channel) : n.channel
            if n.isDrum { drumChannels.insert(ch) } else if firstProgram[ch] == nil { firstProgram[ch] = n.program }
        }
        for ch in drumChannels where ch != 9 { evs.append(Event(time: 0, channel: ch, kind: .drum(true), order: 0)) }
        for (ch, p) in firstProgram {
            if drumChannels.contains(ch) && ch == 9 { continue }
            evs.append(Event(time: 0, channel: ch, kind: .program(instrumentOverride ?? p), order: 1))
        }
        for c in score.controls {
            let kind: Event.Kind
            switch c.kind {
            case .controller(let n, let v): kind = .cc(n, v)
            case .program(let p):
                if instrumentOverride != nil && !drumChannels.contains(c.channel) { continue }
                kind = .program(p)
            case .pitchBend(let v): kind = .bend(v)
            case .channelPressure(let v): kind = .pressure(v)
            }
            evs.append(Event(time: max(0, t(c.beat)), channel: c.channel, kind: kind, order: 2))
        }
        for n in score.notes {
            let ch = n.channel
            evs.append(Event(time: max(0, t(n.startBeat)), channel: ch, kind: .noteOn(n.pitch, max(1, min(127, n.velocity))), order: 4))
            evs.append(Event(time: max(0, t(n.endBeat)), channel: ch, kind: .noteOff(n.pitch), order: 3))
        }
        evs.sort { ($0.time, $0.order) < ($1.time, $1.order) }
        return evs
    }

    public static func apply(_ e: Event, to synth: Synthesizer) {
        switch e.kind {
        case .noteOn(let k, let v): synth.noteOn(channel: e.channel, key: k, velocity: v)
        case .noteOff(let k): synth.noteOff(channel: e.channel, key: k)
        case .cc(let n, let v): synth.controlChange(channel: e.channel, number: n, value: v)
        case .program(let p): synth.programChange(channel: e.channel, program: p)
        case .bend(let v): synth.pitchBend(channel: e.channel, value: v)
        case .pressure(let v): synth.channelPressure(channel: e.channel, value: v)
        case .drum(let d): synth.setDrumChannel(e.channel, d)
        }
    }

    public static func render(score: Score, soundFont: SoundFont, options: Options = Options(),
                              progress: ((Double) -> Void)? = nil) -> AudioSamples {
        let synth = Synthesizer(soundFont: soundFont, sampleRate: options.sampleRate)
        synth.reverbEnabled = options.reverb
        let evs = events(for: score, instrumentOverride: options.instrumentOverride)
        let musicEnd = (evs.last?.time ?? 0)
        let total = Int(((options.leadIn + musicEnd + options.tail) * options.sampleRate).rounded(.up))
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        let lead = Int((options.leadIn * options.sampleRate).rounded())
        var cursor = 0
        var ei = 0
        left.withUnsafeMutableBufferPointer { lp in
            right.withUnsafeMutableBufferPointer { rp in
                while cursor < total {
                    // next event sample position
                    var nextEvent = total
                    if ei < evs.count { nextEvent = min(total, lead + Int((evs[ei].time * options.sampleRate).rounded())) }
                    if nextEvent <= cursor {
                        apply(evs[ei], to: synth)
                        ei += 1
                        continue
                    }
                    let n = min(nextEvent - cursor, 4096)
                    synth.render(left: lp.baseAddress! + cursor, right: rp.baseAddress! + cursor, frames: n)
                    cursor += n
                    if cursor % (44100 * 4) < n { progress?(Double(cursor) / Double(total)) }
                }
            }
        }
        var buf = AudioSamples(sampleRate: options.sampleRate, channels: [left, right])
        if let target = options.normalizePeak {
            let peak = buf.peak
            if peak > 1e-6 { buf.applyGain(target / peak) }
        }
        progress?(1)
        return buf
    }
}
