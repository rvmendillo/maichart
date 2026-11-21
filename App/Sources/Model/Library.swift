import Foundation
import SwiftUI
import MaiCore

struct JobState: Equatable {
    var title: String
    var stage: String
    var progress: Double
}

/// A non-error message shown in the app's own panel (visible above sheets).
struct Notice: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var text: String
}

@MainActor
final class Library: ObservableObject {
    @Published var projects: [SongProject] = []
    @Published var job: JobState? = nil
    @Published var errorMessage: String? = nil
    @Published var notice: Notice? = nil
    /// A project the UI should open (after an import started outside the home screen).
    @Published var openRequest: SongProject? = nil
    let settings: AppSettings
    private var scanningInbox = false

    init(settings: AppSettings) {
        self.settings = settings
        projects = ProjectStore.loadAll()
    }

    func reload() { projects = ProjectStore.loadAll() }

    var renderSettings: RenderSettings {
        RenderSettings(renderer: settings.defaultRenderer, customSoundFont: settings.customSoundFont, instrumentProgram: nil)
    }

    var isBusy: Bool { job != nil }

    /// Runs heavy work off the main thread while the progress panel is shown.
    private func perform<T>(_ title: String, _ work: @escaping (@escaping Pipeline.Progress) throws -> T) async -> Result<T, Error> {
        job = JobState(title: title, stage: "Starting", progress: 0)
        let progress: Pipeline.Progress = { stage, f in
            Task { @MainActor [weak self] in
                guard let self, self.job != nil else { return }
                self.job = JobState(title: title, stage: stage, progress: max(self.job?.progress ?? 0, f))
            }
        }
        let result: Result<T, Error> = await Task.detached(priority: .userInitiated) {
            do { return .success(try work(progress)) } catch { return .failure(error) }
        }.value
        job = nil
        return result
    }

    private func run(_ title: String, _ work: @escaping (@escaping Pipeline.Progress) throws -> SongProject?) async -> SongProject? {
        guard !isBusy else { notice = Notice(title: "Please wait", text: "Another import is still running."); return nil }
        switch await perform(title, work) {
        case .success(let p):
            reload()
            return p
        case .failure(let e):
            errorMessage = ChartImport.describe(e)
            return nil
        }
    }

    /// Imports a picked file (security scoped) and builds the full chart family.
    func importFile(_ url: URL, metadata override: AudioIO.Metadata? = nil) async -> SongProject? {
        guard !isBusy else { notice = Notice(title: "Please wait", text: "Another import is still running."); return nil }
        job = JobState(title: "Opening \(url.lastPathComponent)", stage: "Reading the file", progress: 0.01)
        let scoped = url.startAccessingSecurityScopedResource()
        // copy first so the security scope can end early (coordinated: downloads iCloud files if needed).
        // A unique folder keeps the original file name, which becomes the title when the file has no tags.
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmp = tmpDir.appendingPathComponent(url.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let copied: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            Result { try ChartImport.coordinatedCopy(url, to: tmp) }
        }.value
        if scoped { url.stopAccessingSecurityScopedResource() }
        job = nil
        if case .failure(let e) = copied {
            errorMessage = "Could not read the file: \(ChartImport.describe(e))"
            return nil
        }
        guard Pipeline.kind(of: tmp) != nil else {
            errorMessage = "Unsupported file type .\(url.pathExtension). Use MP3/M4A/WAV/OGG/FLAC, MIDI, MusicXML (.musicxml/.xml/.mxl) or a PDF score. For maimai charts use “maimai chart”."
            return nil
        }
        let meta: AudioIO.Metadata
        if let o = override { meta = o } else { meta = await AudioIO.metadata(url: tmp) }
        let render = renderSettings
        let result = await run("Creating charts for \(meta.title ?? url.deletingPathExtension().lastPathComponent)") { progress in
            try Pipeline.createProject(from: tmp, metadata: meta, render: render, progress: progress)
        }
        return result
    }

    /// Imports existing maimai charts from folders / .adx / .zip archives.
    func importCharts(_ urls: [URL]) async -> [SongProject] {
        guard !isBusy else { notice = Notice(title: "Please wait", text: "Another import is still running."); return [] }
        let existing = projects
        let result = await perform(urls.count == 1 ? "Importing \(urls[0].lastPathComponent)" : "Importing \(urls.count) items") { progress in
            ChartImport.importItems(urls, existing: existing, progress: progress)
        }
        reload()
        guard case .success(let outcome) = result else { return [] }
        if outcome.projects.count != 1 || !outcome.problems.isEmpty || !outcome.duplicates.isEmpty {
            if outcome.projects.isEmpty && outcome.duplicates.isEmpty {
                errorMessage = outcome.summary
            } else {
                notice = Notice(title: "maimai charts", text: outcome.summary)
            }
        }
        return outcome.projects
    }

    /// Imports everything waiting in Files › MaiChart Studio › Import (like AstroDX's folder).
    func scanInbox() async {
        guard !isBusy, !scanningInbox else { return }
        let items = ChartImport.inboxItems()
        guard !items.isEmpty else { return }
        scanningInbox = true
        defer { scanningInbox = false }
        var total = ChartImport.Outcome()
        for item in items {
            if ChartImport.isChartItem(item) {
                let existing = projects
                let r = await perform("Import folder: \(item.lastPathComponent)") { progress in
                    ChartImport.importItems([item], existing: existing, progress: progress)
                }
                let o = (try? r.get()) ?? ChartImport.Outcome(problems: ["\(item.lastPathComponent): import failed"])
                total.merge(o)
                ChartImport.archiveInboxItem(item, failed: o.projects.isEmpty && o.duplicates.isEmpty)
            } else if Pipeline.kind(of: item) != nil {
                let meta = await AudioIO.metadata(url: item)
                let render = renderSettings
                let r = await perform("Import folder: \(item.lastPathComponent)") { progress in
                    try Pipeline.createProject(from: item, metadata: meta, render: render, progress: progress)
                }
                switch r {
                case .success(let p): total.projects.append(p)
                case .failure(let e): total.problems.append("\(item.lastPathComponent): \(ChartImport.describe(e))")
                }
                ChartImport.archiveInboxItem(item, failed: (try? r.get()) == nil)
            } else {
                total.problems.append("\(item.lastPathComponent): not a song, score, chart folder or .adx / .zip")
                ChartImport.archiveInboxItem(item, failed: true)
            }
        }
        reload()
        notice = Notice(title: "Import folder", text: total.summary)
        if total.projects.count == 1 { openRequest = total.projects[0] }
    }

    /// Files opened with MaiChart Studio from the Files app or the share sheet.
    func openIncoming(_ url: URL) async {
        if url.pathExtension.lowercased() == "sf2" {
            installSoundFont(url)
            return
        }
        if ChartImport.isChartItem(url) {
            let ps = await importCharts([url])
            if ps.count == 1 { openRequest = ps[0] }
        } else if let p = await importFile(url) {
            openRequest = p
        }
    }

    /// Copies a .sf2 into Documents/SoundFonts and makes it the default instrument set.
    func installSoundFont(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = ProjectStore.soundFontsDir.appendingPathComponent(url.lastPathComponent)
        do {
            if dest.standardizedFileURL != url.standardizedFileURL { try ChartImport.coordinatedCopy(url, to: dest) }
            _ = try SoundFont(url: dest) // validate
            settings.customSoundFont = dest.lastPathComponent
            notice = Notice(title: "SoundFont installed", text: "\(url.lastPathComponent) is now used for MIDI / score rendering and Piano Tiles.")
        } catch {
            try? FileManager.default.removeItem(at: dest)
            errorMessage = "This SoundFont could not be loaded: \(ChartImport.describe(error))"
        }
    }

    /// Runs MaiChart Studio's own analysis on an imported chart's song and creates a new project with fresh charts.
    func chartAudio(of p: SongProject) async -> SongProject? {
        let track = ProjectStore.file(p, p.trackFile)
        let art = p.coverFile.flatMap { try? Data(contentsOf: ProjectStore.file(p, $0)) }
        return await importFile(track, metadata: AudioIO.Metadata(title: p.title, artist: p.artist, artwork: art))
    }

    func importLink(_ text: String) async -> SongProject? {
        guard !isBusy else { notice = Notice(title: "Please wait", text: "Another import is still running."); return nil }
        job = JobState(title: "Downloading", stage: text, progress: 0.01)
        do {
            let file = try await LinkImporter.download(text)
            job = nil
            return await importFile(file)
        } catch {
            job = nil
            errorMessage = ChartImport.describe(error)
            return nil
        }
    }

    func createDemo() async -> SongProject? {
        let render = renderSettings
        return await run("Building demo song") { progress in try Pipeline.createDemo(render: render, progress: progress) }
    }

    func update(_ p: SongProject) {
        ProjectStore.save(p)
        if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p } else { reload() }
    }

    func regenerate(_ project: SongProject) async -> SongProject? {
        await run(project.isImportedChart ? "Updating &first" : "Regenerating charts") { _ in
            var p = project
            try Pipeline.regenerate(&p)
            return p
        }
    }

    func remix(_ project: SongProject) async -> SongProject? {
        var p = project
        p.options.seed = UInt64.random(in: 1...UInt64(Int32.max))
        return await regenerate(p)
    }

    func rerender(_ project: SongProject, renderer: String, program: Int?) async -> SongProject? {
        var render = renderSettings
        render.renderer = renderer
        render.instrumentProgram = program
        return await run("Rendering audio") { progress in
            var p = project
            try Pipeline.rerender(&p, render: render, progress: progress)
            return p
        }
    }

    func delete(_ p: SongProject) {
        ProjectStore.delete(p)
        reload()
    }

    func exportADX(_ p: SongProject) -> URL? {
        do { return try Pipeline.exportADX(p) } catch { errorMessage = ChartImport.describe(error); return nil }
    }

    func exportFolder(_ p: SongProject) -> URL? {
        do { return try Pipeline.exportFolder(p) } catch { errorMessage = ChartImport.describe(error); return nil }
    }
}
