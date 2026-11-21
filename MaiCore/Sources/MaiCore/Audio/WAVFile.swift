import Foundation

public enum WAVError: Error, LocalizedError {
    case notRIFF, unsupportedFormat(String), truncated

    public var errorDescription: String? {
        switch self {
        case .notRIFF: return "Not a RIFF/WAVE file."
        case .unsupportedFormat(let s): return "Unsupported WAV format: \(s)"
        case .truncated: return "The WAV file is truncated."
        }
    }
}

/// Minimal but complete PCM/float WAV reader and writer (8/16/24/32-bit int, 32/64-bit float, WAVE_FORMAT_EXTENSIBLE).
public enum WAVFile {
    public static func read(data: Data) throws -> AudioSamples {
        let b = [UInt8](data)
        guard b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
              b[8] == 0x57, b[9] == 0x41, b[10] == 0x56, b[11] == 0x45 else { throw WAVError.notRIFF }
        var pos = 12
        var format = 0, channels = 0, rate = 0, bits = 0
        var dataStart = -1, dataLen = 0
        func u16(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 }
        func u32(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24 }
        while pos + 8 <= b.count {
            let id = String(bytes: b[pos..<pos + 4], encoding: .ascii) ?? ""
            let len = u32(pos + 4)
            let body = pos + 8
            if id == "fmt " {
                guard body + 16 <= b.count else { throw WAVError.truncated }
                format = u16(body)
                channels = u16(body + 2)
                rate = u32(body + 4)
                bits = u16(body + 14)
                if format == 0xFFFE, len >= 26, body + 26 <= b.count {
                    format = u16(body + 24) // sub-format GUID starts with the format code
                }
            } else if id == "data" {
                dataStart = body
                dataLen = min(len, b.count - body)
                break
            }
            pos = body + len + (len & 1)
        }
        guard dataStart >= 0, channels > 0, rate > 0 else { throw WAVError.truncated }
        let bytesPerSample = bits / 8
        guard bytesPerSample > 0 else { throw WAVError.unsupportedFormat("bits=\(bits)") }
        let frames = dataLen / (bytesPerSample * channels)
        var out = AudioSamples(sampleRate: Double(rate), channelCount: channels, frames: frames)
        b.withUnsafeBufferPointer { src in
            for c in 0..<channels {
                out.channels[c].withUnsafeMutableBufferPointer { dst in
                    var p = dataStart + c * bytesPerSample
                    let stride = bytesPerSample * channels
                    for f in 0..<frames {
                        let v: Float
                        switch (format, bits) {
                        case (1, 8):
                            v = (Float(src[p]) - 128) / 128
                        case (1, 16):
                            let s = Int16(bitPattern: UInt16(src[p]) | UInt16(src[p + 1]) << 8)
                            v = Float(s) / 32768
                        case (1, 24):
                            var s = Int32(src[p]) | Int32(src[p + 1]) << 8 | Int32(src[p + 2]) << 16
                            if s & 0x80_0000 != 0 { s |= ~0xFF_FFFF }
                            v = Float(s) / 8_388_608
                        case (1, 32):
                            let s = Int32(bitPattern: UInt32(src[p]) | UInt32(src[p + 1]) << 8 | UInt32(src[p + 2]) << 16 | UInt32(src[p + 3]) << 24)
                            v = Float(Double(s) / 2_147_483_648)
                        case (3, 32):
                            let u = UInt32(src[p]) | UInt32(src[p + 1]) << 8 | UInt32(src[p + 2]) << 16 | UInt32(src[p + 3]) << 24
                            v = Float(bitPattern: u)
                        case (3, 64):
                            var u: UInt64 = 0
                            for k in 0..<8 { u |= UInt64(src[p + k]) << (8 * UInt64(k)) }
                            v = Float(Double(bitPattern: u))
                        default:
                            v = 0
                        }
                        dst[f] = v
                        p += stride
                    }
                }
            }
        }
        if !((format == 1 && [8, 16, 24, 32].contains(bits)) || (format == 3 && [32, 64].contains(bits))) {
            throw WAVError.unsupportedFormat("format=\(format) bits=\(bits)")
        }
        return out
    }

    public static func read(url: URL) throws -> AudioSamples {
        try read(data: try Data(contentsOf: url))
    }

    public enum SampleFormat { case int16, int24, float32 }

    /// Encodes the buffer. 16/24-bit output uses TPDF dither so quiet passages stay clean.
    public static func encode(_ buffer: AudioSamples, format: SampleFormat = .int16, dither: Bool = true) -> Data {
        let ch = buffer.channelCount
        let frames = buffer.frameCount
        let bits: Int
        let fmtCode: Int
        switch format {
        case .int16: bits = 16; fmtCode = 1
        case .int24: bits = 24; fmtCode = 1
        case .float32: bits = 32; fmtCode = 3
        }
        let bps = bits / 8
        let dataLen = frames * ch * bps
        var d = [UInt8]()
        d.reserveCapacity(44 + dataLen)
        func put32(_ v: Int) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF)) }
        func put16(_ v: Int) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        d += Array("RIFF".utf8); put32(36 + dataLen); d += Array("WAVE".utf8)
        d += Array("fmt ".utf8); put32(16); put16(fmtCode); put16(ch); put32(Int(buffer.sampleRate))
        put32(Int(buffer.sampleRate) * ch * bps); put16(ch * bps); put16(bits)
        d += Array("data".utf8); put32(dataLen)
        var rng = SeededRandom(seed: 12345)
        let interleaved = buffer.interleaved()
        switch format {
        case .float32:
            for v in interleaved {
                let u = v.bitPattern
                d.append(UInt8(u & 0xFF)); d.append(UInt8((u >> 8) & 0xFF)); d.append(UInt8((u >> 16) & 0xFF)); d.append(UInt8((u >> 24) & 0xFF))
            }
        case .int16:
            for v in interleaved {
                var x = Double(v) * 32767
                if dither { x += (rng.unit() - rng.unit()) }
                let s = Int16(max(-32768, min(32767, x.rounded())))
                let u = UInt16(bitPattern: s)
                d.append(UInt8(u & 0xFF)); d.append(UInt8(u >> 8))
            }
        case .int24:
            for v in interleaved {
                var x = Double(v) * 8_388_607
                if dither { x += (rng.unit() - rng.unit()) }
                let s = Int32(max(-8_388_608, min(8_388_607, x.rounded())))
                let u = UInt32(bitPattern: s)
                d.append(UInt8(u & 0xFF)); d.append(UInt8((u >> 8) & 0xFF)); d.append(UInt8((u >> 16) & 0xFF))
            }
        }
        return Data(d)
    }

    public static func write(_ buffer: AudioSamples, to url: URL, format: SampleFormat = .int16) throws {
        try encode(buffer, format: format).write(to: url)
    }
}
