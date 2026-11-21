import Foundation

public enum ZipError: Error, LocalizedError {
    case notZip, corrupt(String), unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .notZip: return "Not a ZIP archive."
        case .corrupt(let s): return "Corrupt archive: \(s)"
        case .unsupported(let s): return "Unsupported archive feature: \(s)"
        }
    }
}

public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for b in raw.bindMemory(to: UInt8.self) { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Raw DEFLATE (RFC 1951) decoder.
public enum Inflate {
    struct BitReader {
        let data: [UInt8]
        var pos = 0
        var bitBuf: UInt32 = 0
        var bitCount = 0
        mutating func bits(_ n: Int) throws -> Int {
            while bitCount < n {
                guard pos < data.count else { throw ZipError.corrupt("unexpected end of deflate stream") }
                bitBuf |= UInt32(data[pos]) << UInt32(bitCount)
                pos += 1
                bitCount += 8
            }
            let v = Int(bitBuf & ((1 << UInt32(n)) - 1))
            bitBuf >>= UInt32(n)
            bitCount -= n
            return v
        }
        mutating func alignToByte() { bitBuf = 0; bitCount = 0 }
    }

    struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []
        init(lengths: [Int]) {
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var offs = [Int](repeating: 0, count: 16)
            for i in 1..<16 { offs[i] = offs[i - 1] + counts[i - 1] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (s, l) in lengths.enumerated() where l != 0 { symbols[offs[l]] = s; offs[l] += 1 }
        }
        func decode(_ br: inout BitReader) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try br.bits(1)
                let count = counts[len]
                if code - count < first { return symbols[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw ZipError.corrupt("bad huffman code")
        }
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    public static func decompress(_ input: Data, expectedSize: Int = 0) throws -> Data {
        var br = BitReader(data: [UInt8](input))
        var out = [UInt8]()
        out.reserveCapacity(max(expectedSize, input.count * 3))
        var final = 0
        repeat {
            final = try br.bits(1)
            let type = try br.bits(2)
            switch type {
            case 0:
                br.alignToByte()
                guard br.pos + 4 <= br.data.count else { throw ZipError.corrupt("stored block header") }
                let len = Int(br.data[br.pos]) | Int(br.data[br.pos + 1]) << 8
                br.pos += 4
                guard br.pos + len <= br.data.count else { throw ZipError.corrupt("stored block length") }
                out.append(contentsOf: br.data[br.pos..<(br.pos + len)])
                br.pos += len
            case 1, 2:
                let lit: Huffman, dist: Huffman
                if type == 1 {
                    var l = [Int](repeating: 8, count: 288)
                    for i in 144..<256 { l[i] = 9 }
                    for i in 256..<280 { l[i] = 7 }
                    lit = Huffman(lengths: l)
                    dist = Huffman(lengths: [Int](repeating: 5, count: 30))
                } else {
                    let hlit = try br.bits(5) + 257, hdist = try br.bits(5) + 1, hclen = try br.bits(4) + 4
                    let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
                    var cl = [Int](repeating: 0, count: 19)
                    for i in 0..<hclen { cl[order[i]] = try br.bits(3) }
                    let clh = Huffman(lengths: cl)
                    var lengths: [Int] = []
                    while lengths.count < hlit + hdist {
                        let sym = try clh.decode(&br)
                        switch sym {
                        case 0..<16: lengths.append(sym)
                        case 16:
                            guard let prev = lengths.last else { throw ZipError.corrupt("repeat without length") }
                            for _ in 0..<(3 + (try br.bits(2))) { lengths.append(prev) }
                        case 17: for _ in 0..<(3 + (try br.bits(3))) { lengths.append(0) }
                        default: for _ in 0..<(11 + (try br.bits(7))) { lengths.append(0) }
                        }
                    }
                    lit = Huffman(lengths: Array(lengths[0..<hlit]))
                    dist = Huffman(lengths: Array(lengths[hlit..<(hlit + hdist)]))
                }
                while true {
                    let sym = try lit.decode(&br)
                    if sym < 256 { out.append(UInt8(sym)); continue }
                    if sym == 256 { break }
                    let li = sym - 257
                    guard li < lengthBase.count else { throw ZipError.corrupt("bad length symbol") }
                    let len = lengthBase[li] + (try br.bits(lengthExtra[li]))
                    let ds = try dist.decode(&br)
                    guard ds < distBase.count else { throw ZipError.corrupt("bad distance symbol") }
                    let d = distBase[ds] + (try br.bits(distExtra[ds]))
                    guard d <= out.count else { throw ZipError.corrupt("distance too far back") }
                    let start = out.count - d
                    for k in 0..<len { out.append(out[start + k]) }
                }
            default:
                throw ZipError.corrupt("invalid block type")
            }
        } while final == 0
        return Data(out)
    }
}

public struct ZipEntry {
    public var path: String
    public var data: Data
    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }
}

public enum ZipArchive {
    /// Reads every file entry (stored or deflated).
    public static func read(_ data: Data) throws -> [ZipEntry] {
        let b = [UInt8](data)
        func u16(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 }
        func u32(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24 }
        guard b.count >= 22 else { throw ZipError.notZip }
        // end of central directory
        var eocd = -1
        var p = b.count - 22
        while p >= max(0, b.count - 65_557) {
            if b[p] == 0x50 && b[p + 1] == 0x4B && b[p + 2] == 0x05 && b[p + 3] == 0x06 { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = u16(eocd + 10)
        var cd = u32(eocd + 16)
        var entries: [ZipEntry] = []
        for _ in 0..<count {
            guard cd + 46 <= b.count, u32(cd) == 0x0201_4B50 else { throw ZipError.corrupt("central directory") }
            let method = u16(cd + 10)
            let compSize = u32(cd + 20), size = u32(cd + 24)
            let nameLen = u16(cd + 28), extraLen = u16(cd + 30), commentLen = u16(cd + 32)
            let localOff = u32(cd + 42)
            let nameBytes = Array(b[(cd + 46)..<(cd + 46 + nameLen)])
            let name = String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? ""
            cd += 46 + nameLen + extraLen + commentLen
            guard localOff + 30 <= b.count, u32(localOff) == 0x0403_4B50 else { throw ZipError.corrupt("local header") }
            let lNameLen = u16(localOff + 26), lExtraLen = u16(localOff + 28)
            let start = localOff + 30 + lNameLen + lExtraLen
            guard start + compSize <= b.count else { throw ZipError.corrupt("entry size") }
            if name.hasSuffix("/") { continue }
            let raw = Data(b[start..<(start + compSize)])
            switch method {
            case 0: entries.append(ZipEntry(path: name, data: raw))
            case 8: entries.append(ZipEntry(path: name, data: try Inflate.decompress(raw, expectedSize: size)))
            default: throw ZipError.unsupported("compression method \(method)")
            }
        }
        return entries
    }

    /// Writes a ZIP with stored (uncompressed) entries — ideal for already-compressed MP3/JPG payloads.
    public static func write(_ entries: [ZipEntry]) -> Data {
        var out = [UInt8]()
        var central = [UInt8]()
        func le16(_ v: Int, _ a: inout [UInt8]) { a += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32, _ a: inout [UInt8]) { a += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        // fixed DOS timestamp (2025-01-01 00:00) keeps archives reproducible
        let dosTime = 0, dosDate = ((2025 - 1980) << 9) | (1 << 5) | 1
        for e in entries {
            let name = Array(e.path.utf8)
            let crc = CRC32.checksum(e.data)
            let offset = UInt32(out.count)
            le32(0x0403_4B50, &out); le16(20, &out); le16(0x0800, &out); le16(0, &out)
            le16(dosTime, &out); le16(dosDate, &out)
            le32(crc, &out); le32(UInt32(e.data.count), &out); le32(UInt32(e.data.count), &out)
            le16(name.count, &out); le16(0, &out)
            out += name
            out += [UInt8](e.data)
            le32(0x0201_4B50, &central); le16(20, &central); le16(20, &central); le16(0x0800, &central); le16(0, &central)
            le16(dosTime, &central); le16(dosDate, &central)
            le32(crc, &central); le32(UInt32(e.data.count), &central); le32(UInt32(e.data.count), &central)
            le16(name.count, &central); le16(0, &central); le16(0, &central); le16(0, &central); le16(0, &central)
            le32(e.path.hasSuffix("/") ? 0x10 : 0, &central); le32(offset, &central)
            central += name
        }
        let cdOffset = UInt32(out.count)
        out += central
        le32(0x0605_4B50, &out); le16(0, &out); le16(0, &out)
        le16(entries.count, &out); le16(entries.count, &out)
        le32(UInt32(central.count), &out); le32(cdOffset, &out); le16(0, &out)
        return Data(out)
    }
}
