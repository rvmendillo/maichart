import Foundation
import MaiCore

// Developer CLI used to exercise MaiCore on Linux/macOS.
// Commands:
//   maicli chart <song.mid|.musicxml|.mxl> [seed] [outdir]
//   maicli simai-check <maidata.txt>

func fail(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

var args = CommandLine.arguments.dropFirst()
guard let cmd = args.popFirst() else { fail("usage: maicli <command> ...") }

func loadScore(_ path: String) throws -> Score {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return try MIDIFile.parse(data: data, title: url.deletingPathExtension().lastPathComponent)
}

func printChartSet(_ set: GeneratedChartSet) {
    for c in set.charts {
        let st = set.stats[c.difficulty]!
        let rep = set.reports[c.difficulty]!
        let line = String(format: "%-10@ lv %-4@ (%.1f) notes %4d  avgNPS %.2f peak %.1f each %.2f touch %.2f hold %.2f slides %d breaks %d | %@",
                          c.difficulty.displayName as NSString, c.level as NSString, c.levelValue, st.objects, st.avgNPS, st.peakNPS,
                          st.eachRatio, st.touchRatio, st.holdRatio, st.slideCount, st.breakCount, rep.description as NSString)
        print(line)
    }
}

switch cmd {
case "chart":
    guard let path = args.popFirst() else { fail("usage: maicli chart <file> [seed] [outdir]") }
    let seed = UInt64(args.popFirst() ?? "1") ?? 1
    let outDir = args.popFirst()
    do {
        let score = try loadScore(path)
        let feats = FeatureExtractor.features(from: score)
        print("title=\(feats.title) bpm=\(feats.tempo.initialBPM) melody=\(feats.melody.count) harmony=\(feats.harmony.count) drums=\(feats.drums.count) endBeat=\(feats.endBeat)")
        var opts = GeneratorOptions()
        opts.seed = seed
        let set = ChartGenerator.generate(feats, options: opts)
        printChartSet(set)
        if let o = outDir {
            try FileManager.default.createDirectory(atPath: o, withIntermediateDirectories: true)
            try set.maidata.data().write(to: URL(fileURLWithPath: o).appendingPathComponent("maidata.txt"))
            print("wrote \(o)/maidata.txt")
        }
    } catch { fail("error: \(error)") }
case "render":
    // maicli render <song.mid> <soundfont.sf2> <out.wav> [leadIn]
    guard let path = args.popFirst(), let sfPath = args.popFirst(), let out = args.popFirst() else { fail("usage: maicli render <mid> <sf2> <out.wav> [leadIn]") }
    let lead = Double(args.popFirst() ?? "0") ?? 0
    do {
        let score = try loadScore(path)
        let t0 = Date()
        let sf = try SoundFont(url: URL(fileURLWithPath: sfPath))
        let t1 = Date()
        var o = MIDIRenderer.Options()
        o.leadIn = lead
        let buf = MIDIRenderer.render(score: score, soundFont: sf, options: o)
        let t2 = Date()
        try WAVFile.write(buf, to: URL(fileURLWithPath: out), format: .int16)
        print(String(format: "loaded sf2 in %.2fs (%d presets), rendered %.1fs of audio in %.2fs, peak %.3f rms %.4f", t1.timeIntervalSince(t0), sf.presets.count, buf.duration, t2.timeIntervalSince(t1), buf.peak, buf.rms))
    } catch { fail("error: \(error)") }
case "mp3":
    // maicli mp3 <in.wav> <out.mp3>
    guard let inp = args.popFirst(), let out = args.popFirst() else { fail("usage: maicli mp3 <in.wav> <out.mp3>") }
    do {
        let buf = try WAVFile.read(url: URL(fileURLWithPath: inp))
        let t0 = Date()
        let r = try TrackProducer.makeMP3(from: buf)
        try r.mp3.write(to: URL(fileURLWithPath: out))
        print(String(format: "encoded in %.2fs, %d bytes, precompensated=%@, shift=%.4fs", Date().timeIntervalSince(t0), r.mp3.count, r.precompensated ? "yes" : "no", r.timelineShift))
        print("verify: \(r.report)")
        let g = try MP3Decoder.decode(r.mp3, gapless: true)
        print("gapless decode frames \(g.buffer.frameCount) vs naive \(try MP3Decoder.decode(r.mp3).buffer.frameCount), tag=\(g.hasInfoTag)")
    } catch { fail("error: \(error)") }
case "analyze":
    // maicli analyze <audio.wav|mp3> [outdir]
    guard let path = args.popFirst() else { fail("usage: maicli analyze <audio> [outdir]") }
    let outDir = args.popFirst()
    do {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let buf: AudioBuffer
        if path.lowercased().hasSuffix(".mp3") { buf = try MP3Decoder.decode(MP3Tools.removingInfoFrame(data).data).buffer } else { buf = try WAVFile.read(data: data) }
        let t0 = Date()
        var transcription: [BasicPitch.NoteEvent]? = nil
        if let bpPath = ProcessInfo.processInfo.environment["MAICHART_BP_NOTES"] {
            // JSON [[startFrame, endFrame, pitch, amplitude], ...] produced by the reference Basic Pitch
            let arr = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: bpPath))) as! [[Any]]
            transcription = arr.map { BasicPitch.NoteEvent(startFrame: $0[0] as! Int, endFrame: $0[1] as! Int, pitch: $0[2] as! Int, amplitude: ($0[3] as! NSNumber).doubleValue) }
        }
        let a = AudioAnalyzer.analyze(buf, transcription: transcription)
        print(String(format: "analysed %.1fs audio in %.2fs", buf.duration, Date().timeIntervalSince(t0)))
        print(String(format: "BPM %.3f firstDownbeat %.4fs meter %d/4 confidence %.2f residual %.1fms segments %d", a.grid.bpm, a.grid.firstDownbeat, a.grid.beatsPerBar, a.grid.confidence, a.grid.residualMs, a.grid.tempo.segments.count))
        for s in a.grid.tempo.segments.prefix(8) { print(String(format: "  segment beat %.1f bpm %.3f t=%.3f", s.startBeat, s.bpm, s.startTime)) }
        var kinds: [DrumHit.Kind: Int] = [:]
        for d in a.drums { kinds[d.kind, default: 0] += 1 }
        print("drums \(a.drums.count) \(kinds.map { "\($0.key)=\($0.value)" }.sorted()) melody \(a.melody.count) (\(a.melodySource)) sections \(a.sectionStarts)")
        if ProcessInfo.processInfo.environment["MAICHART_EVENTS"] != nil {
            for m in a.melody { print(String(format: "EV melody %.3f %d %.2f", a.grid.tempo.time(atBeat: m.beat), m.pitch, m.strength)) }
            for d in a.drums { print(String(format: "EV drum %.3f %@ %.2f", a.grid.tempo.time(atBeat: d.beat), "\(d.kind)" as NSString, d.strength)) }
            for h in a.harmony { print(String(format: "EV harm %.3f %d", a.grid.tempo.time(atBeat: h.beat), h.pitch)) }
        }
        if let o = outDir {
            let feats = AudioAnalyzer.features(a, title: url.deletingPathExtension().lastPathComponent, artist: "")
            let set = ChartGenerator.generate(feats)
            printChartSet(set)
            try FileManager.default.createDirectory(atPath: o, withIntermediateDirectories: true)
            try set.maidata.data().write(to: URL(fileURLWithPath: o).appendingPathComponent("maidata.txt"))
        }
    } catch { fail("error: \(error)") }
case "onsets":
    guard let path = args.popFirst() else { fail("usage: maicli onsets <wav>") }
    do {
        let buf = try WAVFile.read(url: URL(fileURLWithPath: path))
        let x = DSP.resample(buf.mono(), from: buf.sampleRate, to: AudioAnalyzer.analysisRate)
        for o in AudioAnalyzer.fineOnsets(x) { print(String(format: "%.5f %.3f", o.time, o.strength)) }
    } catch { fail("error: \(error)") }
case "drums":
    guard let path = args.popFirst() else { fail("usage: maicli drums <wav>") }
    do {
        let buf = try WAVFile.read(url: URL(fileURLWithPath: path))
        let a = AudioAnalyzer.analyze(buf)
        for d in a.drums { print(String(format: "%.4f %@ %.3f", a.grid.tempo.time(atBeat: d.beat), "\(d.kind)" as NSString, d.strength)) }
    } catch { fail("error: \(error)") }
case "drum-templates":
    // maicli drum-templates <sf2>: prints 96-band mel templates for GM kick/snare/hat/crash
    guard let sfPath = args.popFirst() else { fail("usage") }
    do {
        let sf = try SoundFont(url: URL(fileURLWithPath: sfPath))
        let fb = DSP.melFilterbank(sampleRate: 22050, nFFT: 2048, nMels: 96, fMin: 30, fMax: 11000)
        for (name, keys) in [("kick", [36, 35]), ("snare", [38, 40, 39]), ("hat", [42, 44, 46]), ("crash", [49, 57])] {
            var acc = [Double](repeating: 0, count: 96)
            for key in keys {
                for vel in [80, 110] {
                    let synth = Synthesizer(soundFont: sf, sampleRate: 22050)
                    synth.reverbEnabled = false; synth.chorusEnabled = false
                    synth.noteOn(channel: 9, key: key, velocity: vel)
                    let (l, r) = synth.render(frames: 22050 / 4)
                    let x = zip(l, r).map { ($0 + $1) / 2 }
                    let spec = DSP.stft(x, sampleRate: 22050, nFFT: 2048, hop: 256, power: true)
                    let mel = DSP.applyFilterbank(spec, fb)
                    for t in 2..<min(mel.count, 9) { for b in 0..<96 { acc[b] += Double(mel[t][b]).squareRoot() } }
                }
            }
            let sum = acc.reduce(0, +)
            print("    static let \(name): [Float] = [" + acc.map { String(format: "%.5f", $0 / sum) }.joined(separator: ", ") + "]")
        }
    } catch { fail("error: \(error)") }
case "simai-times":
    // maicli simai-times <maidata.txt> <difficulty 1-6>: absolute audio times of every note
    guard let path = args.popFirst(), let dn = Int(args.popFirst() ?? "6"), let d = Difficulty(rawValue: dn) else { fail("usage") }
    do {
        let m = MaidataFile(text: try String(contentsOfFile: path, encoding: .utf8))
        guard let body = m.chartBody(d) else { fail("no chart") }
        let c = try SimaiParser.parse(body)
        for n in c.notes { print(String(format: "%.5f", n.time + m.first)) }
    } catch { fail("error: \(error)") }
case "omr":
    // maicli omr <page.pgm>... : prints recognised notes "beat pitch duration"
    var pages: [GrayImage] = []
    while let path = args.popFirst() {
        guard let d = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
        let b = [UInt8](d)
        // binary PGM (P5)
        var fields: [String] = []
        var i = 0
        while fields.count < 4 && i < b.count {
            while i < b.count && (b[i] == 32 || b[i] == 10 || b[i] == 13 || b[i] == 9) { i += 1 }
            if b[i] == 35 { while i < b.count && b[i] != 10 { i += 1 }; continue }
            var tok = ""
            while i < b.count && !(b[i] == 32 || b[i] == 10 || b[i] == 13 || b[i] == 9) { tok.append(Character(UnicodeScalar(b[i]))); i += 1 }
            fields.append(tok)
        }
        i += 1
        guard fields.first == "P5", let w = Int(fields[1]), let h = Int(fields[2]) else { fail("not a P5 pgm") }
        pages.append(GrayImage(width: w, height: h, pixels: Array(b[i..<(i + w * h)])))
    }
    let t0 = Date()
    let r = OMR.recognize(pages: pages, title: "omr")
    FileHandle.standardError.write(String(format: "OMR: %d staves, %d systems, %d notes in %.2fs %@\n", r.staves, r.systems, r.notes, Date().timeIntervalSince(t0), r.warnings.joined(separator: "; ")).data(using: .utf8)!)
    for n in r.score.notes.sorted(by: { ($0.startBeat, $0.pitch) < ($1.startBeat, $1.pitch) }) { print(String(format: "%.3f %d %.3f", n.startBeat, n.pitch, n.durationBeats)) }
case "simai-check":
    guard let path = args.popFirst() else { fail("usage: maicli simai-check <maidata.txt>") }
    do {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let m = MaidataFile(text: text)
        for d in Difficulty.allCases {
            guard let body = m.chartBody(d) else { continue }
            let c = try SimaiParser.parse(body)
            print("\(d.displayName): \(c.notes.count) notes, objects \(c.objectCount), finish \(String(format: "%.2f", c.finishTime))s")
        }
    } catch { fail("error: \(error)") }
default:
    fail("unknown command \(cmd)")
}
