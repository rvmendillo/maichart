import Foundation
import CStbVorbis

public enum OggVorbisError: Error, CustomStringConvertible {
    case notOgg
    case decode(Int32)
    public var description: String {
        switch self {
        case .notOgg: return "Not an Ogg Vorbis file."
        case .decode(let code): return "The Ogg Vorbis audio could not be decoded (error \(code))."
        }
    }
}

/// Ogg Vorbis decoding (track.ogg in AstroDX levels) via stb_vorbis, with float output.
public enum OggVorbisDecoder {
    public static func isOgg(_ data: Data) -> Bool { data.count > 4 && data.prefix(4).elementsEqual("OggS".utf8) }

    public static func decode(_ data: Data) throws -> AudioSamples {
        guard isOgg(data) else { throw OggVorbisError.notOgg }
        var out: UnsafeMutablePointer<Float>? = nil
        var channels: Int32 = 0, sampleRate: Int32 = 0
        var frames: Int = 0
        let r = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return csv_decode(base, Int32(raw.count), &out, &channels, &sampleRate, &frames)
        }
        guard r == 0, let p = out, channels > 0, sampleRate > 0 else { throw OggVorbisError.decode(r) }
        defer { csv_free(p) }
        let c = Int(channels)
        let keep = min(c, 2)
        var a = AudioSamples(sampleRate: Double(sampleRate), channelCount: keep, frames: frames)
        for k in 0..<keep {
            a.channels[k].withUnsafeMutableBufferPointer { dst in
                for i in 0..<frames { dst[i] = p[i * c + k] }
            }
        }
        if c > 2 {
            // fold the remaining channels into both sides so nothing is lost from surround files
            for extra in 2..<c {
                for k in 0..<2 {
                    a.channels[k].withUnsafeMutableBufferPointer { dst in
                        for i in 0..<frames { dst[i] += 0.5 * p[i * c + extra] }
                    }
                }
            }
        }
        return a
    }
}
