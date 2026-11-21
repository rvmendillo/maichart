import Foundation
import AVFoundation
import UIKit
import QuartzCore
import MaiCore

/// Plays the track for the chart player and provides a smooth, latency-compensated clock.
final class ChartAudio {
    let engine = AVAudioEngine()
    let music = AVAudioPlayerNode()
    private var sfxNodes: [AVAudioPlayerNode] = []
    private var sfxIndex = 0
    private var buffer: AVAudioPCMBuffer?
    private var sounds: [String: AVAudioPCMBuffer] = [:]
    /// Host time (seconds, CACurrentMediaTime base) at which audio time 0 is heard.
    private(set) var hostZero: Double = 0
    private(set) var isPlaying = false
    private var pausedAudioTime: Double = 0
    var duration: Double = 0

    init(audio: AudioSamples) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        buffer = AudioIO.pcmBuffer(from: audio)
        duration = audio.duration
        engine.attach(music)
        let fmt = buffer?.format ?? AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        engine.connect(music, to: engine.mainMixerNode, format: fmt)
        let sfxFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        for _ in 0..<8 {
            let n = AVAudioPlayerNode()
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: sfxFormat)
            sfxNodes.append(n)
        }
        sounds = HitSounds.make(format: sfxFormat)
        engine.prepare()
        try? engine.start()
        for n in sfxNodes { n.play() }
    }

    deinit { stop() }

    var outputLatency: Double { AVAudioSession.sharedInstance().outputLatency + AVAudioSession.sharedInstance().ioBufferDuration }

    /// Current audio position in seconds (negative during pre-roll).
    var audioTime: Double { isPlaying ? CACurrentMediaTime() - hostZero : pausedAudioTime }

    /// Starts playback so that `audioTime` equals `from` right now (supports negative pre-roll).
    func start(from: Double) {
        guard let buf = buffer else { return }
        music.stop()
        let sr = buf.format.sampleRate
        let now = CACurrentMediaTime()
        let lat = outputLatency
        if from < 0 {
            // pre-roll: audio sample 0 must be heard at now + |from|
            hostZero = now - from
            music.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
            var playHost = hostZero - lat
            if playHost < now + 0.03 { playHost = now + 0.03; hostZero = playHost + lat }
            music.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: playHost)))
        } else {
            let startFrame = min(Int(buf.frameLength), Int(from * sr))
            let remaining = Int(buf.frameLength) - startFrame
            if remaining > 0, let slice = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: AVAudioFrameCount(remaining)) {
                slice.frameLength = AVAudioFrameCount(remaining)
                for c in 0..<Int(buf.format.channelCount) {
                    slice.floatChannelData![c].update(from: buf.floatChannelData![c] + startFrame, count: remaining)
                }
                music.scheduleBuffer(slice, at: nil, options: [], completionHandler: nil)
            }
            let playHost = now + 0.05
            music.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: playHost)))
            hostZero = playHost + lat - Double(startFrame) / sr
        }
        isPlaying = true
    }

    func pause() {
        guard isPlaying else { return }
        pausedAudioTime = audioTime
        music.pause()
        music.stop()
        isPlaying = false
    }

    func resume() { start(from: pausedAudioTime) }

    func stop() {
        music.stop()
        isPlaying = false
    }

    func setVolumes(music m: Double, sfx: Double) {
        music.volume = Float(m)
        for n in sfxNodes { n.volume = Float(sfx) }
    }

    func play(sound: String) {
        guard let b = sounds[sound] else { return }
        let n = sfxNodes[sfxIndex]
        sfxIndex = (sfxIndex + 1) % sfxNodes.count
        n.scheduleBuffer(b, at: nil, options: [.interrupts], completionHandler: nil)
        if !n.isPlaying { n.play() }
    }
}

/// Procedurally synthesised hit sounds (no external assets).
enum HitSounds {
    static func make(format: AVAudioFormat) -> [String: AVAudioPCMBuffer] {
        let sr = format.sampleRate
        func buf(_ seconds: Double, _ f: (Double) -> Double) -> AVAudioPCMBuffer {
            let n = Int(seconds * sr)
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            b.frameLength = AVAudioFrameCount(n)
            for i in 0..<n {
                let t = Double(i) / sr
                let v = Float(max(-1, min(1, f(t))))
                b.floatChannelData![0][i] = v
                b.floatChannelData![1][i] = v
            }
            return b
        }
        var noise = SeededRandom(seed: 11)
        let noiseTable: [Double] = (0..<Int(sr * 0.7)).map { _ in noise.unit() * 2 - 1 }
        func nz(_ t: Double) -> Double { noiseTable[min(noiseTable.count - 1, Int(t * sr))] }
        let twoPi = 2.0 * Double.pi
        var out: [String: AVAudioPCMBuffer] = [:]
        out["tap"] = buf(0.09) { t in
            let tone = 0.55 * sin(twoPi * 1760.0 * t)
            return (tone + 0.35 * nz(t)) * exp(-t * 55.0)
        }
        out["great"] = buf(0.09) { t in
            let tone = 0.45 * sin(twoPi * 1320.0 * t)
            return (tone + 0.3 * nz(t)) * exp(-t * 60.0)
        }
        out["break"] = buf(0.35) { t in
            let a = 0.4 * sin(twoPi * 1046.0 * t)
            let b = 0.3 * sin(twoPi * 1568.0 * t)
            let c = 0.25 * sin(twoPi * 2093.0 * t)
            let n = 0.2 * nz(t) * exp(-t * 40.0)
            return (a + b + c + n) * exp(-t * 9.0)
        }
        out["touch"] = buf(0.08) { t in
            let tone = 0.5 * sin(twoPi * 2349.0 * t)
            return (tone + 0.2 * nz(t)) * exp(-t * 60.0)
        }
        out["slide"] = buf(0.3) { t in
            let wobble = 0.5 + 0.5 * sin(twoPi * 18.0 * t)
            return 0.35 * nz(t) * exp(-t * 10.0) * wobble
        }
        out["firework"] = buf(0.6) { t in
            let n = 0.45 * nz(t) * exp(-t * 6.0)
            let sweep = 0.3 * sin(twoPi * (600.0 + 900.0 * t) * t) * exp(-t * 5.0)
            return n + sweep
        }
        out["miss"] = buf(0.05) { _ in 0 }
        return out
    }
}

/// Alternative renderer: Apple's AUSampler (AVAudioUnitSampler) driven offline. Uses one sampler per
/// (channel, program) pair so mid-song program changes and drum channels never drop notes.
enum AppleSamplerRenderer {
    static func render(score: Score, soundFontURL: URL, leadIn: Double, sampleRate: Double = 44100,
                       instrumentOverride: Int? = nil, progress: ((Double) -> Void)? = nil) throws -> AudioSamples {
        let engine = AVAudioEngine()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        let events = MIDIRenderer.events(for: score, instrumentOverride: instrumentOverride)
        // which (channel, program, drum) combinations are needed
        struct Key: Hashable { var channel: Int; var program: Int; var drum: Bool }
        var programOf = [Int](repeating: 0, count: 16)
        var drumCh = Set<Int>([9])
        var needed = Set<Key>()
        for e in events {
            switch e.kind {
            case .program(let p): programOf[e.channel] = p
            case .drum(let d): if d { drumCh.insert(e.channel) }
            case .noteOn: needed.insert(Key(channel: e.channel, program: drumCh.contains(e.channel) ? 0 : programOf[e.channel], drum: drumCh.contains(e.channel)))
            default: break
            }
        }
        var samplers: [Key: AVAudioUnitSampler] = [:]
        for k in needed {
            let s = AVAudioUnitSampler()
            engine.attach(s)
            engine.connect(s, to: engine.mainMixerNode, format: fmt)
            let bankMSB = k.drum ? UInt8(kAUSampler_DefaultPercussionBankMSB) : UInt8(kAUSampler_DefaultMelodicBankMSB)
            do {
                try s.loadSoundBankInstrument(at: soundFontURL, program: UInt8(k.program), bankMSB: bankMSB, bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            } catch {
                try? s.loadSoundBankInstrument(at: soundFontURL, program: 0, bankMSB: bankMSB, bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            }
            samplers[k] = s
        }
        try engine.start()
        let musicEnd = events.last?.time ?? 0
        let total = Int(((leadIn + musicEnd + 2.5) * sampleRate).rounded(.up))
        var left = [Float](repeating: 0, count: total), right = [Float](repeating: 0, count: total)
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var cursor = 0
        var ei = 0
        programOf = [Int](repeating: 0, count: 16)
        var active: [Int: [Int: AVAudioUnitSampler]] = [:] // channel -> key -> sampler that started it
        func sampler(for ch: Int) -> AVAudioUnitSampler? {
            let k = Key(channel: ch, program: drumCh.contains(ch) ? 0 : programOf[ch], drum: drumCh.contains(ch))
            return samplers[k]
        }
        while cursor < total {
            let lead = Int(leadIn * sampleRate)
            while ei < events.count && lead + Int(events[ei].time * sampleRate) <= cursor {
                let e = events[ei]
                switch e.kind {
                case .program(let p): programOf[e.channel] = p
                case .noteOn(let key, let vel):
                    if let s = sampler(for: e.channel) {
                        s.startNote(UInt8(key), withVelocity: UInt8(vel), onChannel: 0)
                        active[e.channel, default: [:]][key] = s
                    }
                case .noteOff(let key):
                    if let s = active[e.channel]?[key] { s.stopNote(UInt8(key), onChannel: 0); active[e.channel]?[key] = nil }
                case .cc(let n, let v):
                    for (k, s) in samplers where k.channel == e.channel { s.sendController(UInt8(n), withValue: UInt8(v), onChannel: 0) }
                case .bend(let v):
                    for (k, s) in samplers where k.channel == e.channel { s.sendPitchBend(UInt16(v), onChannel: 0) }
                default: break
                }
                ei += 1
            }
            var n = min(Int(engine.manualRenderingMaximumFrameCount), total - cursor)
            if ei < events.count { n = max(1, min(n, lead + Int(events[ei].time * sampleRate) - cursor)) }
            let status = try engine.renderOffline(AVAudioFrameCount(n), to: out)
            guard status == .success else { break }
            let got = Int(out.frameLength)
            for i in 0..<got { left[cursor + i] = out.floatChannelData![0][i]; right[cursor + i] = out.floatChannelData![1][i] }
            cursor += max(1, got)
            if cursor % (Int(sampleRate) * 5) < n { progress?(Double(cursor) / Double(total)) }
        }
        engine.stop()
        var buf = AudioSamples(sampleRate: sampleRate, channels: [left, right])
        let peak = buf.peak
        if peak > 1e-6 { buf.applyGain(0.84 / peak) }
        return buf
    }
}

/// Cover art generator used when the source has no artwork.
enum CoverArt {
    static func generate(title: String, artist: String, seed: UInt64, size: CGFloat = 800) -> Data? {
        var rng = SeededRandom(seed: seed)
        let palettes: [[UIColor]] = [
            [UIColor(red: 1, green: 0.3, blue: 0.65, alpha: 1), UIColor(red: 0.35, green: 0.2, blue: 0.95, alpha: 1)],
            [UIColor(red: 0.2, green: 0.8, blue: 1, alpha: 1), UIColor(red: 0.6, green: 0.25, blue: 1, alpha: 1)],
            [UIColor(red: 1, green: 0.6, blue: 0.2, alpha: 1), UIColor(red: 1, green: 0.25, blue: 0.5, alpha: 1)],
            [UIColor(red: 0.3, green: 0.95, blue: 0.7, alpha: 1), UIColor(red: 0.15, green: 0.45, blue: 1, alpha: 1)],
        ]
        let pal = palettes[rng.int(0...(palettes.count - 1))]
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [pal[0].cgColor, pal[1].cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(grad, start: .zero, end: CGPoint(x: size, y: size), options: [])
            // rings
            for k in 0..<5 {
                let r = size * CGFloat(0.12 + 0.1 * Double(k))
                cg.setStrokeColor(UIColor.white.withAlphaComponent(0.12 + 0.05 * CGFloat(k % 2)).cgColor)
                cg.setLineWidth(size * 0.02)
                cg.strokeEllipse(in: CGRect(x: size * 0.72 - r, y: size * 0.3 - r, width: 2 * r, height: 2 * r))
            }
            for _ in 0..<40 {
                let x = CGFloat(rng.unit()) * size, y = CGFloat(rng.unit()) * size, s = CGFloat(rng.double(2...7))
                cg.setFillColor(UIColor.white.withAlphaComponent(CGFloat(rng.double(0.2...0.8))).cgColor)
                cg.fillEllipse(in: CGRect(x: x, y: y, width: s, height: s))
            }
            let para = NSMutableParagraphStyle()
            para.alignment = .left
            let titleFont = UIFont.systemFont(ofSize: size * 0.1, weight: .black)
            let attrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: UIColor.white, .paragraphStyle: para,
                                                        .strokeColor: UIColor.black.withAlphaComponent(0.25), .strokeWidth: -2]
            NSString(string: title).draw(in: CGRect(x: size * 0.07, y: size * 0.58, width: size * 0.86, height: size * 0.28), withAttributes: attrs)
            let a2: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size * 0.045, weight: .bold), .foregroundColor: UIColor.white.withAlphaComponent(0.9)]
            NSString(string: artist.isEmpty ? "MaiChart Studio" : artist).draw(in: CGRect(x: size * 0.07, y: size * 0.86, width: size * 0.86, height: size * 0.08), withAttributes: a2)
        }
        return img.jpegData(compressionQuality: 0.9)
    }

    /// Normalises any artwork to a square JPEG.
    static func normalize(_ data: Data, size: CGFloat = 800) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let r = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let out = r.image { _ in
            let s = img.size
            let scale = max(size / s.width, size / s.height)
            let w = s.width * scale, h = s.height * scale
            img.draw(in: CGRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
        }
        return out.jpegData(compressionQuality: 0.9)
    }
}
