import Foundation

/// A complete SoundFont 2 synthesizer (pure Swift). Used for MIDI -> WAV/MP3 rendering,
/// Piano Tiles and score previews. All 16 MIDI channels, drums (bank 128), program/bank
/// changes, pitch bend (RPN 0), sustain pedal, CC7/10/11/91/93 and SF2 modulators.
public final class Synthesizer {
    public let sampleRate: Double
    public private(set) var soundFont: SoundFont
    public var maxVoices = 96
    /// Linear output gain applied after mixing.
    public var masterGain: Float = 0.55
    public var reverbEnabled = true
    public var chorusEnabled = true
    /// Multiplier applied to the bank's initialAttenuation generator (0.4 = EMU/FluidSynth convention).
    public var attenuationScale: Double = 0.4

    struct Channel {
        var program = 0
        var bankMSB = 0
        var bankLSB = 0
        var isDrum = false
        var cc = [Int](repeating: 0, count: 128)
        var pitchBend = 8192
        var bendRangeSemitones = 2.0
        var pressure = 0
        var rpnMSB = 127, rpnLSB = 127
        var preset: SFPreset?

        init(drum: Bool) {
            isDrum = drum
            cc[7] = 100; cc[10] = 64; cc[11] = 127; cc[91] = 40; cc[93] = 0
            cc[101] = 127; cc[100] = 127
        }
    }

    var channels: [Channel]
    var voices: [Voice] = []
    var noteCounter: UInt64 = 0
    let reverb: Reverb
    let chorus: Chorus
    let block = 64
    // scratch buffers
    var dryL = [Float](), dryR = [Float](), revIn = [Float](), choIn = [Float]()

    public init(soundFont: SoundFont, sampleRate: Double = 44100) {
        self.soundFont = soundFont
        self.sampleRate = sampleRate
        channels = (0..<16).map { Channel(drum: $0 == 9) }
        reverb = Reverb(sampleRate: sampleRate)
        chorus = Chorus(sampleRate: sampleRate)
        for i in 0..<16 { resolvePreset(i) }
    }

    public func setSoundFont(_ sf: SoundFont) {
        allSoundOff()
        soundFont = sf
        for i in 0..<16 { resolvePreset(i) }
    }

    func resolvePreset(_ ch: Int) {
        let c = channels[ch]
        let bank = c.isDrum ? 128 : c.bankMSB
        channels[ch].preset = soundFont.preset(bank: bank, program: c.program)
    }

    // MARK: MIDI input

    public func setDrumChannel(_ ch: Int, _ drum: Bool) {
        channels[ch].isDrum = drum
        resolvePreset(ch)
    }

    public func programChange(channel ch: Int, program: Int) {
        channels[ch].program = max(0, min(127, program))
        resolvePreset(ch)
    }

    public func noteOn(channel ch: Int, key: Int, velocity: Int) {
        guard velocity > 0 else { noteOff(channel: ch, key: key); return }
        guard let preset = channels[ch].preset else { return }
        let specs = soundFont.voices(for: preset, key: key, velocity: velocity)
        for spec in specs {
            let excl = Int(spec.gens[Gen.exclusiveClass.rawValue])
            if excl != 0 {
                for v in voices where v.active && v.channel == ch && v.exclusiveClass == excl && v.noteID != noteCounter + 1 {
                    v.kill(fast: true)
                }
            }
        }
        noteCounter += 1
        for spec in specs {
            let v = allocateVoice()
            v.start(spec: spec, data: soundFont.data, channel: ch, key: key, velocity: velocity, noteID: noteCounter,
                    synth: self)
        }
    }

    public func noteOff(channel ch: Int, key: Int) {
        let sustain = channels[ch].cc[64] >= 64
        for v in voices where v.active && v.channel == ch && v.key == key && !v.released {
            if sustain { v.sustained = true } else { v.release() }
        }
    }

    public func controlChange(channel ch: Int, number: Int, value: Int) {
        let v = max(0, min(127, value))
        channels[ch].cc[number] = v
        switch number {
        case 0: channels[ch].bankMSB = v
        case 32: channels[ch].bankLSB = v
        case 64:
            if v < 64 { for voice in voices where voice.active && voice.channel == ch && voice.sustained { voice.sustained = false; voice.release() } }
        case 101: channels[ch].rpnMSB = v
        case 100: channels[ch].rpnLSB = v
        case 6:
            if channels[ch].rpnMSB == 0 && channels[ch].rpnLSB == 0 { channels[ch].bendRangeSemitones = Double(v) }
        case 38:
            if channels[ch].rpnMSB == 0 && channels[ch].rpnLSB == 0 { channels[ch].bendRangeSemitones = floor(channels[ch].bendRangeSemitones) + Double(v) / 100 }
        case 120: for voice in voices where voice.channel == ch { voice.kill(fast: true) }
        case 123: for voice in voices where voice.active && voice.channel == ch && !voice.released { voice.release() }
        case 121:
            let drum = channels[ch].isDrum
            let prog = channels[ch].program, bank = channels[ch].bankMSB
            channels[ch] = Channel(drum: drum)
            channels[ch].program = prog
            channels[ch].bankMSB = bank
            resolvePreset(ch)
        default: break
        }
        for voice in voices where voice.active && voice.channel == ch { voice.modsDirty = true }
    }

    public func pitchBend(channel ch: Int, value: Int) {
        channels[ch].pitchBend = max(0, min(16383, value))
        for voice in voices where voice.active && voice.channel == ch { voice.modsDirty = true }
    }

    public func channelPressure(channel ch: Int, value: Int) {
        channels[ch].pressure = value
        for voice in voices where voice.active && voice.channel == ch { voice.modsDirty = true }
    }

    public func allNotesOff() { for v in voices where v.active { v.release() } }

    public func allSoundOff() { for v in voices { v.kill(fast: false) } }

    public func reset() {
        allSoundOff()
        channels = (0..<16).map { Channel(drum: $0 == 9) }
        for i in 0..<16 { resolvePreset(i) }
        reverb.clear()
        chorus.clear()
    }

    public var activeVoiceCount: Int { voices.filter { $0.active }.count }

    func allocateVoice() -> Voice {
        if let v = voices.first(where: { !$0.active }) { return v }
        if voices.count < maxVoices {
            let v = Voice()
            voices.append(v)
            return v
        }
        // steal: prefer released voices, then the oldest
        let victim = voices.filter { $0.released }.min(by: { $0.noteID < $1.noteID }) ?? voices.min(by: { $0.noteID < $1.noteID })!
        victim.kill(fast: false)
        return victim
    }

    // MARK: Modulator sources

    func sourceValue(_ src: UInt16, voice: Voice) -> Double {
        let index = Int(src & 0x7F)
        let isCC = src & 0x80 != 0
        let negative = src & 0x100 != 0
        let bipolar = src & 0x200 != 0
        let type = Int(src >> 10)
        let ch = channels[voice.channel]
        var x: Double
        if isCC {
            x = Double(ch.cc[index]) / 128
        } else {
            switch index {
            case 0: return 1 // no controller
            case 2: x = Double(voice.velocity) / 128
            case 3: x = Double(voice.key) / 128
            case 10: x = Double(ch.pressure) / 128
            case 13: x = Double(ch.pressure) / 128
            case 14: x = Double(ch.pitchBend) / 16384
            case 16: return ch.bendRangeSemitones / 127 // pitch wheel sensitivity (semitones)
            default: return 0
            }
        }
        if negative { x = 1 - x }
        func curve(_ v: Double) -> Double {
            switch type {
            case 1: return Synthesizer.concave(v)
            case 2: return 1 - Synthesizer.concave(1 - v)
            case 3: return v >= 0.5 ? 1 : 0
            default: return v
            }
        }
        if !bipolar { return curve(x) }
        let c = 2 * x - 1
        return c >= 0 ? curve(c) : -curve(-c)
    }

    static func concave(_ v: Double) -> Double {
        if v <= 0 { return 0 }
        if v >= 1 { return 1 }
        return min(1, max(0, -(20.0 / 96.0) * log10((1 - v) * (1 - v))))
    }

    // MARK: Rendering

    /// Renders `frames` stereo frames, adding into (not replacing) the output buffers.
    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            let n = min(block, frames - done)
            renderBlock(left: left + done, right: right + done, n: n)
            done += n
        }
    }

    public func render(frames: Int) -> (left: [Float], right: [Float]) {
        var l = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: frames)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                render(left: lp.baseAddress!, right: rp.baseAddress!, frames: frames)
            }
        }
        return (l, r)
    }

    func renderBlock(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, n: Int) {
        if dryL.count < n {
            dryL = [Float](repeating: 0, count: block); dryR = dryL; revIn = dryL; choIn = dryL
        }
        for i in 0..<n { dryL[i] = 0; dryR[i] = 0; revIn[i] = 0; choIn[i] = 0 }
        dryL.withUnsafeMutableBufferPointer { dl in
        dryR.withUnsafeMutableBufferPointer { dr in
        revIn.withUnsafeMutableBufferPointer { ri in
        choIn.withUnsafeMutableBufferPointer { ci in
            for v in voices where v.active {
                v.render(n: n, synth: self, outL: dl.baseAddress!, outR: dr.baseAddress!, rev: ri.baseAddress!, cho: ci.baseAddress!)
            }
            if reverbEnabled { reverb.process(input: ri.baseAddress!, outL: dl.baseAddress!, outR: dr.baseAddress!, n: n) }
            if chorusEnabled { chorus.process(input: ci.baseAddress!, outL: dl.baseAddress!, outR: dr.baseAddress!, n: n) }
            let g = masterGain
            for i in 0..<n {
                left[i] += dl[i] * g
                right[i] += dr[i] * g
            }
        }
        }
        }
        }
    }
}

/// One sounding sample with its envelopes, LFOs and filter.
final class Voice {
    var active = false
    var channel = 0, key = 60, velocity = 100
    var noteID: UInt64 = 0
    var released = false
    var sustained = false
    var exclusiveClass = 0
    var modsDirty = true

    var gens = [Double](repeating: 0, count: Gen.count)
    var modulated = [Double](repeating: 0, count: Gen.count)
    var mods: [SFModulator] = []
    var data: UnsafePointer<Float>? = nil
    var dataArray: [Float] = [] // keeps storage alive

    var pos = 0.0
    var start = 0, end = 0, loopStart = 0, loopEnd = 0, loopMode = 0
    var sampleRate = 44100.0
    var rootKey = 60
    var pitchCorrection = 0

    // envelopes
    var volStage = 0 // 0 delay,1 attack,2 hold,3 decay,4 sustain,5 release,6 done
    var volTime = 0.0
    var volAmp = 0.0      // linear amplitude during attack
    var volAtten = 0.0    // centibels during decay/release
    var modStage = 0
    var modTime = 0.0
    var modValue = 0.0
    var modReleaseStart = 0.0
    var lastGain: Float = 0
    // lfos
    var modLfoPhase = 0.0, vibLfoPhase = 0.0, lfoTime = 0.0
    // filter
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var lastFc = -1.0, lastQ = -1.0
    var filterOn = false
    var killFast = false

    func start(spec: SoundFont.VoiceSpec, data arr: [Float], channel ch: Int, key k: Int, velocity vel: Int, noteID id: UInt64, synth: Synthesizer) {
        active = true
        channel = ch; key = k; velocity = vel; noteID = id
        released = false; sustained = false; killFast = false
        gens = spec.gens
        mods = spec.mods
        if Int(gens[Gen.keynum.rawValue]) >= 0 { key = Int(gens[Gen.keynum.rawValue]) }
        if Int(gens[Gen.velocity.rawValue]) > 0 { velocity = Int(gens[Gen.velocity.rawValue]) }
        dataArray = arr
        let s = spec.sample
        func g(_ x: Gen) -> Int { Int(gens[x.rawValue]) }
        start = s.start + g(.startAddrsOffset) + 32768 * g(.startAddrsCoarseOffset)
        end = s.end + g(.endAddrsOffset) + 32768 * g(.endAddrsCoarseOffset)
        loopStart = s.loopStart + g(.startloopAddrsOffset) + 32768 * g(.startloopAddrsCoarseOffset)
        loopEnd = s.loopEnd + g(.endloopAddrsOffset) + 32768 * g(.endloopAddrsCoarseOffset)
        let n = arr.count
        start = max(0, min(n - 1, start)); end = max(start + 1, min(n - 1, end))
        loopStart = max(start, min(end - 1, loopStart)); loopEnd = max(loopStart + 1, min(end, loopEnd))
        loopMode = g(.sampleModes) & 3
        if loopEnd - loopStart < 4 { loopMode = 0 }
        sampleRate = s.sampleRate
        rootKey = g(.overridingRootKey) >= 0 ? g(.overridingRootKey) : (s.originalPitch == 255 ? 60 : s.originalPitch)
        pitchCorrection = s.pitchCorrection
        exclusiveClass = g(.exclusiveClass)
        pos = Double(start)
        volStage = 0; volTime = 0; volAmp = 0; volAtten = 0
        modStage = 0; modTime = 0; modValue = 0
        lastGain = 0
        modLfoPhase = 0; vibLfoPhase = 0; lfoTime = 0
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
        lastFc = -1; lastQ = -1
        modsDirty = true
        computeModulated(synth: synth)
        // skip zero-length stages immediately
    }

    func release() {
        guard active, !released else { return }
        released = true
        if volStage < 5 {
            // convert attack amplitude to attenuation for a smooth release
            if volStage <= 1 {
                let amp = volStage == 0 ? 0.0 : volAmp
                volAtten = amp <= 1e-5 ? 1000 : -200 * log10(amp)
            } else if volStage == 2 {
                volAtten = 0
            }
            volStage = 5
            volTime = 0
        }
        if modStage < 5 { modReleaseStart = modValue; modStage = 5; modTime = 0 }
    }

    func kill(fast: Bool) {
        if fast {
            killFast = true
            release()
        } else {
            active = false
        }
    }

    func computeModulated(synth: Synthesizer) {
        for i in 0..<Gen.count { modulated[i] = gens[i] }
        modulated[Gen.initialAttenuation.rawValue] *= synth.attenuationScale
        for m in mods {
            let d = Int(m.dest)
            guard d < Gen.count, m.dest & 0x8000 == 0 else { continue }
            let a = synth.sourceValue(m.src, voice: self)
            if a == 0 { continue }
            let b = synth.sourceValue(m.amtSrc, voice: self)
            var v = Double(m.amount) * a * b
            if m.transform == 2 { v = abs(v) }
            modulated[d] += v
        }
        modsDirty = false
    }

    @inline(__always) static func tc2sec(_ tc: Double) -> Double { tc <= -12000 ? 0 : pow(2, tc / 1200) }

    func render(n: Int, synth: Synthesizer, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>,
                rev: UnsafeMutablePointer<Float>, cho: UnsafeMutablePointer<Float>) {
        if modsDirty { computeModulated(synth: synth) }
        let sr = synth.sampleRate
        let dt = Double(n) / sr
        let m = modulated
        // ---------- modulation envelope
        let key = Double(self.key)
        func modEnvStep() {
            let delay = Voice.tc2sec(m[Gen.delayModEnv.rawValue])
            let attack = Voice.tc2sec(m[Gen.attackModEnv.rawValue])
            let hold = Voice.tc2sec(m[Gen.holdModEnv.rawValue] + m[Gen.keynumToModEnvHold.rawValue] * (60 - key))
            let decay = Voice.tc2sec(m[Gen.decayModEnv.rawValue] + m[Gen.keynumToModEnvDecay.rawValue] * (60 - key))
            let sustain = 1 - max(0, min(1000, m[Gen.sustainModEnv.rawValue])) / 1000
            let rel = Voice.tc2sec(m[Gen.releaseModEnv.rawValue])
            modTime += dt
            switch modStage {
            case 0: modValue = 0; if modTime >= delay { modStage = 1; modTime -= delay }
            case 1:
                modValue = attack <= 0 ? 1 : min(1, modTime / attack)
                if modTime >= attack { modStage = 2; modTime -= attack; modValue = 1 }
            case 2: modValue = 1; if modTime >= hold { modStage = 3; modTime -= hold }
            case 3:
                modValue = decay <= 0 ? sustain : max(sustain, 1 - modTime / decay)
                if modValue <= sustain { modStage = 4 }
            case 4: modValue = sustain
            case 5:
                modValue = rel <= 0 ? 0 : max(0, modReleaseStart - modTime / rel)
            default: modValue = 0
            }
        }
        modEnvStep()
        // ---------- volume envelope (returns linear gain at block end)
        let vDelay = Voice.tc2sec(m[Gen.delayVolEnv.rawValue])
        let vAttack = Voice.tc2sec(m[Gen.attackVolEnv.rawValue])
        let vHold = Voice.tc2sec(m[Gen.holdVolEnv.rawValue] + m[Gen.keynumToVolEnvHold.rawValue] * (60 - key))
        let vDecay = Voice.tc2sec(m[Gen.decayVolEnv.rawValue] + m[Gen.keynumToVolEnvDecay.rawValue] * (60 - key))
        let vSustain = max(0, min(1440, m[Gen.sustainVolEnv.rawValue]))
        var vRelease = Voice.tc2sec(m[Gen.releaseVolEnv.rawValue])
        if killFast { vRelease = min(vRelease, 0.006) }
        volTime += dt
        var envGain = 0.0
        loop: while true {
            switch volStage {
            case 0:
                if volTime >= vDelay { volStage = 1; volTime -= vDelay; continue loop }
                envGain = 0
            case 1:
                if vAttack <= 0 || volTime >= vAttack { volStage = 2; volTime -= max(0, vAttack); volAmp = 1; continue loop }
                volAmp = volTime / vAttack
                envGain = volAmp
            case 2:
                if volTime >= vHold { volStage = 3; volTime -= vHold; volAtten = 0; continue loop }
                envGain = 1
            case 3:
                volAtten = vDecay <= 0 ? vSustain : min(vSustain, 1000 * volTime / vDecay)
                if volAtten >= vSustain { volStage = 4 }
                envGain = pow(10, -volAtten / 200)
                if volAtten >= 960 { volStage = 6 }
            case 4:
                envGain = pow(10, -vSustain / 200)
                if vSustain >= 960 { volStage = 6 }
            case 5:
                let att = volAtten + (vRelease <= 0 ? 1000 : 1000 * volTime / vRelease)
                envGain = att >= 960 ? 0 : pow(10, -att / 200)
                if att >= 960 { volStage = 6 }
            default:
                envGain = 0
            }
            break
        }
        if volStage == 6 { active = false; return }
        // ---------- LFOs (triangle)
        lfoTime += dt
        func tri(_ phase: Double) -> Double {
            let p = phase - floor(phase)
            return p < 0.25 ? 4 * p : (p < 0.75 ? 2 - 4 * p : 4 * p - 4)
        }
        var modLfo = 0.0, vibLfo = 0.0
        if lfoTime >= Voice.tc2sec(m[Gen.delayModLFO.rawValue]) {
            modLfoPhase += dt * 8.176 * pow(2, m[Gen.freqModLFO.rawValue] / 1200)
            modLfo = tri(modLfoPhase)
        }
        if lfoTime >= Voice.tc2sec(m[Gen.delayVibLFO.rawValue]) {
            vibLfoPhase += dt * 8.176 * pow(2, m[Gen.freqVibLFO.rawValue] / 1200)
            vibLfo = tri(vibLfoPhase)
        }
        // ---------- pitch
        var cents = (key - Double(rootKey)) * m[Gen.scaleTuning.rawValue]
        cents += m[Gen.coarseTune.rawValue] * 100 + m[Gen.fineTune.rawValue] + Double(pitchCorrection)
        cents += modLfo * m[Gen.modLfoToPitch.rawValue] + vibLfo * m[Gen.vibLfoToPitch.rawValue] + modValue * m[Gen.modEnvToPitch.rawValue]
        cents += m[Gen.pitch]
        let ratio = pow(2, cents / 1200) * sampleRate / sr
        // ---------- filter
        let fc = m[Gen.initialFilterFc.rawValue] + modLfo * m[Gen.modLfoToFilterFc.rawValue] + modValue * m[Gen.modEnvToFilterFc.rawValue]
        let qdb = max(0, min(960, m[Gen.initialFilterQ.rawValue])) / 10
        var fHz = 8.176 * pow(2, max(1500, min(13500, fc)) / 1200)
        fHz = min(fHz, 0.45 * sr)
        filterOn = !(fc >= 13490 && qdb < 0.5) && fHz < 0.45 * sr - 1
        if filterOn && (abs(fHz - lastFc) > 0.5 || abs(qdb - lastQ) > 0.01) {
            let q = max(0.7071, pow(10, qdb / 20))
            let w0 = 2 * Double.pi * fHz / sr
            let alpha = sin(w0) / (2 * q)
            let cw = cos(w0)
            let a0 = 1 + alpha
            let gainComp = 1 / max(1, sqrt(q)) // keep resonant peaks from exploding
            b0 = (1 - cw) / 2 / a0 * gainComp
            b1 = (1 - cw) / a0 * gainComp
            b2 = b0
            a1 = -2 * cw / a0
            a2 = (1 - alpha) / a0
            lastFc = fHz; lastQ = qdb
        }
        // ---------- gain & pan
        let atten = max(0, m[Gen.initialAttenuation.rawValue]) + modLfo * m[Gen.modLfoToVolume.rawValue]
        let attGain = pow(10, -max(0, min(1440, atten)) / 200)
        let target = Float(envGain * attGain)
        let pan = max(-500, min(500, m[Gen.pan.rawValue])) / 1000 + 0.5
        let gl = Float(cos(pan * Double.pi / 2)), gr = Float(sin(pan * Double.pi / 2))
        let revSend = Float(max(0, min(1000, m[Gen.reverbEffectsSend.rawValue])) / 1000)
        let choSend = Float(max(0, min(1000, m[Gen.chorusEffectsSend.rawValue])) / 1000)
        // ---------- sample loop
        let looping = loopMode == 1 || (loopMode == 3 && !released)
        let ls = Double(loopStart), le = Double(loopEnd), loopLen = le - ls
        let endD = Double(end)
        var p = pos
        var g = lastGain
        let gStep = (target - g) / Float(n)
        var fx1 = x1, fx2 = x2, fy1 = y1, fy2 = y2
        let fb0 = b0, fb1 = b1, fb2 = b2, fa1 = a1, fa2 = a2
        let useFilter = filterOn
        var finished = false
        dataArray.withUnsafeBufferPointer { dp in
            let d = dp.baseAddress!
            let last = dp.count - 1
            @inline(__always) func at(_ i: Int) -> Double {
                var j = i
                if looping && j >= loopEnd { j -= loopEnd - loopStart }
                if j < 0 { j = 0 }
                if j > last { j = last }
                return Double(d[j])
            }
            for i in 0..<n {
                let ip = Int(p)
                let f = p - Double(ip)
                // 4-point cubic Hermite interpolation
                let xm1 = at(ip - 1), x0 = at(ip), xp1 = at(ip + 1), xp2 = at(ip + 2)
                let c1 = 0.5 * (xp1 - xm1)
                let c2 = xm1 - 2.5 * x0 + 2 * xp1 - 0.5 * xp2
                let c3 = 0.5 * (xp2 - xm1) + 1.5 * (x0 - xp1)
                var s = ((c3 * f + c2) * f + c1) * f + x0
                if useFilter {
                    let y = fb0 * s + fb1 * fx1 + fb2 * fx2 - fa1 * fy1 - fa2 * fy2
                    fx2 = fx1; fx1 = s; fy2 = fy1; fy1 = y
                    s = y
                }
                g += gStep
                let v = Float(s) * g
                outL[i] += v * gl
                outR[i] += v * gr
                rev[i] += v * revSend
                cho[i] += v * choSend
                p += ratio
                if looping {
                    if p >= le { p -= loopLen * floor((p - ls) / loopLen) }
                } else if p >= endD {
                    finished = true
                    break
                }
            }
        }
        // denormal guard
        if abs(fy1) < 1e-20 { fy1 = 0 }
        if abs(fy2) < 1e-20 { fy2 = 0 }
        x1 = fx1; x2 = fx2; y1 = fy1; y2 = fy2
        pos = p
        lastGain = target
        if finished { active = false }
    }
}

/// Freeverb-style stereo reverb.
final class Reverb {
    final class Comb {
        var buf: [Float]; var idx = 0; var store: Float = 0
        init(_ n: Int) { buf = [Float](repeating: 0, count: n) }
        @inline(__always) func process(_ x: Float, feedback: Float, damp: Float) -> Float {
            let y = buf[idx]
            store = y * (1 - damp) + store * damp
            buf[idx] = x + store * feedback
            idx += 1; if idx >= buf.count { idx = 0 }
            return y
        }
    }
    final class Allpass {
        var buf: [Float]; var idx = 0
        init(_ n: Int) { buf = [Float](repeating: 0, count: n) }
        @inline(__always) func process(_ x: Float) -> Float {
            let b = buf[idx]
            let y = -x + b
            buf[idx] = x + b * 0.5
            idx += 1; if idx >= buf.count { idx = 0 }
            return y
        }
    }
    var combL: [Comb], combR: [Comb], apL: [Allpass], apR: [Allpass]
    var roomSize: Float = 0.78
    var damp: Float = 0.35
    var wet: Float = 0.32

    init(sampleRate: Double) {
        let s = sampleRate / 44100
        let combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
        let aps = [556, 441, 341, 225]
        combL = combs.map { Comb(Int(Double($0) * s)) }
        combR = combs.map { Comb(Int(Double($0 + 23) * s)) }
        apL = aps.map { Allpass(Int(Double($0) * s)) }
        apR = aps.map { Allpass(Int(Double($0 + 23) * s)) }
    }

    func clear() {
        for c in combL + combR { for i in c.buf.indices { c.buf[i] = 0 }; c.store = 0 }
        for a in apL + apR { for i in a.buf.indices { a.buf[i] = 0 } }
    }

    func process(input: UnsafeMutablePointer<Float>, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, n: Int) {
        let fb = roomSize, dm = damp
        for i in 0..<n {
            let x = input[i] * 0.015
            var l: Float = 0, r: Float = 0
            for c in combL { l += c.process(x, feedback: fb, damp: dm) }
            for c in combR { r += c.process(x, feedback: fb, damp: dm) }
            for a in apL { l = a.process(l) }
            for a in apR { r = a.process(r) }
            outL[i] += l * wet * 3
            outR[i] += r * wet * 3
        }
    }
}

/// Simple stereo chorus (two modulated delay taps).
final class Chorus {
    var buf: [Float]
    var idx = 0
    var phase = 0.0
    let sr: Double
    var depth = 0.0025
    var base = 0.012
    var rate = 0.35
    var level: Float = 0.6

    init(sampleRate: Double) {
        sr = sampleRate
        buf = [Float](repeating: 0, count: Int(sampleRate * 0.05))
    }

    func clear() { for i in buf.indices { buf[i] = 0 } }

    func process(input: UnsafeMutablePointer<Float>, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, n: Int) {
        let len = buf.count
        for i in 0..<n {
            buf[idx] = input[i]
            phase += rate / sr
            if phase > 1 { phase -= 1 }
            let m1 = (base + depth * sin(2 * Double.pi * phase)) * sr
            let m2 = (base + depth * sin(2 * Double.pi * (phase + 0.25))) * sr
            func tap(_ delay: Double) -> Float {
                let pos = Double(idx) - delay
                var p = pos.truncatingRemainder(dividingBy: Double(len))
                if p < 0 { p += Double(len) }
                let i0 = Int(p), f = Float(p - Double(i0))
                let a = buf[i0], b = buf[(i0 + 1) % len]
                return a + (b - a) * f
            }
            outL[i] += tap(m1) * level
            outR[i] += tap(m2) * level
            idx += 1; if idx >= len { idx = 0 }
        }
    }
}
