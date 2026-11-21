import Foundation

/// Beat grid detected from audio.
public struct BeatGrid: Codable, Equatable {
    public var bpm: Double
    /// Seconds (audio time) of the first downbeat at or after the music start (beat 0).
    public var firstDownbeat: Double
    public var beatsPerBar: Int
    /// 0...1, how well onsets agree with the grid.
    public var confidence: Double
    /// Full tempo map (beat 0 = firstDownbeat). Contains several segments for drifting/live tempo.
    public var tempo: TempoMap
    /// Median absolute deviation (ms) of on-beat onsets from the grid.
    public var residualMs: Double
}

public struct AudioAnalysis {
    public var grid: BeatGrid
    public var duration: Double
    public var drums: [DrumHit]
    public var melody: [PitchedNote]
    public var harmony: [PitchedNote]
    public var bass: [PitchedNote]
    public var beatEnergy: [Double]
    public var sectionStarts: [Double]
    public var onsetTimes: [Double]
    public var melodySource: String
}

public enum AudioAnalyzer {
    public static let analysisRate = 22050.0
    static let hop = 256
    static let nFFT = 2048

    struct Frontend {
        var x: [Float]               // mono, 22.05 kHz
        var frameRate: Double
        var mel: [[Float]]           // frames x 64, log power (dB)
        var melFreqs: [Double]
        var ose: [Float]             // broadband onset envelope (hop 256)
        var chroma: [[Float]] = []   // frames x 12 (110 Hz - 2 kHz)
        /// Percussive part (HPSS) of a 96-band mel power spectrogram, in dB.
        var perc: [[Float]] = []
        var percFreqs: [Double] = []
        /// Share of spectral energy that is percussive (0 = no drums).
        var percussiveness: Double = 0
        var bassChroma: [[Float]] = [] // frames x 12 (40 - 220 Hz)
        var fineOnsets: [(time: Double, strength: Float)] // precise onsets (hop 64)
    }

    // MARK: Public entry

    /// Analyses audio. Supply Basic Pitch note events (times in seconds) when available.
    public static func analyze(_ audio: AudioSamples, transcription: [BasicPitch.NoteEvent]? = nil,
                               progress: ((Double, String) -> Void)? = nil) -> AudioAnalysis {
        progress?(0.02, "Preparing audio")
        let mono = audio.mono()
        let x = DSP.resample(mono, from: audio.sampleRate, to: analysisRate)
        progress?(0.12, "Spectral analysis")
        let fe = frontend(x)
        progress?(0.35, "Tempo & beat grid")
        let grid = beatGrid(fe)
        progress?(0.55, "Drums")
        let drumHitsT = detectDrums(fe)
        let drums = drumHitsT.map { DrumHit(beat: grid.tempo.beat(atTime: $0.time), kind: $0.kind, strength: $0.strength) }
        progress?(0.65, "Melody")
        var melody: [PitchedNote] = [], harmony: [PitchedNote] = [], bass: [PitchedNote] = []
        var source = "Basic Pitch"
        if let tr = transcription, !tr.isEmpty {
            (melody, harmony, bass) = splitTranscription(tr, tempo: grid.tempo, onsets: fe.fineOnsets.map { $0.time })
        } else {
            source = "DSP pitch tracker"
            let notes = MelodyTracker.snapToOnsets(MelodyTracker.track(fe.x, sampleRate: analysisRate), onsets: fe.fineOnsets.map { $0.time })
            melody = notes.map { PitchedNote(beat: grid.tempo.beat(atTime: $0.start), duration: max(0.05, grid.tempo.beat(atTime: $0.end) - grid.tempo.beat(atTime: $0.start)), pitch: $0.pitch, strength: $0.strength) }
        }
        // real attacks not explained by melody/drums/harmony (arpeggios, hats, plucks)
        var explained = (melody + harmony + bass).map { grid.tempo.time(atBeat: $0.beat) } + drumHitsT.map { $0.time }
        explained.sort()
        var extra: [DrumHit] = []
        let strengths = fe.fineOnsets.map { Double($0.strength) }.sorted()
        let medianStrength = strengths.isEmpty ? 1 : strengths[strengths.count / 2]
        for o in fe.fineOnsets where Double(o.strength) >= medianStrength * 0.8 {
            if nearestOnset(o.time, explained, before: 0.035, after: 0.035) == nil {
                extra.append(DrumHit(beat: grid.tempo.beat(atTime: o.time), kind: .perc, strength: min(0.5, Double(o.strength) / (medianStrength * 4))))
            }
        }
        let allDrums = (drums + extra).sorted { $0.beat < $1.beat }
        progress?(0.85, "Energy & sections")
        let duration = Double(mono.count) / audio.sampleRate
        let endBeat = grid.tempo.beat(atTime: duration)
        let energy = beatEnergy(fe, tempo: grid.tempo, endBeat: endBeat)
        let sections = sectionStarts(energy: energy, drums: drums, beatsPerBar: grid.beatsPerBar)
        progress?(1, "Done")
        return AudioAnalysis(grid: grid, duration: duration, drums: allDrums, melody: melody, harmony: harmony, bass: bass,
                             beatEnergy: energy, sectionStarts: sections, onsetTimes: fe.fineOnsets.map { $0.time }, melodySource: source)
    }

    public static func features(_ a: AudioAnalysis, title: String, artist: String) -> SongFeatures {
        let end = a.grid.tempo.beat(atTime: a.duration)
        return SongFeatures(title: title, artist: artist, source: .audio, tempo: a.grid.tempo,
                            timeSignatures: [TimeSignature(beat: 0, numerator: a.grid.beatsPerBar, denominator: 4)],
                            endBeat: end, melody: a.melody, harmony: a.harmony, bass: a.bass, drums: a.drums,
                            beatEnergy: a.beatEnergy, sectionStarts: a.sectionStarts)
    }

    // MARK: Frontend

    static func frontend(_ x: [Float]) -> Frontend {
        let spec = DSP.stft(x, sampleRate: analysisRate, nFFT: nFFT, hop: hop, power: true)
        let fb = DSP.melFilterbank(sampleRate: analysisRate, nFFT: nFFT, nMels: 64, fMin: 30, fMax: 11000)
        let melP = DSP.applyFilterbank(spec, fb)
        let mel = melP.map { row in row.map { 10 * log10($0 + 1e-10) } }
        let melMin = DSP.hzToMel(30), melMax = DSP.hzToMel(11000)
        let melFreqs = (0..<64).map { DSP.melToHz(melMin + (melMax - melMin) * Double($0 + 1) / 65) }
        // SuperFlux-style onset envelope: max-filtered reference, lag 1
        var ose = [Float](repeating: 0, count: mel.count)
        for t in 1..<max(1, mel.count) {
            var s: Float = 0
            for b in 0..<64 {
                let ref = max(mel[t - 1][max(0, b - 1)], mel[t - 1][b], mel[t - 1][min(63, b + 1)])
                s += max(0, mel[t][b] - ref)
            }
            ose[t] = s / 64
        }
        let local = DSP.movingAverage(ose, radius: 20)
        for i in ose.indices { ose[i] = max(0, ose[i] - local[i]) }
        let fine = fineOnsets(x)
        var chroma = [[Float]](repeating: [Float](repeating: 0, count: 12), count: spec.frames)
        var bassChroma = chroma
        let binHz = analysisRate / Double(nFFT)
        var pcOf = [Int](repeating: -1, count: spec.bins)
        for k in 1..<spec.bins {
            let f = Double(k) * binHz
            if f >= 40 && f <= 2000 { pcOf[k] = ((Int((12 * log2(f / 440) + 69).rounded()) % 12) + 12) % 12 }
        }
        spec.data.withUnsafeBufferPointer { sp in
            for t in 0..<spec.frames {
                let base = t * spec.bins
                for k in 1..<spec.bins where pcOf[k] >= 0 {
                    let f = Double(k) * binHz
                    let v = sp[base + k].squareRoot()
                    if f >= 110 { chroma[t][pcOf[k]] += v }
                    if f <= 220 { bassChroma[t][pcOf[k]] += v }
                }
            }
        }
        var fe = Frontend(x: x, frameRate: analysisRate / Double(hop), mel: mel, melFreqs: melFreqs, ose: ose, fineOnsets: fine)
        fe.chroma = chroma
        fe.bassChroma = bassChroma
        // ---- mel-domain HPSS (median across time = harmonic, across frequency = percussive)
        let nb = 96
        let fb2 = DSP.melFilterbank(sampleRate: analysisRate, nFFT: nFFT, nMels: nb, fMin: 30, fMax: 11000)
        let mp = DSP.applyFilterbank(spec, fb2)
        let frames = mp.count
        var harm = [[Float]](repeating: [Float](repeating: 0, count: nb), count: frames)
        for b in 0..<nb {
            let col = DSP.movingMedian(mp.map { $0[b] }, window: 17)
            for t in 0..<frames { harm[t][b] = col[t] }
        }
        var percDB = [[Float]](repeating: [Float](repeating: -100, count: nb), count: frames)
        var pe = 0.0, te = 0.0
        for t in 0..<frames {
            let pv = DSP.movingMedian(mp[t], window: 13)
            for b in 0..<nb {
                let p2 = pv[b] * pv[b], h2 = harm[t][b] * harm[t][b]
                let mask = p2 / (p2 + h2 + 1e-20)
                let v = mp[t][b] * mask
                percDB[t][b] = 10 * log10(v + 1e-10)
                pe += Double(v); te += Double(mp[t][b])
            }
        }
        let m0 = DSP.hzToMel(30), m1 = DSP.hzToMel(11000)
        fe.perc = percDB
        fe.percFreqs = (0..<nb).map { DSP.melToHz(m0 + (m1 - m0) * Double($0 + 1) / Double(nb + 1)) }
        fe.percussiveness = te > 0 ? pe / te : 0
        return fe
    }

    /// High time-resolution onsets (2.9 ms hop) with bias-corrected times.
    public static func fineOnsets(_ x: [Float]) -> [(time: Double, strength: Float)] {
        let h = 64, n = 512
        let spec = DSP.stft(x, sampleRate: analysisRate, nFFT: n, hop: h, power: true)
        let fb = DSP.melFilterbank(sampleRate: analysisRate, nFFT: n, nMels: 32, fMin: 40, fMax: 11000)
        let mel = DSP.applyFilterbank(spec, fb).map { $0.map { 10 * log10($0 + 1e-10) } }
        var flux = [Float](repeating: 0, count: mel.count)
        for t in 2..<max(2, mel.count) {
            var s: Float = 0
            for b in 0..<32 { s += max(0, mel[t][b] - max(mel[t - 1][b], mel[t - 2][b])) }
            flux[t] = s / 32
        }
        let avg = DSP.movingAverage(flux, radius: 80)
        var peaks: [(Double, Float)] = []
        let fr = analysisRate / Double(h)
        // loudness gate: ignore attacks far below the song's loud passages (reverb tails, noise)
        var frameDB = [Float](repeating: -120, count: mel.count)
        for t in 0..<mel.count { frameDB[t] = mel[t].max() ?? -120 }
        let loud = DSP.percentile(frameDB, 0.9)
        let gate = loud - 32
        var last = -1000
        for t in 3..<max(3, flux.count - 3) {
            let v = flux[t]
            guard v > flux[t - 1], v >= flux[t + 1], v >= flux[t - 2], v >= flux[t + 2], v >= flux[t - 3], v >= flux[t + 3] else { continue }
            guard v > avg[t] * 1.6 + 0.4 else { continue }
            guard frameDB[min(mel.count - 1, t + 2)] > gate else { continue }
            if t - last < Int(0.03 * fr) { continue }
            // parabolic refinement; flux at frame t reflects energy entering frame centres around t*h
            let off = DSP.parabolicOffset(Double(flux[t - 1]), Double(v), Double(flux[t + 1]))
            let time = (Double(t) + off) * Double(h) / analysisRate - onsetBias
            peaks.append((time, v))
            last = t
        }
        return peaks
    }

    /// Calibrated latency of the fine onset detector (seconds), measured on synthetic click tracks.
    static var onsetBias = -0.0089

    // MARK: Tempo & grid

    static func prior(_ bpm: Double) -> Double { exp(-0.5 * pow(log2(bpm / 150) / 0.85, 2)) }

    /// Magnitude/phase of the onset envelope at frequency f (Hz) over frames [a, b).
    static func dft(_ ose: [Double], fr: Double, f: Double, a: Int, b: Int) -> (mag: Double, phase: Double) {
        var re = 0.0, im = 0.0
        let w = -2 * Double.pi * f / fr
        var cr = cos(w * Double(a)), ci = sin(w * Double(a))
        let dr = cos(w), di = sin(w)
        for t in a..<max(a, b) {
            re += ose[t] * cr; im += ose[t] * ci
            let nr = cr * dr - ci * di
            ci = cr * di + ci * dr
            cr = nr
        }
        return ((re * re + im * im).squareRoot(), atan2(im, re))
    }

    struct SegmentFit { var bpm: Double; var t0: Double; var residualMs: Double; var matched: Int; var expected: Double }

    /// Tempo + phase for the audio between tStart and tEnd (seconds), optionally near a BPM hint.
    static func fitSegment(_ fe: Frontend, ose: [Double], tStart: Double, tEnd: Double, hint: Double?) -> SegmentFit {
        let fr = fe.frameRate
        let a = max(0, Int(tStart * fr)), b = min(ose.count, Int(tEnd * fr))
        let n = b - a
        let z: [Double] = {
            let seg = Array(ose[a..<max(a, b)])
            let m = seg.reduce(0, +) / Double(max(1, seg.count))
            return seg.map { $0 - m }
        }()
        func comb(_ bpm: Double) -> Double {
            dft(ose, fr: fr, f: bpm / 60, a: a, b: b).mag + 0.5 * dft(ose, fr: fr, f: 2 * bpm / 60, a: a, b: b).mag
                + 0.25 * dft(ose, fr: fr, f: 4 * bpm / 60, a: a, b: b).mag
        }
        var best: Double
        if let h = hint {
            best = h
        } else {
            // autocorrelation tempo with prior + harmonics
            let maxLag = min(n - 1, Int(60 * fr / 50) * 2 + 2)
            var ac = [Double](repeating: 0, count: max(2, maxLag + 2))
            if maxLag > 1 {
                for L in 1...maxLag {
                    var s = 0.0
                    var t = 0
                    while t + L < n { s += z[t] * z[t + L]; t += 1 }
                    ac[L] = s / Double(max(1, n - L))
                }
            }
            func acAt(_ lag: Double) -> Double {
                let i = Int(lag)
                if i < 1 || i + 1 >= ac.count { return 0 }
                let f = lag - Double(i)
                return ac[i] * (1 - f) + ac[i + 1] * f
            }
            best = 120
            var bestS = -Double.infinity
            var bpm = 70.0
            while bpm <= 240 {
                let L = 60 * fr / bpm
                let s = (acAt(L) + 0.5 * acAt(2 * L) + 0.25 * acAt(4 * L)) * prior(bpm)
                if s > bestS { bestS = s; best = bpm }
                bpm += 0.25
            }
            var candidates = [best, best * 2, best / 2, best * 1.5, best / 1.5].filter { $0 >= 60 && $0 <= 260 }
            candidates = candidates.map { c -> Double in
                var bb = c, bs = -Double.infinity
                var x = c * 0.985
                while x <= c * 1.015 { let sc = comb(x); if sc > bs { bs = sc; bb = x }; x += c * 0.0005 }
                return bb
            }
            var chosenScore = -Double.infinity
            for c in candidates {
                let sc = comb(c) * prior(c) * (c > 225 ? 0.7 : 1) * (c < 90 ? 0.75 : 1)
                if sc > chosenScore { chosenScore = sc; best = c }
            }
        }
        var bpmEst = best
        var bs = -Double.infinity
        let span = hint == nil ? 0.6 : max(0.6, best * 0.02)
        var x = best - span
        let step = hint == nil ? 0.002 : 0.005
        while x <= best + span { let sc = comb(x); if sc > bs { bs = sc; bpmEst = x }; x += step }
        let ph = dft(ose, fr: fr, f: bpmEst / 60, a: 0, b: ose.count > b ? b : ose.count).phase
        let period = 60 / bpmEst
        // phase of a DFT taken from frame 0 gives beat times t0 + k*period
        var t0 = (-ph / (2 * Double.pi)) * period
        t0 = t0.truncatingRemainder(dividingBy: period); if t0 < 0 { t0 += period }
        // refine with precise onsets inside the segment
        let onsets = fe.fineOnsets.filter { $0.time >= tStart - 0.05 && $0.time < tEnd + 0.05 }
        var period2 = period, t02 = t0
        var residuals: [Double] = []
        for iteration in 0..<4 {
            var xs: [Double] = [], ys: [Double] = [], ws: [Double] = []
            let tol = iteration == 0 ? 0.07 : 0.045
            for o in onsets {
                let k = ((o.time - t02) / period2).rounded()
                let pred = t02 + k * period2
                if abs(o.time - pred) < tol { xs.append(k); ys.append(o.time); ws.append(Double(o.strength)) }
            }
            guard xs.count >= 8 else { break }
            let sw = ws.reduce(0, +)
            let mx = zip(xs, ws).reduce(0) { $0 + $1.0 * $1.1 } / sw
            let my = zip(ys, ws).reduce(0) { $0 + $1.0 * $1.1 } / sw
            var sxx = 0.0, sxy = 0.0
            for i in xs.indices { sxx += ws[i] * (xs[i] - mx) * (xs[i] - mx); sxy += ws[i] * (xs[i] - mx) * (ys[i] - my) }
            if sxx > 0 {
                let slope = sxy / sxx
                if slope > period * 0.97 && slope < period * 1.03 { period2 = slope }
                t02 = my - period2 * mx
            }
            residuals = xs.indices.map { ys[$0] - (t02 + xs[$0] * period2) }
        }
        var finalBPM = 60 / period2
        let segDur = max(1, tEnd - tStart)
        for stepB in [1.0, 0.5, 0.25] {
            let nice = (finalBPM / stepB).rounded() * stepB
            if abs(nice - finalBPM) < 0.08 {
                let drift = abs(60 / nice - period2) * (segDur / period2)
                if drift < 0.012 { finalBPM = nice; break }
            }
        }
        let periodF = 60 / finalBPM
        var devs: [Double] = []
        for o in onsets {
            let k = ((o.time - t02) / periodF).rounded()
            let d = o.time - (t02 + k * periodF)
            if abs(d) < 0.045 { devs.append(d) }
        }
        if !devs.isEmpty { devs.sort(); t02 += devs[devs.count / 2] }
        let absRes = residuals.map { abs($0) }.sorted()
        let mad = absRes.isEmpty ? 50 : absRes[absRes.count / 2] * 1000
        return SegmentFit(bpm: finalBPM, t0: t02, residualMs: mad, matched: devs.count, expected: segDur / periodF)
    }

    /// Local tempo per window (8 s, hop 2 s) smoothed with Viterbi; returns (centre time, bpm).
    static func localTempoPath(_ ose: [Double], fr: Double) -> [(t: Double, bpm: Double)] {
        let win = Int(8 * fr), hopW = Int(2 * fr)
        guard ose.count > win + hopW else { return [] }
        var windows: [[(bpm: Double, score: Double)]] = []
        var centres: [Double] = []
        var s = 0
        while s + win <= ose.count {
            let seg = Array(ose[s..<(s + win)])
            let m = seg.reduce(0, +) / Double(seg.count)
            let z = seg.map { $0 - m }
            var cands: [(Double, Double)] = []
            var prevScore = -Double.infinity, prev2 = -Double.infinity
            var bpm = 70.0
            var scores: [(Double, Double)] = []
            while bpm <= 240 {
                let L = 60 * fr / bpm
                func ac(_ lag: Double) -> Double {
                    let i = Int(lag)
                    guard i >= 1, i + 1 < z.count else { return 0 }
                    let f = lag - Double(i)
                    var a = 0.0, b2 = 0.0
                    var t = 0
                    while t + i + 1 < z.count { a += z[t] * z[t + i]; b2 += z[t] * z[t + i + 1]; t += 1 }
                    return (a * (1 - f) + b2 * f) / Double(z.count)
                }
                let sc = ac(L) + 0.5 * ac(2 * L)
                scores.append((bpm, sc))
                bpm += 1
            }
            for k in 1..<(scores.count - 1) where scores[k].1 > scores[k - 1].1 && scores[k].1 >= scores[k + 1].1 && scores[k].1 > 0 {
                cands.append((scores[k].0, scores[k].1 * prior(scores[k].0)))
            }
            _ = prevScore; _ = prev2
            cands.sort { $0.1 > $1.1 }
            let top = Array(cands.prefix(6))
            let mx = top.first?.1 ?? 1
            windows.append(top.isEmpty ? [(120, 0)] : top.map { ($0.0, $0.1 / max(1e-9, mx)) })
            centres.append((Double(s) + Double(win) / 2) / fr)
            s += hopW
            prevScore = 0
        }
        // Viterbi: reward score, penalise tempo jumps (octave jumps cost more)
        var cost = windows[0].map { -log(max(1e-3, $0.score)) }
        var back: [[Int]] = [Array(repeating: 0, count: windows[0].count)]
        for w in 1..<windows.count {
            var nc = [Double](repeating: .infinity, count: windows[w].count)
            var nb = [Int](repeating: 0, count: windows[w].count)
            for (j, c) in windows[w].enumerated() {
                for (i, p) in windows[w - 1].enumerated() {
                    let jump = abs(log2(c.bpm / p.bpm))
                    let penalty = jump < 0.02 ? 0 : (jump < 0.12 ? 2.5 + 30 * jump : 6)
                    let v = cost[i] + penalty - log(max(1e-3, c.score))
                    if v < nc[j] { nc[j] = v; nb[j] = i }
                }
            }
            cost = nc
            back.append(nb)
        }
        var idx = cost.enumerated().min { $0.element < $1.element }!.offset
        var path = [Double](repeating: 0, count: windows.count)
        for w in stride(from: windows.count - 1, through: 0, by: -1) {
            path[w] = windows[w][idx].bpm
            idx = back[w][idx]
        }
        return zip(centres, path).map { ($0, $1) }
    }

    static func beatGrid(_ fe: Frontend) -> BeatGrid {
        let ose = fe.ose.map { Double($0) }
        let duration = Double(fe.x.count) / analysisRate
        // ---- tempo segments from the local tempo path
        let path = localTempoPath(ose, fr: fe.frameRate)
        var segments: [(start: Double, end: Double, bpm: Double)] = []
        for p in path {
            if let last = segments.last, abs(log2(p.bpm / last.bpm)) < 0.025 {
                segments[segments.count - 1].end = p.t
            } else {
                segments.append((p.t - 1, p.t, p.bpm))
            }
        }
        // merge short segments (< 10 s) into their neighbours
        var merged: [(start: Double, end: Double, bpm: Double)] = []
        for sgm in segments {
            if let last = merged.last, sgm.end - sgm.start < 10 || last.end - last.start < 10 && merged.count == 1 && false {
                merged[merged.count - 1].end = sgm.end
            } else if sgm.end - sgm.start < 10, var last = merged.popLast() {
                last.end = sgm.end; merged.append(last)
            } else {
                merged.append(sgm)
            }
        }
        // collapse octave-equivalent neighbours (same tempo reported at x2)
        var finalSegs: [(start: Double, end: Double, bpm: Double)] = []
        for sgm in merged {
            if let last = finalSegs.last {
                let r = sgm.bpm / last.bpm
                if abs(log2(r)) < 0.025 || abs(log2(r) - 1) < 0.025 || abs(log2(r) + 1) < 0.025 {
                    finalSegs[finalSegs.count - 1].end = sgm.end
                    continue
                }
            }
            finalSegs.append(sgm)
        }
        var tempo: TempoMap
        var mainFit: SegmentFit
        if finalSegs.count <= 1 {
            mainFit = fitSegment(fe, ose: ose, tStart: 0, tEnd: duration, hint: nil)
            let period = 60 / mainFit.bpm
            var first = mainFit.t0.truncatingRemainder(dividingBy: period)
            if first < 0 { first += period }
            tempo = TempoMap(bpm: mainFit.bpm, offset: first)
            if let pw = piecewiseTempo(onsets: fe.fineOnsets, bpm: mainFit.bpm, firstBeat: first) { tempo = pw }
        } else {
            // fit each segment around its local tempo, then join at beat boundaries
            finalSegs[0].start = 0
            finalSegs[finalSegs.count - 1].end = duration
            for i in 1..<finalSegs.count { finalSegs[i].start = finalSegs[i - 1].end }
            var fits = finalSegs.map { fitSegment(fe, ose: ose, tStart: $0.start, tEnd: $0.end, hint: $0.bpm) }
            // refine each boundary: the split that best explains the onsets on both grids
            for i in 1..<finalSegs.count {
                let a = fits[i - 1], b = fits[i]
                let pa = 60 / a.bpm, pb = 60 / b.bpm
                let centre = finalSegs[i].start
                let window = fe.fineOnsets.filter { abs($0.time - centre) < 10 }
                func onGrid(_ t: Double, _ t0: Double, _ p: Double) -> Bool {
                    let k = ((t - t0) / p).rounded()
                    return abs(t - (t0 + k * p)) < 0.025
                }
                var bestT = centre, bestScore = -1
                var cand = centre - 9
                while cand <= centre + 9 {
                    var sc = 0
                    for o in window { if o.time < cand ? onGrid(o.time, a.t0, pa) : onGrid(o.time, b.t0, pb) { sc += 1 } }
                    if sc > bestScore { bestScore = sc; bestT = cand }
                    cand += 0.05
                }
                finalSegs[i].start = bestT
                finalSegs[i - 1].end = bestT
            }
            fits = finalSegs.map { fitSegment(fe, ose: ose, tStart: $0.start, tEnd: $0.end, hint: $0.bpm) }
            mainFit = fits.max { $0.matched < $1.matched }!
            var changes: [(beat: Double, bpm: Double)] = []
            let p0 = 60 / fits[0].bpm
            var first = fits[0].t0.truncatingRemainder(dividingBy: p0)
            if first < 0 { first += p0 }
            changes.append((0, fits[0].bpm))
            var segStartBeat = 0.0
            var segStartTime = first
            for i in 1..<fits.count {
                let prev = fits[i - 1], cur = fits[i]
                let pPrev = 60 / prev.bpm, pCur = 60 / cur.bpm
                // beats of the previous segment up to the boundary, rounded to whole bars of 4
                let boundary = finalSegs[i].start
                let rawBeats = (boundary - segStartTime) / pPrev
                let barBeats = (rawBeats / 4).rounded() * 4
                let beatsInPrev = max(4, abs(rawBeats - barBeats) < 1.2 ? barBeats : rawBeats.rounded())
                let nominalTime = segStartTime + beatsInPrev * pPrev
                // the current grid's beat closest to that time
                let k = ((nominalTime - cur.t0) / pCur).rounded()
                let actual = cur.t0 + k * pCur
                // stretch the last bar of the previous segment so the change lands exactly on the new grid
                let lastBarStart = segStartTime + (beatsInPrev - 4) * pPrev
                let adjBPM = 240 / max(0.1, actual - lastBarStart)
                if abs(adjBPM - prev.bpm) / prev.bpm < 0.06 && abs(adjBPM - prev.bpm) > 0.001 {
                    changes.append((segStartBeat + beatsInPrev - 4, adjBPM))
                }
                segStartBeat += beatsInPrev
                segStartTime = actual
                changes.append((segStartBeat, cur.bpm))
            }
            tempo = TempoMap(changes: changes, offset: first)
        }
        // ---- downbeat & meter
        let (downIdx, beatsPerBar) = downbeat(fe, tempo: tempo)
        let rebased = tempo.rebased(toBeat: Double(downIdx))
        var finalTempo = rebased
        var k = 0
        while finalTempo.time(atBeat: Double(-beatsPerBar * (k + 1))) >= 0 && k < 64 { k += 1 }
        if k > 0 { finalTempo = rebased.rebased(toBeat: Double(-beatsPerBar * k)) }
        let confidence = max(0, min(1, Double(mainFit.matched) / max(1, mainFit.expected) * 0.6 + (1 - min(1, mainFit.residualMs / 30)) * 0.4))
        return BeatGrid(bpm: finalTempo.dominantBPM(untilBeat: finalTempo.beat(atTime: duration)), firstDownbeat: finalTempo.offset,
                        beatsPerBar: beatsPerBar, confidence: confidence, tempo: finalTempo, residualMs: mainFit.residualMs)
    }

    /// Detects slow tempo drift / tempo changes; returns nil when a single tempo fits.
    static func piecewiseTempo(onsets: [(time: Double, strength: Float)], bpm: Double, firstBeat: Double) -> TempoMap? {
        let period = 60 / bpm
        guard let lastT = onsets.last?.time, lastT > 30 else { return nil }
        // windowed phase deviation every 8 seconds
        var points: [(t: Double, dev: Double)] = []
        var w = 0.0
        while w < lastT {
            var devs: [Double] = []
            for o in onsets where o.time >= w && o.time < w + 8 {
                let k = ((o.time - firstBeat) / period).rounded()
                let d = o.time - (firstBeat + k * period)
                if abs(d) < period * 0.3 { devs.append(d) }
            }
            if devs.count >= 6 { devs.sort(); points.append((w + 4, devs[devs.count / 2])) }
            w += 8
        }
        guard points.count >= 4 else { return nil }
        let maxDev = points.map { abs($0.dev) }.max() ?? 0
        if maxDev < 0.022 { return nil } // constant tempo is good enough (< 22 ms anywhere)
        // fit a beat-time function through the deviations: segment where slope changes
        var changes: [(beat: Double, bpm: Double)] = []
        var segStart = 0
        var i = 1
        while i < points.count {
            // slope (dev per second) of the segment so far
            let seg = Array(points[segStart...i])
            let n = Double(seg.count)
            let mt = seg.reduce(0) { $0 + $1.t } / n, md = seg.reduce(0) { $0 + $1.dev } / n
            var stt = 0.0, std = 0.0
            for p in seg { stt += (p.t - mt) * (p.t - mt); std += (p.t - mt) * (p.dev - md) }
            let slope = stt > 0 ? std / stt : 0
            let resid = seg.map { abs($0.dev - (md + slope * ($0.t - mt))) }.max() ?? 0
            if resid > 0.015 && i - segStart >= 3 {
                changes.append((0, 0)) // marker; computed below
                segStart = i - 1
            }
            i += 1
        }
        if changes.isEmpty {
            // single linear drift = slightly wrong BPM; correct globally
            let n = Double(points.count)
            let mt = points.reduce(0) { $0 + $1.t } / n, md = points.reduce(0) { $0 + $1.dev } / n
            var stt = 0.0, std = 0.0
            for p in points { stt += (p.t - mt) * (p.t - mt); std += (p.t - mt) * (p.dev - md) }
            let slope = stt > 0 ? std / stt : 0
            let newPeriod = period * (1 + slope)
            let off = firstBeat + md - slope * mt
            return TempoMap(bpm: 60 / newPeriod, offset: off.truncatingRemainder(dividingBy: newPeriod))
        }
        // general case: beat tracking with local tempo per 8-beat window
        var beatTimes: [Double] = []
        var t = firstBeat
        var p = period
        while t < lastT + period {
            beatTimes.append(t)
            // look for onsets near the next predicted beat and adapt
            let pred = t + p
            let near = onsets.filter { abs($0.time - pred) < p * 0.12 }.max { $0.strength < $1.strength }
            if let nb = near {
                let newP = nb.time - t
                if newP > p * 0.9 && newP < p * 1.1 { p = 0.85 * p + 0.15 * newP }
                t = 0.7 * pred + 0.3 * nb.time
            } else {
                t = pred
            }
        }
        // quantise local tempi into segments of at least 8 beats with stable BPM
        var map: [(beat: Double, bpm: Double)] = []
        var b0 = 0
        while b0 + 8 < beatTimes.count {
            let b1 = min(beatTimes.count - 1, b0 + 8)
            let localBPM = 60 * Double(b1 - b0) / (beatTimes[b1] - beatTimes[b0])
            let rounded = (localBPM * 10).rounded() / 10
            if map.isEmpty || abs(map.last!.bpm - rounded) > 0.35 { map.append((Double(b0), rounded)) }
            b0 = b1
        }
        if map.count <= 1 { return nil }
        return TempoMap(changes: map, offset: firstBeat)
    }

    /// Returns (beat index of the first downbeat in 0..<beatsPerBar, beatsPerBar).
    static func downbeat(_ fe: Frontend, tempo: TempoMap) -> (Int, Int) {
        let duration = Double(fe.x.count) / analysisRate
        let lastBeat = Int(tempo.beat(atTime: duration))
        guard lastBeat > 16 else { return (0, 4) }
        let lowBands = fe.melFreqs.indices.filter { fe.melFreqs[$0] < 160 }
        let midBands = fe.melFreqs.indices.filter { fe.melFreqs[$0] >= 160 && fe.melFreqs[$0] < 4000 }
        func frame(_ t: Double) -> Int { max(0, min(fe.mel.count - 1, Int((t * fe.frameRate).rounded()))) }
        var kick: [Double] = [], change: [Double] = [], onset: [Double] = []
        var prevVec: [Float]? = nil
        for k in 0...lastBeat {
            let t = tempo.time(atBeat: Double(k))
            let f = frame(t)
            var kv: Float = 0
            for df in -2...2 {
                let ff = max(1, min(fe.mel.count - 1, f + df))
                var s: Float = 0
                for b in lowBands { s += max(0, fe.mel[ff][b] - fe.mel[ff - 1][b]) }
                kv = max(kv, s)
            }
            kick.append(Double(kv))
            onset.append(Double(fe.ose[min(fe.ose.count - 1, f)]))
            // harmonic content of the following beat
            let f2 = frame(tempo.time(atBeat: Double(k + 1)))
            var vec = [Float](repeating: 0, count: midBands.count)
            if f2 > f {
                for ff in f..<f2 { for (i, b) in midBands.enumerated() { vec[i] += fe.mel[ff][b] } }
                for i in vec.indices { vec[i] /= Float(f2 - f) }
            }
            if let pv = prevVec {
                var d: Float = 0
                for i in vec.indices { d += abs(vec[i] - pv[i]) }
                change.append(Double(d) / Double(max(1, vec.count)))
            } else {
                change.append(0)
            }
            prevVec = vec
        }
        func norm(_ a: [Double]) -> [Double] {
            let m = a.reduce(0, +) / Double(a.count)
            let sd = (a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count)).squareRoot()
            return a.map { sd > 0 ? ($0 - m) / sd : 0 }
        }
        let kn = norm(kick), cn = norm(change), on = norm(onset)
        // bar-level novelty: harmonic difference between the windows before/after beat k
        var beatVecs: [[Float]] = []
        for k in 0...lastBeat {
            let f = frame(tempo.time(atBeat: Double(k))), f2 = frame(tempo.time(atBeat: Double(k + 1)))
            var vec = [Float](repeating: 0, count: midBands.count)
            if f2 > f { for ff in f..<f2 { for (i, b) in midBands.enumerated() { vec[i] += fe.mel[ff][b] } }; for i in vec.indices { vec[i] /= Float(f2 - f) } }
            beatVecs.append(vec)
        }
        func barNovelty(_ k: Int, _ len: Int) -> Double {
            guard k - len >= 0, k + len <= beatVecs.count else { return 0 }
            var d = 0.0
            for i in 0..<midBands.count {
                var a: Float = 0, b: Float = 0
                for j in (k - len)..<k { a += beatVecs[j][i] }
                for j in k..<(k + len) { b += beatVecs[j][i] }
                d += Double(abs(a - b)) / Double(len)
            }
            return d / Double(max(1, midBands.count))
        }
        // beat-synchronous chroma (normalised) and bass pitch class
        func beatChroma(_ src: [[Float]]) -> [[Float]] {
            (0...lastBeat).map { k in
                let f = frame(tempo.time(atBeat: Double(k))), f2 = max(f + 1, frame(tempo.time(atBeat: Double(k + 1))))
                var v = [Float](repeating: 0, count: 12)
                for ff in f..<min(src.count, f2) { for i in 0..<12 { v[i] += src[ff][i] } }
                let n = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
                return n > 0 ? v.map { $0 / n } : v
            }
        }
        let bc = beatChroma(fe.chroma), bb = beatChroma(fe.bassChroma)
        func chromaNovelty(_ c: [[Float]], _ k: Int, _ len: Int) -> Double {
            guard k - len >= 0, k + len <= c.count else { return 0 }
            var a = [Float](repeating: 0, count: 12), b = a
            for j in (k - len)..<k { for i in 0..<12 { a[i] += c[j][i] } }
            for j in k..<(k + len) { for i in 0..<12 { b[i] += c[j][i] } }
            let na = (a.reduce(0) { $0 + $1 * $1 }).squareRoot(), nb = (b.reduce(0) { $0 + $1 * $1 }).squareRoot()
            guard na > 0, nb > 0 else { return 0 }
            var dot: Float = 0
            for i in 0..<12 { dot += a[i] * b[i] }
            return Double(1 - dot / (na * nb))
        }
        func bassChange(_ k: Int) -> Double {
            guard k > 0 else { return 0 }
            var dot: Float = 0
            for i in 0..<12 { dot += bb[k][i] * bb[k - 1][i] }
            return Double(1 - dot)
        }
        let cnov4 = norm((0...lastBeat).map { chromaNovelty(bc, $0, 4) + 0.5 * chromaNovelty(bc, $0, 2) })
        let cnov3 = norm((0...lastBeat).map { chromaNovelty(bc, $0, 3) })
        let bch = norm((0...lastBeat).map { bassChange($0) })
        let nov4 = norm((0...lastBeat).map { barNovelty($0, 4) }).enumerated().map { $0.element * 0.4 + cnov4[$0.offset] * 1.0 }
        let nov3 = norm((0...lastBeat).map { barNovelty($0, 3) }).enumerated().map { $0.element * 0.4 + cnov3[$0.offset] * 1.0 }
        let percussive = fe.percussiveness
        let drumWeight = max(0.1, min(1, (percussive - 0.04) / 0.08))
        func score(period: Int, phase: Int) -> Double {
            var s = 0.0, c = 0.0
            var k = phase
            let nov = period == 3 ? nov3 : nov4
            while k < kn.count {
                s += kn[k] * 0.7 * drumWeight + cn[k] * 0.3 + nov[k] * 1.4 + bch[k] * (1.1 - 0.6 * drumWeight) + on[k] * 0.2
                c += 1; k += period
            }
            return c > 0 ? s / c : 0
        }
        var best4 = 0, best4S = -Double.infinity
        for p in 0..<4 { let s = score(period: 4, phase: p); if s > best4S { best4S = s; best4 = p } }
        if ProcessInfo.processInfo.environment["MAICHART_DEBUG"] != nil {
            print(String(format: "percussive share %.3f drumWeight %.2f", percussive, drumWeight))
            for p in 0..<4 {
                func comp(_ a: [Double]) -> Double { var s = 0.0, c = 0.0; var k = p; while k < a.count { s += a[k]; c += 1; k += 4 }; return s / max(1, c) }
                print(String(format: "downbeat phase %d: kick %.2f change %.2f nov %.2f bass %.2f onset %.2f total %.2f", p, comp(kn), comp(cn), comp(nov4), comp(bch), comp(on), score(period: 4, phase: p)))
            }
        }
        var best3 = 0, best3S = -Double.infinity
        for p in 0..<3 { let s = score(period: 3, phase: p); if s > best3S { best3S = s; best3 = p } }
        if best3S > best4S * 1.45 && best3S > 0.6 { return (best3, 3) }
        return (best4, 4)
    }

    // MARK: Drums

    /// 96-band mel magnitude templates of GM drums (derived from GeneralUser GS with MaiSynth).
    enum DrumTemplates {
    static let kick: [Float] = [0.34233, 0.26032, 0.09850, 0.04716, 0.02870, 0.01761, 0.01088, 0.01133, 0.00818, 0.00560, 0.00400, 0.00373, 0.00387, 0.00329, 0.00232, 0.00258, 0.00192, 0.00166, 0.00155, 0.00186, 0.00214, 0.00157, 0.00127, 0.00149, 0.00190, 0.00171, 0.00140, 0.00145, 0.00158, 0.00156, 0.00212, 0.00182, 0.00210, 0.00196, 0.00165, 0.00161, 0.00191, 0.00186, 0.00213, 0.00177, 0.00180, 0.00207, 0.00258, 0.00217, 0.00174, 0.00276, 0.00263, 0.00246, 0.00274, 0.00311, 0.00248, 0.00251, 0.00274, 0.00240, 0.00269, 0.00217, 0.00284, 0.00242, 0.00260, 0.00220, 0.00231, 0.00248, 0.00221, 0.00198, 0.00217, 0.00214, 0.00186, 0.00160, 0.00162, 0.00151, 0.00137, 0.00130, 0.00116, 0.00093, 0.00098, 0.00088, 0.00085, 0.00096, 0.00084, 0.00095, 0.00093, 0.00081, 0.00069, 0.00065, 0.00066, 0.00072, 0.00075, 0.00095, 0.00106, 0.00122, 0.00158, 0.00215, 0.00311, 0.00420, 0.00463, 0.00426]
    static let snare: [Float] = [0.00333, 0.00509, 0.00903, 0.01987, 0.08561, 0.05922, 0.01243, 0.01474, 0.03005, 0.02907, 0.01238, 0.01542, 0.02065, 0.02468, 0.01431, 0.01513, 0.01240, 0.01104, 0.01618, 0.01497, 0.01494, 0.02147, 0.01501, 0.01133, 0.00869, 0.01178, 0.01797, 0.01474, 0.01161, 0.00962, 0.01081, 0.01178, 0.00913, 0.01223, 0.01068, 0.01045, 0.01038, 0.00996, 0.00863, 0.00936, 0.01112, 0.00921, 0.01010, 0.00902, 0.00847, 0.00941, 0.00965, 0.00902, 0.00822, 0.00911, 0.00819, 0.00799, 0.00731, 0.00666, 0.00690, 0.00677, 0.00758, 0.00664, 0.00677, 0.00720, 0.00679, 0.00697, 0.00520, 0.00514, 0.00570, 0.00604, 0.00625, 0.00618, 0.00669, 0.00655, 0.00665, 0.00621, 0.00749, 0.00681, 0.00693, 0.00649, 0.00644, 0.00569, 0.00524, 0.00468, 0.00413, 0.00417, 0.00354, 0.00322, 0.00368, 0.00323, 0.00320, 0.00291, 0.00258, 0.00246, 0.00212, 0.00212, 0.00193, 0.00174, 0.00168, 0.00163]
    static let hat: [Float] = [0.00858, 0.00674, 0.00548, 0.00405, 0.00359, 0.00401, 0.00475, 0.00524, 0.00481, 0.01281, 0.02250, 0.03645, 0.03513, 0.01750, 0.01262, 0.01166, 0.00584, 0.00493, 0.00497, 0.00331, 0.00358, 0.00471, 0.00435, 0.00266, 0.00431, 0.00714, 0.00592, 0.01081, 0.01012, 0.00576, 0.00492, 0.00538, 0.00644, 0.00521, 0.00335, 0.00428, 0.00533, 0.00738, 0.00632, 0.00643, 0.01139, 0.01356, 0.00441, 0.00508, 0.00892, 0.01086, 0.00690, 0.00655, 0.00730, 0.01391, 0.00932, 0.00505, 0.00630, 0.00661, 0.00612, 0.00622, 0.00663, 0.00874, 0.00792, 0.00606, 0.00546, 0.00671, 0.00946, 0.00964, 0.00928, 0.00720, 0.01179, 0.01324, 0.01167, 0.01331, 0.01547, 0.01161, 0.01327, 0.00952, 0.01199, 0.01331, 0.01336, 0.01362, 0.01575, 0.01193, 0.01454, 0.01411, 0.01696, 0.01446, 0.01556, 0.01593, 0.01504, 0.01561, 0.01696, 0.01736, 0.02254, 0.02270, 0.02162, 0.01990, 0.02176, 0.02019]
    static let crash: [Float] = [0.00109, 0.00119, 0.00112, 0.00147, 0.00138, 0.00174, 0.00216, 0.00359, 0.00624, 0.00718, 0.00846, 0.00596, 0.01315, 0.01105, 0.01119, 0.01395, 0.01468, 0.01607, 0.01144, 0.01359, 0.01430, 0.01466, 0.01524, 0.01693, 0.01468, 0.01329, 0.01259, 0.01386, 0.01395, 0.01251, 0.01026, 0.00787, 0.00929, 0.01146, 0.00924, 0.00771, 0.00870, 0.00851, 0.00900, 0.00974, 0.00801, 0.00704, 0.00900, 0.01054, 0.01247, 0.00923, 0.00792, 0.00978, 0.00927, 0.01148, 0.01135, 0.01126, 0.01280, 0.00778, 0.00903, 0.00961, 0.00893, 0.01032, 0.00749, 0.01133, 0.01134, 0.01174, 0.01044, 0.00722, 0.00969, 0.01834, 0.02875, 0.02007, 0.00847, 0.00811, 0.02278, 0.02619, 0.01788, 0.01072, 0.00929, 0.01454, 0.01322, 0.01278, 0.01033, 0.01140, 0.01082, 0.00879, 0.01147, 0.01080, 0.01140, 0.01043, 0.00798, 0.01021, 0.01081, 0.00809, 0.00751, 0.00679, 0.00706, 0.00687, 0.00651, 0.00602]
    }

    /// Semi-supervised NMF drum transcription on the percussive (HPSS) spectrogram.
    static func detectDrums(_ fe: Frontend) -> [(time: Double, kind: DrumHit.Kind, strength: Double)] {
        let nF = fe.perc.count
        let nb = 96
        guard nF > 20, fe.percussiveness > 0.06 else { return [] }
        var V = [Float](repeating: 0, count: nF * nb)
        for t in 0..<nF { for b in 0..<nb { V[t * nb + b] = pow(10, fe.perc[t][b] / 20) } }
        let fixed: [[Float]] = [DrumTemplates.kick, DrumTemplates.snare, DrumTemplates.hat]
        let nFixed = fixed.count
        var rng = SeededRandom(seed: 99)
        let K = 5
        var W = [[Float]](repeating: [Float](repeating: 0, count: nb), count: K)
        for k in 0..<nFixed { W[k] = fixed[k] }
        for k in nFixed..<K { W[k] = (0..<nb).map { _ in Float(0.5 + rng.unit()) / Float(nb) } }
        var H = [[Float]](repeating: [Float](repeating: 0.1, count: nF), count: K)
        let eps: Float = 1e-9
        for iter in 0..<40 {
            var WtW = [[Float]](repeating: [Float](repeating: 0, count: K), count: K)
            for i in 0..<K { for j in 0..<K { var s: Float = 0; for b in 0..<nb { s += W[i][b] * W[j][b] }; WtW[i][j] = s } }
            V.withUnsafeBufferPointer { vp in
                for t in 0..<nF {
                    var wtv = [Float](repeating: 0, count: K)
                    for k in 0..<K { var s: Float = 0; for b in 0..<nb { s += W[k][b] * vp[t * nb + b] }; wtv[k] = s }
                    var h = (0..<K).map { H[$0][t] }
                    for k in 0..<K {
                        var den: Float = 0
                        for j in 0..<K { den += WtW[k][j] * h[j] }
                        h[k] *= wtv[k] / (den + eps)
                    }
                    for k in 0..<K { H[k][t] = h[k] }
                }
            }
            if iter % 2 == 1 {
                var HHt = [[Float]](repeating: [Float](repeating: 0, count: K), count: K)
                for i in 0..<K { for j in 0..<K { var s: Float = 0; for t in 0..<nF { s += H[i][t] * H[j][t] }; HHt[i][j] = s } }
                var VHt = [[Float]](repeating: [Float](repeating: 0, count: nb), count: K)
                V.withUnsafeBufferPointer { vp in
                    for t in 0..<nF { for k in 0..<K where H[k][t] > 0 { let h = H[k][t]; for b in 0..<nb { VHt[k][b] += vp[t * nb + b] * h } } }
                }
                for k in 0..<K {
                    var upd = W[k]
                    for b in 0..<nb {
                        var den: Float = 0
                        for j in 0..<K { den += W[j][b] * HHt[j][k] }
                        upd[b] = W[k][b] * VHt[k][b] / (den + eps)
                    }
                    let sum = upd.reduce(0, +)
                    if sum > 0 { upd = upd.map { $0 / sum } }
                    if k < nFixed { for b in 0..<nb { W[k][b] = 0.85 * fixed[k][b] + 0.15 * upd[b] } } else { W[k] = upd }
                }
            }
        }
        var hits: [(Double, DrumHit.Kind, Double)] = []
        let kinds: [DrumHit.Kind] = [.kick, .snare, .closedHat]
        for k in 0..<nFixed {
            let h = H[k]
            let sorted = h.sorted()
            let p99 = max(1e-9, sorted[Int(Double(sorted.count - 1) * 0.99)])
            var diff = [Float](repeating: 0, count: nF)
            for t in 1..<nF { diff[t] = max(0, h[t] - h[t - 1]) / p99 }
            let med = DSP.movingMedian(diff, window: 87)
            var last = -100
            for t in 2..<(nF - 2) {
                let v = diff[t]
                guard v > diff[t - 1], v >= diff[t + 1], v >= diff[t - 2], v >= diff[t + 2] else { continue }
                let isCymbal = k == 2
                guard v > (isCymbal ? 0.1 : 0.12) + 2.5 * med[t], h[t] / p99 > (isCymbal ? 0.16 : 0.18) else { continue }
                if isCymbal {
                    // a real cymbal dominates the top octave of the percussive spectrum at its onset
                    let hiBands = fe.percFreqs.indices.filter { fe.percFreqs[$0] >= 6000 }
                    let loBands = fe.percFreqs.indices.filter { fe.percFreqs[$0] >= 300 && fe.percFreqs[$0] < 2000 }
                    var hiE: Float = 0, loE: Float = 0
                    for b in hiBands { hiE += max(0, fe.perc[t][b] - fe.perc[max(0, t - 2)][b]) }
                    for b in loBands { loE += max(0, fe.perc[t][b] - fe.perc[max(0, t - 2)][b]) }
                    if hiE / Float(max(1, hiBands.count)) < 0.8 * loE / Float(max(1, loBands.count)) { continue }
                }
                if t - last < 4 { continue }
                last = t
                var kind = kinds[k]
                if isCymbal {
                    // long decays are crashes (strong) or open hats (weaker)
                    let l1 = min(nF - 1, t + Int(0.15 * fe.frameRate)), l2 = min(nF - 1, t + Int(0.4 * fe.frameRate))
                    let peak = max(h[t], h[min(nF - 1, t + 1)])
                    let l3 = min(nF - 1, t + Int(0.8 * fe.frameRate))
                    if h[l2] > peak * 0.5 && h[l3] > peak * 0.25 && peak / p99 > 0.75 { kind = .crash }
                    else if h[l1] > peak * 0.45 { kind = .openHat }
                }
                hits.append((Double(t) / fe.frameRate, kind, Double(min(1, h[t] / p99))))
            }
        }
        hits.sort { $0.0 < $1.0 }
        let fine = fe.fineOnsets.map { $0.time }
        return hits.compactMap { h in
            if let o = nearestOnset(h.0, fine, before: 0.03, after: 0.03) { return (o, h.1, h.2) }
            // cymbals without an acoustic attack are most likely leakage from other instruments
            if h.1 == .closedHat || h.1 == .openHat || h.1 == .crash { return nil }
            return (h.0, h.1, h.2)
        }
    }

    // MARK: Transcription split

    static func nearestOnset(_ t: Double, _ onsets: [Double], before: Double, after: Double) -> Double? {
        var lo = 0, hi = onsets.count
        while lo < hi { let m = (lo + hi) / 2; if onsets[m] < t { lo = m + 1 } else { hi = m } }
        var best: Double? = nil, bestD = Double.infinity
        for j in max(0, lo - 3)..<min(onsets.count, lo + 3) {
            let d = onsets[j] - t
            if d >= -before && d <= after && abs(d) < bestD { bestD = abs(d); best = onsets[j] }
        }
        return best
    }

    static func splitTranscription(_ notes: [BasicPitch.NoteEvent], tempo: TempoMap, onsets: [Double] = []) -> ([PitchedNote], [PitchedNote], [PitchedNote]) {
        struct N { var start: Double; var end: Double; var pitch: Int; var amp: Double }
        let all = notes.compactMap { e -> N? in
            // Basic Pitch frames are ~11.6 ms; snap note starts to precise acoustic onsets and
            // drop notes without an attack (sustain continuations, reverb tails)
            guard let snapped = onsets.isEmpty ? e.startTime : nearestOnset(e.startTime, onsets, before: 0.05, after: 0.05) else { return nil }
            return N(start: snapped, end: max(snapped + 0.03, e.endTime), pitch: e.pitch, amp: e.amplitude)
        }.sorted { $0.start < $1.start }
        var melodyN: [N] = []
        var used = Set<Int>()
        var i = 0
        while i < all.count {
            var j = i
            while j < all.count && all[j].start - all[i].start < 0.04 { j += 1 }
            let group = Array(all[i..<j])
            // salience: amplitude, register, penalise octave duplicates of louder notes
            var best: Int? = nil, bestS = -Double.infinity
            for (k, n) in group.enumerated() where n.pitch >= 52 && n.pitch <= 100 {
                var s = n.amp + 0.25 * Double(n.pitch - 60) / 24
                if group.contains(where: { ($0.pitch == n.pitch - 12 || $0.pitch == n.pitch - 24) && $0.amp > n.amp * 1.1 }) { s -= 0.3 }
                if let last = melodyN.last, abs(last.pitch - n.pitch) > 14 { s -= 0.12 } // continuity
                if s > bestS { bestS = s; best = k }
            }
            if let b = best {
                var n = group[b]
                if var last = melodyN.popLast() {
                    if last.end > n.start { last.end = max(last.start + 0.03, n.start) }
                    melodyN.append(last)
                }
                n.end = max(n.end, n.start + 0.05)
                melodyN.append(n)
                used.insert(i + b)
            }
            i = j
        }
        func pn(_ n: N) -> PitchedNote {
            let b0 = tempo.beat(atTime: n.start), b1 = tempo.beat(atTime: n.end)
            return PitchedNote(beat: b0, duration: max(0.05, b1 - b0), pitch: n.pitch, strength: min(1, n.amp * 1.6))
        }
        let melody = melodyN.map(pn)
        var harmony: [PitchedNote] = [], bass: [PitchedNote] = []
        for (k, n) in all.enumerated() where !used.contains(k) {
            if n.pitch < 48 { bass.append(pn(n)) } else { harmony.append(pn(n)) }
        }
        return (melody, harmony, bass)
    }

    // MARK: Energy & sections

    static func beatEnergy(_ fe: Frontend, tempo: TempoMap, endBeat: Double) -> [Double] {
        let n = max(1, Int(endBeat.rounded(.up)) + 1)
        var e = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let a = Int(max(0, tempo.time(atBeat: Double(k))) * analysisRate)
            let b = Int(max(0, tempo.time(atBeat: Double(k + 1))) * analysisRate)
            guard b > a, a < fe.x.count else { continue }
            var s = 0.0
            var i = a
            while i < min(b, fe.x.count) { s += Double(fe.x[i] * fe.x[i]); i += 4 }
            e[k] = 10 * log10(s / Double(max(1, (min(b, fe.x.count) - a) / 4)) + 1e-9)
        }
        let sorted = e.sorted()
        let lo = sorted[Int(Double(sorted.count - 1) * 0.08)], hi = max(lo + 1, sorted[Int(Double(sorted.count - 1) * 0.95)])
        let norm = e.map { max(0, min(1, ($0 - lo) / (hi - lo))) }
        return DSP.movingAverage(norm.map { Float($0) }, radius: 2).map { Double($0) }
    }

    static func sectionStarts(energy: [Double], drums: [DrumHit], beatsPerBar: Int) -> [Double] {
        var out: [Double] = []
        let bpb = Double(beatsPerBar)
        let bars = Int(Double(energy.count) / bpb)
        guard bars > 4 else { return [] }
        var barE = (0..<bars).map { b -> Double in
            let s = Int(Double(b) * bpb), e = min(energy.count, Int(Double(b + 1) * bpb))
            return energy[s..<e].reduce(0, +) / Double(max(1, e - s))
        }
        barE = barE.map { $0 }
        for b in 2..<bars {
            let before = (barE[max(0, b - 2)] + barE[b - 1]) / 2
            let after = (barE[b] + barE[min(bars - 1, b + 1)]) / 2
            if after - before > 0.22 { out.append(Double(b) * bpb) }
        }
        for d in drums where d.kind == .crash && d.strength > 0.5 {
            let barPos = d.beat / bpb
            if abs(barPos - barPos.rounded()) < 0.06 { out.append(barPos.rounded() * bpb) }
        }
        return Array(Set(out)).sorted()
    }
}

/// DSP fallback melody tracker: harmonic-summation salience + Viterbi smoothing.
public enum MelodyTracker {
    public struct Note { public var start: Double; public var end: Double; public var pitch: Int; public var strength: Double }

    /// Keeps only notes that begin with an audible attack (or clear legato pitch jumps) and moves
    /// their starts onto the precise onset times.
    public static func snapToOnsets(_ notes: [Note], onsets: [Double]) -> [Note] {
        var out: [Note] = []
        for n in notes where n.strength >= 0.12 {
            if let o = AudioAnalyzer.nearestOnset(n.start, onsets, before: 0.06, after: 0.035) {
                var m = n
                m.start = o
                if let last = out.last, abs(last.start - o) < 0.03 { // same attack: keep the stronger
                    if m.strength > last.strength { out[out.count - 1] = m }
                    continue
                }
                if var last = out.popLast() { last.end = min(last.end, max(last.start + 0.03, o)); out.append(last) }
                out.append(m)
            } else if var last = out.popLast() {
                if n.pitch == last.pitch || abs(n.start - last.end) < 0.05 { last.end = max(last.end, n.end) }
                out.append(last)
            }
        }
        return out
    }

    public static func track(_ x: [Float], sampleRate: Double) -> [Note] {
        let nfft = 2048, hop = 256
        let spec = DSP.stft(x, sampleRate: sampleRate, nFFT: nfft, hop: hop)
        let binHz = sampleRate / Double(nfft)
        // candidate pitches: MIDI 45...93 in 20-cent steps
        let lowMidi = 45.0, highMidi = 93.0, stepC = 0.2
        let nCand = Int((highMidi - lowMidi) / stepC) + 1
        let cands = (0..<nCand).map { lowMidi + Double($0) * stepC }
        var sal = [[Float]](repeating: [Float](repeating: 0, count: nCand), count: spec.frames)
        var frameMax = [Float](repeating: 0, count: spec.frames)
        for t in 0..<spec.frames {
            // spectral peaks with log magnitude
            var peaks: [(Double, Float)] = []
            for k in 2..<min(spec.bins - 1, Int(5000 / binHz)) {
                let v = spec[t, k]
                if v > spec[t, k - 1] && v >= spec[t, k + 1] && v > 1e-4 {
                    let off = DSP.parabolicOffset(Double(spec[t, k - 1]), Double(v), Double(spec[t, k + 1]))
                    peaks.append(((Double(k) + off) * binHz, log1p(v * 100)))
                }
            }
            if peaks.isEmpty { continue }
            let top = peaks.sorted { $0.1 > $1.1 }.prefix(24)
            for (ci, m) in cands.enumerated() {
                let f0 = 440 * pow(2, (m - 69) / 12)
                var s: Float = 0
                for (f, mag) in top {
                    let h = (f / f0).rounded()
                    if h < 1 || h > 8 { continue }
                    let cents = abs(1200 * log2(f / (h * f0)))
                    if cents < 50 { s += mag * Float(pow(0.8, h - 1)) * Float(1 - cents / 50) }
                }
                sal[t][ci] = s
                frameMax[t] = max(frameMax[t], s)
            }
        }
        // Viterbi over candidates (+ unvoiced state)
        let globalMax = frameMax.max() ?? 1
        let voicingThresh = globalMax * 0.18
        var path = [Int](repeating: -1, count: spec.frames)
        if spec.frames > 0 {
            var score = [Float](repeating: 0, count: nCand + 1)
            var back = [[Int32]](repeating: [Int32](repeating: 0, count: nCand + 1), count: spec.frames)
            let maxJump = Int(12 / stepC) // one octave
            for t in 0..<spec.frames {
                var next = [Float](repeating: -Float.infinity, count: nCand + 1)
                // best previous for each state using a windowed max with linear jump penalty
                let prevBest = score.enumerated().max { $0.element < $1.element }!
                for c in 0..<nCand {
                    var bestV = score[nCand] - 0.5 // from unvoiced
                    var bestI = nCand
                    let lo = max(0, c - maxJump), hi = min(nCand - 1, c + maxJump)
                    var j = lo
                    while j <= hi {
                        let v = score[j] - Float(abs(j - c)) * 0.02
                        if v > bestV { bestV = v; bestI = j }
                        j += 1
                    }
                    if prevBest.element - 1.5 > bestV { bestV = prevBest.element - 1.5; bestI = prevBest.offset }
                    next[c] = bestV + (sal[t][c] - voicingThresh) / max(1e-3, globalMax)
                    back[t][c] = Int32(bestI)
                }
                next[nCand] = prevBest.element
                back[t][nCand] = Int32(prevBest.offset)
                score = next
            }
            var s = score.enumerated().max { $0.element < $1.element }!.offset
            for t in stride(from: spec.frames - 1, through: 0, by: -1) {
                path[t] = s == nCand ? -1 : s
                s = Int(back[t][s])
            }
        }
        // segment into notes: stable semitone, minimum 70 ms
        var notes: [Note] = []
        let fr = sampleRate / Double(hop)
        var t = 0
        while t < path.count {
            guard path[t] >= 0 else { t += 1; continue }
            let semi = Int(cands[path[t]].rounded())
            var e = t
            var strength: Float = 0
            while e < path.count, path[e] >= 0, Int(cands[path[e]].rounded()) == semi { strength = max(strength, sal[e][path[e]]); e += 1 }
            if Double(e - t) / fr >= 0.07 {
                notes.append(Note(start: Double(t) / fr, end: Double(e) / fr, pitch: semi, strength: Double(strength / max(1e-3, globalMax))))
            }
            t = max(e, t + 1)
        }
        return notes
    }
}
