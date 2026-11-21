import XCTest
@testable import MaiCore

final class OMRTests: XCTestCase {
    func loadPGM(_ name: String) throws -> GrayImage {
        let gz = [UInt8](try Data(contentsOf: ChartGeneratorTests.resource(name)))
        // gzip: 10 byte header (no optional fields from `gzip -9 -c`), deflate body, 8 byte trailer
        var start = 10
        if gz[3] & 0x08 != 0 { while gz[start] != 0 { start += 1 }; start += 1 } // file name
        let raw = [UInt8](try Inflate.decompress(Data(gz[start..<(gz.count - 8)])))
        var fields: [String] = []
        var i = 0
        while fields.count < 4 {
            while raw[i] == 32 || raw[i] == 10 { i += 1 }
            var tok = ""
            while !(raw[i] == 32 || raw[i] == 10) { tok.append(Character(UnicodeScalar(raw[i]))); i += 1 }
            fields.append(tok)
        }
        i += 1
        let w = Int(fields[1])!, h = Int(fields[2])!
        return GrayImage(width: w, height: h, pixels: Array(raw[i..<(i + w * h)]))
    }

    func recall(_ page: String, _ midi: String) throws -> (Double, OMR.Result) {
        let r = OMR.recognize(pages: [try loadPGM(page)])
        let truthScore = try MIDIFile.parse(data: Data(contentsOf: ChartGeneratorTests.resource(midi)))
        let truth = truthScore.notes.map { ($0.startBeat, $0.pitch) }
        let est = r.score.notes.map { ($0.startBeat, $0.pitch) }
        let hit = truth.filter { t in est.contains { abs($0.0 - t.0) < 0.06 && $0.1 == t.1 } }.count
        return (Double(hit) / Double(truth.count), r)
    }

    func testEngravedMelodyIsRecognised() throws {
        let (rec, r) = try recall("omr_melody.pgm.gz", "omr_melody.mid")
        XCTAssertEqual(r.staves, 1)
        XCTAssertGreaterThanOrEqual(rec, 0.55, "exact note recall \(rec)")
    }

    func testGrandStaffIsOneSystemWithBothClefs() throws {
        let (rec, r) = try recall("omr_piano.pgm.gz", "omr_piano.mid")
        XCTAssertEqual(r.staves, 2)
        XCTAssertEqual(r.systems, 1)
        XCTAssertGreaterThanOrEqual(rec, 0.6, "exact note recall \(rec)")
        // left hand notes must be low (bass clef recognised)
        XCTAssertTrue(r.score.notes.contains { $0.pitch < 48 })
    }
}
