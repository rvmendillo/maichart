import XCTest
import AVFoundation
@testable import MaiChartStudio
import MaiCore

/// Integration tests that need iOS frameworks (CoreML, AVFoundation, PDFKit). Run in the simulator on CI.
final class AppIntegrationTests: XCTestCase {
    func testBundledSoundFontAndModelLoad() throws {
        let (sf, name) = try SoundFontLibrary.load(custom: nil)
        XCTAssertEqual(name, "GeneralUser GS")
        XCTAssertGreaterThan(sf.presets.count, 200)
        XCTAssertNoThrow(try BasicPitchRunner())
    }

    func testBasicPitchCoreMLTranscribesRenderedPiano() throws {
        let (sf, _) = try SoundFontLibrary.load(custom: nil)
        // a C major arpeggio, one note every 0.5 s
        let notes = (0..<12).map { MusicNote(pitch: [60, 64, 67, 72][$0 % 4], startBeat: Double($0), durationBeats: 0.9, velocity: 100) }
        let score = Score(title: "arp", tempo: TempoMap(bpm: 120), notes: notes)
        var o = MIDIRenderer.Options(); o.leadIn = 0.5
        let audio = MIDIRenderer.render(score: score, soundFont: sf, options: o)
        let events = try BasicPitchRunner().transcribe(audio)
        print("BasicPitch CoreML events: \(events.count)")
        var hits = 0
        for n in notes {
            let t = 0.5 + Double(n.startBeat) * 0.5
            if events.contains(where: { abs($0.startTime - t) < 0.06 && $0.pitch == n.pitch }) { hits += 1 }
        }
        print("BasicPitch matched \(hits)/\(notes.count)")
        XCTAssertGreaterThanOrEqual(hits, 10)
    }

    func testDemoPipelineEndToEndAndAppleDecoderAlignment() throws {
        let p = try Pipeline.createDemo(render: RenderSettings(), progress: { _, _ in })
        defer { ProjectStore.delete(p) }
        XCTAssertEqual(p.levels.count, 6)
        let text = try XCTUnwrap(ProjectStore.maidataText(p))
        let m = MaidataFile(text: text)
        for d in Difficulty.allCases { XCTAssertNoThrow(try SimaiParser.parse(XCTUnwrap(m.chartBody(d)))) }
        let a = try XCTUnwrap(p.alignment)
        print("Demo track alignment (Apple decoder): \(a)")
        XCTAssertEqual(a.lagSamples, 0)
        XCTAssertGreaterThan(a.correlation, 0.995)
        XCTAssertEqual(p.trackShift, 0, "the Apple-decoded MP3 must line up with the WAV without any offset")
        // independent check straight from disk: Apple's decoder vs the reference WAV
        let url = ProjectStore.file(p, "track.mp3")
        let file = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        let apple = AudioIO.audioBuffer(from: buf)
        let wav = try WAVFile.read(url: ProjectStore.file(p, "reference.wav"))
        let direct = AudioAlignment.compare(reference: wav, decoded: apple)
        print("Apple AVAudioFile track.mp3 vs reference.wav: \(direct)")
        XCTAssertEqual(direct.lagSamples, 0)
        XCTAssertGreaterThan(direct.correlation, 0.995)
        // a naive decoder (minimp3, no gapless info) keeps the standard 529-sample decoder delay
        let naive = try MP3Decoder.decode(Data(contentsOf: url)).buffer
        let cmp = AudioAlignment.compare(reference: apple, decoded: naive)
        print("minimp3 vs Apple on track.mp3: \(cmp)")
        XCTAssertLessThanOrEqual(abs(cmp.lagSamples - TrackProducer.mp3DecoderDelay), 1)
        // export contains no WAV
        let adx = try Pipeline.exportADX(p)
        let entries = try ZipArchive.read(Data(contentsOf: adx))
        print("ADX entries: \(entries.map { $0.path })")
        XCTAssertFalse(entries.contains { $0.path.lowercased().hasSuffix(".wav") })
        XCTAssertTrue(entries.contains { $0.path.hasSuffix("/maidata.txt") })
        XCTAssertTrue(entries.contains { $0.path.hasSuffix("/track.mp3") })
    }

    func testAppleSamplerRendererPlaysEveryChannel() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "NeonSkyline", withExtension: "mid", subdirectory: "Demo") ?? Bundle.main.url(forResource: "NeonSkyline", withExtension: "mid"))
        let score = try MIDIFile.parse(data: Data(contentsOf: url))
        let audio = try AppleSamplerRenderer.render(score: score, soundFontURL: XCTUnwrap(SoundFontLibrary.bundledURL), leadIn: 1)
        print("AUSampler render: \(audio.duration) s, rms \(audio.rms)")
        XCTAssertGreaterThan(audio.duration, score.durationSeconds)
        XCTAssertGreaterThan(audio.rms, 0.02)
    }

    func testAudioImportPathsM4AAndMP3() throws {
        // build an AAC (.m4a) from the demo render, then import it like a user would
        let demo = try Pipeline.createDemo(render: RenderSettings(), progress: { _, _ in })
        defer { ProjectStore.delete(demo) }
        let wav = try WAVFile.read(url: ProjectStore.file(demo, "reference.wav"))
        let m4a = FileManager.default.temporaryDirectory.appendingPathComponent("Neon Test.m4a")
        try? FileManager.default.removeItem(at: m4a)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
        do {
            let out = try AVAudioFile(forWriting: m4a, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try out.write(from: XCTUnwrap(AudioIO.pcmBuffer(from: wav)))
        }
        var p = try Pipeline.createProject(from: m4a, metadata: AudioIO.Metadata(title: "Neon M4A", artist: "test", artwork: nil),
                                           render: RenderSettings(), progress: { s, f in if f > 0.99 { print(s) } })
        defer { ProjectStore.delete(p) }
        print("M4A import: bpm \(p.bpm) first \(p.first) levels \(p.levels) melody \(p.melodySource ?? "") alignment \(p.alignment?.description ?? "-") shift \(p.trackShift)")
        XCTAssertEqual(p.bpm, 160, accuracy: 0.05)
        XCTAssertEqual(p.levels.count, 6)
        let m4aAlign = try XCTUnwrap(p.alignment)
        XCTAssertGreaterThan(m4aAlign.correlation, 0.99)
        XCTAssertEqual(p.trackShift, Double(m4aAlign.lagSamples) / 44100, accuracy: 1e-9)
        let m4aFirst = p.first
        // MP3 import keeps audio frames bit-exact
        let mp3In = ProjectStore.file(demo, "track.mp3")
        let tmpMP3 = FileManager.default.temporaryDirectory.appendingPathComponent("Neon Test.mp3")
        try? FileManager.default.removeItem(at: tmpMP3)
        try FileManager.default.copyItem(at: mp3In, to: tmpMP3)
        p = try Pipeline.createProject(from: tmpMP3, metadata: AudioIO.Metadata(title: "Neon MP3", artist: "test", artwork: nil),
                                       render: RenderSettings(), progress: { _, _ in })
        let original = try Data(contentsOf: tmpMP3), track = try Data(contentsOf: ProjectStore.file(p, "track.mp3"))
        XCTAssertEqual(MP3Tools.removingInfoFrame(original).data, track)
        print("MP3 import: bpm \(p.bpm) first \(p.first) levels \(p.levels)")
        XCTAssertEqual(p.bpm, 160, accuracy: 0.05)
        XCTAssertEqual(p.trackIsOriginal, true)
        // the same music through both import paths lands on the same beat grid (within 10 ms)
        XCTAssertEqual(p.first, m4aFirst, accuracy: 0.010)
        ProjectStore.delete(p)
    }

    func testPlayerAutoplayOnDemoChart() throws {
        let p = try Pipeline.createDemo(render: RenderSettings(), progress: { _, _ in })
        defer { ProjectStore.delete(p) }
        let m = MaidataFile(text: try XCTUnwrap(ProjectStore.maidataText(p)))
        let chart = PlayChart(try SimaiParser.parse(XCTUnwrap(m.chartBody(.remaster))))
        let e = JudgeEngine(chart: chart)
        var t = -1.0
        while t < chart.finishTime + 2 { _ = e.autoplay(t); t += 1.0 / 120 }
        XCTAssertTrue(e.allPerfect)
        XCTAssertGreaterThan(e.achievement, 100.99)
    }
}
