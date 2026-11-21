import Foundation

/// Magnitude spectrogram stored frame-major: data[frame * bins + bin].
public struct Spectrogram {
    public var frames: Int
    public var bins: Int
    public var hop: Int
    public var nFFT: Int
    public var sampleRate: Double
    public var data: [Float]

    /// Centre time of frame `t` in seconds (frames are centred, librosa-style).
    @inline(__always) public func time(ofFrame t: Double) -> Double { t * Double(hop) / sampleRate }
    public var frameRate: Double { sampleRate / Double(hop) }
    @inline(__always) public func frequency(ofBin k: Int) -> Double { Double(k) * sampleRate / Double(nFFT) }

    @inline(__always) public subscript(frame: Int, bin: Int) -> Float {
        get { data[frame * bins + bin] }
        set { data[frame * bins + bin] = newValue }
    }
}

public enum DSP {
    /// Periodic Hann window (matches scipy/librosa `hann` with fftbins=True).
    public static func hann(_ n: Int) -> [Float] {
        (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
    }

    /// Short-time Fourier transform magnitude with centred frames and reflect padding.
    public static func stft(_ x: [Float], sampleRate: Double, nFFT: Int, hop: Int, power: Bool = false) -> Spectrogram {
        let pad = nFFT / 2
        let n = x.count
        let frames = max(1, 1 + n / hop)
        let bins = nFFT / 2 + 1
        var out = [Float](repeating: 0, count: frames * bins)
        let window = hann(nFFT)
        let fft = RealFFT(size: nFFT)
        var frame = [Float](repeating: 0, count: nFFT)
        var re = [Float](repeating: 0, count: bins)
        var im = [Float](repeating: 0, count: bins)
        @inline(__always) func sample(_ i: Int) -> Float {
            if n == 0 { return 0 }
            if n == 1 { return x[0] }
            var j = i
            // reflect padding (no edge repeat)
            let period = 2 * (n - 1)
            j = j % period
            if j < 0 { j += period }
            if j >= n { j = period - j }
            return x[j]
        }
        x.withUnsafeBufferPointer { xp in
            for t in 0..<frames {
                let start = t * hop - pad
                if start >= 0 && start + nFFT <= n {
                    for i in 0..<nFFT { frame[i] = xp[start + i] * window[i] }
                } else {
                    for i in 0..<nFFT { frame[i] = sample(start + i) * window[i] }
                }
                frame.withUnsafeBufferPointer { fp in
                    re.withUnsafeMutableBufferPointer { rp in
                        im.withUnsafeMutableBufferPointer { ip in
                            fft.forward(fp.baseAddress!, re: rp.baseAddress!, im: ip.baseAddress!)
                        }
                    }
                }
                let base = t * bins
                if power {
                    for k in 0..<bins { out[base + k] = re[k] * re[k] + im[k] * im[k] }
                } else {
                    for k in 0..<bins { out[base + k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() }
                }
            }
        }
        return Spectrogram(frames: frames, bins: bins, hop: hop, nFFT: nFFT, sampleRate: sampleRate, data: out)
    }

    // MARK: Mel filterbank (Slaney scale + Slaney normalisation, librosa defaults)

    public static func hzToMel(_ f: Double) -> Double {
        let fSp = 200.0 / 3
        let minLogHz = 1000.0
        let minLogMel = minLogHz / fSp
        let logStep = log(6.4) / 27
        return f >= minLogHz ? minLogMel + log(f / minLogHz) / logStep : f / fSp
    }

    public static func melToHz(_ m: Double) -> Double {
        let fSp = 200.0 / 3
        let minLogHz = 1000.0
        let minLogMel = minLogHz / fSp
        let logStep = log(6.4) / 27
        return m >= minLogMel ? minLogHz * exp(logStep * (m - minLogMel)) : fSp * m
    }

    /// Returns `nMels` sparse triangular filters as (startBin, weights).
    public static func melFilterbank(sampleRate: Double, nFFT: Int, nMels: Int, fMin: Double = 0, fMax: Double? = nil) -> [(start: Int, weights: [Float])] {
        let fMaxV = fMax ?? sampleRate / 2
        let bins = nFFT / 2 + 1
        let melMin = hzToMel(fMin), melMax = hzToMel(fMaxV)
        let pts = (0..<(nMels + 2)).map { melToHz(melMin + (melMax - melMin) * Double($0) / Double(nMels + 1)) }
        var filters: [(Int, [Float])] = []
        for m in 0..<nMels {
            let lo = pts[m], ce = pts[m + 1], hi = pts[m + 2]
            let enorm = 2.0 / (hi - lo)
            var start = -1
            var w: [Float] = []
            for k in 0..<bins {
                let f = Double(k) * sampleRate / Double(nFFT)
                let lower = (f - lo) / (ce - lo)
                let upper = (hi - f) / (hi - ce)
                let v = max(0, min(lower, upper)) * enorm
                if v > 0 {
                    if start < 0 { start = k }
                    // fill gaps (should not happen for triangles)
                    while start + w.count < k { w.append(0) }
                    w.append(Float(v))
                }
            }
            if start < 0 {
                // filter narrower than a bin: put weight on nearest bin
                let k = min(bins - 1, Int((ce * Double(nFFT) / sampleRate).rounded()))
                start = k
                w = [Float(enorm)]
            }
            filters.append((start, w))
        }
        return filters
    }

    /// Applies a sparse filterbank to a (power or magnitude) spectrogram -> frames x nFilters.
    public static func applyFilterbank(_ spec: Spectrogram, _ fb: [(start: Int, weights: [Float])]) -> [[Float]] {
        var out = [[Float]](repeating: [Float](repeating: 0, count: fb.count), count: spec.frames)
        spec.data.withUnsafeBufferPointer { sp in
            for t in 0..<spec.frames {
                let base = t * spec.bins
                for (m, f) in fb.enumerated() {
                    var s: Float = 0
                    for (i, w) in f.weights.enumerated() {
                        let k = f.start + i
                        if k < spec.bins { s += w * sp[base + k] }
                    }
                    out[t][m] = s
                }
            }
        }
        return out
    }

    // MARK: Resampling

    /// High quality band-limited resampling (Kaiser-windowed sinc, ~100 dB stop band).
    public static func resample(_ x: [Float], from inRate: Double, to outRate: Double, quality: Int = 16) -> [Float] {
        if x.isEmpty { return [] }
        if abs(inRate - outRate) < 1e-9 { return x }
        let ratio = outRate / inRate
        let cutoff = min(1.0, ratio) * 0.97
        let zeroCrossings = Double(quality)
        let halfWidth = zeroCrossings / cutoff // in input samples
        let phases = 512
        let beta = 9.0
        // Precompute filter table h(u) for u in [0, zeroCrossings] sampled at `phases` per zero crossing.
        let tableSize = Int(zeroCrossings) * phases + 2
        var table = [Double](repeating: 0, count: tableSize)
        let i0beta = besselI0(beta)
        for i in 0..<tableSize {
            let u = Double(i) / Double(phases) // in units of (cutoff-scaled) samples
            if u > zeroCrossings { table[i] = 0; continue }
            let sinc = u == 0 ? 1.0 : sin(Double.pi * u) / (Double.pi * u)
            let r = u / zeroCrossings
            let w = besselI0(beta * (1 - r * r).squareRoot()) / i0beta
            table[i] = sinc * w
        }
        let outCount = Int((Double(x.count) * ratio).rounded(.down))
        var y = [Float](repeating: 0, count: outCount)
        let n = x.count
        x.withUnsafeBufferPointer { xp in
            table.withUnsafeBufferPointer { tp in
                for i in 0..<outCount {
                    let t = Double(i) / ratio
                    let kStart = max(0, Int((t - halfWidth).rounded(.up)))
                    let kEnd = min(n - 1, Int((t + halfWidth).rounded(.down)))
                    if kStart > kEnd { continue }
                    var acc = 0.0
                    for k in kStart...kEnd {
                        let u = abs(t - Double(k)) * cutoff * Double(phases)
                        let iu = Int(u)
                        if iu >= tableSize - 1 { continue }
                        let frac = u - Double(iu)
                        let h = tp[iu] + (tp[iu + 1] - tp[iu]) * frac
                        acc += Double(xp[k]) * h
                    }
                    y[i] = Float(acc * cutoff)
                }
            }
        }
        return y
    }

    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let q = x * x / 4
        var k = 1.0
        while term > 1e-12 * sum {
            term *= q / (k * k)
            sum += term
            k += 1
        }
        return sum
    }

    // MARK: Small helpers

    public static func movingAverage(_ x: [Float], radius: Int) -> [Float] {
        guard radius > 0, !x.isEmpty else { return x }
        var out = [Float](repeating: 0, count: x.count)
        var prefix = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { prefix[i + 1] = prefix[i] + Double(x[i]) }
        for i in 0..<x.count {
            let a = max(0, i - radius), b = min(x.count, i + radius + 1)
            out[i] = Float((prefix[b] - prefix[a]) / Double(b - a))
        }
        return out
    }

    /// Running median with an odd window (simple but adequate for envelopes).
    public static func movingMedian(_ x: [Float], window: Int) -> [Float] {
        guard window > 1, !x.isEmpty else { return x }
        let r = window / 2
        var out = [Float](repeating: 0, count: x.count)
        var buf: [Float] = []
        buf.reserveCapacity(window)
        for i in 0..<x.count {
            buf.removeAll(keepingCapacity: true)
            let a = max(0, i - r), b = min(x.count - 1, i + r)
            for j in a...b { buf.append(x[j]) }
            buf.sort()
            out[i] = buf[buf.count / 2]
        }
        return out
    }

    public static func normalize(_ x: [Float]) -> [Float] {
        let m = x.max() ?? 0
        guard m > 0 else { return x }
        return x.map { $0 / m }
    }

    /// Parabolic interpolation of a peak at index i; returns fractional offset in [-0.5, 0.5].
    public static func parabolicOffset(_ y0: Double, _ y1: Double, _ y2: Double) -> Double {
        let d = y0 - 2 * y1 + y2
        if abs(d) < 1e-12 { return 0 }
        return max(-0.5, min(0.5, 0.5 * (y0 - y2) / d))
    }

    public static func mean(_ x: [Float]) -> Float {
        x.isEmpty ? 0 : x.reduce(0, +) / Float(x.count)
    }

    public static func percentile(_ x: [Float], _ p: Double) -> Float {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        let idx = max(0, min(s.count - 1, Int((Double(s.count - 1) * p).rounded())))
        return s[idx]
    }
}
