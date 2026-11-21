import XCTest
@testable import MaiCore

final class FoundationTests: XCTestCase {
    func testRealFFTMatchesNaiveDFT() {
        var rng = SeededRandom(seed: 1)
        for n in [8, 64, 1024] {
            let x = (0..<n).map { _ in Float(rng.unit() * 2 - 1) }
            let fft = RealFFT(size: n)
            let (re, im) = fft.forward(x)
            for k in stride(from: 0, through: n / 2, by: max(1, n / 16)) {
                var sr = 0.0, si = 0.0
                for t in 0..<n {
                    let a = -2 * Double.pi * Double(k * t) / Double(n)
                    sr += Double(x[t]) * cos(a)
                    si += Double(x[t]) * sin(a)
                }
                XCTAssertEqual(Double(re[k]), sr, accuracy: 1e-3 * Double(n), "n=\(n) k=\(k) re")
                XCTAssertEqual(Double(im[k]), si, accuracy: 1e-3 * Double(n), "n=\(n) k=\(k) im")
            }
        }
    }

    func testResamplePreservesSineFrequencyAndLength() {
        let sr = 44100.0
        let f = 1000.0
        let x = (0..<44100).map { Float(sin(2 * Double.pi * f * Double($0) / sr)) }
        let y = DSP.resample(x, from: sr, to: 22050)
        XCTAssertEqual(y.count, 22050)
        // compare with ideal sine at the new rate (skip edges)
        var err = 0.0, ref = 0.0
        for i in 200..<(y.count - 200) {
            let ideal = sin(2 * Double.pi * f * Double(i) / 22050)
            err += pow(Double(y[i]) - ideal, 2)
            ref += ideal * ideal
        }
        let snr = 10 * log10(ref / max(err, 1e-20))
        XCTAssertGreaterThan(snr, 60, "resampler SNR \(snr) dB")
    }

    func testWAVRoundTrip() throws {
        let buf = AudioSamples(sampleRate: 44100, channels: [[0, 0.5, -0.5, 0.25], [0.1, -0.1, 0.9, -1.0]])
        for fmt in [WAVFile.SampleFormat.int16, .int24, .float32] {
            let d = WAVFile.encode(buf, format: fmt, dither: false)
            let back = try WAVFile.read(data: d)
            XCTAssertEqual(back.channelCount, 2)
            XCTAssertEqual(back.frameCount, 4)
            for c in 0..<2 { for i in 0..<4 { XCTAssertEqual(back.channels[c][i], buf.channels[c][i], accuracy: 1e-4) } }
        }
    }

    func testTempoMapConversions() {
        let tm = TempoMap(changes: [(0, 120), (8, 60), (12, 240)], offset: 1.5)
        XCTAssertEqual(tm.time(atBeat: 0), 1.5, accuracy: 1e-9)
        XCTAssertEqual(tm.time(atBeat: 8), 1.5 + 4, accuracy: 1e-9)
        XCTAssertEqual(tm.time(atBeat: 12), 1.5 + 4 + 4, accuracy: 1e-9)
        XCTAssertEqual(tm.time(atBeat: 16), 1.5 + 4 + 4 + 1, accuracy: 1e-9)
        for b in stride(from: -2.0, through: 20, by: 0.37) {
            XCTAssertEqual(tm.beat(atTime: tm.time(atBeat: b)), b, accuracy: 1e-9)
        }
    }

    func testMIDIWriteParseRoundTrip() throws {
        let notes = [
            MusicNote(pitch: 60, startBeat: 0, durationBeats: 1, velocity: 100, channel: 0, program: 0),
            MusicNote(pitch: 64, startBeat: 1, durationBeats: 0.5, velocity: 90, channel: 0, program: 0),
            MusicNote(pitch: 67, startBeat: 1.5, durationBeats: 2.5, velocity: 80, channel: 1, program: 40),
            MusicNote(pitch: 36, startBeat: 0, durationBeats: 0.25, velocity: 120, channel: 9, isDrum: true),
            MusicNote(pitch: 38, startBeat: 1, durationBeats: 0.25, velocity: 110, channel: 9, isDrum: true),
        ]
        let score = Score(title: "Round Trip", tempo: TempoMap(changes: [(0, 150), (2, 100)]),
                          timeSignatures: [TimeSignature(beat: 0, numerator: 3, denominator: 4)], notes: notes)
        let data = MIDIFile.write(score)
        let back = try MIDIFile.parse(data: data)
        XCTAssertEqual(back.title, "Round Trip")
        XCTAssertEqual(back.notes.count, notes.count)
        XCTAssertEqual(back.tempo.segments.count, 2)
        XCTAssertEqual(back.tempo.segments[1].bpm, 100, accuracy: 0.01)
        XCTAssertEqual(back.timeSignatures.first?.numerator, 3)
        let drums = back.notes.filter { $0.isDrum }
        XCTAssertEqual(drums.count, 2)
        let strings = back.notes.first { $0.pitch == 67 }!
        XCTAssertEqual(strings.program, 40)
        XCTAssertEqual(strings.durationBeats, 2.5, accuracy: 1e-6)
    }

    func testSimaiWriterProducesParsableChartWithExactTiming() throws {
        let tempo = TempoMap(changes: [(0, 150), (8, 200)], offset: 0.25)
        let timing = ChartTiming(tempo: tempo, endBeat: 16)
        let b = ticksPerBeat
        let notes: [ChartNote] = [
            ChartNote(tick: 0, kind: .tap(button: 1)),
            ChartNote(tick: b / 2, kind: .tap(button: 2)),
            ChartNote(tick: b, kind: .tap(button: 3)), ChartNote(tick: b, kind: .tap(button: 6)),
            ChartNote(tick: b + b / 3, kind: .touch(area: .b(4))),
            ChartNote(tick: 2 * b, kind: .hold(button: 8, length: b * 3 / 2)),
            ChartNote(tick: 2 * b, kind: .touch(area: .e(3)), firework: true),
            ChartNote(tick: 4 * b, kind: .slide(button: 1, segments: [SlideSegment(shape: "-", vertices: [5])], duration: b), isBreak: true),
            ChartNote(tick: 6 * b, kind: .touchHold(area: .c, length: 4 * b)), // spans tempo change at beat 8
            ChartNote(tick: 9 * b + b / 4, kind: .tap(button: 4), isBreak: true),
        ]
        let text = SimaiWriter.write(notes, timing: timing)
        XCTAssertTrue(text.hasSuffix("E\n"))
        let parsed = try SimaiParser.parse(text)
        XCTAssertEqual(parsed.notes.count, notes.count)
        // check every note time against the tempo map (chart time 0 = beat 0)
        for n in notes {
            let expected = tempo.time(atBeat: Double(n.tick) / Double(b)) - tempo.offset
            XCTAssertTrue(parsed.notes.contains { abs($0.time - expected) < 1e-6 }, "missing note at \(expected)s\n\(text)")
        }
        let hold = parsed.notes.first { $0.location == .button(8) }!
        XCTAssertEqual(hold.holdLength!, 1.5 * 60 / 150, accuracy: 1e-6)
        let th = parsed.notes.first { $0.location == .sensor(.c) }!
        let thExpected = tempo.time(atBeat: 10) - tempo.time(atBeat: 6)
        XCTAssertEqual(th.holdLength!, thExpected, accuracy: 1e-3)
        let slide = parsed.notes.first { !$0.slides.isEmpty }!
        XCTAssertTrue(slide.isBreak)
        XCTAssertEqual(slide.slides[0].delay, 60 / 150, accuracy: 1e-6)
        XCTAssertEqual(slide.slides[0].duration, 60 / 150, accuracy: 1e-6)
        XCTAssertEqual(slide.slides[0].segments, [SlideSegment(shape: "-", vertices: [5])])
        let each = parsed.notes.filter { abs($0.time - 60.0 / 150) < 1e-6 }
        XCTAssertEqual(each.count, 2)
        XCTAssertEqual(each.first?.eachCount, 2)
        let fw = parsed.notes.first { $0.location == .sensor(.e(3)) }!
        XCTAssertTrue(fw.firework)
    }

    func testParserMatchesSimaiSharpSamples() throws {
        // Taken from SimaiSharp's own test resources.
        let a = try SimaiParser.parse("12345678")
        XCTAssertEqual(a.notes.count, 8)
        XCTAssertTrue(a.notes.allSatisfy { $0.time == 0 && $0.eachCount == 8 })
        let b = try SimaiParser.parse("(60)1,(120)1,(60)1")
        XCTAssertEqual(b.notes.map { $0.time }, [0, 1, 1.5])
        let c = try SimaiParser.parse("""
        (170){16}7/2-6[8:1],,1-5[8:1],8,2,,1,,
                      {8}2,18,7,16,2/7h[4:1],1,
        E
        """)
        XCTAssertGreaterThan(c.notes.count, 10)
        XCTAssertThrowsError(try SimaiParser.parse("1,2,K"))
        XCTAssertThrowsError(try SimaiParser.parse("1-[4:1]"))
        let d = try SimaiParser.parse("(120){4}1-3-5[4:1]*>8[8:1],C1h[#2.5],B3f,1V35[4:1],2pp6[4:1],3qq7[4:1],4w8[4:1],E")
        let star = d.notes[0]
        XCTAssertEqual(star.slides.count, 2)
        XCTAssertEqual(star.slides[0].segments.count, 2)
        XCTAssertEqual(d.notes[1].holdLength!, 2.5, accuracy: 1e-9)
        XCTAssertEqual(d.notes.first { $0.slides.first?.segments.first?.shape == "V" }?.slides[0].segments[0].vertices, [3, 5])
    }

    func testMaidataKeyValues() {
        let text = "\u{FEFF}&title=Test\n&first=0.5\n&inote_5=(120){4}1,\n2,\nE\n&lv_5=12+\n"
        let m = MaidataFile(text: text)
        XCTAssertEqual(m.title, "Test")
        XCTAssertEqual(m.first, 0.5)
        XCTAssertEqual(m.level(.master), "12+")
        XCTAssertEqual(m.chartBody(.master), "(120){4}1,\n2,\nE")
    }
}
