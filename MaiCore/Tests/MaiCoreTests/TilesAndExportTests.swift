import XCTest
@testable import MaiCore

final class TilesAndExportTests: XCTestCase {
    func testPianoTilesRules() throws {
        for file in ["pop160.mid", "piano_solo.mid", "ballad_tempo.mid"] {
            let score = try MIDIFile.parse(data: Data(contentsOf: ChartGeneratorTests.resource(file)))
            let tiles = PianoTilesBuilder.build(score: score)
            XCTAssertGreaterThan(tiles.count, 20, file)
            XCTAssertTrue(tiles.allSatisfy { (0..<4).contains($0.lane) }, "4 lanes only")
            // never more than two tiles at the same moment; simultaneous tiles share the same length and differ in lane
            let groups = Dictionary(grouping: tiles, by: { Int(($0.time * 1000).rounded()) })
            for (_, g) in groups {
                XCTAssertLessThanOrEqual(g.count, 2, file)
                if g.count == 2 {
                    XCTAssertEqual(g[0].duration, g[1].duration, accuracy: 1e-9, "equal length for simultaneous tiles")
                    XCTAssertNotEqual(g[0].lane, g[1].lane)
                }
            }
            // tiles in the same lane never overlap
            for lane in 0..<4 {
                let l = tiles.filter { $0.lane == lane }.sorted { $0.time < $1.time }
                for k in 1..<max(1, l.count) { XCTAssertLessThanOrEqual(l[k - 1].time + l[k - 1].duration, l[k].time + 1e-6, "\(file) lane \(lane) overlap") }
            }
            XCTAssertTrue(tiles.allSatisfy { !$0.sounds.isEmpty })
            // autoplay judge
            let j = TilesJudge(tiles: tiles)
            for tile in tiles { _ = j.tap(lane: tile.lane, at: tile.time) }
            j.update(1000)
            XCTAssertEqual(j.maxCombo, tiles.count)
        }
    }

    func testAdxPackageHasNoWAVAndParses() throws {
        let set = ChartGenerator.generate(FeatureExtractor.features(from: try MIDIFile.parse(data: Data(contentsOf: ChartGeneratorTests.resource("piano_solo.mid")))),
                                          title: "Glass/Garden: \"Test\"", artist: "MaiChart")
        let level = LevelPackager.Level(title: set.maidata.title, maidata: set.maidata.data(), track: Data([0xFF, 0xFB, 0x90, 0x00]), background: Data([1, 2, 3]))
        let adx = LevelPackager.adx([level])
        let entries = try ZipArchive.read(adx)
        XCTAssertEqual(Set(entries.map { $0.path }), ["Glass Garden Test/maidata.txt", "Glass Garden Test/track.mp3", "Glass Garden Test/bg.jpg"])
        XCTAssertFalse(entries.contains { $0.path.lowercased().hasSuffix(".wav") })
        XCTAssertEqual([UInt8](entries[0].data.prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 BOM for AstroDX")
        let text = String(decoding: entries[0].data, as: UTF8.self)
        XCTAssertTrue(text.contains("&title=Glass/Garden"))
        let m = MaidataFile(text: text)
        for d in Difficulty.allCases { XCTAssertNoThrow(try SimaiParser.parse(m.chartBody(d)!)) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = try LevelPackager.writeFolder(level, into: tmp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("maidata.txt").path))
        try? FileManager.default.removeItem(at: tmp)
    }
}
