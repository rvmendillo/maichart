import Foundation

/// Simple de-interleaved floating point audio container used throughout the engine.
public struct AudioBuffer {
    public var sampleRate: Double
    /// One array per channel, all with identical length.
    public var channels: [[Float]]

    public init(sampleRate: Double, channels: [[Float]]) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public init(sampleRate: Double, channelCount: Int, frames: Int) {
        self.sampleRate = sampleRate
        self.channels = Array(repeating: [Float](repeating: 0, count: frames), count: channelCount)
    }

    public init(sampleRate: Double, interleaved: [Float], channelCount: Int) {
        self.sampleRate = sampleRate
        let frames = channelCount > 0 ? interleaved.count / channelCount : 0
        var chans = Array(repeating: [Float](repeating: 0, count: frames), count: channelCount)
        interleaved.withUnsafeBufferPointer { src in
            for c in 0..<channelCount {
                chans[c].withUnsafeMutableBufferPointer { dst in
                    var i = c
                    for f in 0..<frames {
                        dst[f] = src[i]
                        i += channelCount
                    }
                }
            }
        }
        self.channels = chans
    }

    public var channelCount: Int { channels.count }
    public var frameCount: Int { channels.first?.count ?? 0 }
    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

    /// Average of all channels.
    public func mono() -> [Float] {
        guard let first = channels.first else { return [] }
        if channels.count == 1 { return first }
        var out = [Float](repeating: 0, count: first.count)
        let scale = 1 / Float(channels.count)
        for ch in channels {
            ch.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<dst.count { dst[i] += src[i] * scale }
                }
            }
        }
        return out
    }

    public func interleaved() -> [Float] {
        let n = frameCount, c = channelCount
        var out = [Float](repeating: 0, count: n * c)
        out.withUnsafeMutableBufferPointer { dst in
            for ci in 0..<c {
                channels[ci].withUnsafeBufferPointer { src in
                    var j = ci
                    for f in 0..<n {
                        dst[j] = src[f]
                        j += c
                    }
                }
            }
        }
        return out
    }

    public var peak: Float {
        var p: Float = 0
        for ch in channels { for v in ch { let a = abs(v); if a > p { p = a } } }
        return p
    }

    public var rms: Float {
        var s: Double = 0
        var n = 0
        for ch in channels { for v in ch { s += Double(v) * Double(v) }; n += ch.count }
        return n > 0 ? Float((s / Double(n)).squareRoot()) : 0
    }

    /// Returns a copy with `frames` of silence prepended (positive) or frames removed from the start (negative).
    public func shifted(byFrames frames: Int) -> AudioBuffer {
        var out = self
        for c in 0..<channelCount {
            if frames >= 0 {
                out.channels[c] = [Float](repeating: 0, count: frames) + channels[c]
            } else {
                let k = min(-frames, channels[c].count)
                out.channels[c] = Array(channels[c][k...])
            }
        }
        return out
    }

    public mutating func applyGain(_ g: Float) {
        for c in 0..<channelCount {
            channels[c].withUnsafeMutableBufferPointer { p in
                for i in 0..<p.count { p[i] *= g }
            }
        }
    }

    public func slice(from start: Int, count: Int) -> AudioBuffer {
        let s = max(0, min(start, frameCount))
        let e = max(s, min(frameCount, s + count))
        return AudioBuffer(sampleRate: sampleRate, channels: channels.map { Array($0[s..<e]) })
    }

    /// Converts to stereo (duplicating mono or downmixing >2 channels).
    public func stereo() -> AudioBuffer {
        if channelCount == 2 { return self }
        if channelCount == 1 { return AudioBuffer(sampleRate: sampleRate, channels: [channels[0], channels[0]]) }
        let m = mono()
        return AudioBuffer(sampleRate: sampleRate, channels: [m, m])
    }

    /// Number of leading frames whose absolute value on every channel stays below `threshold`.
    public func leadingSilenceFrames(threshold: Float = 0.0005) -> Int {
        let n = frameCount
        var i = 0
        while i < n {
            for ch in channels where abs(ch[i]) > threshold { return i }
            i += 1
        }
        return n
    }
}
