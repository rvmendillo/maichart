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

    func testTrackProducerAlignsForAppleAndNaiveDecoders() throws {
        // 1 s of silence then a click train
        let sr = 44100.0
        var x = [Float](repeating: 0, count: Int(sr * 6))
        var t = 44100
        while t < x.count - 2000 { for k in 0..<400 { x[t + k] = Float(sin(Double(k) * 0.3)) * Float(exp(-Double(k) / 80)) * 0.8 }; t += 11025 }
        let pcm = AudioSamples(sampleRate: sr, channels: [x, x])
        // iOS target: minimp3 keeps 529 samples, Apple removes them -> target lag 0
        let apple = try TrackProducer.makeMP3(from: pcm, targetDecoderDelay: 0)
        XCTAssertEqual(apple.report.lagSamples, TrackProducer.mp3DecoderDelay)
        XCTAssertEqual(apple.timelineShift, 0)
        XCTAssertTrue(apple.precompensated)
        // naive target: minimp3 itself is the target -> lag 0
        let naive = try TrackProducer.makeMP3(from: pcm, targetDecoderDelay: TrackProducer.mp3DecoderDelay)
        XCTAssertEqual(naive.report.lagSamples, 0)
        XCTAssertGreaterThan(naive.report.correlation, 0.99)
        // no leading silence: nothing trimmed, delay measured and reported as a timeline shift
        var y = x
        for k in 0..<2000 { y[k] = Float(sin(Double(k) * 0.05)) * 0.5 }
        let shifted = try TrackProducer.makeMP3(from: AudioSamples(sampleRate: sr, channels: [y, y]), targetDecoderDelay: 0)
        XCTAssertFalse(shifted.precompensated)
        XCTAssertEqual(shifted.timelineShift, 576 / sr, accuracy: 1.5 / sr)
        // a full-scale master gets ~1 dB of headroom; the report is measured against what was encoded
        var loud = x
        for i in loud.indices { loud[i] *= 1.25 }
        let loudPCM = AudioSamples(sampleRate: sr, channels: [loud, loud])
        let hot = try TrackProducer.makeMP3(from: loudPCM, targetDecoderDelay: TrackProducer.mp3DecoderDelay)
        XCTAssertGreaterThan(loudPCM.peak, 0.9)
        XCTAssertEqual(hot.gain, 0.9 / loudPCM.peak, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(hot.report.decodedPeak, 1.0)
        let decoded = try MP3Decoder.decode(hot.mp3, gapless: false).buffer
        let fair = AudioAlignment.compare(reference: loudPCM, decoded: decoded, referenceGain: hot.gain)
        let unfair = AudioAlignment.compare(reference: loudPCM, decoded: decoded)
        XCTAssertEqual(fair.lagSamples, 0)
        XCTAssertGreaterThan(fair.snrDB, unfair.snrDB + 6)
        XCTAssertGreaterThan(fair.snrDB, 20)
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
