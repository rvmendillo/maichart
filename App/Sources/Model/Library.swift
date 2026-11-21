import Foundation
import SwiftUI
import MaiCore

struct JobState: Equatable {
    var title: String
    var stage: String
    var progress: Double
}

@MainActor
final class Library: ObservableObject {
    @Published var projects: [SongProject] = []
    @Published var job: JobState? = nil
    @Published var errorMessage: String? = nil
    let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        projects = ProjectStore.loadAll()
    }

    func reload() { projects = ProjectStore.loadAll() }

    var renderSettings: RenderSettings {
        RenderSettings(renderer: settings.defaultRenderer, customSoundFont: settings.customSoundFont, instrumentProgram: nil)
    }

    private func run(_ title: String, _ work: @escaping (@escaping Pipeline.Progress) throws -> SongProject?) async -> SongProject? {
        job = JobState(title: title, stage: "Starting", progress: 0)
        let progress: Pipeline.Progress = { stage, f in
            Task { @MainActor [weak self] in
                guard let self, self.job != nil else { return }
                self.job = JobState(title: title, stage: stage, progress: max(self.job?.progress ?? 0, f))
            }
        }
        let result: Result<SongProject?, Error> = await Task.detached(priority: .userInitiated) {
            do { return .success(try work(progress)) } catch { return .failure(error) }
        }.value
        job = nil
        switch result {
        case .success(let p):
            reload()
            return p
        case .failure(let e):
            errorMessage = e.localizedDescription
            return nil
        }
    }

    /// Imports a picked file (security scoped) and builds the full chart family.
    func importFile(_ url: URL) async -> SongProject? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // copy first so the security scope can end early
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.copyItem(at: url, to: tmp)
        } catch {
            errorMessage = "Could not read the file: \(error.localizedDescription)"
            return nil
        }
        let meta = await AudioIO.metadata(url: tmp)
        let render = renderSettings
        let result = await run("Creating charts for \(url.deletingPathExtension().lastPathComponent)") { progress in
            try Pipeline.createProject(from: tmp, metadata: meta, render: render, progress: progress)
        }
        try? FileManager.default.removeItem(at: tmp)
        return result
    }

    func importLink(_ text: String) async -> SongProject? {
        job = JobState(title: "Downloading", stage: text, progress: 0.01)
        do {
            let file = try await LinkImporter.download(text)
            job = nil
            return await importFile(file)
        } catch {
            job = nil
            errorMessage = error.localizedDescription
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
        await run("Regenerating charts") { _ in
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
        do { return try Pipeline.exportADX(p) } catch { errorMessage = error.localizedDescription; return nil }
    }

    func exportFolder(_ p: SongProject) -> URL? {
        do { return try Pipeline.exportFolder(p) } catch { errorMessage = error.localizedDescription; return nil }
    }
}
