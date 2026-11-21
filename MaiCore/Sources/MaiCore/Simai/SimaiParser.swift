import Foundation

public struct SimaiParseError: Error, LocalizedError, Equatable {
    public var line: Int
    public var column: Int
    public var message: String
    public var errorDescription: String? { "simai syntax error at line \(line), column \(column): \(message)" }
}

public enum SimaiLocation: Hashable, Codable {
    case button(Int)
    case sensor(TouchArea)

    public var isButton: Bool { if case .button = self { return true } else { return false } }
    public var buttonIndex: Int? { if case .button(let b) = self { return b } else { return nil } }
    public var area: TouchArea? { if case .sensor(let a) = self { return a } else { return nil } }
}

public struct SimaiSlidePath: Codable, Equatable {
    public var segments: [SlideSegment]
    public var delay: Double     // seconds after the star tap
    public var duration: Double  // seconds of movement
    public var isBreak: Bool
}

public struct SimaiNote: Codable, Equatable {
    public var time: Double
    public var location: SimaiLocation
    public var holdLength: Double?   // seconds (nil for non-holds)
    public var isBreak: Bool
    public var isEx: Bool
    public var firework: Bool
    public var isMine: Bool
    /// Star head shown (slides with a tap head, or forced by `$`).
    public var isStar: Bool
    /// `?`/`!` slides have no tap head.
    public var headless: Bool
    public var slides: [SimaiSlidePath]
    /// Number of notes sharing this time (EACH highlighting).
    public var eachCount: Int
    /// '`' pseudo-each groups are never highlighted.
    public var forceBrokenEach: Bool

    public var isHold: Bool { holdLength != nil }
    public var isTouch: Bool { !location.isButton }
    public var endTime: Double {
        var e = time + (holdLength ?? 0)
        for s in slides { e = max(e, time + s.delay + s.duration) }
        return e
    }
}

public struct SimaiParsedChart: Codable, Equatable {
    public var notes: [SimaiNote]
    public var bpmChanges: [(time: Double, bpm: Double)] {
        get { zip(bpmTimes, bpmValues).map { ($0, $1) } }
        set { bpmTimes = newValue.map { $0.time }; bpmValues = newValue.map { $0.bpm } }
    }
    private var bpmTimes: [Double] = []
    private var bpmValues: [Double] = []
    public var finishTime: Double

    public init(notes: [SimaiNote], bpmChanges: [(time: Double, bpm: Double)], finishTime: Double) {
        self.notes = notes
        self.finishTime = finishTime
        self.bpmChanges = bpmChanges
    }

    public static func == (a: SimaiParsedChart, b: SimaiParsedChart) -> Bool {
        a.notes == b.notes && a.bpmTimes == b.bpmTimes && a.bpmValues == b.bpmValues && a.finishTime == b.finishTime
    }

    /// Notes counted the arcade way (each slide path counts separately from its star).
    public var objectCount: Int {
        notes.reduce(0) { $0 + ($1.headless ? 0 : 1) + $1.slides.count }
    }
}

/// Parses simai chart bodies with the same tokenisation rules as AstroDX's SimaiSharp.
public enum SimaiParser {
    enum TokenType { case tempo, subdivision, location, decorator, slide, duration, slideJoiner, timeStep, eachDivider, endOfFile }
    struct Token { var type: TokenType; var text: Substring; var line: Int; var col: Int }

    static let decorators: Set<Character> = ["f", "b", "x", "h", "m", "!", "?", "@", "$"]
    static let slideChars: Set<Character> = ["-", ">", "<", "^", "p", "q", "v", "V", "s", "z", "w"]
    static let separators: Set<Character> = ["\r", "\t", " ", "\u{2002}", "\u{2008}", "\u{3000}", "\u{2028}", "\u{2029}"]

    static func tokenize(_ s: String) throws -> [Token] {
        let chars = Array(s)
        var tokens: [Token] = []
        var i = 0, line = 1, col = 0
        func sub(_ a: Int, _ b: Int) -> Substring { Substring(String(chars[a..<b])) }
        while i < chars.count {
            col += 1
            let c = chars[i]
            switch c {
            case ",":
                tokens.append(Token(type: .timeStep, text: ",", line: line, col: col)); i += 1
            case "(", "{", "[":
                let term: Character = c == "(" ? ")" : (c == "{" ? "}" : "]")
                var j = i + 1
                while j < chars.count && chars[j] != term {
                    if chars[j] == c { throw SimaiParseError(line: line, column: col, message: "unterminated section") }
                    j += 1
                }
                if j >= chars.count { throw SimaiParseError(line: line, column: col, message: "unterminated section") }
                let type: TokenType = c == "(" ? .tempo : (c == "{" ? .subdivision : .duration)
                tokens.append(Token(type: type, text: sub(i + 1, j), line: line, col: col))
                i = j + 1
            case "0"..."8":
                tokens.append(Token(type: .location, text: sub(i, i + 1), line: line, col: col)); i += 1
            case "A", "B", "C", "D", "E":
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if let n = next, ("0"..."8").contains(n) {
                    tokens.append(Token(type: .location, text: sub(i, i + 2), line: line, col: col)); i += 2
                } else if c == "C" {
                    tokens.append(Token(type: .location, text: "C", line: line, col: col)); i += 1
                } else if c == "E" && (next == nil || separators.contains(next!) || next == "\n" || next == "\0") {
                    tokens.append(Token(type: .endOfFile, text: "E", line: line, col: col)); i += 1
                } else {
                    throw SimaiParseError(line: line, column: col, message: "expected 1-8 after \(c)")
                }
            case _ where decorators.contains(c):
                tokens.append(Token(type: .decorator, text: sub(i, i + 1), line: line, col: col)); i += 1
            case _ where slideChars.contains(c):
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                let len = (next == "p" || next == "q") && (c == "p" || c == "q") ? 2 : 1
                tokens.append(Token(type: .slide, text: sub(i, i + len), line: line, col: col)); i += len
            case "*":
                tokens.append(Token(type: .slideJoiner, text: "*", line: line, col: col)); i += 1
            case "/", "`":
                tokens.append(Token(type: .eachDivider, text: sub(i, i + 1), line: line, col: col)); i += 1
            case "\n":
                line += 1; col = 0; i += 1
            case _ where separators.contains(c):
                i += 1
            case "|":
                if i + 1 < chars.count && chars[i + 1] == "|" {
                    while i < chars.count && chars[i] != "\n" { i += 1 }
                } else {
                    throw SimaiParseError(line: line, column: col, message: "unexpected '|'")
                }
            default:
                throw SimaiParseError(line: line, column: col, message: "unsupported character '\(c)'")
            }
        }
        return tokens
    }

    struct Timing {
        var time: Double = 0
        var tempo: Double = 0
        var subdivisions: Double = 0
        var secondsPerQuarter: Double { tempo == 0 ? 0 : 60 / tempo }
        var secondsPerStep: Double { secondsPerQuarter / ((subdivisions == 0 ? 4 : subdivisions) / 4) }
    }

    static func number(_ s: Substring, _ t: Token) throws -> Double {
        guard let v = Double(s.trimmingCharacters(in: .whitespaces)) else {
            throw SimaiParseError(line: t.line, column: t.col, message: "invalid number '\(s)'")
        }
        return v
    }

    public static func parse(_ body: String) throws -> SimaiParsedChart {
        let tokens = try tokenize(body)
        var timing = Timing()
        var bpmChanges: [(Double, Double)] = []
        var time = 0.0
        var notes: [SimaiNote] = []
        var collection: [SimaiNote] = []
        var collectionBroken = false
        var maxFinish = 0.0
        var finish: Double? = nil
        var i = 0

        func flushCollection() {
            guard !collection.isEmpty else { return }
            let count = collection.filter { !$0.headless || !$0.slides.isEmpty }.count
            for var n in collection {
                n.eachCount = count
                n.forceBrokenEach = collectionBroken
                notes.append(n)
            }
            collection.removeAll()
            collectionBroken = false
        }

        func location(_ t: Token) -> SimaiLocation? {
            let s = String(t.text)
            if let f = s.first, f.isNumber { if let v = Int(s), (1...8).contains(v) { return .button(v) } else { return nil } }
            return TouchArea.parse(s).map { .sensor($0) }
        }

        func durationSeconds(_ t: Token, timing: Timing) throws -> Double {
            let s = t.text
            if s.hasPrefix("#") { return try number(s.dropFirst(), t) }
            var tempo = timing.tempo
            var rest = s
            if let h = s.firstIndex(of: "#") {
                tempo = try number(s[s.startIndex..<h], t)
                rest = s[s.index(after: h)...]
            }
            guard let colon = rest.firstIndex(of: ":") else { throw SimaiParseError(line: t.line, column: t.col, message: "expected x:y") }
            let nom = try number(rest[rest.startIndex..<colon], t)
            let den = try number(rest[rest.index(after: colon)...], t)
            guard nom != 0, tempo != 0 else { return 0 }
            return (60 / tempo) / (nom / 4) * den
        }

        func slideDuration(_ t: Token, timing: Timing, path: inout SimaiSlidePath) throws {
            let s = t.text
            var override = timing
            var declStart = s.startIndex
            if let first = s.firstIndex(of: "#") {
                let last = s.lastIndex(of: "#")!
                declStart = s.index(after: last)
                let delayValue = try number(s[s.startIndex..<first], t)
                if first != last {
                    path.delay = delayValue
                } else {
                    override.tempo = delayValue
                    path.delay = override.secondsPerQuarter
                }
            }
            let decl = s[declStart...]
            if let colon = decl.firstIndex(of: ":") {
                let nom = try number(decl[decl.startIndex..<colon], t)
                let den = try number(decl[decl.index(after: colon)...], t)
                if nom != 0 { path.duration += (override.secondsPerQuarter / (nom / 4)) * den }
            } else {
                path.duration += try number(decl, t)
            }
        }

        while i < tokens.count {
            let tok = tokens[i]
            switch tok.type {
            case .tempo:
                let v = try number(tok.text, tok)
                timing.tempo = v
                timing.time = time
                bpmChanges.append((time, v))
                i += 1
            case .subdivision:
                if tok.text.hasPrefix("#") {
                    let secs = try number(tok.text.dropFirst(), tok)
                    timing.tempo = secs == 0 ? 0 : 60 / secs
                    timing.subdivisions = 4
                } else {
                    timing.subdivisions = try number(tok.text, tok)
                }
                i += 1
            case .location:
                if tok.text == "0" { i += 1; continue }
                guard let loc = location(tok) else { throw SimaiParseError(line: tok.line, column: tok.col, message: "invalid location") }
                var note = SimaiNote(time: time, location: loc, holdLength: nil, isBreak: false, isEx: false, firework: false,
                                     isMine: false, isStar: false, headless: false, slides: [], eachCount: 1, forceBrokenEach: false)
                var forceNormal = false, forceStar = false
                i += 1
                noteLoop: while i < tokens.count {
                    let t = tokens[i]
                    switch t.type {
                    case .decorator:
                        switch t.text.first! {
                        case "f": note.firework = true
                        case "b": note.isBreak = true
                        case "x": note.isEx = true
                        case "m": note.isMine = true
                        case "h": if note.holdLength == nil { note.holdLength = 0 }
                        case "?", "!": note.headless = true
                        case "@": forceNormal = true
                        case "$": forceStar = true
                        default: break
                        }
                        i += 1
                    case .duration:
                        note.holdLength = try durationSeconds(t, timing: timing)
                        i += 1
                    case .slide:
                        if note.holdLength != nil { note.holdLength = nil } // hold head with slide behaves like slide star
                        var path = SimaiSlidePath(segments: [], delay: timing.secondsPerQuarter, duration: 0, isBreak: false)
                        var startVertex = loc.buttonIndex ?? 1
                        var j = i
                        slideLoop: while j < tokens.count {
                            let st = tokens[j]
                            switch st.type {
                            case .slide:
                                var verts: [Int] = []
                                j += 1
                                while j < tokens.count, tokens[j].type == .location {
                                    guard let l = location(tokens[j]), case .button(let v) = l else {
                                        throw SimaiParseError(line: tokens[j].line, column: tokens[j].col, message: "slide vertex must be 1-8")
                                    }
                                    verts.append(v); j += 1
                                }
                                if verts.isEmpty { throw SimaiParseError(line: st.line, column: st.col, message: "slide needs a target") }
                                path.segments.append(SlideSegment(shape: String(st.text), vertices: verts))
                                startVertex = verts.last!
                            case .decorator:
                                if st.text == "b" { path.isBreak = true } else {
                                    throw SimaiParseError(line: st.line, column: st.col, message: "unsupported slide decorator")
                                }
                                j += 1
                            case .duration:
                                try slideDuration(st, timing: timing, path: &path)
                                j += 1
                            case .slideJoiner:
                                j += 1
                                break slideLoop
                            default:
                                break slideLoop
                            }
                        }
                        _ = startVertex
                        note.slides.append(path)
                        i = j
                        // after a joiner the next token is another slide of the same star
                        if i < tokens.count, tokens[i].type == .slide { continue noteLoop }
                    case .tempo, .subdivision:
                        throw SimaiParseError(line: t.line, column: t.col, message: "tempo/subdivision inside a note")
                    case .slideJoiner:
                        throw SimaiParseError(line: t.line, column: t.col, message: "'*' outside a slide")
                    default:
                        break noteLoop
                    }
                }
                note.isStar = (!note.slides.isEmpty && !forceNormal) || forceStar
                if note.isTouch && note.holdLength == nil && note.slides.isEmpty { /* plain touch */ }
                maxFinish = max(maxFinish, note.endTime)
                collection.append(note)
            case .timeStep:
                flushCollection()
                time += timing.secondsPerStep
                i += 1
            case .eachDivider:
                if tok.text == "`" { collectionBroken = true }
                i += 1
            case .endOfFile:
                finish = time
                i += 1
            case .decorator, .slide, .duration, .slideJoiner:
                throw SimaiParseError(line: tok.line, column: tok.col, message: "token outside a note")
            }
        }
        flushCollection()
        notes.sort { $0.time < $1.time }
        return SimaiParsedChart(notes: notes, bpmChanges: bpmChanges, finishTime: finish ?? maxFinish)
    }

    /// Splits a maidata.txt file into key/value pairs (multi-line values supported).
    public static func keyValues(_ text: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var key: String? = nil
        var value = ""
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        for rawLine in t.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.hasPrefix("&") {
                if let k = key { result.append((k, value.trimmingCharacters(in: .whitespacesAndNewlines))) }
                let parts = line.dropFirst().split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                key = String(parts.first ?? "")
                value = parts.count > 1 ? String(parts[1]) + "\n" : "\n"
            } else if key != nil {
                value += line + "\n"
            }
        }
        if let k = key { result.append((k, value.trimmingCharacters(in: .whitespacesAndNewlines))) }
        return result
    }
}

/// A parsed maidata.txt (metadata + raw chart bodies).
public struct MaidataFile {
    public var fields: [String: String]
    public var title: String { fields["title"] ?? "" }
    public var artist: String { fields["artist"] ?? "" }
    public var first: Double { Double(fields["first"] ?? "") ?? 0 }

    public init(text: String) {
        var f: [String: String] = [:]
        for (k, v) in SimaiParser.keyValues(text) { f[k.lowercased()] = v }
        fields = f
    }

    public func chartBody(_ d: Difficulty) -> String? {
        guard let b = fields["inote_\(d.rawValue)"], !b.isEmpty else { return nil }
        return b
    }

    public func level(_ d: Difficulty) -> String? { fields["lv_\(d.rawValue)"] }

    /// &first plus optional per-difficulty &first_N.
    public func firstOffset(_ d: Difficulty) -> Double {
        if let s = fields["first_\(d.rawValue)"], let v = Double(s) { return v }
        return first
    }
}
