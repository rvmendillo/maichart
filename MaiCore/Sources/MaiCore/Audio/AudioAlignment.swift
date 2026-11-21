import Foundation

/// Compares a reference waveform (e.g. the internal WAV render) with a decoded MP3.
public struct AlignmentReport: Codable, CustomStringConvertible {
    public var lagSamples: Int
    public var lagMilliseconds: Double
    public var correlation: Double
    public var snrDB: Double
    public var spectralDistanceDB: Double
    public var referenceDuration: Double
    public var decodedDuration: Double
    public var referencePeak: Float
    public var decodedPeak: Float
    public var clippedSamples: Int

    /// Waveforms line up within 1 sample and the codec is transparent enough.
    public var aligned: Bool { abs(lagSamples) <= 1 }
    public var transparent: Bool { correlation > 0.995 && spectralDistanceDB < 3.0 }

    public var description: String {
        String(format: "lag %d samples (%.2f ms), corr %.5f, SNR %.1f dB, LSD %.2f dB, dur %.3fs vs %.3fs, peak %.3f vs %.3f, clipped %d",
               lagSamples, lagMilliseconds, correlation, snrDB, spectralDistanceDB, referenceDuration, decodedDuration,
               referencePeak, decodedPeak, clippedSamples)
    }
}

public enum AudioAlignment {
    /// Finds the integer lag (decoded relative to reference) by FFT cross-correlation of a loud excerpt.
    public static func lag(reference: [Float], decoded: [Float], maxLag: Int) -> Int {
        let n = min(reference.count, decoded.count)
        guard n > 2 * maxLag + 64 else { return 0 }
        // choose the loudest ~6 s window to correlate
        let win = min(n - 2 * maxLag, 6 * 44100)
        var bestStart = maxLag, bestE = -1.0
        let step = max(1, win / 2)
        var s = maxLag
        while s + win + maxLag <= n {
            var e = 0.0
            var k = s
            while k < s + win { e += Double(reference[k] * reference[k]); k += 16 }
            if e > bestE { bestE = e; bestStart = s }
            s += step
        }
        let a = Array(decoded[(bestStart - maxLag)..<min(decoded.count, bestStart + win + maxLag)])
        let b = Array(reference[bestStart..<(bestStart + win)])
        // r[lag] = sum a[t+lag] * b[t]; a starts maxLag earlier, so shift accordingly
        let r = ComplexFFT.crossCorrelation(a, b, maxLag: 2 * maxLag)
        var best = 0
        var bestV = -Double.infinity
        for (i, v) in r.enumerated() where v > bestV { bestV = v; best = i }
        return (best - 2 * maxLag) - maxLag
    }

    public static func compare(reference: AudioBuffer, decoded: AudioBuffer, maxLagMilliseconds: Double = 120) -> AlignmentReport {
        let ref = reference.mono()
        var dec = decoded.mono()
        if abs(decoded.sampleRate - reference.sampleRate) > 0.5 {
            dec = DSP.resample(dec, from: decoded.sampleRate, to: reference.sampleRate)
        }
        let sr = reference.sampleRate
        let maxLag = Int(maxLagMilliseconds / 1000 * sr)
        let l = lag(reference: ref, decoded: dec, maxLag: maxLag)
        // overlap after alignment: dec[t + l] ~ ref[t]
        let start = max(0, -l)
        let end = min(ref.count, dec.count - l)
        var sxx = 0.0, syy = 0.0, sxy = 0.0, err = 0.0
        if end > start {
            for t in start..<end {
                let x = Double(ref[t]), y = Double(dec[t + l])
                sxx += x * x; syy += y * y; sxy += x * y
                err += (x - y) * (x - y)
            }
        }
        let corr = sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
        let snr = err > 0 ? 10 * log10(sxx / err) : 120
        // log-spectral distance on aligned excerpts (up to 16 kHz)
        var lsd = 0.0
        if end - start > 8192 {
            let len = min(end - start, Int(sr * 20))
            let a = Array(ref[start..<(start + len)])
            let b = Array(dec[(start + l)..<(start + l + len)])
            let sa = DSP.stft(a, sampleRate: sr, nFFT: 2048, hop: 1024, power: true)
            let sb = DSP.stft(b, sampleRate: sr, nFFT: 2048, hop: 1024, power: true)
            let maxBin = min(sa.bins, Int(16000 / (sr / 2048)))
            var acc = 0.0, count = 0
            for f in 0..<min(sa.frames, sb.frames) {
                var frameE = 0.0
                for k in 1..<maxBin { frameE += Double(sa[f, k]) }
                if frameE < 1e-6 { continue } // skip silence
                var d2 = 0.0
                for k in 1..<maxBin {
                    let x = 10 * log10(Double(sa[f, k]) + 1e-10), y = 10 * log10(Double(sb[f, k]) + 1e-10)
                    let dd = max(-60, min(60, x - y))
                    d2 += dd * dd
                }
                acc += (d2 / Double(maxBin - 1)).squareRoot()
                count += 1
            }
            lsd = count > 0 ? acc / Double(count) : 0
        }
        var clipped = 0
        for ch in decoded.channels { for v in ch where abs(v) >= 0.9999 { clipped += 1 } }
        return AlignmentReport(lagSamples: l, lagMilliseconds: Double(l) / sr * 1000, correlation: corr, snrDB: snr,
                               spectralDistanceDB: lsd, referenceDuration: reference.duration, decodedDuration: decoded.duration,
                               referencePeak: reference.peak, decodedPeak: decoded.peak, clippedSamples: clipped)
    }
}

/// Produces AstroDX track audio while keeping the chart timeline exact.
public enum TrackProducer {
    public struct Result {
        public var mp3: Data
        /// Verification of the MP3 against the source PCM (as decoded by a naive decoder).
        public var report: AlignmentReport
        /// Seconds by which the MP3 timeline is later than the source PCM (add to &first). 0 when pre-compensated.
        public var timelineShift: Double
        public var precompensated: Bool
    }

    /// Encodes PCM to a 320 kbps CBR MP3 without an info tag. When the first ~25 ms are silent the
    /// encoder delay is removed up front so the decoded MP3 lines up sample-exactly with the WAV.
    public static func makeMP3(from source: AudioBuffer, options: MP3Encoder.Options = MP3Encoder.Options(),
                               progress: ((Double) -> Void)? = nil) throws -> Result {
        var pcm = source.channelCount > 2 ? source.stereo() : source
        // keep MP3 encoding from clipping: leave ~1 dB of headroom for codec overshoot
        let peak = pcm.peak
        if peak > 0.9 { pcm.applyGain(0.9 / peak) }
        let delay = MP3Encoder.nominalDelay
        let silent = pcm.leadingSilenceFrames(threshold: 0.0003)
        let precomp = silent >= delay + 64
        let input = precomp ? pcm.shifted(byFrames: -delay) : pcm
        let data = try MP3Encoder.encode(input, options: options) { progress?($0 * 0.85) }
        let decoded = try MP3Decoder.decode(data, gapless: false).buffer
        var report = AudioAlignment.compare(reference: pcm, decoded: decoded)
        var shift = Double(report.lagSamples) / pcm.sampleRate
        if precomp && report.lagSamples != 0 && abs(report.lagSamples) < delay {
            // unexpected decoder behaviour: fall back to measuring and compensating via &first
            report = AudioAlignment.compare(reference: pcm, decoded: decoded)
            shift = Double(report.lagSamples) / pcm.sampleRate
        }
        progress?(1)
        return Result(mp3: data, report: report, timelineShift: shift, precompensated: precomp && report.lagSamples == 0)
    }
}
