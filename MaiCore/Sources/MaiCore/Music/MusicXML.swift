import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum MusicXMLError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let s): return "The MusicXML file could not be read: \(s)" }
    }
}

/// Minimal XML DOM built with XMLParser.
final class XMLNode {
    let name: String
    var attributes: [String: String]
    var children: [XMLNode] = []
    var text = ""
    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }
    func child(_ n: String) -> XMLNode? { children.first { $0.name == n } }
    func all(_ n: String) -> [XMLNode] { children.filter { $0.name == n } }
    func value(_ path: String) -> String? {
        var node: XMLNode? = self
        for p in path.split(separator: "/") { node = node?.child(String(p)) }
        return node?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func double(_ path: String) -> Double? { value(path).flatMap { Double($0) } }
}

final class DOMBuilder: NSObject, XMLParserDelegate {
    var stack: [XMLNode] = []
    var root: XMLNode?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let n = XMLNode(name: elementName, attributes: attributeDict)
        stack.last?.children.append(n)
        if root == nil { root = n }
        stack.append(n)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    static func parse(_ data: Data) throws -> XMLNode {
        let p = XMLParser(data: data)
        let b = DOMBuilder()
        p.delegate = b
        p.shouldResolveExternalEntities = false
        guard p.parse(), let r = b.root else {
            throw MusicXMLError.invalid(p.parserError?.localizedDescription ?? "XML syntax error")
        }
        return r
    }
}

public enum MusicXML {
    /// Parses .musicxml/.xml or compressed .mxl data.
    public static func parse(data: Data, title fallbackTitle: String = "") throws -> Score {
        var xmlData = data
        if data.count > 4, data[data.startIndex] == 0x50, data[data.startIndex + 1] == 0x4B {
            let entries = try ZipArchive.read(data)
            var rootPath: String? = nil
            if let container = entries.first(where: { $0.path == "META-INF/container.xml" }),
               let dom = try? DOMBuilder.parse(container.data) {
                rootPath = dom.child("rootfiles")?.child("rootfile")?.attributes["full-path"]
            }
            let main = entries.first { $0.path == rootPath }
                ?? entries.first { !$0.path.hasPrefix("META-INF") && ($0.path.hasSuffix(".xml") || $0.path.hasSuffix(".musicxml")) }
            guard let m = main else { throw MusicXMLError.invalid("no score inside the .mxl archive") }
            xmlData = m.data
        }
        let root = try DOMBuilder.parse(xmlData)
        guard root.name == "score-partwise" else {
            if root.name == "score-timewise" { throw MusicXMLError.invalid("timewise MusicXML is not supported; please export partwise") }
            throw MusicXMLError.invalid("unexpected root element <\(root.name)>")
        }
        return try convert(root, fallbackTitle: fallbackTitle)
    }

    struct PartInfo {
        var name = ""
        var program = 0
        var channel: Int? = nil
        var unpitched: [String: Int] = [:] // instrument id -> GM key
    }

    static let stepSemitone: [String: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    static let dynamicsVelocity: [String: Int] = ["pppp": 20, "ppp": 28, "pp": 40, "p": 55, "mp": 70, "mf": 85, "f": 100, "ff": 112, "fff": 122, "ffff": 127, "sf": 110, "sfz": 112, "fp": 100]

    static func convert(_ root: XMLNode, fallbackTitle: String) throws -> Score {
        var title = root.value("work/work-title") ?? root.value("movement-title") ?? fallbackTitle
        if title.isEmpty { title = fallbackTitle }
        let composer = root.child("identification")?.all("creator").first { $0.attributes["type"] == "composer" }?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var parts: [String: PartInfo] = [:]
        if let list = root.child("part-list") {
            for sp in list.all("score-part") {
                var info = PartInfo()
                info.name = sp.value("part-name") ?? ""
                for mi in sp.all("midi-instrument") {
                    if let p = mi.value("midi-program").flatMap(Int.init) { info.program = max(0, p - 1) }
                    if let c = mi.value("midi-channel").flatMap(Int.init) { info.channel = max(0, c - 1) }
                    if let u = mi.value("midi-unpitched").flatMap(Int.init), let id = mi.attributes["id"] { info.unpitched[id] = u - 1 }
                }
                parts[sp.attributes["id"] ?? ""] = info
            }
        }
        let partNodes = root.all("part")
        guard !partNodes.isEmpty else { throw MusicXMLError.invalid("no parts") }
        // measure playback order (repeats/endings) from the first part
        let order = playbackOrder(partNodes[0].all("measure"))
        var notes: [MusicNote] = []
        var tempoChanges: [(Double, Double)] = []
        var timeSigs: [TimeSignature] = []
        var tracks: [TrackInfo] = []
        var nextChannel = 0
        for (pi, part) in partNodes.enumerated() {
            let id = part.attributes["id"] ?? ""
            let info = parts[id] ?? PartInfo()
            let measures = part.all("measure")
            var isDrum = !info.unpitched.isEmpty || measures.contains { $0.all("note").contains { $0.child("unpitched") != nil } }
            if let c = info.channel, c == 9 { isDrum = true }
            var channel = isDrum ? 9 : (info.channel ?? nextChannel)
            if !isDrum {
                if channel == 9 { channel = 10 }
                nextChannel = max(nextChannel, channel) + 1
                if nextChannel == 9 { nextChannel = 10 }
                channel = min(channel, 15)
            }
            var divisions = 1.0
            var measureStart = 0.0 // in quarter notes
            var velocity = 90
            var pending: [Int: MusicNote] = [:] // tie continuation by pitch*16+voice
            var partNotes: [MusicNote] = []
            var lastNoteStart = 0.0
            for mi in order where mi < measures.count {
                let m = measures[mi]
                var cursor = 0.0
                var maxCursor = 0.0
                var nominal: Double? = nil
                for el in m.children {
                    switch el.name {
                    case "attributes":
                        if let d = el.double("divisions"), d > 0 { divisions = d }
                        if let t = el.child("time"), let beats = t.value("beats"), let bt = t.double("beat-type") {
                            // compound values like "3+2" are summed
                            let num = beats.split(separator: "+").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.reduce(0, +)
                            if num > 0, pi == 0 {
                                let sig = TimeSignature(beat: measureStart, numerator: num, denominator: Int(bt))
                                if timeSigs.last.map({ $0.numerator != sig.numerator || $0.denominator != sig.denominator }) ?? true { timeSigs.append(sig) }
                            }
                            if num > 0 { nominal = Double(num) * 4 / bt }
                        }
                    case "direction":
                        if let s = el.child("sound"), let t = s.attributes["tempo"].flatMap(Double.init), t > 0, pi == 0 {
                            tempoChanges.append((measureStart + cursor / divisions, t))
                        } else if let mt = el.child("direction-type")?.child("metronome"), let pm = mt.double("per-minute"), pi == 0 {
                            let unit = mt.value("beat-unit") ?? "quarter"
                            let factor: Double = ["whole": 4, "half": 2, "quarter": 1, "eighth": 0.5, "16th": 0.25][unit] ?? 1
                            let dotted = mt.child("beat-unit-dot") != nil ? 1.5 : 1
                            tempoChanges.append((measureStart + cursor / divisions, pm * factor * dotted))
                        }
                        if let dyn = el.child("direction-type")?.child("dynamics")?.children.first?.name, let v = dynamicsVelocity[dyn] { velocity = v }
                        if let s = el.child("sound"), let d = s.attributes["dynamics"].flatMap(Double.init) { velocity = max(1, min(127, Int(d * 0.9))) }
                    case "sound":
                        if let t = el.attributes["tempo"].flatMap(Double.init), t > 0, pi == 0 { tempoChanges.append((measureStart + cursor / divisions, t)) }
                    case "backup":
                        cursor -= (el.double("duration") ?? 0)
                        cursor = max(0, cursor)
                    case "forward":
                        cursor += (el.double("duration") ?? 0)
                        maxCursor = max(maxCursor, cursor)
                    case "note":
                        if el.child("grace") != nil { continue }
                        let dur = el.double("duration") ?? 0
                        let isChord = el.child("chord") != nil
                        let start = isChord ? lastNoteStart : cursor
                        if !isChord { lastNoteStart = cursor; cursor += dur; maxCursor = max(maxCursor, cursor) }
                        if el.child("rest") != nil { continue }
                        var pitch: Int? = nil
                        if let p = el.child("pitch"), let step = p.value("step"), let oct = p.value("octave").flatMap(Int.init) {
                            let alter = Int((p.double("alter") ?? 0).rounded())
                            pitch = 12 * (oct + 1) + (stepSemitone[step.uppercased()] ?? 0) + alter
                        } else if let u = el.child("unpitched") {
                            if let inst = el.child("instrument")?.attributes["id"], let key = info.unpitched[inst] {
                                pitch = key
                            } else if let step = u.value("display-step"), let oct = u.value("display-octave").flatMap(Int.init) {
                                pitch = drumKey(step: step, octave: oct, notehead: el.value("notehead") ?? "")
                            }
                        }
                        guard let pch = pitch else { continue }
                        var vel = velocity
                        if let dv = el.attributes["dynamics"].flatMap(Double.init) { vel = max(1, min(127, Int(dv * 0.9))) }
                        let voice = Int(el.value("voice") ?? "1") ?? 1
                        let key = pch * 16 + voice
                        let ties = el.all("tie").map { $0.attributes["type"] ?? "" } + (el.child("notations")?.all("tied").map { $0.attributes["type"] ?? "" } ?? [])
                        let startBeat = measureStart + start / divisions
                        let lenBeats = dur / divisions
                        if ties.contains("stop"), var prev = pending[key] {
                            prev.durationBeats = startBeat + lenBeats - prev.startBeat
                            if ties.contains("start") { pending[key] = prev } else { pending[key] = nil; partNotes.append(prev) }
                            continue
                        }
                        let note = MusicNote(pitch: pch, startBeat: startBeat, durationBeats: max(0.01, lenBeats), velocity: vel,
                                             channel: channel, track: pi, program: isDrum ? 0 : info.program, isDrum: isDrum)
                        if ties.contains("start") { pending[key] = note } else { partNotes.append(note) }
                    default:
                        break
                    }
                }
                let measureLen = max(maxCursor / divisions, (m.attributes["implicit"] == "yes") ? 0 : (nominal ?? 0))
                measureStart += measureLen > 0 ? measureLen : (nominal ?? 4)
            }
            partNotes.append(contentsOf: pending.values)
            notes.append(contentsOf: partNotes)
            tracks.append(TrackInfo(index: pi, name: info.name, channel: channel, program: info.program, isDrum: isDrum, noteCount: partNotes.count))
        }
        var tempo = TempoMap(bpm: 120)
        if !tempoChanges.isEmpty {
            var dedup: [(beat: Double, bpm: Double)] = []
            for (b, t) in tempoChanges.sorted(by: { $0.0 < $1.0 }) where dedup.last.map({ abs($0.bpm - t) > 1e-6 }) ?? true {
                dedup.append((b, t))
            }
            if dedup.first!.beat > 0 { dedup.insert((0, dedup.first!.bpm), at: 0) }
            tempo = TempoMap(changes: dedup)
        }
        return Score(title: title, composer: composer, tempo: tempo, timeSignatures: timeSigs, notes: notes, tracks: tracks)
    }

    /// Standard drum-set notation positions -> GM percussion keys.
    static func drumKey(step: String, octave: Int, notehead: String) -> Int {
        let x = notehead.lowercased().contains("x") || notehead.lowercased().contains("cross")
        switch (step.uppercased(), octave) {
        case ("F", 4), ("E", 4): return 36
        case ("C", 5): return 38
        case ("G", 5): return x ? 42 : 43
        case ("A", 5): return x ? 49 : 45
        case ("B", 5): return 51
        case ("E", 5): return 48
        case ("D", 5): return 47
        case ("A", 4): return 41
        case ("D", 4): return 44
        default: return x ? 42 : 38
        }
    }

    /// Expands repeats and first/second endings into a linear measure order.
    static func playbackOrder(_ measures: [XMLNode]) -> [Int] {
        struct Info { var forward = false; var backward = false; var times = 2; var endings: [Int] = []; var endingStart = false; var endingStop = false }
        var infos = [Info](repeating: Info(), count: measures.count)
        for (i, m) in measures.enumerated() {
            for bl in m.all("barline") {
                if let r = bl.child("repeat") {
                    if r.attributes["direction"] == "forward" { infos[i].forward = true }
                    if r.attributes["direction"] == "backward" {
                        infos[i].backward = true
                        if let t = r.attributes["times"].flatMap(Int.init) { infos[i].times = max(1, t) }
                    }
                }
                if let e = bl.child("ending") {
                    let nums = (e.attributes["number"] ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
                    if e.attributes["type"] == "start" { infos[i].endings = nums; infos[i].endingStart = true }
                    if e.attributes["type"] == "stop" || e.attributes["type"] == "discontinue" { infos[i].endingStop = true; if infos[i].endings.isEmpty { infos[i].endings = nums } }
                }
            }
        }
        // propagate ending numbers across multi-measure endings
        var current: [Int] = []
        for i in infos.indices {
            if infos[i].endingStart { current = infos[i].endings }
            if !current.isEmpty { infos[i].endings = current }
            if infos[i].endingStop { current = [] }
        }
        var order: [Int] = []
        var i = 0
        var repeatStart = 0
        var pass = 1
        var played = [Int: Int]()
        var guardCount = 0
        while i < measures.count && guardCount < measures.count * 8 {
            guardCount += 1
            if infos[i].forward && pass == 1 { repeatStart = i }
            if !infos[i].endings.isEmpty && !infos[i].endings.contains(pass) {
                i += 1
                continue
            }
            order.append(i)
            if infos[i].backward {
                let n = played[i, default: 0]
                if n + 1 < infos[i].times {
                    played[i] = n + 1
                    pass += 1
                    i = repeatStart
                    continue
                }
                played[i] = 0
                pass = 1
                repeatStart = i + 1
            }
            i += 1
        }
        return order.isEmpty ? Array(measures.indices) : order
    }
}
