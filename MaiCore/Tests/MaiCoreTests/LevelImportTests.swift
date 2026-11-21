import XCTest
@testable import MaiCore

final class LevelImportTests: XCTestCase {
    func res(_ name: String) throws -> Data { try Data(contentsOf: ChartGeneratorTests.resource(name)) }

    /// The tone sequence encoded in tones.ogg (without its small noise floor).
    func toneReference(sampleRate: Double = 44100, seconds: Double = 3) -> [Float] {
        let n = Int(sampleRate * seconds)
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            let k = Int(t / 0.25), ph = t - Double(k) * 0.25
            let f = [440.0, 494, 523, 587, 659, 698, 784, 880][k % 8]
            return Float(0.45 * exp(-ph * 9) * sin(2 * Double.pi * f * t))
        }
    }

    func testOggVorbisDecodesSampleExactly() throws {
        let data = try res("tones.ogg")
        XCTAssertTrue(OggVorbisDecoder.isOgg(data))
        let a = try OggVorbisDecoder.decode(data)
        XCTAssertEqual(a.sampleRate, 44100)
        XCTAssertEqual(a.channelCount, 2)
        XCTAssertEqual(a.frameCount, 132_300, "same length as the source (and as FFmpeg's decode)")
        let ref = AudioSamples(sampleRate: 44100, channels: [toneReference(), toneReference().map { $0 * 0.8 }])
        let report = AudioAlignment.compare(reference: ref, decoded: a)
        print("Ogg vs source: \(report)")
        XCTAssertEqual(report.lagSamples, 0, "track.ogg must start on the same sample as the source")
        XCTAssertGreaterThan(report.correlation, 0.99)
        XCTAssertThrowsError(try OggVorbisDecoder.decode(Data("not ogg".utf8)))
    }

    func testAdxArchiveWithFoldersJunkAndEncodings() throws {
        let levels = try LevelImporter.levels(inArchive: try res("levels_pack.adx"), archiveName: "levels_pack.adx")
        XCTAssertEqual(levels.map { $0.info.name }, ["Second", "Tone Song"], "__MACOSX entries are ignored")
        let tone = try XCTUnwrap(levels.first { $0.info.name == "Tone Song" })
        XCTAssertEqual(tone.info.title, "Tone Song")
        XCTAssertEqual(tone.info.artist, "MaiChart Tests")
        XCTAssertEqual(tone.info.maidata.first, 0.25, accuracy: 1e-9, "BOM + CRLF maidata parsed")
        XCTAssertEqual(tone.info.trackFile, "track.ogg")
        XCTAssertEqual(tone.info.backgroundFile, "bg.png")
        XCTAssertEqual(tone.info.difficulties, [.expert, .master])
        XCTAssertEqual(tone.info.extraChartSlots, [7])
        XCTAssertNoThrow(try LevelImporter.validate(tone.info))
        for d in tone.info.difficulties {
            let chart = try SimaiParser.parse(XCTUnwrap(tone.info.maidata.chartBody(d)))
            XCTAssertFalse(chart.notes.isEmpty)
        }
        XCTAssertEqual(tone.files["track.ogg"], try res("tones.ogg"))
        let second = try XCTUnwrap(levels.first { $0.info.name == "Second" })
        XCTAssertEqual(second.info.trackFile, "track.mp3")
        XCTAssertNil(second.info.backgroundFile)
        XCTAssertEqual(second.info.difficulties, [.remaster])
        XCTAssertEqual(second.info.maidata.level(.remaster), "13")
        // a zip with maidata.txt at its root is named after the archive
        let flat = ZipArchive.write([ZipEntry(path: "maidata.txt", data: Data("&title=\n&inote_5=(100)1,E\n".utf8)),
                                     ZipEntry(path: "track.mp3", data: Data([1, 2, 3]))])
        let f = try LevelImporter.levels(inArchive: flat, archiveName: "Flat Song.zip")
        XCTAssertEqual(f.map { $0.info.title }, ["Flat Song"])
        // archives without charts are rejected with a clear error
        XCTAssertThrowsError(try LevelImporter.levels(inArchive: ZipArchive.write([ZipEntry(path: "a.txt", data: Data())]), archiveName: "x.zip"))
    }

    func testLevelDirectoriesOnDiskAndValidation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lvl-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        func make(_ rel: String, _ files: [String: Data]) throws {
            let d = root.appendingPathComponent(rel)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            for (n, data) in files { try data.write(to: d.appendingPathComponent(n)) }
        }
        let md = Data("&title=A\n&inote_4=(120)1,E\n".utf8)
        try make("AstroDX/levels/aaa", ["maidata.txt": md, "track.mp3": Data([1])])
        try make("AstroDX/levels/bbb", ["maidata.txt": md, "Track.OGG": Data([1]), "BG.JPG": Data([2]), "pv.mp4": Data([3])])
        try make("AstroDX/levels/ccc", ["maidata.txt": md]) // no audio
        try make("AstroDX/collections/pack", ["manifest.json": Data("{}".utf8)])
        let dirs = LevelImporter.levelDirectories(in: root)
        XCTAssertEqual(dirs.map { $0.lastPathComponent }, ["aaa", "bbb", "ccc"])
        // a level folder picked directly is found as itself
        XCTAssertEqual(LevelImporter.levelDirectories(in: root.appendingPathComponent("AstroDX/levels/bbb")).count, 1)
        let b = try LevelImporter.inspect(directory: dirs[1])
        XCTAssertEqual(b.trackFile, "Track.OGG")
        XCTAssertEqual(b.backgroundFile, "BG.JPG")
        XCTAssertEqual(b.videoFile, "pv.mp4")
        XCTAssertThrowsError(try LevelImporter.validate(LevelImporter.inspect(directory: dirs[2]))) { e in
            XCTAssertTrue("\(e)".contains("no track"), "\(e)")
        }
    }

    func testMaidataEditorKeepsEverythingElse() {
        let text = "\u{FEFF}&title=X\r\n&artist=Y\r\n&first=0.5\r\n&inote_5=(120)\r\n1,2,E\r\n"
        let edited = MaidataEditor.setting("first", to: MaidataEditor.formatSeconds(0.512), in: text)
        XCTAssertEqual(edited, "\u{FEFF}&title=X\r\n&artist=Y\r\n&first=0.512\r\n&inote_5=(120)\r\n1,2,E\r\n")
        XCTAssertEqual(MaidataFile(text: edited).first, 0.512, accuracy: 1e-9)
        let inserted = MaidataEditor.setting("first", to: "0.1", in: "&title=X\n&artist=Y\n&inote_5=1,E\n")
        XCTAssertEqual(inserted, "&title=X\n&artist=Y\n&first=0.1\n&inote_5=1,E\n")
        XCTAssertEqual(MaidataEditor.formatSeconds(1.25), "1.25")
        XCTAssertEqual(MaidataEditor.formatSeconds(-0.00001), "0")
        XCTAssertEqual(MaidataEditor.formatSeconds(2), "2")
    }

    func testCRLFMaidataAndLenientSlideDurations() throws {
        let text = "&title=T\r\n&first=1\r\n&inote_5=(120){4}\r\n1-5[#1.5],2-6[0.5##160#4:1],3-7[160#2:1],4h[#1],E\r\n&lv_5=12\r\n"
        let m = MaidataFile(text: text)
        XCTAssertEqual(m.first, 1)
        XCTAssertEqual(m.level(.master), "12")
        let c = try SimaiParser.parse(try XCTUnwrap(m.chartBody(.master)))
        let slides = c.notes.flatMap { $0.slides }
        XCTAssertEqual(slides.count, 3)
        XCTAssertEqual(slides[0].duration, 1.5, accuracy: 1e-9)     // [#1.5]: 1.5 s, default 1-beat delay
        XCTAssertEqual(slides[0].delay, 0.5, accuracy: 1e-9)
        XCTAssertEqual(slides[1].delay, 0.5, accuracy: 1e-9)        // [0.5##160#4:1]
        XCTAssertEqual(slides[1].duration, 60.0 / 160, accuracy: 1e-9)
        XCTAssertEqual(slides[2].delay, 60.0 / 160, accuracy: 1e-9) // [160#2:1]
        XCTAssertEqual(slides[2].duration, 2 * 60.0 / 160, accuracy: 1e-9)
    }

    func testImportedLevelRepackagesWithOriginalNamesAndFiles() throws {
        let levels = try LevelImporter.levels(inArchive: try res("levels_pack.adx"), archiveName: "levels_pack.adx")
        let tone = try XCTUnwrap(levels.first { $0.info.name == "Tone Song" })
        var extras = tone.files
        for k in ["maidata.txt", "track.ogg", "bg.png"] { extras.removeValue(forKey: k) }
        extras["notes.txt"] = Data("kept".utf8)
        let level = LevelPackager.Level(title: tone.info.title, maidata: tone.files["maidata.txt"]!, track: tone.files["track.ogg"]!,
                                        trackExtension: "ogg", background: tone.files["bg.png"], backgroundExtension: "png",
                                        folder: tone.info.name, extraFiles: extras)
        let back = try LevelImporter.levels(inArchive: LevelPackager.adx([level]), archiveName: "re.adx")
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].info.name, "Tone Song")
        XCTAssertEqual(Set(back[0].files.keys), ["maidata.txt", "track.ogg", "bg.png", "notes.txt"])
        XCTAssertEqual(back[0].files["maidata.txt"], tone.files["maidata.txt"], "maidata.txt is byte-identical")
    }
}
