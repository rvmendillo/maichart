import Foundation

/// Deterministic, fast pseudo random generator (SplitMix64).
/// Every creative decision in the chart generator flows through this, so the
/// same seed always reproduces the same chart while "Remix" simply changes the seed.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
        // warm up so that small seeds diverge quickly
        for _ in 0..<4 { _ = next() }
    }

    public init(string: String, salt: UInt64 = 0) {
        self.init(seed: SeededRandom.hash(string) ^ salt)
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform double in [0, 1).
    public mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    public mutating func chance(_ p: Double) -> Bool {
        if p <= 0 { return false }
        if p >= 1 { return true }
        return unit() < p
    }

    public mutating func int(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    public mutating func double(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * unit()
    }

    public mutating func pick<T>(_ items: [T]) -> T {
        items[Int(next() % UInt64(items.count))]
    }

    /// Picks an index with probability proportional to `weights` (negative weights count as 0).
    public mutating func weightedIndex(_ weights: [Double]) -> Int {
        let total = weights.reduce(0) { $0 + max(0, $1) }
        if total <= 0 { return Int(next() % UInt64(max(1, weights.count))) }
        var r = unit() * total
        for (i, w) in weights.enumerated() {
            let ww = max(0, w)
            if r < ww { return i }
            r -= ww
        }
        return weights.count - 1
    }

    public mutating func shuffle<T>(_ items: inout [T]) {
        guard items.count > 1 else { return }
        for i in stride(from: items.count - 1, to: 0, by: -1) {
            let j = Int(next() % UInt64(i + 1))
            items.swapAt(i, j)
        }
    }

    /// FNV-1a 64-bit hash, stable across launches and platforms.
    public static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    public static func hash(bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }
}
