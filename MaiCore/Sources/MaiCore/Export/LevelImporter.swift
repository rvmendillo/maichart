import Foundation

/// What was found in one maimai level folder (AstroDX / Majdata layout: maidata.txt + track + bg [+ pv.mp4]).
public struct LevelInfo {
    /// Level folder name (or the archive name when maidata.txt sits at the archive root).
    public var name: String
    public var maidataText: String
    public var maidata: MaidataFile
    /// File names directly inside the level folder.
    public var fileNames: [String]
    public var trackFile: String?
    public var backgroundFile: String?
    public var videoFile: String?
    /// Standard difficulties (EASY…Re:MASTER) that have a chart.
    public var difficulties: [Difficulty]
    /// Other chart slots present (e.g. 7 = UTAGE / original), kept untouched on export.
    public var extraChartSlots: [Int]

    public var title: String {
        let t = maidata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? name : t
    }
    public var artist: String { maidata.artist.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum LevelImportError: Error, CustomStringConvertible {
    case noLevels(String)
    case noTrack(String)
    case noCharts(String)

    public var description: String {
        switch self {
        case .noLevels(let n):
            return "No maimai chart was found in “\(n)”. A chart folder contains maidata.txt and track.mp3 (or track.ogg); a .adx/.zip contains one or more such folders."
        case .noTrack(let n):
            return "“\(n)” has a maidata.txt but no track.mp3 / track.ogg audio file."
        case .noCharts(let n):
            return "“\(n)” has a maidata.txt without any &inote_ chart."
        }
    }
}

public enum LevelImporter {
    static let audioExtensions = ["mp3", "ogg", "wav", "m4a", "aac", "flac", "aif", "aiff"]
    static let imageExtensions = ["jpg", "jpeg", "png", "webp", "bmp"]

    /// Decodes maidata.txt bytes: UTF-8 (with or without BOM), UTF-16 with BOM, then Shift-JIS, then Latin-1.
    public static func decodeText(_ data: Data) -> String {
        let b = [UInt8](data.prefix(3))
        if b.count >= 2, (b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF),
           let s = String(data: data, encoding: .utf16) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) { return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
        if let s = String(data: data, encoding: .shiftJIS) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// Picks the audio, background and video files the way AstroDX names them, with lenient fallbacks.
    public static func inspect(name: String, fileNames: [String], maidataData: Data) -> LevelInfo {
        let text = decodeText(maidataData)
        let m = MaidataFile(text: text)
        func ext(_ f: String) -> String { (f as NSString).pathExtension.lowercased() }
        func base(_ f: String) -> String { ((f as NSString).deletingPathExtension).lowercased() }
        let audio = fileNames.filter { audioExtensions.contains(ext($0)) }
        let track = audio.filter { base($0) == "track" }.sorted { rank(ext($0)) < rank(ext($1)) }.first
            ?? audio.sorted { rank(ext($0)) < rank(ext($1)) }.first
        let images = fileNames.filter { imageExtensions.contains(ext($0)) }
        let bg = images.first { base($0) == "bg" } ?? images.first { ["cover", "jacket", "bg_"].contains(base($0)) } ?? images.first
        let video = fileNames.first { $0.lowercased() == "pv.mp4" } ?? fileNames.first { $0.lowercased() == "mv.mp4" }
            ?? fileNames.first { ext($0) == "mp4" }
        let diffs = Difficulty.allCases.filter { m.chartBody($0) != nil }
        var extra: [Int] = []
        for (k, v) in m.fields where k.hasPrefix("inote_") && !v.isEmpty {
            if let n = Int(k.dropFirst(6)), !(1...6).contains(n) { extra.append(n) }
        }
        return LevelInfo(name: name, maidataText: text, maidata: m, fileNames: fileNames.sorted(), trackFile: track,
                         backgroundFile: bg, videoFile: video, difficulties: diffs, extraChartSlots: extra.sorted())
    }

    static func rank(_ ext: String) -> Int { audioExtensions.firstIndex(of: ext) ?? 99 }

    static func isJunk(_ component: String) -> Bool {
        component == "__MACOSX" || component.hasPrefix("._") || component == ".DS_Store" || component == "Thumbs.db"
    }

    /// Every level inside a .adx / .zip archive: each directory that directly contains maidata.txt.
    /// Returns the level info plus its files (name → bytes).
    public static func levels(inArchive data: Data, archiveName: String) throws -> [(info: LevelInfo, files: [String: Data])] {
        let entries = try ZipArchive.read(data)
        var byDir: [String: [String: Data]] = [:]
        for e in entries {
            let path = e.path.replacingOccurrences(of: "\\", with: "/")
            if path.hasSuffix("/") { continue }
            var comps = path.split(separator: "/").map(String.init)
            if comps.isEmpty || comps.contains(where: isJunk) { continue }
            let file = comps.removeLast()
            byDir[comps.joined(separator: "/"), default: [:]][file] = e.data
        }
        let fallbackName = (archiveName as NSString).deletingPathExtension
        var out: [(LevelInfo, [String: Data])] = []
        for dir in byDir.keys.sorted() {
            let files = byDir[dir]!
            guard let maidataName = files.keys.first(where: { $0.lowercased() == "maidata.txt" }) else { continue }
            let name = dir.isEmpty ? fallbackName : String(dir.split(separator: "/").last!)
            let info = inspect(name: name, fileNames: Array(files.keys), maidataData: files[maidataName]!)
            out.append((info, files))
        }
        if out.isEmpty { throw LevelImportError.noLevels(archiveName) }
        return out
    }

    /// Level folders on disk below `root` (the root itself when it holds maidata.txt), sorted by path.
    public static func levelDirectories(in root: URL, maxDepth: Int = 4) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        func visit(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            if items.contains(where: { $0.lastPathComponent.lowercased() == "maidata.txt" }) {
                found.append(dir)
                return
            }
            guard depth < maxDepth else { return }
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !isJunk(item.lastPathComponent) {
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { visit(item, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return found
    }

    /// Reads maidata.txt and the file list of a level folder on disk (audio/video are not loaded).
    public static func inspect(directory: URL) throws -> LevelInfo {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let files = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true && !isJunk($0.lastPathComponent) }
        guard let maidata = files.first(where: { $0.lastPathComponent.lowercased() == "maidata.txt" }) else {
            throw LevelImportError.noLevels(directory.lastPathComponent)
        }
        return inspect(name: directory.lastPathComponent, fileNames: files.map { $0.lastPathComponent }, maidataData: try Data(contentsOf: maidata))
    }

    /// Checks that a level can be played: it needs an audio track and at least one chart.
    public static func validate(_ info: LevelInfo) throws {
        guard info.trackFile != nil else { throw LevelImportError.noTrack(info.name) }
        guard !info.difficulties.isEmpty || !info.extraChartSlots.isEmpty else { throw LevelImportError.noCharts(info.name) }
    }
}

/// Small, careful edits to an existing maidata.txt (everything else stays byte-for-byte the same).
public enum MaidataEditor {
    /// Sets `&key=value`, replacing the existing line or inserting it after the &artist/&title line.
    public static func setting(_ key: String, to value: String, in text: String) -> String {
        let hadBOM = text.hasPrefix("\u{FEFF}")
        let body = hadBOM ? String(text.dropFirst()) : text
        let newline = body.contains("\r\n") ? "\r\n" : "\n"
        var lines = body.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).map(String.init)
        let prefix = "&\(key)="
        if let i = lines.firstIndex(where: { $0.lowercased().hasPrefix(prefix.lowercased()) }) {
            lines[i] = prefix + value
        } else {
            let anchor = lines.lastIndex(where: { $0.lowercased().hasPrefix("&artist=") }) ?? lines.lastIndex(where: { $0.lowercased().hasPrefix("&title=") })
            lines.insert(prefix + value, at: anchor.map { $0 + 1 } ?? 0)
        }
        return (hadBOM ? "\u{FEFF}" : "") + lines.joined(separator: newline)
    }

    /// Formats seconds for &first (up to 4 decimals, no trailing zeros).
    public static func formatSeconds(_ v: Double) -> String {
        var s = String(format: "%.4f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s == "-0" ? "0" : s
    }
}
