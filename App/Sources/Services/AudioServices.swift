import Foundation
import AVFoundation
import CoreML
import UIKit
import MaiCore

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m } else { return nil } }
}

enum AudioIO {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "mp4", "alac", "ogg", "opus"]

    /// Decodes an audio file with Apple's decoders. MP3s are decoded after removing the Xing/Info frame,
    /// i.e. exactly the bytes exported as track.mp3, so the timeline is the one AstroDX on iOS plays.
    static func decode(url: URL) throws -> AudioSamples {
        var url = url
        var tmp: URL? = nil
        if url.pathExtension.lowercased() == "mp3" {
            // decode exactly what AstroDX will play: the Info-frame-free file, through Apple's decoder
            let data = try Data(contentsOf: url)
            let stripped = MP3Tools.removingInfoFrame(data)
            if stripped.removed {
                let t = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
                try stripped.data.write(to: t)
                tmp = t
                url = t
            }
        }
        defer { if let t = tmp { try? FileManager.default.removeItem(at: t) } }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw AppError.message("This audio format can't be decoded on this device (\(url.pathExtension)). Please use MP3, M4A/AAC, WAV, AIFF or FLAC.")
        }
        let format = file.processingFormat
        let total = AVAudioFrameCount(file.length)
        guard total > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else {
            throw AppError.message("The audio file is empty.")
        }
        try file.read(into: buf)
        return audioBuffer(from: buf)
    }

    static func audioBuffer(from buf: AVAudioPCMBuffer) -> AudioSamples {
        let n = Int(buf.frameLength)
        let chans = Int(buf.format.channelCount)
        var out = AudioSamples(sampleRate: buf.format.sampleRate, channelCount: max(1, min(2, chans)), frames: n)
        if let data = buf.floatChannelData {
            for c in 0..<out.channelCount {
                out.channels[c].withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: data[c], count: n)
                }
            }
        }
        return out
    }

    static func pcmBuffer(from a: AudioSamples) -> AVAudioPCMBuffer? {
        let st = a.stereo()
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: st.sampleRate, channels: 2),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(st.frameCount)) else { return nil }
        buf.frameLength = AVAudioFrameCount(st.frameCount)
        for c in 0..<2 {
            st.channels[c].withUnsafeBufferPointer { src in buf.floatChannelData![c].update(from: src.baseAddress!, count: st.frameCount) }
        }
        return buf
    }

    struct Metadata { var title: String?; var artist: String?; var artwork: Data? }

    static func metadata(url: URL) async -> Metadata {
        var m = Metadata()
        if url.pathExtension.lowercased() == "mp3", let d = try? Data(contentsOf: url) {
            let id3 = MP3Tools.readID3(d)
            m.title = id3.title; m.artist = id3.artist; m.artwork = id3.artwork
        }
        let asset = AVURLAsset(url: url)
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle: if m.title == nil, let v = try? await item.load(.stringValue) { m.title = v }
                case .commonKeyArtist: if m.artist == nil, let v = try? await item.load(.stringValue) { m.artist = v }
                case .commonKeyArtwork: if m.artwork == nil, let v = try? await item.load(.dataValue) { m.artwork = v }
                default: break
                }
            }
        }
        return m
    }
}

/// Runs Spotify's Basic Pitch (CoreML) and converts the output to note events.
final class BasicPitchRunner {
    let model: MLModel

    init() throws {
        guard let url = Bundle.main.url(forResource: "NMPModel", withExtension: "mlmodelc") else {
            throw AppError.message("The Basic Pitch model is missing from the app bundle.")
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: cfg)
    }

    static func floats(_ a: MLMultiArray) -> [Float] {
        let shaped = MLShapedArray<Float>(converting: a)
        return shaped.scalars
    }

    func transcribe(_ audio: AudioSamples, progress: ((Double) -> Void)? = nil) throws -> [BasicPitch.NoteEvent] {
        let mono = DSP.resample(audio.mono(), from: audio.sampleRate, to: BasicPitch.sampleRate)
        let windows = BasicPitch.windows(mono)
        var notes: [[Float]] = [], onsets: [[Float]] = []
        for (i, w) in windows.enumerated() {
            let arr = try MLMultiArray(shape: [1, NSNumber(value: BasicPitch.windowSamples), 1], dataType: .float32)
            let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: w.count)
            w.withUnsafeBufferPointer { ptr.update(from: $0.baseAddress!, count: w.count) }
            let input = try MLDictionaryFeatureProvider(dictionary: ["input_2": MLFeatureValue(multiArray: arr)])
            let out = try model.prediction(from: input)
            guard let n = out.featureValue(for: "Identity_1")?.multiArrayValue,
                  let o = out.featureValue(for: "Identity_2")?.multiArrayValue else {
                throw AppError.message("Unexpected Basic Pitch model output.")
            }
            notes.append(Self.floats(n))
            onsets.append(Self.floats(o))
            progress?(Double(i + 1) / Double(windows.count))
        }
        let n = BasicPitch.unwrap(notes, bins: BasicPitch.noteBins, originalLength: mono.count)
        let o = BasicPitch.unwrap(onsets, bins: BasicPitch.noteBins, originalLength: mono.count)
        return BasicPitch.notes(note: n, onset: o, frameCount: n.count / BasicPitch.noteBins)
    }
}

enum SoundFontLibrary {
    static var bundledURL: URL? { Bundle.main.url(forResource: "GeneralUser-GS", withExtension: "sf2", subdirectory: "SoundFonts") ?? Bundle.main.url(forResource: "GeneralUser-GS", withExtension: "sf2") }

    private static var cache: [String: SoundFont] = [:]
    private static let lock = NSLock()

    /// Loads the selected soundfont (custom one from Documents/SoundFonts, else the bundled GeneralUser GS).
    static func load(custom: String?) throws -> (SoundFont, String) {
        lock.lock(); defer { lock.unlock() }
        if let name = custom {
            let url = ProjectStore.soundFontsDir.appendingPathComponent(name)
            if let sf = cache[url.path] { return (sf, name) }
            if FileManager.default.fileExists(atPath: url.path) {
                let sf = try SoundFont(url: url)
                cache[url.path] = sf
                return (sf, (name as NSString).deletingPathExtension)
            }
        }
        guard let url = bundledURL else { throw AppError.message("Bundled soundfont missing.") }
        if let sf = cache[url.path] { return (sf, "GeneralUser GS") }
        let sf = try SoundFont(url: url)
        cache[url.path] = sf
        return (sf, "GeneralUser GS")
    }

    static var installed: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: ProjectStore.soundFontsDir.path).filter { $0.lowercased().hasSuffix(".sf2") }.sorted()) ?? []
    }
}

/// Real-time MaiSynth output for Piano Tiles and instrument previews (sample-accurate scheduling).
final class SynthPlayer {
    let engine = AVAudioEngine()
    private(set) var synth: Synthesizer
    private var source: AVAudioSourceNode!
    private let lock = NSLock()
    private var queue: [(frame: Int64, action: (Synthesizer) -> Void)] = []
    private var rendered: Int64 = 0
    let sampleRate: Double

    init(soundFont: SoundFont) throws {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let sr = AVAudioSession.sharedInstance().sampleRate > 0 ? AVAudioSession.sharedInstance().sampleRate : 48000
        sampleRate = sr
        synth = Synthesizer(soundFont: soundFont, sampleRate: sr)
        synth.masterGain = 0.5
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        source = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = Int(frameCount)
            for i in 0..<n { l[i] = 0; r[i] = 0 }
            self.lock.lock()
            var done = 0
            while done < n {
                // apply due events, then render up to the next event
                while let first = self.queue.first, first.frame <= self.rendered + Int64(done) {
                    first.action(self.synth)
                    self.queue.removeFirst()
                }
                var chunk = n - done
                if let next = self.queue.first { chunk = max(1, min(chunk, Int(next.frame - (self.rendered + Int64(done))))) }
                self.synth.render(left: l + done, right: r + done, frames: chunk)
                done += chunk
            }
            self.rendered += Int64(n)
            self.lock.unlock()
            // soft clip to avoid harsh overloads
            for i in 0..<n { l[i] = tanhf(l[i]); r[i] = tanhf(r[i]) }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: fmt)
        try engine.start()
    }

    deinit { engine.stop() }

    /// Schedules an action `delay` seconds from now (sample accurate).
    func schedule(after delay: Double = 0, _ action: @escaping (Synthesizer) -> Void) {
        lock.lock()
        let frame = rendered + Int64(max(0, delay) * sampleRate) + 256
        let idx = queue.firstIndex { $0.frame > frame } ?? queue.count
        queue.insert((frame, action), at: idx)
        lock.unlock()
    }

    func play(_ s: Tile.Sound, programOverride: Int?, after extra: Double = 0) {
        let ch = s.isDrum ? 9 : s.channel
        let prog = s.isDrum ? s.program : (programOverride ?? s.program)
        schedule(after: s.delay + extra) { syn in
            if !s.isDrum { syn.programChange(channel: ch, program: prog) }
            syn.noteOn(channel: ch, key: s.pitch, velocity: s.velocity)
        }
        schedule(after: s.delay + extra + s.duration) { syn in syn.noteOff(channel: ch, key: s.pitch) }
    }

    func noteOn(channel: Int = 0, key: Int, velocity: Int = 100, program: Int? = nil) {
        schedule { syn in
            if let p = program { syn.programChange(channel: channel, program: p) }
            syn.noteOn(channel: channel, key: key, velocity: velocity)
        }
    }

    func noteOff(channel: Int = 0, key: Int) { schedule { $0.noteOff(channel: channel, key: key) } }

    func allOff() {
        lock.lock()
        queue.removeAll()
        synth.allNotesOff()
        lock.unlock()
    }

    func setSoundFont(_ sf: SoundFont) {
        lock.lock()
        synth.setSoundFont(sf)
        lock.unlock()
    }
}
