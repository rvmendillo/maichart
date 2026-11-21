import XCTest
@testable import MaiCore

final class MusicXMLTests: XCTestCase {
    func truth() throws -> [[Double]] {
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: ChartGeneratorTests.resource("bwv1.6.truth.json"))) as! [String: Any]
        return (j["notes"] as! [[NSNumber]]).map { $0.map { $0.doubleValue } }
    }

    func check(_ score: Score, file: String) throws {
        let t = try truth()
        let mine = score.notes.map { [$0.startBeat, Double($0.pitch), $0.durationBeats] }
            .sorted { ($0[0], $0[1], $0[2]) < ($1[0], $1[1], $1[2]) }
        XCTAssertEqual(mine.count, t.count, "\(file): note count")
        var matched = 0
        var pool = t
        for n in mine {
            if let i = pool.firstIndex(where: { abs($0[0] - n[0]) < 1e-3 && $0[1] == n[1] && abs($0[2] - n[2]) < 1e-3 }) {
                matched += 1
                pool.remove(at: i)
            }
        }
        XCTAssertEqual(matched, t.count, "\(file): \(t.count - matched) notes differ from music21")
    }

    func testCompressedMXLMatchesMusic21() throws {
        let data = try Data(contentsOf: ChartGeneratorTests.resource("bwv1.6.mxl"))
        let score = try MusicXML.parse(data: data, title: "bwv1.6")
        XCTAssertEqual(score.tracks.count, 5)
        try check(score, file: "mxl")
    }

    func testUncompressedMusicXMLMatchesMusic21() throws {
        let data = try Data(contentsOf: ChartGeneratorTests.resource("bwv1.6.musicxml"))
        let score = try MusicXML.parse(data: data)
        try check(score, file: "musicxml")
        // the chart generator accepts MusicXML-derived scores
        let set = ChartGenerator.generate(FeatureExtractor.features(from: score, source: .musicXML))
        XCTAssertEqual(set.charts.count, 6)
        XCTAssertTrue(set.reports.values.allSatisfy { $0.isPlayable })
    }

    func testZipRoundTripAndInflate() throws {
        let entries = [ZipEntry(path: "Song/maidata.txt", data: Data("&title=x\n".utf8)), ZipEntry(path: "Song/track.mp3", data: Data((0..<5000).map { UInt8($0 % 251) }))]
        let zip = ZipArchive.write(entries)
        let back = try ZipArchive.read(zip)
        XCTAssertEqual(back.map { $0.path }, entries.map { $0.path })
        XCTAssertEqual(back[1].data, entries[1].data)
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testRepeatsAndEndingsExpand() throws {
        let xml = """
        <?xml version="1.0"?><score-partwise><part-list><score-part id="P1"><part-name>A</part-name></score-part></part-list>
        <part id="P1">
        <measure number="1"><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
        <barline location="left"><repeat direction="forward"/></barline>
        <note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration></note></measure>
        <measure number="2"><barline location="left"><ending number="1" type="start"/></barline><note><pitch><step>D</step><octave>4</octave></pitch><duration>4</duration></note>
        <barline location="right"><ending number="1" type="stop"/><repeat direction="backward"/></barline></measure>
        <measure number="3"><barline location="left"><ending number="2" type="start"/></barline><note><pitch><step>E</step><octave>4</octave></pitch><duration>4</duration></note>
        <barline location="right"><ending number="2" type="discontinue"/></barline></measure>
        </part></score-partwise>
        """
        let s = try MusicXML.parse(data: Data(xml.utf8))
        XCTAssertEqual(s.notes.map { $0.pitch }, [60, 62, 60, 64])
        XCTAssertEqual(s.notes.map { $0.startBeat }, [0, 4, 8, 12])
    }
}
