import Foundation
import MaiCore

/// Imports existing maimai charts — AstroDX / Majdata level folders (maidata.txt + track.mp3/ogg + bg),
/// folders of levels, and .adx / .zip archives — as projects that can be played, nudged and exported again.
enum ChartImport {
    struct Outcome {
        var projects: [SongProject] = []
        var duplicates: [String] = []
        var problems: [String] = []

        mutating func merge(_ o: Outcome) {
            projects += o.projects; duplicates += o.duplicates; problems += o.problems
        }

        var summary: String {
            var parts: [String] = []
            if !projects.isEmpty {
                parts.append(projects.count == 1 ? "Added “\(projects[0].title)”." : "Added \(projects.count) charts.")
            }
            if !duplicates.isEmpty {
                parts.append("Already in your library: \(duplicates.prefix(5).joined(separator: ", "))\(duplicates.count > 5 ? "…" : "").")
            }
            if !problems.isEmpty {
                parts.append("Not imported:\n• " + problems.prefix(6).joined(separator: "\n• ") + (problems.count > 6 ? "\n• …" : ""))
            }
            return parts.isEmpty ? "Nothing to import." : parts.joined(separator: "\n\n")
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Folders and .adx/.zip archives are chart sources; everything else is a song to chart.
    static func isChartItem(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "adx" || ext == "zip" || isDirectory(url)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return "\(error)"
    }

    // MARK: Import

    /// Imports every level found in the given folders / archives (security-scoped URLs are handled here).
    /// Runs off the main thread.
    static func importItems(_ urls: [URL], existing: [SongProject], progress: @escaping Pipeline.Progress) -> Outcome {
        var out = Outcome()
        var known = existing
        let total = Double(max(1, urls.count))
        for (k, url) in urls.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let base = Double(k) / total
            progress("Reading \(url.lastPathComponent)", base * 0.98)
            do {
                if isDirectory(url) {
                    let dirs = LevelImporter.levelDirectories(in: url)
                    if dirs.isEmpty {
                        if requestCloudDownloads(in: url) {
                            throw AppError.message("“\(url.lastPathComponent)” is still downloading from iCloud. Wait a moment and import it again.")
                        }
                        throw LevelImportError.noLevels(url.lastPathComponent)
                    }
                    for (j, d) in dirs.enumerated() {
                        progress("Importing \(d.lastPathComponent)", (base + Double(j) / Double(dirs.count) / total) * 0.98)
                        do {
                            let info = try LevelImporter.inspect(directory: d)
                            let names = info.fileNames
                            if let p = try importLevel(info: info, known: known, write: { dest in
                                for name in names { try coordinatedCopy(d.appendingPathComponent(name), to: dest.appendingPathComponent(name)) }
                            }) {
                                out.projects.append(p); known.append(p)
                            } else {
                                out.duplicates.append(info.title)
                            }
                        } catch {
                            out.problems.append("\(d.lastPathComponent): \(describe(error))")
                        }
                    }
                } else {
                    let data = try coordinatedData(url)
                    let ext = url.pathExtension.lowercased()
                    guard ext == "adx" || ext == "zip" || data.starts(with: [0x50, 0x4B, 0x03, 0x04]) else {
                        if url.lastPathComponent.lowercased() == "maidata.txt" {
                            throw AppError.message("Pick the folder that contains maidata.txt (together with its track.mp3 / track.ogg), or a .adx / .zip archive.")
                        }
                        throw AppError.message("This is not a chart folder or a .adx / .zip archive.")
                    }
                    let levels = try LevelImporter.levels(inArchive: data, archiveName: url.lastPathComponent)
                    for (j, lv) in levels.enumerated() {
                        progress("Importing \(lv.info.name)", (base + Double(j) / Double(levels.count) / total) * 0.98)
                        do {
                            let files = lv.files
                            if let p = try importLevel(info: lv.info, known: known, write: { dest in
                                for (name, bytes) in files { try bytes.write(to: dest.appendingPathComponent(name), options: .atomic) }
                            }) {
                                out.projects.append(p); known.append(p)
                            } else {
                                out.duplicates.append(lv.info.title)
                            }
                        } catch {
                            out.problems.append("\(lv.info.name): \(describe(error))")
                        }
                    }
                }
            } catch {
                out.problems.append("\(url.lastPathComponent): \(describe(error))")
            }
        }
        progress("Done", 1)
        return out
    }

    /// Creates the project for one level. Returns nil when the same chart is already in the library.
    static func importLevel(info: LevelInfo, known: [SongProject], write: (URL) throws -> Void) throws -> SongProject? {
        try LevelImporter.validate(info)
        let signature = fingerprint(info.maidataText)
        if known.contains(where: { $0.source == .chart && $0.importSignature == signature }) { return nil }
        var p = SongProject(title: info.title, artist: info.artist, source: .chart, sourceFile: "level")
        p.levelFolderName = info.name
        p.importSignature = signature
        let levelDir = ProjectStore.dir(p.id).appendingPathComponent("level", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: levelDir, withIntermediateDirectories: true)
            try write(levelDir)
            try finalize(&p, info: info, levelDir: levelDir)
            ProjectStore.save(p)
            return p
        } catch {
            ProjectStore.delete(p)
            throw error
        }
    }

    static func finalize(_ p: inout SongProject, info: LevelInfo, levelDir: URL) throws {
        guard let track = info.trackFile else { throw LevelImportError.noTrack(info.name) }
        guard FileManager.default.fileExists(atPath: levelDir.appendingPathComponent(track).path) else { throw LevelImportError.noTrack(info.name) }
        p.trackFile = "level/" + track
        p.coverFile = info.backgroundFile.map { "level/" + $0 }
        // working copy: the sync nudge edits this one, level/maidata.txt stays the original
        let maidataName = info.fileNames.first { $0.lowercased() == "maidata.txt" } ?? "maidata.txt"
        let working = ProjectStore.file(p, "maidata.txt")
        try? FileManager.default.removeItem(at: working)
        try FileManager.default.copyItem(at: levelDir.appendingPathComponent(maidataName), to: working)
        p.baseFirst = info.maidata.first
        p.userOffsetMs = 0
        var levels: [String] = [], values: [Double] = [], counts: [Int] = []
        var longest = 0.0
        var bpm = Double(info.maidata.fields["wholebpm"] ?? "")
        var unreadable: [String] = []
        for d in Difficulty.allCases {
            guard let body = info.maidata.chartBody(d) else { levels.append(""); values.append(0); counts.append(0); continue }
            let lv = (info.maidata.level(d) ?? "").trimmingCharacters(in: .whitespaces)
            levels.append(lv.isEmpty ? "?" : lv)
            values.append(levelValue(lv))
            if let c = try? SimaiParser.parse(body) {
                counts.append(c.objectCount)
                longest = max(longest, c.finishTime)
                if bpm == nil { bpm = c.bpmChanges.first?.bpm }
            } else {
                counts.append(0)
                unreadable.append(d.displayName)
            }
        }
        p.levels = levels
        p.levelValues = values
        p.noteCounts = counts
        p.bpm = bpm ?? 120
        p.durationSeconds = longest
        var summary = "Imported maimai chart · " + Difficulty.allCases.filter { info.maidata.chartBody($0) != nil }.map { $0.displayName }.joined(separator: ", ")
        if info.extraChartSlots.contains(7) { summary += " + UTAGE" }
        let designers = Set(Difficulty.allCases.compactMap { info.maidata.fields["des_\($0.rawValue)"] } + [info.maidata.fields["des"]].compactMap { $0 })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.sorted()
        if !designers.isEmpty { summary += " · by " + designers.prefix(3).joined(separator: ", ") }
        if !unreadable.isEmpty { summary += " · ⚠︎ the built-in player can't read \(unreadable.joined(separator: ", "))" }
        p.notesSummary = summary
    }

    /// "13+" → 13.7, "13" → 13.0, "12.8" → 12.8, anything else → 0.
    static func levelValue(_ s: String) -> Double {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("+"), let v = Double(t.dropLast()) { return v + 0.7 }
        return Double(t) ?? 0
    }

    /// Stable content fingerprint (FNV-1a 64) used to skip charts that are already imported.
    static func fingerprint(_ text: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in text.utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01B3 }
        return String(h, radix: 16)
    }

    // MARK: Sync nudge and export

    /// Writes the nudged &first into the working maidata.txt (restores the original bytes when the nudge is 0).
    static func applyOffset(_ p: inout SongProject) throws {
        let working = ProjectStore.file(p, "maidata.txt")
        let levelDir = ProjectStore.dir(p.id).appendingPathComponent("level")
        let originalName = ((try? FileManager.default.contentsOfDirectory(atPath: levelDir.path)) ?? []).first { $0.lowercased() == "maidata.txt" }
        if p.userOffsetMs == 0, let o = originalName {
            try? FileManager.default.removeItem(at: working)
            try FileManager.default.copyItem(at: levelDir.appendingPathComponent(o), to: working)
            return
        }
        let text = LevelImporter.decodeText(try Data(contentsOf: working))
        let edited = MaidataEditor.setting("first", to: MaidataEditor.formatSeconds(p.first), in: text)
        try Data(edited.utf8).write(to: working, options: .atomic)
    }

    /// The level as AstroDX expects it: original folder name and files, track/bg renamed to track.* / bg.*.
    static func level(_ p: SongProject) throws -> LevelPackager.Level {
        let levelDir = ProjectStore.dir(p.id).appendingPathComponent("level")
        let md = try Data(contentsOf: ProjectStore.file(p, "maidata.txt"))
        let trackURL = ProjectStore.file(p, p.trackFile)
        let track = try Data(contentsOf: trackURL)
        var bg: Data? = nil
        var bgExt = "jpg"
        if let c = p.coverFile {
            let u = ProjectStore.file(p, c)
            bg = try? Data(contentsOf: u)
            bgExt = u.pathExtension.lowercased()
        }
        var video: Data? = nil
        var extras: [String: Data] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: levelDir.path)) ?? [] {
            let rel = "level/" + name
            if name.lowercased() == "maidata.txt" || rel == p.trackFile || rel == p.coverFile || name.hasPrefix(".") { continue }
            let url = levelDir.appendingPathComponent(name)
            if ChartImport.isDirectory(url) { continue }
            if name.lowercased() == "pv.mp4" { video = try? Data(contentsOf: url); continue }
            if let d = try? Data(contentsOf: url) { extras[name] = d }
        }
        return LevelPackager.Level(title: p.title, maidata: md, track: track, trackExtension: trackURL.pathExtension.lowercased(),
                                   background: bg, backgroundExtension: bgExt, video: video, folder: p.levelFolderName, extraFiles: extras)
    }

    // MARK: Import folder (AstroDX-style drop folder)

    /// Items waiting in Files › MaiChart Studio › Import.
    static func inboxItems() -> [URL] {
        let inbox = ProjectStore.importInbox
        let skip: Set<String> = ["readme.txt", "imported", "failed"]
        let items = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter { !skip.contains($0.lastPathComponent.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Moves a processed inbox item into Import/Imported or Import/Failed.
    static func archiveInboxItem(_ url: URL, failed: Bool) {
        let fm = FileManager.default
        let dest = ProjectStore.importInbox.appendingPathComponent(failed ? "Failed" : "Imported", isDirectory: true)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var target = dest.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            let base = (url.lastPathComponent as NSString).deletingPathExtension, ext = url.pathExtension
            target = dest.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        try? fm.moveItem(at: url, to: target)
    }

    // MARK: File access helpers

    static func coordinatedData(_ url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(AppError.message("Could not read \(url.lastPathComponent)."))
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            result = Result { try Data(contentsOf: u) }
        }
        if let e = coordError { throw e }
        return try result.get()
    }

    static func coordinatedCopy(_ src: URL, to dst: URL) throws {
        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [], error: &coordError) { u in
            do {
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: u, to: dst)
            } catch { failure = error }
        }
        if let e = coordError ?? failure { throw e }
    }

    /// iOS 16 iCloud placeholders (".name.icloud"): asks iCloud to download them. Returns true if any were found.
    static func requestCloudDownloads(in root: URL) -> Bool {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
        var found = false
        for case let u as URL in e where u.lastPathComponent.hasPrefix(".") && u.lastPathComponent.hasSuffix(".icloud") {
            var name = u.lastPathComponent
            name.removeFirst()
            name = String(name.dropLast(".icloud".count))
            try? FileManager.default.startDownloadingUbiquitousItem(at: u.deletingLastPathComponent().appendingPathComponent(name))
            found = true
        }
        return found
    }
}
