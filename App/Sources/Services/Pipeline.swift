import Foundation
import AVFoundation
import UIKit
import MaiCore

struct RenderSettings {
    var renderer: String = "MaiSynth"          // "MaiSynth" or "Apple AUSampler"
    var customSoundFont: String? = nil
    var instrumentProgram: Int? = nil
}

/// Heavy lifting for creating / updating projects. All functions are synchronous and meant to run off the main thread.
enum Pipeline {
    typealias Progress = (String, Double) -> Void

    static func kind(of url: URL) -> SongProject.Source? {
        let ext = url.pathExtension.lowercased()
        if AudioIO.audioExtensions.contains(ext) { return .audio }
        if ["mid", "midi", "kar", "rmi"].contains(ext) { return .midi }
        if ["musicxml", "xml", "mxl"].contains(ext) { return .musicXML }
        if ext == "pdf" { return .pdf }
        return nil
    }

    // MARK: Create

    static func createProject(from url: URL, metadata: AudioIO.Metadata, render: RenderSettings, progress: @escaping Progress) throws -> SongProject {
        guard let kind = kind(of: url) else {
            throw AppError.message("Unsupported file type .\(url.pathExtension). Use MP3/M4A/WAV, MIDI, MusicXML (.musicxml/.xml/.mxl) or a PDF score.")
        }
        let baseTitle = url.deletingPathExtension().lastPathComponent
        var p = SongProject(title: metadata.title?.isEmpty == false ? metadata.title! : baseTitle,
                            artist: metadata.artist ?? "", source: kind, sourceFile: "source." + url.pathExtension.lowercased())
        p.options.seed = UInt64.random(in: 1...UInt64(Int32.max))
        p.renderer = render.renderer
        p.instrumentProgram = render.instrumentProgram
        let dir = ProjectStore.dir(p.id)
        let src = dir.appendingPathComponent(p.sourceFile)
        try? FileManager.default.removeItem(at: src)
        try FileManager.default.copyItem(at: url, to: src)
        do {
            switch kind {
            case .audio:
                try processAudio(&p, progress: progress)
            case .midi, .musicXML, .pdf:
                let score = try loadScore(p, progress: progress)
                if p.title == baseTitle, !score.title.trimmingCharacters(in: .whitespaces).isEmpty { p.title = score.title }
                if p.artist.isEmpty { p.artist = score.composer }
                try processScore(&p, score: score, render: render, progress: progress)
            }
            progress("Cover art", 0.97)
            if let art = metadata.artwork, let jpg = CoverArt.normalize(art) {
                try jpg.write(to: dir.appendingPathComponent("bg.jpg"))
            } else if let jpg = CoverArt.generate(title: p.title, artist: p.artist, seed: p.options.seed) {
                try jpg.write(to: dir.appendingPathComponent("bg.jpg"))
            }
            p.coverFile = "bg.jpg"
            ProjectStore.save(p)
            progress("Done", 1)
            return p
        } catch {
            ProjectStore.delete(p)
            throw error
        }
    }

    static func loadScore(_ p: SongProject, progress: @escaping Progress) throws -> Score {
        let url = ProjectStore.file(p, p.sourceFile)
        let data = try Data(contentsOf: url)
        switch p.source {
        case .midi:
            progress("Reading MIDI", 0.05)
            return try MIDIFile.parse(data: data, title: p.title)
        case .musicXML:
            progress("Reading MusicXML", 0.05)
            return try MusicXML.parse(data: data, title: p.title)
        case .pdf:
            progress("Optical music recognition", 0.05)
            return try PDFScoreReader.read(url: url) { progress("Recognising page \($0)", 0.05 + 0.15 * $1) }
        case .audio:
            throw AppError.message("Not a score")
        }
    }

    // MARK: Audio sources

    static func processAudio(_ p: inout SongProject, progress: @escaping Progress) throws {
        let dir = ProjectStore.dir(p.id)
        let srcURL = dir.appendingPathComponent(p.sourceFile)
        let trackURL = dir.appendingPathComponent("track.mp3")
        progress("Decoding audio", 0.04)
        let audio: AudioSamples
        if p.sourceFile.hasSuffix(".mp3") {
            // keep the original audio frames bit-exact; only the Xing/Info header frame is removed so every
            // player starts on the same sample. Analysis uses exactly this file through Apple's decoder.
            let original = try Data(contentsOf: srcURL)
            try MP3Tools.removingInfoFrame(original).data.write(to: trackURL)
            audio = try AudioIO.decode(url: trackURL)
            p.trackIsOriginal = true
            p.alignment = nil
            p.trackShift = 0
        } else {
            audio = try AudioIO.decode(url: srcURL)
        }
        guard audio.duration > 5 else { throw AppError.message("The audio is too short (\(String(format: "%.1f", audio.duration)) s).") }
        p.durationSeconds = audio.duration
        progress("Transcribing melody (Basic Pitch)", 0.08)
        var transcription: [BasicPitch.NoteEvent]? = nil
        do {
            let runner = try BasicPitchRunner()
            transcription = try runner.transcribe(audio) { progress("Transcribing melody (Basic Pitch)", 0.08 + 0.42 * $0) }
        } catch {
            transcription = nil // DSP fallback inside the analyser
        }
        let analysis = AudioAnalyzer.analyze(audio, transcription: transcription) { f, msg in progress(msg, 0.5 + 0.25 * f) }
        p.bpm = analysis.grid.bpm
        p.gridConfidence = analysis.grid.confidence
        p.melodySource = analysis.melodySource
        p.notesSummary = "\(analysis.melody.count) melody notes · \(analysis.drums.count) drum hits · \(analysis.grid.tempo.segments.count) tempo segment(s)"
        let features = AudioAnalyzer.features(analysis, title: p.title, artist: p.artist)
        ProjectStore.saveFeatures(features, for: p)
        if !p.sourceFile.hasSuffix(".mp3") {
            progress("Encoding 320 kbps MP3", 0.78)
            try encodeTrack(&p, from: audio, to: trackURL) { progress("Encoding 320 kbps MP3 & verifying waveform", 0.78 + 0.12 * $0) }
        }
        try generate(&p, features: features, progress: progress)
    }

    /// Encodes track.mp3 and verifies it with Apple's decoder (what AstroDX on iOS uses). Any remaining
    /// offset between the WAV/source and the decoded MP3 is written into &first via trackShift.
    static func encodeTrack(_ p: inout SongProject, from audio: AudioSamples, to url: URL, progress: @escaping (Double) -> Void) throws {
        let r = try TrackProducer.makeMP3(from: audio, targetDecoderDelay: 0, progress: progress)
        try r.mp3.write(to: url, options: .atomic)
        let decoded = try AudioIO.decode(url: url)
        let report = AudioAlignment.compare(reference: audio, decoded: decoded, referenceGain: r.gain)
        p.alignment = report
        p.trackShift = Double(report.lagSamples) / audio.sampleRate
        p.trackIsOriginal = false
    }

    // MARK: Score sources

    static func leadIn(for score: Score) -> Double {
        let bar = (score.timeSignatures.first?.beatsPerBar ?? 4) * score.tempo.secondsPerBeat(atBeat: 0)
        var n = 1.0
        while n * bar < 1.6 { n += 1 }
        return n * bar
    }

    static func processScore(_ p: inout SongProject, score: Score, render: RenderSettings, progress: @escaping Progress) throws {
        let dir = ProjectStore.dir(p.id)
        guard !score.notes.isEmpty else { throw AppError.message("No playable notes were found in this score.") }
        try MIDIFile.write(score).write(to: dir.appendingPathComponent("score.mid"))
        let lead = leadIn(for: score)
        progress("Rendering with \(render.renderer)", 0.22)
        let audio = try renderScore(score, leadIn: lead, render: render) { progress("Rendering with \(render.renderer)", 0.22 + 0.4 * $0) }
        p.durationSeconds = audio.duration
        // internal reference render (never exported)
        try WAVFile.write(audio, to: dir.appendingPathComponent("reference.wav"), format: .int16)
        progress("Encoding 320 kbps MP3 & verifying waveform", 0.66)
        try encodeTrack(&p, from: audio, to: dir.appendingPathComponent("track.mp3")) { progress("Encoding 320 kbps MP3 & verifying waveform", 0.66 + 0.2 * $0) }
        var features = FeatureExtractor.features(from: score, source: p.source == .musicXML ? .musicXML : (p.source == .pdf ? .omr : .midi), artist: p.artist)
        features.tempo = score.tempo.withOffset(lead)
        p.bpm = score.tempo.initialBPM
        p.gridConfidence = 1
        p.melodySource = "score"
        p.notesSummary = "\(score.notes.count) notes · \(score.tracks.count) track(s) · \(features.drums.count) drum hits"
        ProjectStore.saveFeatures(features, for: p)
        try generate(&p, features: features, progress: progress)
    }

    static func renderScore(_ score: Score, leadIn: Double, render: RenderSettings, progress: @escaping (Double) -> Void) throws -> AudioSamples {
        if render.renderer == "Apple AUSampler" {
            var sfURL = SoundFontLibrary.bundledURL!
            if let c = render.customSoundFont { sfURL = ProjectStore.soundFontsDir.appendingPathComponent(c) }
            return try AppleSamplerRenderer.render(score: score, soundFontURL: sfURL, leadIn: leadIn, instrumentOverride: render.instrumentProgram, progress: progress)
        }
        let (sf, _) = try SoundFontLibrary.load(custom: render.customSoundFont)
        var o = MIDIRenderer.Options()
        o.leadIn = leadIn
        o.instrumentOverride = render.instrumentProgram
        return MIDIRenderer.render(score: score, soundFont: sf, options: o, progress: progress)
    }

    // MARK: Charts

    static func generate(_ p: inout SongProject, features: SongFeatures, progress: @escaping Progress) throws {
        progress("Designing charts", 0.92)
        let set = ChartGenerator.generate(features, options: p.options, title: p.title, artist: p.artist)
        var md = set.maidata
        p.baseFirst = set.timing.first + p.trackShift
        md.timing.tempo = set.timing.tempo.withOffset(p.first)
        try md.data().write(to: ProjectStore.file(p, "maidata.txt"), options: .atomic)
        p.levels = set.charts.map { $0.level }
        p.levelValues = set.charts.map { $0.levelValue }
        p.noteCounts = set.charts.map { $0.noteCount }
    }

    /// Regenerates charts from cached analysis (remix, option changes, offset changes).
    static func regenerate(_ p: inout SongProject) throws {
        guard let f = ProjectStore.loadFeatures(p) else { throw AppError.message("Analysis data missing — please re-import the song.") }
        try generate(&p, features: f, progress: { _, _ in })
        ProjectStore.save(p)
    }

    /// Re-renders a score-based project with another renderer / instrument / soundfont.
    static func rerender(_ p: inout SongProject, render: RenderSettings, progress: @escaping Progress) throws {
        guard p.source != .audio else { return }
        let url = ProjectStore.file(p, "score.mid")
        let score = try MIDIFile.parse(data: Data(contentsOf: url), title: p.title)
        p.renderer = render.renderer
        p.instrumentProgram = render.instrumentProgram
        try processScore(&p, score: score, render: render, progress: progress)
        ProjectStore.save(p)
    }

    // MARK: Export

    static func level(_ p: SongProject) throws -> LevelPackager.Level {
        let md = try Data(contentsOf: ProjectStore.file(p, "maidata.txt"))
        let track = try Data(contentsOf: ProjectStore.file(p, "track.mp3"))
        let bg = try? Data(contentsOf: ProjectStore.file(p, p.coverFile ?? "bg.jpg"))
        return LevelPackager.Level(title: p.title, maidata: md, track: track, background: bg)
    }

    /// Writes "<Title>.adx" (zip with the level folder) into Documents/AstroDX Export and returns it.
    static func exportADX(_ p: SongProject) throws -> URL {
        let lv = try level(p)
        let url = ProjectStore.exportRoot.appendingPathComponent(LevelPackager.folderName(p.title) + ".adx")
        try LevelPackager.adx([lv]).write(to: url, options: .atomic)
        return url
    }

    /// Writes a plain folder (maidata.txt, track.mp3, bg.jpg) for manual copying.
    static func exportFolder(_ p: SongProject) throws -> URL {
        try LevelPackager.writeFolder(try level(p), into: ProjectStore.exportRoot)
    }

    /// Creates the bundled demo project (used on first launch and for screenshots).
    static func createDemo(render: RenderSettings, progress: @escaping Progress) throws -> SongProject {
        guard let url = Bundle.main.url(forResource: "NeonSkyline", withExtension: "mid", subdirectory: "Demo") ?? Bundle.main.url(forResource: "NeonSkyline", withExtension: "mid") else {
            throw AppError.message("Demo song missing")
        }
        var p = try createProject(from: url, metadata: AudioIO.Metadata(title: "Neon Skyline", artist: "MaiChart Studio Demo", artwork: nil), render: render, progress: progress)
        p.title = "Neon Skyline"
        p.artist = "MaiChart Studio Demo"
        try regenerate(&p)
        return p
    }
}

/// Downloads a direct file link (mp3/m4a/wav/mid/musicxml/pdf...) into a temporary file.
enum LinkImporter {
    static func download(_ text: String) async throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw AppError.message("Please paste a valid http(s) link.")
        }
        if let host = url.host?.lowercased(), host.contains("youtube.com") || host.contains("youtu.be") {
            throw AppError.message("YouTube links can't be downloaded directly (YouTube's terms don't allow it). Import an audio file you own instead — e.g. save it to Files and pick it here, or share it to MaiChart Studio.")
        }
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.message("The server answered with an error.")
        }
        var ext = url.pathExtension.lowercased()
        if Pipeline.kind(of: URL(fileURLWithPath: "x." + ext)) == nil {
            let mime = http.mimeType ?? ""
            let map = ["audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/aac": "m4a", "audio/wav": "wav",
                       "audio/x-wav": "wav", "audio/midi": "mid", "audio/x-midi": "mid", "application/pdf": "pdf",
                       "application/vnd.recordare.musicxml+xml": "musicxml", "application/vnd.recordare.musicxml": "mxl"]
            ext = map[mime] ?? ""
        }
        guard !ext.isEmpty else { throw AppError.message("That link is not a supported audio, MIDI, MusicXML or PDF file.") }
        let name = url.deletingPathExtension().lastPathComponent.isEmpty ? "Downloaded" : url.deletingPathExtension().lastPathComponent
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name + "." + ext)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
