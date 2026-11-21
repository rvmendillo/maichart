import Foundation

/// maimai difficulties in simai numbering (&inote_N).
public enum Difficulty: Int, CaseIterable, Codable, Comparable, Identifiable {
    case easy = 1, basic, advanced, expert, master, remaster

    public var id: Int { rawValue }
    public static func < (a: Difficulty, b: Difficulty) -> Bool { a.rawValue < b.rawValue }

    public var displayName: String {
        switch self {
        case .easy: return "EASY"
        case .basic: return "BASIC"
        case .advanced: return "ADVANCED"
        case .expert: return "EXPERT"
        case .master: return "MASTER"
        case .remaster: return "Re:MASTER"
        }
    }

    /// RGB (0...1) theme colour matching the arcade convention.
    public var rgb: (Double, Double, Double) {
        switch self {
        case .easy: return (0.28, 0.65, 1.0)
        case .basic: return (0.30, 0.85, 0.36)
        case .advanced: return (1.0, 0.70, 0.12)
        case .expert: return (1.0, 0.33, 0.45)
        case .master: return (0.66, 0.34, 0.98)
        case .remaster: return (0.90, 0.82, 1.0)
        }
    }
}

/// Touch sensor areas of the DX cabinet. Index is 1...8 (C has no index).
public enum TouchArea: Hashable, Codable {
    case a(Int), b(Int), c, d(Int), e(Int)

    public var simai: String {
        switch self {
        case .a(let i): return "A\(i)"
        case .b(let i): return "B\(i)"
        case .c: return "C"
        case .d(let i): return "D\(i)"
        case .e(let i): return "E\(i)"
        }
    }

    public var index: Int {
        switch self {
        case .a(let i), .b(let i), .d(let i), .e(let i): return i
        case .c: return 0
        }
    }

    /// Angle in degrees, clockwise from 12 o'clock.
    public var angle: Double {
        switch self {
        case .a(let i), .b(let i): return Geometry.buttonAngle(i)
        case .d(let i), .e(let i): return Double(i - 1) * 45
        case .c: return 0
        }
    }

    /// Distance from the centre relative to the judgement ring radius (1.0).
    public var radius: Double {
        switch self {
        case .a: return 0.88
        case .b: return 0.48
        case .c: return 0
        case .d: return 0.92
        case .e: return 0.62
        }
    }

    public var isCenter: Bool { if case .c = self { return true } else { return false } }

    public static func parse(_ s: String) -> TouchArea? {
        guard let f = s.first else { return nil }
        let rest = s.dropFirst()
        if f == "C" { return rest.isEmpty || rest == "1" || rest == "2" ? .c : nil }
        guard let i = Int(rest), (1...8).contains(i) else { return nil }
        switch f {
        case "A": return .a(i)
        case "B": return .b(i)
        case "D": return .d(i)
        case "E": return .e(i)
        default: return nil
        }
    }

    /// The button (1...8) whose lane is closest to this area.
    public var nearestButton: Int {
        switch self {
        case .a(let i), .b(let i): return i
        case .d(let i), .e(let i): return i // D/E i sits between button i-1 and i; pick i
        case .c: return 1
        }
    }
}

public enum Geometry {
    /// Button 1 sits at 22.5° clockwise from the top, then every 45°.
    public static func buttonAngle(_ button: Int) -> Double { 22.5 + Double(button - 1) * 45 }

    /// Unit-circle position (x right, y down) of a button on the judgement ring.
    public static func buttonPoint(_ button: Int, radius: Double = 1) -> (x: Double, y: Double) {
        point(angle: buttonAngle(button), radius: radius)
    }

    public static func point(angle deg: Double, radius: Double) -> (x: Double, y: Double) {
        let a = deg * Double.pi / 180
        return (radius * sin(a), -radius * cos(a))
    }

    /// Normalises a button number into 1...8.
    @inline(__always) public static func wrap(_ b: Int) -> Int { ((b - 1) % 8 + 8) % 8 + 1 }

    /// Circular distance between two buttons (0...4).
    @inline(__always) public static func distance(_ a: Int, _ b: Int) -> Int {
        let d = abs(wrap(a) - wrap(b)) % 8
        return min(d, 8 - d)
    }

    /// Mirror across the vertical axis (1<->8, 2<->7, 3<->6, 4<->5).
    @inline(__always) public static func mirror(_ b: Int) -> Int { 9 - wrap(b) }

    /// Right-hand side (1-4) or left-hand side (5-8).
    @inline(__always) public static func isRightSide(_ b: Int) -> Bool { wrap(b) <= 4 }
}

/// One segment of a slide path, e.g. `-5` or `V35`.
public struct SlideSegment: Codable, Hashable {
    /// simai shape token: "-", ">", "<", "^", "v", "V", "p", "q", "pp", "qq", "s", "z", "w"
    public var shape: String
    public var vertices: [Int]

    public init(shape: String, vertices: [Int]) {
        self.shape = shape
        self.vertices = vertices
    }

    public var simai: String { shape + vertices.map(String.init).joined() }
    public var end: Int { vertices.last ?? 1 }
}

/// Chart time unit: 96 ticks per quarter-note beat (so 384 per 4/4 bar).
public let ticksPerBeat = 96

public struct ChartNote: Codable, Hashable {
    public enum Kind: Codable, Hashable {
        case tap(button: Int)
        case hold(button: Int, length: Int)
        case slide(button: Int, segments: [SlideSegment], duration: Int)
        case touch(area: TouchArea)
        case touchHold(area: TouchArea, length: Int)
    }

    public var tick: Int
    public var kind: Kind
    public var isBreak: Bool = false
    public var isEx: Bool = false
    public var firework: Bool = false

    public init(tick: Int, kind: Kind, isBreak: Bool = false, isEx: Bool = false, firework: Bool = false) {
        self.tick = tick
        self.kind = kind
        self.isBreak = isBreak
        self.isEx = isEx
        self.firework = firework
    }

    public var button: Int? {
        switch kind {
        case .tap(let b), .hold(let b, _), .slide(let b, _, _): return b
        default: return nil
        }
    }

    public var touchArea: TouchArea? {
        switch kind {
        case .touch(let a), .touchHold(let a, _): return a
        default: return nil
        }
    }

    /// Ticks during which a hand is busy with this note (holds/slides include their tail; slides include the 1-beat star wait).
    public var occupiedLength: Int {
        switch kind {
        case .hold(_, let l), .touchHold(_, let l): return l
        case .slide(_, _, let d): return ticksPerBeat + d
        default: return 0
        }
    }

    public var endTick: Int { tick + occupiedLength }

    public var isHoldLike: Bool {
        switch kind {
        case .hold, .touchHold: return true
        default: return false
        }
    }

    public var isSlide: Bool { if case .slide = kind { return true } else { return false } }
    public var isTouch: Bool { touchArea != nil }

    /// Angle used for hand assignment (degrees clockwise from top).
    public var angle: Double {
        if let b = button { return Geometry.buttonAngle(b) }
        if let a = touchArea { return a.isCenter ? -1 : a.angle }
        return 0
    }
}

public struct Chart: Codable {
    public var difficulty: Difficulty
    public var level: String          // e.g. "13+"
    public var levelValue: Double     // internal constant, e.g. 13.7
    public var designer: String
    public var notes: [ChartNote]

    public init(difficulty: Difficulty, level: String = "", levelValue: Double = 0, designer: String = "", notes: [ChartNote]) {
        self.difficulty = difficulty
        self.level = level
        self.levelValue = levelValue
        self.designer = designer
        self.notes = notes.sorted { $0.tick < $1.tick }
    }

    public var noteCount: Int {
        notes.reduce(0) { acc, n in
            if case .slide = n.kind { return acc + 2 } // star tap + slide
            return acc + 1
        }
    }
}

/// Song-level timing used when writing charts.
public struct ChartTiming: Codable {
    /// Tempo map whose beat 0 is the chart start (simai time 0).
    public var tempo: TempoMap
    /// Seconds into the audio at which chart time 0 occurs (&first).
    public var first: Double { tempo.offset }
    public var timeSignatures: [TimeSignature]
    public var endBeat: Double

    public init(tempo: TempoMap, timeSignatures: [TimeSignature] = [], endBeat: Double) {
        self.tempo = tempo
        self.timeSignatures = timeSignatures
        self.endBeat = endBeat
    }
}
