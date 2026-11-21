import Foundation
import CLAME
import CMiniMP3

public enum MP3Error: Error, LocalizedError {
    case encoderInit, encoderConfig(Int32), encode(Int32), decode(Int32), unsupportedChannels

    public var errorDescription: String? {
        switch self {
        case .encoderInit: return "Could not initialise the LAME MP3 encoder."
        case .encoderConfig(let c): return "LAME rejected the encoder settings (code \(c))."
        case .encode(let c): return "MP3 encoding failed (LAME code \(c))."
        case .decode(let c): return "The MP3 could not be decoded (code \(c))."
        case .unsupportedChannels: return "Only mono and stereo audio can be encoded."
        }
    }
}

/// LAME based MP3 encoder.
public enum MP3Encoder {
    public struct Options {
        public var bitrate: Int32 = 320
        /// LAME algorithm quality: 0 = best/slowest, 2 = recommended high quality.
        public var quality: Int32 = 2
        /// Xing/LAME info frame. Off by default: without it every decoder (gapless or not)
        /// produces the same timeline, which keeps AstroDX sync predictable.
        public var writeInfoTag = false
        public init() {}
    }

    /// Standard LAME encoder delay (576) + MP3 decoder delay (528 + 1) in samples.
    public static let nominalDelay = 1105

    public static func encode(_ input: AudioBuffer, options: Options = Options(), progress: ((Double) -> Void)? = nil) throws -> Data {
        let buffer = input.channelCount > 2 ? input.stereo() : input
        guard buffer.channelCount == 1 || buffer.channelCount == 2 else { throw MP3Error.unsupportedChannels }
        guard let gfp = lame_init() else { throw MP3Error.encoderInit }
        defer { lame_close(gfp) }
        lame_set_in_samplerate(gfp, Int32(buffer.sampleRate))
        lame_set_out_samplerate(gfp, Int32(buffer.sampleRate))
        lame_set_num_channels(gfp, Int32(buffer.channelCount))
        lame_set_mode(gfp, buffer.channelCount == 2 ? JOINT_STEREO : MONO)
        lame_set_VBR(gfp, vbr_off)
        lame_set_brate(gfp, options.bitrate)
        lame_set_quality(gfp, options.quality)
        lame_set_bWriteVbrTag(gfp, options.writeInfoTag ? 1 : 0)
        lame_set_write_id3tag_automatic(gfp, 0)
        let r = lame_init_params(gfp)
        guard r >= 0 else { throw MP3Error.encoderConfig(r) }

        let frames = buffer.frameCount
        let chunk = 8192
        var out = Data()
        out.reserveCapacity(frames / 44100 * 40_000 + 8192)
        var mp3buf = [UInt8](repeating: 0, count: Int(1.25 * Double(chunk)) + 7200)
        let left = buffer.channels[0]
        let right = buffer.channelCount == 2 ? buffer.channels[1] : buffer.channels[0]
        var pos = 0
        try left.withUnsafeBufferPointer { lp in
            try right.withUnsafeBufferPointer { rp in
                while pos < frames {
                    let n = min(chunk, frames - pos)
                    let written = mp3buf.withUnsafeMutableBufferPointer { mb -> Int32 in
                        lame_encode_buffer_ieee_float(gfp, lp.baseAddress! + pos, rp.baseAddress! + pos, Int32(n),
                                                      mb.baseAddress!, Int32(mb.count))
                    }
                    guard written >= 0 else { throw MP3Error.encode(written) }
                    out.append(mp3buf, count: Int(written))
                    pos += n
                    if pos % (chunk * 32) == 0 { progress?(Double(pos) / Double(frames)) }
                }
            }
        }
        let flushed = mp3buf.withUnsafeMutableBufferPointer { mb in lame_encode_flush(gfp, mb.baseAddress!, Int32(mb.count)) }
        guard flushed >= 0 else { throw MP3Error.encode(flushed) }
        out.append(mp3buf, count: Int(flushed))
        if options.writeInfoTag {
            var tag = [UInt8](repeating: 0, count: 2880)
            let n = lame_get_lametag_frame(gfp, &tag, tag.count)
            if n > 0 && n <= tag.count, let off = MP3Tools.firstFrameOffset(out) {
                // LAME reserves the first frame for the tag; overwrite it in place
                out.replaceSubrange(off..<min(out.count, off + n), with: tag[0..<n])
            }
        }
        progress?(1)
        return out
    }
}

/// minimp3 based decoder.
public enum MP3Decoder {
    public struct Result {
        public var buffer: AudioBuffer
        public var hasInfoTag: Bool
        /// Encoder + decoder delay declared by a LAME tag (samples), 0 when absent.
        public var tagDelay: Int
        public var tagPadding: Int
    }

    /// - Parameter gapless: true = honour LAME delay/padding like a gapless player; false = naive decoder output.
    public static func decode(_ data: Data, gapless: Bool = false) throws -> Result {
        var res = cmp3_result()
        let code: Int32 = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return cmp3_decode(base, raw.count, gapless ? 1 : 0, &res)
        }
        guard code == 0, res.channels > 0 else { throw MP3Error.decode(code) }
        defer { cmp3_free(&res) }
        let count = res.frames * Int(res.channels)
        let interleaved = Array(UnsafeBufferPointer(start: res.pcm, count: count))
        let buf = AudioBuffer(sampleRate: Double(res.sample_rate), interleaved: interleaved, channelCount: Int(res.channels))
        return Result(buffer: buf, hasInfoTag: res.has_vbr_tag != 0, tagDelay: Int(res.tag_delay), tagPadding: Int(res.tag_padding))
    }
}

public enum MP3Tools {
    /// Byte offset of the first MPEG audio frame (after ID3v2).
    public static func firstFrameOffset(_ data: Data) -> Int? {
        var off = 0, size = 0
        var isTag: Int32 = 0
        let r: Int32 = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return cmp3_find_tag_frame(base, raw.count, &off, &size, &isTag)
        }
        return r == 0 ? off : nil
    }

    /// Removes a Xing/Info/VBRI header frame without touching any audio frame (lossless).
    /// Afterwards gapless and naive decoders produce the identical timeline.
    public static func removingInfoFrame(_ data: Data) -> (data: Data, removed: Bool) {
        var off = 0, size = 0
        var isTag: Int32 = 0
        let r: Int32 = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return cmp3_find_tag_frame(base, raw.count, &off, &size, &isTag)
        }
        guard r == 0, isTag != 0, size > 0, off + size <= data.count else { return (data, false) }
        var d = data
        d.removeSubrange(off..<(off + size))
        return (d, true)
    }

    public struct ID3Info {
        public var title: String?
        public var artist: String?
        public var album: String?
        public var artwork: Data?
    }

    /// Minimal ID3v2.2/2.3/2.4 reader for title, artist and the cover picture (APIC/PIC).
    public static func readID3(_ data: Data) -> ID3Info {
        var info = ID3Info()
        let b = [UInt8](data.prefix(min(data.count, 16 * 1024 * 1024)))
        guard b.count > 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return info }
        let ver = Int(b[3])
        let flags = b[5]
        let size = (Int(b[6] & 0x7F) << 21) | (Int(b[7] & 0x7F) << 14) | (Int(b[8] & 0x7F) << 7) | Int(b[9] & 0x7F)
        var p = 10
        let end = min(b.count, 10 + size)
        if flags & 0x40 != 0, ver >= 3, p + 4 <= end { // extended header
            let ext = ver == 4 ? ((Int(b[p] & 0x7F) << 21) | (Int(b[p + 1] & 0x7F) << 14) | (Int(b[p + 2] & 0x7F) << 7) | Int(b[p + 3] & 0x7F))
                               : (Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])) + 4
            p += ext
        }
        func text(_ bytes: ArraySlice<UInt8>) -> String? {
            guard let enc = bytes.first else { return nil }
            var body = Array(bytes.dropFirst())
            while body.last == 0 { body.removeLast() }
            let s: String?
            switch enc {
            case 1: s = String(bytes: body, encoding: .utf16)
            case 2: s = String(bytes: body, encoding: .utf16BigEndian)
            case 3: s = String(bytes: body, encoding: .utf8)
            default: s = String(bytes: body, encoding: .isoLatin1)
            }
            return s?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        }
        while p + (ver == 2 ? 6 : 10) <= end {
            let idLen = ver == 2 ? 3 : 4
            let id = String(bytes: b[p..<p + idLen], encoding: .ascii) ?? ""
            if id.trimmingCharacters(in: CharacterSet(charactersIn: "\0")).isEmpty { break }
            let fsize: Int
            if ver == 2 { fsize = Int(b[p + 3]) << 16 | Int(b[p + 4]) << 8 | Int(b[p + 5]) }
            else if ver == 4 { fsize = (Int(b[p + 4] & 0x7F) << 21) | (Int(b[p + 5] & 0x7F) << 14) | (Int(b[p + 6] & 0x7F) << 7) | Int(b[p + 7] & 0x7F) }
            else { fsize = Int(b[p + 4]) << 24 | Int(b[p + 5]) << 16 | Int(b[p + 6]) << 8 | Int(b[p + 7]) }
            let hdr = ver == 2 ? 6 : 10
            let bodyStart = p + hdr
            let bodyEnd = min(end, bodyStart + fsize)
            guard fsize > 0, bodyStart < bodyEnd else { break }
            let body = b[bodyStart..<bodyEnd]
            switch id {
            case "TIT2", "TT2": info.title = text(body)
            case "TPE1", "TP1": info.artist = text(body)
            case "TALB", "TAL": info.album = text(body)
            case "APIC", "PIC":
                if info.artwork == nil, let enc = body.first {
                    var q = body.startIndex + 1
                    if id == "PIC" { q += 3 } else { while q < body.endIndex && b[q] != 0 { q += 1 }; q += 1 } // mime
                    q += 1 // picture type
                    // description (terminated by 0 or 00 00 for UTF-16)
                    if enc == 1 || enc == 2 {
                        while q + 1 < body.endIndex && !(b[q] == 0 && b[q + 1] == 0) { q += 2 }
                        q += 2
                    } else {
                        while q < body.endIndex && b[q] != 0 { q += 1 }
                        q += 1
                    }
                    if q < body.endIndex { info.artwork = Data(b[q..<body.endIndex]) }
                }
            default: break
            }
            p = bodyEnd
        }
        return info
    }
}
