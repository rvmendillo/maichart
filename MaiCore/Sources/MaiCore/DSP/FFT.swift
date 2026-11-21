import Foundation

/// Real-input FFT (power-of-two size) implemented with a half-size complex radix-2 transform.
/// Instances own scratch memory and are not thread-safe; create one per thread.
public final class RealFFT {
    public let size: Int
    public var binCount: Int { size / 2 + 1 }
    private let m: Int // half size (complex FFT length)
    private let logM: Int
    private var bitrev: [Int]
    private var twCos: [Float] // complex FFT twiddles (length m/2)
    private var twSin: [Float]
    private var postCos: [Float] // real-split twiddles (length m+1)
    private var postSin: [Float]
    private var zr: [Float]
    private var zi: [Float]

    public init(size: Int) {
        precondition(size >= 4 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        m = size / 2
        var l = 0
        while (1 << l) < m { l += 1 }
        logM = l
        var br = [Int](repeating: 0, count: size / 2)
        for i in 0..<(size / 2) {
            var r = 0
            var x = i
            for _ in 0..<l { r = (r << 1) | (x & 1); x >>= 1 }
            br[i] = r
        }
        bitrev = br
        let mm = size / 2
        let nn = size
        twCos = (0..<max(1, mm / 2)).map { Float(cos(2 * Double.pi * Double($0) / Double(mm))) }
        twSin = (0..<max(1, mm / 2)).map { Float(-sin(2 * Double.pi * Double($0) / Double(mm))) }
        postCos = (0...mm).map { Float(cos(2 * Double.pi * Double($0) / Double(nn))) }
        postSin = (0...mm).map { Float(sin(2 * Double.pi * Double($0) / Double(nn))) }
        zr = [Float](repeating: 0, count: mm)
        zi = [Float](repeating: 0, count: mm)
    }

    /// Forward transform of `size` real samples into `binCount` complex bins (unnormalised).
    public func forward(_ input: UnsafePointer<Float>, re outRe: UnsafeMutablePointer<Float>, im outIm: UnsafeMutablePointer<Float>) {
        let m = self.m
        zr.withUnsafeMutableBufferPointer { zrp in
        zi.withUnsafeMutableBufferPointer { zip in
        bitrev.withUnsafeBufferPointer { br in
            let zr = zrp.baseAddress!, zi = zip.baseAddress!
            for i in 0..<m {
                let j = br[i]
                zr[j] = input[2 * i]
                zi[j] = input[2 * i + 1]
            }
            twCos.withUnsafeBufferPointer { tc in
            twSin.withUnsafeBufferPointer { ts in
                var len = 2
                while len <= m {
                    let halfLen = len / 2
                    let step = m / len
                    var start = 0
                    while start < m {
                        var k = 0
                        for j in 0..<halfLen {
                            let wr = tc[k], wi = ts[k]
                            let a = start + j, b = a + halfLen
                            let xr = zr[b] * wr - zi[b] * wi
                            let xi = zr[b] * wi + zi[b] * wr
                            zr[b] = zr[a] - xr
                            zi[b] = zi[a] - xi
                            zr[a] += xr
                            zi[a] += xi
                            k += step
                        }
                        start += len
                    }
                    len <<= 1
                }
            }
            }
            // split into the spectrum of the real signal
            postCos.withUnsafeBufferPointer { pc in
            postSin.withUnsafeBufferPointer { ps in
                for k in 0...m {
                    let ka = k == m ? 0 : k
                    let kb = k == 0 ? 0 : m - k
                    let ar = zr[ka], ai = zi[ka]
                    let br_ = zr[kb], bi = -zi[kb]
                    let er = 0.5 * (ar + br_), ei = 0.5 * (ai + bi)
                    let or_ = 0.5 * (ai - bi), oi = -0.5 * (ar - br_)
                    let c = pc[k], s = ps[k]
                    // X = Ze + (c - i s) * Zo
                    outRe[k] = er + c * or_ + s * oi
                    outIm[k] = ei + c * oi - s * or_
                }
            }
            }
        }
        }
        }
    }

    /// Convenience returning arrays.
    public func forward(_ input: [Float]) -> (re: [Float], im: [Float]) {
        precondition(input.count == size)
        var re = [Float](repeating: 0, count: binCount)
        var im = [Float](repeating: 0, count: binCount)
        input.withUnsafeBufferPointer { ip in
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { imp in
                    forward(ip.baseAddress!, re: rp.baseAddress!, im: imp.baseAddress!)
                }
            }
        }
        return (re, im)
    }
}

/// Complex FFT (in place, split arrays) used for convolution / correlation helpers.
public final class ComplexFFT {
    public let size: Int
    private var bitrev: [Int]
    private var twCos: [Double]
    private var twSin: [Double]

    public init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0)
        self.size = size
        var l = 0
        while (1 << l) < size { l += 1 }
        bitrev = (0..<size).map { i in
            var r = 0, x = i
            for _ in 0..<l { r = (r << 1) | (x & 1); x >>= 1 }
            return r
        }
        twCos = (0..<size / 2).map { cos(2 * Double.pi * Double($0) / Double(size)) }
        twSin = (0..<size / 2).map { -sin(2 * Double.pi * Double($0) / Double(size)) }
    }

    /// In-place transform. `inverse` uses conjugate twiddles and scales by 1/n.
    public func transform(re: inout [Double], im: inout [Double], inverse: Bool = false) {
        let n = size
        for i in 0..<n {
            let j = bitrev[i]
            if j > i { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let half = len / 2
            let step = n / len
            var start = 0
            while start < n {
                var k = 0
                for j in 0..<half {
                    let wr = twCos[k]
                    let wi = inverse ? -twSin[k] : twSin[k]
                    let a = start + j, b = a + half
                    let xr = re[b] * wr - im[b] * wi
                    let xi = re[b] * wi + im[b] * wr
                    re[b] = re[a] - xr; im[b] = im[a] - xi
                    re[a] += xr; im[a] += xi
                    k += step
                }
                start += len
            }
            len <<= 1
        }
        if inverse {
            let s = 1.0 / Double(n)
            for i in 0..<n { re[i] *= s; im[i] *= s }
        }
    }

    public static func nextPow2(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }

    /// Full cross-correlation r[lag] = sum_t a[t+lag] * b[t] for lags in -maxLag...maxLag.
    public static func crossCorrelation(_ a: [Float], _ b: [Float], maxLag: Int) -> [Double] {
        let n = nextPow2(a.count + b.count + 1)
        let fft = ComplexFFT(size: n)
        var ar = [Double](repeating: 0, count: n), ai = [Double](repeating: 0, count: n)
        var br = [Double](repeating: 0, count: n), bi = [Double](repeating: 0, count: n)
        for i in 0..<a.count { ar[i] = Double(a[i]) }
        for i in 0..<b.count { br[i] = Double(b[i]) }
        fft.transform(re: &ar, im: &ai)
        fft.transform(re: &br, im: &bi)
        var cr = [Double](repeating: 0, count: n), ci = [Double](repeating: 0, count: n)
        for k in 0..<n {
            // A * conj(B)
            cr[k] = ar[k] * br[k] + ai[k] * bi[k]
            ci[k] = ai[k] * br[k] - ar[k] * bi[k]
        }
        fft.transform(re: &cr, im: &ci, inverse: true)
        var out = [Double](repeating: 0, count: 2 * maxLag + 1)
        for lag in -maxLag...maxLag {
            let idx = lag >= 0 ? lag : n + lag
            out[lag + maxLag] = cr[idx]
        }
        return out
    }
}
