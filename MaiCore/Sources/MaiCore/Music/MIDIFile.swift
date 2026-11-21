import Foundation

public enum MIDIError: Error, LocalizedError {
    case notMIDI, truncated, unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notMIDI: return "This is not a Standard MIDI File (missing MThd header)."
        case .truncated: return "The MIDI file is truncated or corrupt."
        case .unsupported(let s): return "Unsupported MIDI feature: \(s)"
        }
    }
}

/// Standard MIDI File (format 0/1/2) reader and format-1 writer.
public enum MIDIFile {
    struct RawEvent {
        var tick: Int
        var order: Int
        var status: UInt8
        var data1: UInt8
        var data2: UInt8
        var meta: UInt8? = nil
        var metaData: [UInt8] = []
    }

    public static func parse(data: Data, title: String = "") throws -> Score {
        let b = [UInt8](data)
        var p = 0
        // Some files are wrapped in a RIFF 'RMID' container.
        if b.count > 20, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x52, b[9] == 0x4D, b[10] == 0x49, b[11] == 0x44 {
            var q = 12
            while q + 8 <= b.count {
                let id = String(bytes: b[q..<q + 4], encoding: .ascii) ?? ""
                let len = Int(b[q + 4]) | Int(b[q + 5]) << 8 | Int(b[q + 6]) << 16 | Int(b[q + 7]) << 24
                if id == "data" { p = q + 8; break }
                q += 8 + len + (len & 1)
            }
        }
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        guard p + 14 <= b.count, b[p] == 0x4D, b[p + 1] == 0x54, b[p + 2] == 0x68, b[p + 3] == 0x64 else { throw MIDIError.notMIDI }
        let headerLen = u32(p + 4)
        let format = u16(p + 8)
        let ntracks = u16(p + 10)
        let division = u16(p + 12)
        p += 8 + headerLen
        var ppq = 480
        var smpteTicksPerSecond: Double? = nil
        if division & 0x8000 != 0 {
            let fps = Double(256 - (division >> 8))
            let tpf = Double(division & 0xFF)
            smpteTicksPerSecond = (fps == 29 ? 29.97 : fps) * tpf
            ppq = 960
        } else {
            ppq = max(1, division)
        }

        var tracksRaw: [[RawEvent]] = []
        var order = 0
        for _ in 0..<ntracks {
            // find next MTrk chunk (skip unknown chunks)
            var found = false
            while p + 8 <= b.count {
                let isTrack = b[p] == 0x4D && b[p + 1] == 0x54 && b[p + 2] == 0x72 && b[p + 3] == 0x6B
                let len = u32(p + 4)
                if isTrack { found = true; break }
                p += 8 + len
            }
            if !found { break }
            let len = u32(p + 4)
            var q = p + 8
            let end = min(b.count, q + len)
            p = q + len
            var tick = 0
            var running: UInt8 = 0
            var events: [RawEvent] = []
            func readVLQ() -> Int? {
                var v = 0
                for _ in 0..<4 {
                    guard q < end else { return nil }
                    let c = b[q]; q += 1
                    v = (v << 7) | Int(c & 0x7F)
                    if c & 0x80 == 0 { return v }
                }
                return v
            }
            while q < end {
                guard let delta = readVLQ() else { break }
                tick += delta
                guard q < end else { break }
                var status = b[q]
                if status & 0x80 != 0 {
                    q += 1
                    if status < 0xF0 { running = status }
                } else {
                    status = running
                    if status == 0 { throw MIDIError.truncated }
                }
                if status == 0xFF {
                    guard q < end else { break }
                    let type = b[q]; q += 1
                    guard let l = readVLQ(), q + l <= end else { break }
                    events.append(RawEvent(tick: tick, order: order, status: 0xFF, data1: 0, data2: 0, meta: type, metaData: Array(b[q..<q + l])))
                    order += 1
                    q += l
                    if type == 0x2F { break }
                } else if status == 0xF0 || status == 0xF7 {
                    guard let l = readVLQ() else { break }
                    // Detect GS "use rhythm part" sysex (F0 41 10 42 12 40 1x 15 0y ...)
                    let sx = Array(b[q..<min(end, q + l)])
                    events.append(RawEvent(tick: tick, order: order, status: status, data1: 0, data2: 0, meta: nil, metaData: sx))
                    order += 1
                    q += l
                } else {
                    let type = status & 0xF0
                    let needs2 = !(type == 0xC0 || type == 0xD0)
                    guard q < end else { break }
                    let d1 = b[q] & 0x7F; q += 1
                    var d2: UInt8 = 0
                    if needs2 { guard q < end else { break }; d2 = b[q] & 0x7F; q += 1 }
                    events.append(RawEvent(tick: tick, order: order, status: status, data1: d1, data2: d2))
                    order += 1
                }
            }
            tracksRaw.append(events)
        }
        if tracksRaw.isEmpty { throw MIDIError.truncated }

        // Format 2 = independent sequences: lay them out one after another.
        if format == 2 && tracksRaw.count > 1 {
            var offsetTick = 0
            for i in tracksRaw.indices {
                let maxTick = tracksRaw[i].map { $0.tick }.max() ?? 0
                for j in tracksRaw[i].indices { tracksRaw[i][j].tick += offsetTick }
                offsetTick += maxTick
            }
        }

        // Global tempo + time signature maps (from any track).
        var tempoChanges: [(tick: Int, usPerQuarter: Int)] = []
        var timeSigs: [(tick: Int, num: Int, den: Int)] = []
        var markers: [(tick: Int, text: String)] = []
        var songTitle = title
        for (ti, events) in tracksRaw.enumerated() {
            for e in events where e.status == 0xFF {
                switch e.meta {
                case 0x51 where e.metaData.count >= 3:
                    let us = Int(e.metaData[0]) << 16 | Int(e.metaData[1]) << 8 | Int(e.metaData[2])
                    if us > 0 { tempoChanges.append((e.tick, us)) }
                case 0x58 where e.metaData.count >= 2:
                    let den = 1 << Int(min(6, e.metaData[1]))
                    timeSigs.append((e.tick, Int(e.metaData[0]), den))
                case 0x06, 0x01:
                    if let s = decodeText(e.metaData), !s.trimmingCharacters(in: .whitespaces).isEmpty {
                        markers.append((e.tick, s))
                    }
                case 0x03:
                    if ti == 0, songTitle.isEmpty, let s = decodeText(e.metaData), !s.isEmpty, format != 0 || true {
                        // track 0 name is commonly the song title
                        if tracksRaw.count == 1 || format == 1 { songTitle = s }
                    }
                default: break
                }
            }
        }
        tempoChanges.sort { $0.tick < $1.tick }
        let tempo: TempoMap
        if let tps = smpteTicksPerSecond {
            // treat as 120 BPM with ppq derived from ticks-per-second
            ppq = Int((tps / 2).rounded())
            tempo = TempoMap(bpm: 120)
        } else if tempoChanges.isEmpty {
            tempo = TempoMap(bpm: 120)
        } else {
            tempo = TempoMap(changes: tempoChanges.map { (Double($0.tick) / Double(ppq), 60_000_000 / Double($0.usPerQuarter)) })
        }
        let sigs = timeSigs.sorted { $0.tick < $1.tick }.map { TimeSignature(beat: Double($0.tick) / Double(ppq), numerator: $0.num, denominator: $0.den) }

        // Notes per track/channel.
        var notes: [MusicNote] = []
        var controls: [ControlEvent] = []
        var trackInfos: [TrackInfo] = []
        var channelProgram = [Int](repeating: 0, count: 16)
        var channelBankMSB = [Int](repeating: 0, count: 16)
        var drumChannels = Set<Int>([9])
        // Merge all events in time order so program changes on one track affect notes on another.
        var all: [(track: Int, e: RawEvent)] = []
        for (ti, events) in tracksRaw.enumerated() { for e in events { all.append((ti, e)) } }
        all.sort { ($0.e.tick, $0.e.order) < ($1.e.tick, $1.e.order) }
        struct Key: Hashable { var track: Int; var channel: Int; var pitch: Int }
        var open: [Key: [(tick: Int, vel: Int, program: Int, drum: Bool)]] = [:]
        var trackNames = [String](repeating: "", count: tracksRaw.count)
        var trackChannels = [Set<Int>](repeating: [], count: tracksRaw.count)
        var trackPrograms = [Int](repeating: -1, count: tracksRaw.count)
        var trackNoteCounts = [Int](repeating: 0, count: tracksRaw.count)
        let maxTick = all.map { $0.e.tick }.max() ?? 0
        func beat(_ tick: Int) -> Double { Double(tick) / Double(ppq) }

        for (ti, e) in all {
            if e.status == 0xFF {
                if e.meta == 0x03, let s = decodeText(e.metaData), trackNames[ti].isEmpty { trackNames[ti] = s }
                if e.meta == 0x04, let s = decodeText(e.metaData), trackNames[ti].isEmpty { trackNames[ti] = s }
                continue
            }
            if e.status == 0xF0 {
                // GS: F0 41 dev 42 12 40 1x 15 vv cs F7 -> part x uses rhythm map vv (0=normal)
                let d = e.metaData
                if d.count >= 8, d[0] == 0x41, d[2] == 0x42, d[3] == 0x12, d[4] == 0x40, (d[5] & 0xF0) == 0x10, d[6] == 0x15 {
                    let part = Int(d[5] & 0x0F)
                    let ch = part == 0 ? 9 : (part <= 9 ? part - 1 : part)
                    if d[7] == 0 { drumChannels.remove(ch) } else { drumChannels.insert(ch) }
                }
                continue
            }
            if e.status == 0xF7 { continue }
            let type = Int(e.status & 0xF0)
            let ch = Int(e.status & 0x0F)
            switch type {
            case 0x90 where e.data2 > 0:
                let k = Key(track: ti, channel: ch, pitch: Int(e.data1))
                open[k, default: []].append((e.tick, Int(e.data2), channelProgram[ch], drumChannels.contains(ch)))
                trackChannels[ti].insert(ch)
            case 0x80, 0x90:
                let k = Key(track: ti, channel: ch, pitch: Int(e.data1))
                if var stack = open[k], !stack.isEmpty {
                    let on = stack.removeFirst()
                    open[k] = stack
                    let dur = max(1, e.tick - on.tick)
                    notes.append(MusicNote(pitch: Int(e.data1), startBeat: beat(on.tick), durationBeats: Double(dur) / Double(ppq),
                                           velocity: on.vel, channel: ch, track: ti, program: on.program, isDrum: on.drum))
                    trackNoteCounts[ti] += 1
                }
            case 0xB0:
                if e.data1 == 0 {
                    channelBankMSB[ch] = Int(e.data2)
                    // XG drum banks (127) and GM2 percussion (120)
                    if e.data2 == 127 || e.data2 == 120 { drumChannels.insert(ch) } else if ch != 9 && drumChannels.contains(ch) && e.data2 == 0 { drumChannels.remove(ch) }
                }
                controls.append(ControlEvent(beat: beat(e.tick), channel: ch, kind: .controller(number: Int(e.data1), value: Int(e.data2))))
            case 0xC0:
                channelProgram[ch] = Int(e.data1)
                if trackPrograms[ti] < 0 { trackPrograms[ti] = Int(e.data1) }
                controls.append(ControlEvent(beat: beat(e.tick), channel: ch, kind: .program(Int(e.data1))))
            case 0xE0:
                let v = Int(e.data1) | Int(e.data2) << 7
                controls.append(ControlEvent(beat: beat(e.tick), channel: ch, kind: .pitchBend(v)))
            case 0xD0:
                controls.append(ControlEvent(beat: beat(e.tick), channel: ch, kind: .channelPressure(Int(e.data1))))
            default:
                break
            }
        }
        // close hanging notes at the end
        for (k, stack) in open {
            for on in stack {
                let dur = max(ppq / 4, maxTick - on.tick)
                notes.append(MusicNote(pitch: k.pitch, startBeat: beat(on.tick), durationBeats: Double(dur) / Double(ppq),
                                       velocity: on.vel, channel: k.channel, track: k.track, program: on.program, isDrum: on.drum))
                trackNoteCounts[k.track] += 1
            }
        }
        for ti in tracksRaw.indices {
            let ch = trackChannels[ti].sorted().first ?? 0
            let isDrum = !trackChannels[ti].isEmpty && trackChannels[ti].allSatisfy { drumChannels.contains($0) }
            trackInfos.append(TrackInfo(index: ti, name: trackNames[ti], channel: ch,
                                        program: max(0, trackPrograms[ti]), isDrum: isDrum, noteCount: trackNoteCounts[ti]))
        }
        var score = Score(title: songTitle, tempo: tempo, timeSignatures: sigs, notes: notes, tracks: trackInfos, controls: controls)
        score.markers = markers.sorted { $0.tick < $1.tick }.map { (beat($0.tick), $0.text) }
        return score
    }

    static func decodeText(_ bytes: [UInt8]) -> String? {
        if let s = String(bytes: bytes, encoding: .utf8) { return s.trimmingCharacters(in: .controlCharacters) }
        if let s = String(bytes: bytes, encoding: .shiftJIS) { return s }
        return String(bytes: bytes, encoding: .isoLatin1)
    }

    // MARK: Writer

    /// Writes a format-1 SMF (one tempo track + one track per channel).
    public static func write(_ score: Score, ppq: Int = 480) -> Data {
        var out: [UInt8] = []
        func put32(_ v: Int, _ a: inout [UInt8]) { a += [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func put16(_ v: Int, _ a: inout [UInt8]) { a += [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func vlq(_ v: Int) -> [UInt8] {
            var v = max(0, v)
            var bytes = [UInt8(v & 0x7F)]
            v >>= 7
            while v > 0 { bytes.insert(UInt8((v & 0x7F) | 0x80), at: 0); v >>= 7 }
            return bytes
        }
        func tick(_ beat: Double) -> Int { Int((beat * Double(ppq)).rounded()) }

        struct Ev { var tick: Int; var prio: Int; var bytes: [UInt8] }
        var tempoTrack: [Ev] = []
        let titleBytes = Array(score.title.utf8)
        if !titleBytes.isEmpty { tempoTrack.append(Ev(tick: 0, prio: 0, bytes: [0xFF, 0x03] + vlq(titleBytes.count) + titleBytes)) }
        for s in score.tempo.segments {
            let us = Int((60_000_000 / s.bpm).rounded())
            tempoTrack.append(Ev(tick: tick(s.startBeat), prio: 1, bytes: [0xFF, 0x51, 0x03, UInt8((us >> 16) & 0xFF), UInt8((us >> 8) & 0xFF), UInt8(us & 0xFF)]))
        }
        for ts in score.timeSignatures {
            var dpow = 0
            while (1 << dpow) < ts.denominator { dpow += 1 }
            tempoTrack.append(Ev(tick: tick(ts.beat), prio: 1, bytes: [0xFF, 0x58, 0x04, UInt8(ts.numerator), UInt8(dpow), 24, 8]))
        }
        var tracks: [[Ev]] = [tempoTrack]
        let channels = Set(score.notes.map { $0.isDrum ? 9 : $0.channel }).sorted()
        for ch in channels {
            var evs: [Ev] = []
            let chNotes = score.notes.filter { ($0.isDrum ? 9 : $0.channel) == ch }
            if ch != 9, let prog = chNotes.first?.program {
                evs.append(Ev(tick: 0, prio: 0, bytes: [0xC0 | UInt8(ch), UInt8(max(0, min(127, prog)))]))
            }
            for c in score.controls where c.channel == ch {
                switch c.kind {
                case .controller(let n, let v): evs.append(Ev(tick: tick(c.beat), prio: 1, bytes: [0xB0 | UInt8(ch), UInt8(n & 0x7F), UInt8(v & 0x7F)]))
                case .program(let p) where c.beat > 0: evs.append(Ev(tick: tick(c.beat), prio: 1, bytes: [0xC0 | UInt8(ch), UInt8(p & 0x7F)]))
                case .pitchBend(let v): evs.append(Ev(tick: tick(c.beat), prio: 1, bytes: [0xE0 | UInt8(ch), UInt8(v & 0x7F), UInt8((v >> 7) & 0x7F)]))
                case .channelPressure(let v): evs.append(Ev(tick: tick(c.beat), prio: 1, bytes: [0xD0 | UInt8(ch), UInt8(v & 0x7F)]))
                default: break
                }
            }
            for n in chNotes {
                let p = UInt8(max(0, min(127, n.pitch)))
                evs.append(Ev(tick: tick(n.startBeat), prio: 3, bytes: [0x90 | UInt8(ch), p, UInt8(max(1, min(127, n.velocity)))]))
                evs.append(Ev(tick: max(tick(n.startBeat) + 1, tick(n.endBeat)), prio: 2, bytes: [0x80 | UInt8(ch), p, 0]))
            }
            tracks.append(evs)
        }
        out += Array("MThd".utf8); put32(6, &out); put16(1, &out); put16(tracks.count, &out); put16(ppq, &out)
        for evs in tracks {
            let sorted = evs.enumerated().sorted { ($0.element.tick, $0.element.prio, $0.offset) < ($1.element.tick, $1.element.prio, $1.offset) }.map { $0.element }
            var body: [UInt8] = []
            var last = 0
            for e in sorted {
                body += vlq(e.tick - last)
                body += e.bytes
                last = e.tick
            }
            body += [0x00, 0xFF, 0x2F, 0x00]
            out += Array("MTrk".utf8); put32(body.count, &out); out += body
        }
        return Data(out)
    }
}
