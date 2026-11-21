import Foundation
import MaiCore

struct SongProject: Codable, Identifiable, Hashable {
    enum Source: String, Codable {
        case audio, midi, musicXML, pdf
        /// An existing maimai chart (AstroDX / Majdata level folder or .adx) imported as-is.
        case chart

        var label: String {
            switch self {
            case .audio: return "Audio"
            case .midi: return "MIDI"
            case .musicXML: return "MusicXML"
            case .pdf: return "PDF score"
            case .chart: return "maimai chart"
            }
        }
        var icon: String {
            switch self {
            case .audio: return "waveform"
            case .midi: return "pianokeys"
            case .musicXML: return "music.note.list"
            case .pdf: return "doc.richtext"
            case .chart: return "square.stack.3d.up.fill"
            }
        }
    }

    var id: UUID = UUID()
    var title: String
    var artist: String
    var createdAt: Date = Date()
    var source: Source
    var sourceFile: String
    var trackFile: String = "track.mp3"
    var coverFile: String? = nil
    var bpm: Double = 120
    /// &first before the user's manual nudge (seconds).
    var baseFirst: Double = 0
    /// Manual sync adjustment written into &first (milliseconds; + = notes later).
    var userOffsetMs: Double = 0
    var gridConfidence: Double? = nil
    var melodySource: String? = nil
    var options: GeneratorOptions = GeneratorOptions()
    var levels: [String] = []
    var levelValues: [Double] = []
    var noteCounts: [Int] = []
    var alignment: AlignmentReport? = nil
    var trackShift: Double = 0
    /// True when track.mp3 is the user's own MP3 (bit-exact audio frames).
    var trackIsOriginal: Bool? = nil
    var instrumentProgram: Int? = nil
    var renderer: String = "MaiSynth"
    var soundFontName: String = "GeneralUser GS"
    var notesSummary: String = ""
    var durationSeconds: Double = 0
    /// Imported charts: the original level folder name (kept on export so AstroDX sees the same level).
    var levelFolderName: String? = nil
    /// Imported charts: fingerprint of the original maidata.txt (skips re-importing the same chart).
    var importSignature: String? = nil

    static func == (a: SongProject, b: SongProject) -> Bool { a.id == b.id && a.levels == b.levels && a.userOffsetMs == b.userOffsetMs && a.title == b.title && a.options == b.options }
    func hash(into h: inout Hasher) { h.combine(id) }

    var first: Double { baseFirst + userOffsetMs / 1000 }
    var hasCharts: Bool { levels.contains { !$0.isEmpty } }
    var isImportedChart: Bool { source == .chart }

    /// Whether this project has a chart for the difficulty (imported levels may skip some).
    func hasChart(_ d: Difficulty) -> Bool {
        let i = d.rawValue - 1
        return i < levels.count && !levels[i].isEmpty
    }
}

enum ProjectStore {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var exportRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("AstroDX Export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var soundFontsDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("SoundFonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Files › On My iPhone › MaiChart Studio › Import — anything dropped here is imported when the app opens,
    /// the same way AstroDX picks up files placed in its folder.
    static var importInbox: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Import", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let readme = dir.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path) {
            let text = """
            Put files here and MaiChart Studio adds them when it opens:

            • maimai charts: level folders (maidata.txt + track.mp3 or track.ogg + bg.jpg), folders of levels
              (for example a copy of AstroDX's "levels" folder), or .adx / .zip archives.
            • Songs to chart: MP3, M4A, WAV, FLAC, MIDI, MusicXML (.musicxml/.mxl) or PDF scores.

            Imported items are moved to the "Imported" folder (you can delete them there).
            Items that could not be imported are moved to "Failed".
            """
            try? Data(text.utf8).write(to: readme)
        }
        return dir
    }

    static func dir(_ id: UUID) -> URL {
        let d = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func file(_ p: SongProject, _ name: String) -> URL { dir(p.id).appendingPathComponent(name) }

    static func loadAll() -> [SongProject] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [SongProject] = []
        let dec = JSONDecoder()
        for d in items {
            let f = d.appendingPathComponent("project.json")
            if let data = try? Data(contentsOf: f), let p = try? dec.decode(SongProject.self, from: data) { out.append(p) }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    static func save(_ p: SongProject) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(p) { try? data.write(to: file(p, "project.json"), options: .atomic) }
    }

    static func delete(_ p: SongProject) { try? FileManager.default.removeItem(at: dir(p.id)) }

    static func saveFeatures(_ f: SongFeatures, for p: SongProject) {
        if let data = try? JSONEncoder().encode(f) { try? data.write(to: file(p, "features.json"), options: .atomic) }
    }

    static func loadFeatures(_ p: SongProject) -> SongFeatures? {
        guard let data = try? Data(contentsOf: file(p, "features.json")) else { return nil }
        return try? JSONDecoder().decode(SongFeatures.self, from: data)
    }

    static func maidataText(_ p: SongProject) -> String? {
        guard let d = try? Data(contentsOf: file(p, "maidata.txt")) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}

/// Persistent user preferences.
final class AppSettings: ObservableObject {
    @Published var noteSpeed: Double { didSet { save() } }
    @Published var touchSpeed: Double { didSet { save() } }
    /// Player-only calibration (ms): + shifts judgement/visuals later (does not change exports).
    @Published var playerOffsetMs: Double { didSet { save() } }
    @Published var hitSounds: Bool { didSet { save() } }
    @Published var showSensors: Bool { didSet { save() } }
    @Published var showGuides: Bool { didSet { save() } }
    @Published var musicVolume: Double { didSet { save() } }
    @Published var sfxVolume: Double { didSet { save() } }
    @Published var defaultRenderer: String { didSet { save() } }
    @Published var customSoundFont: String? { didSet { save() } }

    private let d = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        noteSpeed = d.object(forKey: "noteSpeed") as? Double ?? 7.0
        touchSpeed = d.object(forKey: "touchSpeed") as? Double ?? 6.5
        playerOffsetMs = d.object(forKey: "playerOffsetMs") as? Double ?? 0
        hitSounds = d.object(forKey: "hitSounds") as? Bool ?? true
        showSensors = d.object(forKey: "showSensors") as? Bool ?? false
        showGuides = d.object(forKey: "showGuides") as? Bool ?? true
        musicVolume = d.object(forKey: "musicVolume") as? Double ?? 0.9
        sfxVolume = d.object(forKey: "sfxVolume") as? Double ?? 0.6
        defaultRenderer = d.string(forKey: "defaultRenderer") ?? "MaiSynth"
        customSoundFont = d.string(forKey: "customSoundFont")
    }

    private func save() {
        d.set(noteSpeed, forKey: "noteSpeed")
        d.set(touchSpeed, forKey: "touchSpeed")
        d.set(playerOffsetMs, forKey: "playerOffsetMs")
        d.set(hitSounds, forKey: "hitSounds")
        d.set(showSensors, forKey: "showSensors")
        d.set(showGuides, forKey: "showGuides")
        d.set(musicVolume, forKey: "musicVolume")
        d.set(sfxVolume, forKey: "sfxVolume")
        d.set(defaultRenderer, forKey: "defaultRenderer")
        d.set(customSoundFont, forKey: "customSoundFont")
    }
}
