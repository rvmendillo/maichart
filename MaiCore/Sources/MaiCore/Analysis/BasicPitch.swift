import Foundation

/// Pre/post-processing for Spotify's Basic Pitch model (Apache-2.0).
/// The neural network itself runs in CoreML on device; everything around it lives here so it
/// is identical on every platform and verified against the reference Python implementation.
public enum BasicPitch {
    public static let sampleRate = 22050.0
    public static let fftHop = 256
    public static let windowSamples = 22050 * 2 - 256          // AUDIO_N_SAMPLES = 43844
    public static let overlapFrames = 30
    public static let overlapSamples = overlapFrames * fftHop   // 7680
    public static let hopSamples = windowSamples - overlapSamples
    public static let framesPerWindow = 172
    public static let annotationsFPS = 86                       // 22050 // 256
    public static let noteBins = 88
    public static let contourBins = 264
    public static let midiOffset = 21

    /// Splits mono 22.05 kHz audio into model input windows (each `windowSamples` long).
    public static func windows(_ audio: [Float]) -> [[Float]] {
        let padded = [Float](repeating: 0, count: overlapSamples / 2) + audio
        var out: [[Float]] = []
        var i = 0
        while i < padded.count {
            var w = Array(padded[i..<min(padded.count, i + windowSamples)])
            if w.count < windowSamples { w += [Float](repeating: 0, count: windowSamples - w.count) }
            out.append(w)
            i += hopSamples
        }
        return out
    }

    /// Concatenates per-window outputs (each frames x bins, row-major) into one matrix.
    public static func unwrap(_ windows: [[Float]], bins: Int, originalLength: Int) -> [Float] {
        let olap = overlapFrames / 2
        var out: [Float] = []
        for w in windows {
            let frames = w.count / bins
            guard frames > 2 * olap else { continue }
            out.append(contentsOf: w[(olap * bins)..<((frames - olap) * bins)])
        }
        let n = Int(floor(Double(originalLength) * Double(annotationsFPS) / sampleRate))
        if out.count > n * bins { out.removeLast(out.count - n * bins) }
        return out
    }

    /// Time (seconds, relative to the audio start) of output frame `i` (reference: model_frames_to_time).
    public static func frameTime(_ i: Int) -> Double {
        let windowOffset = Double(fftHop) / sampleRate * (Double(framesPerWindow) - Double(windowSamples) / Double(fftHop)) + 0.0018
        return Double(i) * Double(fftHop) / sampleRate - windowOffset * floor(Double(i) / Double(framesPerWindow))
    }

    public struct NoteEvent: Equatable {
        public var startFrame: Int
        public var endFrame: Int
        public var pitch: Int
        public var amplitude: Double
        public init(startFrame: Int, endFrame: Int, pitch: Int, amplitude: Double) {
            self.startFrame = startFrame
            self.endFrame = endFrame
            self.pitch = pitch
            self.amplitude = amplitude
        }
        public var startTime: Double { BasicPitch.frameTime(startFrame) }
        public var endTime: Double { BasicPitch.frameTime(endFrame) }
    }

    /// Port of `output_to_notes_polyphonic` (onset_thresh 0.5, frame_thresh 0.3, min 11 frames ≈ 127.7 ms).
    public static func notes(note frames: [Float], onset onsetsIn: [Float], frameCount n: Int,
                             onsetThreshold: Float = 0.5, frameThreshold: Float = 0.3, minNoteLength: Int = 11,
                             inferOnsets: Bool = true, melodiaTrick: Bool = true, energyTolerance: Int = 11) -> [NoteEvent] {
        let bins = noteBins
        guard n > 2, frames.count >= n * bins, onsetsIn.count >= n * bins else { return [] }
        var onsets = Array(onsetsIn[0..<(n * bins)])
        if inferOnsets {
            // frame_diff = min over n=1,2 of (frames[t] - frames[t-n]) with zero padding, clipped at 0, first 2 rows zeroed
            var diff = [Float](repeating: 0, count: n * bins)
            var maxDiff: Float = 0
            for t in 2..<n {
                for f in 0..<bins {
                    let cur = frames[t * bins + f]
                    let d1 = cur - frames[(t - 1) * bins + f]
                    let d2 = cur - frames[(t - 2) * bins + f]
                    let d = max(0, min(d1, d2))
                    diff[t * bins + f] = d
                    if d > maxDiff { maxDiff = d }
                }
            }
            let maxOnset = onsets.max() ?? 0
            if maxDiff > 0 {
                let scale = maxOnset / maxDiff
                for i in 0..<(n * bins) { onsets[i] = max(onsets[i], diff[i] * scale) }
            }
        }
        // strict local maxima along time (argrelmax, axis 0, edges excluded)
        var onsetIdx: [(Int, Int)] = []
        for t in 1..<(n - 1) {
            for f in 0..<bins {
                let v = onsets[t * bins + f]
                if v > onsets[(t - 1) * bins + f] && v > onsets[(t + 1) * bins + f] && v >= onsetThreshold {
                    onsetIdx.append((t, f))
                }
            }
        }
        var remaining = Array(frames[0..<(n * bins)])
        var events: [NoteEvent] = []
        for (start, f) in onsetIdx.reversed() {
            if start >= n - 1 { continue }
            var i = start + 1
            var k = 0
            while i < n - 1 && k < energyTolerance {
                if remaining[i * bins + f] < frameThreshold { k += 1 } else { k = 0 }
                i += 1
            }
            i -= k
            if i - start <= minNoteLength { continue }
            for t in start..<i {
                remaining[t * bins + f] = 0
                if f < bins - 1 { remaining[t * bins + f + 1] = 0 }
                if f > 0 { remaining[t * bins + f - 1] = 0 }
            }
            var s: Double = 0
            for t in start..<i { s += Double(frames[t * bins + f]) }
            events.append(NoteEvent(startFrame: start, endFrame: i, pitch: f + midiOffset, amplitude: s / Double(i - start)))
        }
        if melodiaTrick {
            // visiting cells in descending value order is equivalent to repeated argmax (cells only ever get zeroed)
            var candidates: [(Float, Int)] = []
            for idx in 0..<(n * bins) where remaining[idx] > frameThreshold { candidates.append((remaining[idx], idx)) }
            candidates.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            for (value, idx) in candidates {
                guard remaining[idx] == value, value > frameThreshold else { continue }
                let mid = idx / bins, f = idx % bins
                remaining[idx] = 0
                var i = mid + 1
                var k = 0
                while i < n - 1 && k < energyTolerance {
                    if remaining[i * bins + f] < frameThreshold { k += 1 } else { k = 0 }
                    remaining[i * bins + f] = 0
                    if f < bins - 1 { remaining[i * bins + f + 1] = 0 }
                    if f > 0 { remaining[i * bins + f - 1] = 0 }
                    i += 1
                }
                let iEnd = i - 1 - k
                i = mid - 1
                k = 0
                while i > 0 && k < energyTolerance {
                    if remaining[i * bins + f] < frameThreshold { k += 1 } else { k = 0 }
                    remaining[i * bins + f] = 0
                    if f < bins - 1 { remaining[i * bins + f + 1] = 0 }
                    if f > 0 { remaining[i * bins + f - 1] = 0 }
                    i -= 1
                }
                let iStart = i + 1 + k
                if iEnd - iStart <= minNoteLength { continue }
                var s: Double = 0
                for t in iStart..<iEnd { s += Double(frames[t * bins + f]) }
                events.append(NoteEvent(startFrame: iStart, endFrame: iEnd, pitch: f + midiOffset, amplitude: s / Double(iEnd - iStart)))
            }
        }
        return events
    }
}
