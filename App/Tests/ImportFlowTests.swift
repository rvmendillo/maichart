import XCTest
import AVFoundation
@testable import MaiChartStudio
import MaiCore

/// The import paths a user can take: New chart → song file, New chart → maimai chart (.adx / folders),
/// the Import drop folder, and what can be done with an imported chart afterwards.
@MainActor
final class ImportFlowTests: XCTestCase {
    func resource(_ name: String, _ ext: String) throws -> URL {
        let b = Bundle(for: ImportFlowTests.self)
        return try XCTUnwrap(b.url(forResource: name, withExtension: ext, subdirectory: "Resources") ?? b.url(forResource: name, withExtension: ext))
    }

    /// The demo MIDI ships in the app bundle (the test host).
    func demoMIDI() throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: "NeonSkyline", withExtension: "mid", subdirectory: "Demo") ?? Bundle.main.url(forResource: "NeonSkyline", withExtension: "mid"))
    }

    func tempCopy(_ url: URL, name: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name ?? url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    func cleanUp(_ lib: Library) {
        for p in lib.projects where p.title.hasPrefix("Tone Song") || p.title == "Second" || p.title.hasPrefix("Inbox") || p.title.hasPrefix("Import Test") {
            lib.delete(p)
        }
    }

    func testSongFileImportEntryPoint() async throws {
        let lib = Library(settings: AppSettings())
        let mid = try tempCopy(try demoMIDI(), name: "Import Test.mid")
        let p = await lib.importFile(mid)
        XCTAssertNil(lib.errorMessage)
        let project = try XCTUnwrap(p, "the picked file must turn into a project")
        defer { lib.delete(project) }
        XCTAssertEqual(project.levels.count, 6)
        XCTAssertNil(lib.job, "progress panel is closed afterwards")
        XCTAssertTrue(lib.projects.contains { $0.id == project.id })
        // unsupported files explain themselves instead of silently doing nothing
        let txt = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: txt)
        let none = await lib.importFile(txt)
        XCTAssertNil(none)
        XCTAssertNotNil(lib.errorMessage)
        lib.errorMessage = nil
    }

    func testImportChartsPlayNudgeExportAndDuplicates() async throws {
        let lib = Library(settings: AppSettings())
        cleanUp(lib)
        defer { cleanUp(lib) }
        let adx = try tempCopy(try resource("levels_pack", "adx"))
        let imported = await lib.importCharts([adx])
        XCTAssertEqual(Set(imported.map { $0.title }), ["Tone Song", "Second"])
        var tone = try XCTUnwrap(imported.first { $0.title == "Tone Song" })
        XCTAssertEqual(tone.source, .chart)
        XCTAssertEqual(tone.trackFile, "level/track.ogg")
        XCTAssertEqual(tone.coverFile, "level/bg.png")
        XCTAssertEqual(tone.levelFolderName, "Tone Song")
        XCTAssertFalse(tone.hasChart(.easy))
        XCTAssertTrue(tone.hasChart(.expert))
        XCTAssertEqual(tone.levels[Difficulty.master.rawValue - 1], "12+")
        XCTAssertGreaterThan(tone.noteCounts[Difficulty.master.rawValue - 1], 0)
        XCTAssertTrue(tone.notesSummary.contains("UTAGE"))

        // the player can decode the level's own audio (Ogg Vorbis) and play every chart
        let audio = try AudioIO.decode(url: ProjectStore.file(tone, tone.trackFile), asIs: true)
        XCTAssertEqual(audio.duration, 3.0, accuracy: 0.01)
        let m = MaidataFile(text: try XCTUnwrap(ProjectStore.maidataText(tone)))
        XCTAssertEqual(m.firstOffset(.master), 0.25, accuracy: 1e-9)
        for d in [Difficulty.expert, .master] {
            let chart = PlayChart(try SimaiParser.parse(XCTUnwrap(m.chartBody(d))))
            let e = JudgeEngine(chart: chart)
            var t = -1.0
            while t < chart.finishTime + 2 { _ = e.autoplay(t); t += 1.0 / 120 }
            XCTAssertTrue(e.allPerfect, "\(d)")
        }

        // importing the same archive again adds nothing and says why
        let again = await lib.importCharts([adx])
        XCTAssertTrue(again.isEmpty)
        XCTAssertTrue(lib.notice?.text.contains("Already in your library") == true, lib.notice?.text ?? "no notice")
        lib.notice = nil

        // sync nudge goes into &first of the working copy only
        let originalBytes = try Data(contentsOf: ProjectStore.dir(tone.id).appendingPathComponent("level/maidata.txt"))
        tone.userOffsetMs = 12
        try Pipeline.regenerate(&tone)
        XCTAssertEqual(MaidataFile(text: try XCTUnwrap(ProjectStore.maidataText(tone))).first, 0.262, accuracy: 1e-9)
        XCTAssertEqual(try Data(contentsOf: ProjectStore.dir(tone.id).appendingPathComponent("level/maidata.txt")), originalBytes)

        // export keeps the level's folder name and files (track.ogg, bg.png) with the nudged &first
        let exported = try Pipeline.exportADX(tone)
        let back = try LevelImporter.levels(inArchive: Data(contentsOf: exported), archiveName: exported.lastPathComponent)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].info.name, "Tone Song")
        XCTAssertEqual(Set(back[0].files.keys), ["maidata.txt", "track.ogg", "bg.png"])
        XCTAssertEqual(back[0].info.maidata.first, 0.262, accuracy: 1e-9)
        XCTAssertEqual(back[0].files["track.ogg"], try Data(contentsOf: try resource("tones", "ogg")))

        // removing the nudge restores the original bytes
        tone.userOffsetMs = 0
        try Pipeline.regenerate(&tone)
        XCTAssertEqual(try Data(contentsOf: ProjectStore.file(tone, "maidata.txt")), originalBytes)

        // a plain level folder works the same way (here: a changed copy, so it is not a duplicate)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Tone Song Copy")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = String(decoding: originalBytes, as: UTF8.self).replacingOccurrences(of: "&title=Tone Song", with: "&title=Tone Song Copy")
        try Data(text.utf8).write(to: folder.appendingPathComponent("maidata.txt"))
        try FileManager.default.copyItem(at: try resource("tones", "ogg"), to: folder.appendingPathComponent("track.ogg"))
        let fromFolder = await lib.importCharts([folder.deletingLastPathComponent()])
        XCTAssertEqual(fromFolder.map { $0.title }, ["Tone Song Copy"])

        // a folder without any chart gives a clear message
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let nothing = await lib.importCharts([empty])
        XCTAssertTrue(nothing.isEmpty)
        XCTAssertTrue(lib.errorMessage?.contains("No maimai chart") == true, lib.errorMessage ?? "no error")
        lib.errorMessage = nil
    }

    func testImportFolderPicksUpChartsAndSongs() async throws {
        let lib = Library(settings: AppSettings())
        cleanUp(lib)
        defer { cleanUp(lib) }
        let inbox = ProjectStore.importInbox
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("README.txt").path))
        for sub in ["Imported", "Failed"] { try? FileManager.default.removeItem(at: inbox.appendingPathComponent(sub)) }
        let before = Set(lib.projects.map { $0.id })
        // a new level archive (distinct chart) and a MIDI song
        let ogg = try Data(contentsOf: try resource("tones", "ogg"))
        let zip = ZipArchive.write([
            ZipEntry(path: "Inbox Song/maidata.txt", data: Data("&title=Inbox Song\n&artist=Drop\n&lv_5=9\n&inote_5=(120){4}1,2,3,4,E\n".utf8)),
            ZipEntry(path: "Inbox Song/track.ogg", data: ogg),
        ])
        try zip.write(to: inbox.appendingPathComponent("Inbox Song.adx"))
        let mid = try demoMIDI()
        try? FileManager.default.removeItem(at: inbox.appendingPathComponent("Inbox Tune.mid"))
        try FileManager.default.copyItem(at: mid, to: inbox.appendingPathComponent("Inbox Tune.mid"))
        try Data("x".utf8).write(to: inbox.appendingPathComponent("random.bin"))

        await lib.scanInbox()
        let added = lib.projects.filter { !before.contains($0.id) }
        defer { for p in added { lib.delete(p) } }
        XCTAssertEqual(added.filter { $0.source == .chart }.map { $0.title }, ["Inbox Song"])
        XCTAssertEqual(added.filter { $0.source == .midi }.count, 1, "the MIDI dropped into the folder was charted")
        XCTAssertEqual(added.first { $0.source == .midi }?.levels.count, 6)
        XCTAssertTrue(ChartImport.inboxItems().isEmpty, "processed items leave the inbox")
        let imported = (try? FileManager.default.contentsOfDirectory(atPath: inbox.appendingPathComponent("Imported").path)) ?? []
        let failed = (try? FileManager.default.contentsOfDirectory(atPath: inbox.appendingPathComponent("Failed").path)) ?? []
        XCTAssertTrue(imported.contains("Inbox Song.adx") && imported.contains("Inbox Tune.mid"), "\(imported)")
        XCTAssertTrue(failed.contains("random.bin"), "\(failed)")
        XCTAssertNotNil(lib.notice)
        print("Import folder notice: \(lib.notice?.text ?? "-")")
        for sub in ["Imported", "Failed"] { try? FileManager.default.removeItem(at: inbox.appendingPathComponent(sub)) }
    }
}
