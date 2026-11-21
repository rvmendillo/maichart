import Foundation

/// Builds AstroDX level folders / .adx archives (zip that contains the level folder).
/// Export never includes the internal WAV render: only maidata.txt, track.mp3 and the cover.
public enum LevelPackager {
    public struct Level {
        public var title: String
        public var maidata: Data
        public var track: Data
        public var trackExtension: String = "mp3"
        public var background: Data?
        public var backgroundExtension: String = "jpg"
        public var video: Data?

        public init(title: String, maidata: Data, track: Data, trackExtension: String = "mp3", background: Data? = nil,
                    backgroundExtension: String = "jpg", video: Data? = nil) {
            self.title = title
            self.maidata = maidata
            self.track = track
            self.trackExtension = trackExtension
            self.background = background
            self.backgroundExtension = backgroundExtension
            self.video = video
        }
    }

    /// File-system safe folder name (keeps Unicode letters, removes reserved characters).
    public static func folderName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}").union(.controlCharacters).union(.newlines)
        var s = title.components(separatedBy: bad).joined(separator: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        if s.isEmpty { s = "MaiChart Song" }
        return String(s.prefix(80))
    }

    public static func entries(_ level: Level) -> [ZipEntry] {
        let folder = folderName(level.title)
        var e = [ZipEntry(path: "\(folder)/maidata.txt", data: level.maidata),
                 ZipEntry(path: "\(folder)/track.\(level.trackExtension)", data: level.track)]
        if let bg = level.background { e.append(ZipEntry(path: "\(folder)/bg.\(level.backgroundExtension)", data: bg)) }
        if let v = level.video { e.append(ZipEntry(path: "\(folder)/pv.mp4", data: v)) }
        return e
    }

    /// `.adx` archive (zip containing the level folder) — open it with AstroDX or move it into the AstroDX folder.
    public static func adx(_ levels: [Level]) -> Data {
        ZipArchive.write(levels.flatMap { entries($0) })
    }

    /// Writes the plain level folder (for copying into AstroDX manually). Returns the folder URL.
    @discardableResult
    public static func writeFolder(_ level: Level, into directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent(folderName(level.title), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for e in entries(level) {
            let name = (e.path as NSString).lastPathComponent
            try e.data.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
        return folder
    }
}
