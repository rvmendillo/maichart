import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MaiCore

/// What the user chose in the New chart sheet. The sheet closes first; the picker or job starts afterwards
/// from the home screen, so progress and errors are never hidden behind the sheet.
enum ImportRequest: Equatable {
    case song, chart, chartFolder, link(String), demo
    /// Used by automated screenshots: import a file without the system picker.
    case file(URL)
}

struct HomeView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: AppSettings
    @State private var showImport = false
    @State private var showSettings = false
    @State private var path: [SongProject] = []
    @State private var pendingRequest: ImportRequest? = nil
    @State private var pickerKind: ImportRequest = .song
    @State private var showPicker = false
    @State private var showCopyPicker = false
    var initialScreen: String? = nil

    let columns = [GridItem(.adaptive(minimum: 300), spacing: 14)]

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                MaiBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        hero
                        if library.projects.isEmpty {
                            emptyState
                        } else {
                            SectionHeader(title: "My charts (\(library.projects.count))", icon: "square.grid.2x2.fill")
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(library.projects) { p in
                                    NavigationLink(value: p) { ProjectCard(project: p) }.buttonStyle(.plain)
                                }
                            }
                        }
                        inboxHint
                    }
                    .padding(16)
                }
                // folders can only be opened in place; files are picked as local copies (below)
                .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                    handlePicked(result)
                }
                .sheet(isPresented: $showCopyPicker) {
                    CopyingDocumentPicker(types: pickerKind == .chart ? ImportSheet.chartTypes : ImportSheet.songTypes,
                                          multiple: pickerKind == .chart) { urls in
                        showCopyPicker = false
                        handlePicked(.success(urls))
                    }
                    .ignoresSafeArea()
                }
            }
            .navigationDestination(for: SongProject.self) { p in
                ProjectView(project: p, autoOpen: initialScreen == "player" || initialScreen == "tiles" ? initialScreen : (initialScreen == "chart-actions" ? "bottom" : nil))
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill").foregroundColor(.white) }
                        .accessibilityIdentifier("settings")
                }
            }
            .sheet(isPresented: $showImport, onDismiss: startPendingRequest) {
                ImportSheet { request in
                    pendingRequest = request
                    showImport = false
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(settings) }
        }
        .onChange(of: library.openRequest) { p in
            guard let p else { return }
            library.openRequest = nil
            path = [p]
        }
        .task { await openInitialScreen() }
    }

    /// Runs what was chosen in the New chart sheet once the sheet is gone.
    func startPendingRequest() {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        switch request {
        case .song, .chart:
            pickerKind = request
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showCopyPicker = true }
        case .chartFolder:
            pickerKind = .chartFolder
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showPicker = true }
        case .link(let text):
            Task { if let p = await library.importLink(text) { path = [p] } }
        case .demo:
            Task { if let p = await library.createDemo() { path = [p] } }
        case .file(let url):
            Task { if let p = await library.importFile(url) { path = [p] } }
        }
    }

    func handlePicked(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            library.errorMessage = error.localizedDescription
        case .success(let urls):
            guard !urls.isEmpty else { return }
            let kind = pickerKind
            Task {
                if kind == .chart || kind == .chartFolder {
                    let imported = await library.importCharts(urls)
                    if imported.count == 1 { path = [imported[0]] }
                } else if let p = await library.importFile(urls[0]) {
                    path = [p]
                }
                // local copies made by the picker live in our tmp folder; the project has its own copy now
                let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
                for u in urls where u.resolvingSymlinksInPath().path.hasPrefix(tmp) { try? FileManager.default.removeItem(at: u) }
            }
        }
    }

    /// `-screen <name>` launch argument (automated screenshots).
    func openInitialScreen() async {
        guard let s = initialScreen, s != "home" else { return }
        if library.projects.isEmpty && ["project", "player", "tiles", "chart", "chart-actions"].contains(s) { _ = await library.createDemo() }
        switch s {
        case "import":
            showImport = true
        case "settings":
            showSettings = true
        case "importing":
            // the New chart flow with a bundled file instead of the system picker
            showImport = true
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let url = Bundle.main.url(forResource: "NeonSkyline", withExtension: "mid", subdirectory: "Demo") ?? Bundle.main.url(forResource: "NeonSkyline", withExtension: "mid") {
                pendingRequest = .file(url)
            }
            showImport = false
        case "chart", "chart-actions":
            // export the demo as .adx and import it back as a maimai chart
            if let existing = library.projects.first(where: { $0.source == .chart }) {
                path = [existing]
            } else if let demo = library.projects.first(where: { $0.source != .chart }), let adx = library.exportADX(demo) {
                let imported = await library.importCharts([adx])
                if let p = imported.first ?? library.projects.first(where: { $0.source == .chart }) { path = [p] }
            }
        default:
            if let p = library.projects.first { path = [p] }
        }
    }

    var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image("AppIconImage").resizable().frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.8), lineWidth: 2))
                VStack(alignment: .leading, spacing: 0) {
                    MaiTitle(text: "MaiChart Studio", size: 28)
                    Text("Charts for AstroDX · every difficulty · on-beat").font(MaiFont.bold(13)).foregroundColor(MaiColor.cyan)
                }
            }
            Text("Import a song (MP3, M4A, WAV, OGG), a MIDI / MusicXML score or a PDF score — or an existing maimai chart folder / .adx. MaiChart Studio finds the beat, follows the melody and drums, and writes EASY → Re:MASTER charts that build on each other.")
                .font(MaiFont.body(14)).foregroundColor(.white.opacity(0.85))
            Button { showImport = true } label: { Label("New chart", systemImage: "plus.circle.fill") }
                .buttonStyle(MaiButtonStyle(kind: .primary))
                .disabled(library.isBusy)
                .accessibilityIdentifier("new-chart")
        }
        .maiPanel()
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.house.fill").font(.system(size: 44)).foregroundColor(MaiColor.yellow)
            Text("No charts yet").font(MaiFont.heavy(18)).foregroundColor(.white)
            Button("Try the demo song") { Task { if let p = await library.createDemo() { path = [p] } } }
                .buttonStyle(MaiButtonStyle(kind: .secondary))
                .disabled(library.isBusy)
        }
        .frame(maxWidth: .infinity)
        .maiPanel(accent: MaiColor.cyan)
    }

    var inboxHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Import folder", icon: "tray.and.arrow.down.fill")
            Text("Like AstroDX: put chart folders, .adx / .zip files, songs or scores in Files › On My iPhone › MaiChart Studio › Import. They're added automatically when you open the app.")
                .font(MaiFont.body(12)).foregroundColor(.white.opacity(0.75))
            Button { Task { await library.scanInbox() } } label: { Label("Check Import folder now", systemImage: "arrow.clockwise") }
                .buttonStyle(MaiButtonStyle(kind: .secondary, compact: true))
                .disabled(library.isBusy)
        }
        .maiPanel(accent: MaiColor.mint)
    }
}

struct ProjectCard: View {
    let project: SongProject
    var body: some View {
        HStack(spacing: 12) {
            CoverImage(project: project).frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 6) {
                Text(project.title).font(MaiFont.heavy(16)).foregroundColor(.white).lineLimit(1)
                Text(project.artist.isEmpty ? project.source.label : project.artist).font(MaiFont.bold(12)).foregroundColor(MaiColor.cyan).lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(Difficulty.allCases.filter { $0 >= .advanced && project.hasChart($0) }) { d in
                        Text(project.levels[d.rawValue - 1])
                            .font(MaiFont.heavy(12))
                            .foregroundColor(d == .remaster ? MaiColor.violet : .white)
                            .frame(minWidth: 28)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(d == .remaster ? Color.white : MaiColor.difficulty(d)))
                    }
                    if project.isImportedChart {
                        Image(systemName: "square.stack.3d.up.fill").font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundColor(.white.opacity(0.6))
        }
        .maiPanel(accent: MaiColor.violet, padding: 12)
    }
}

struct ImportSheet: View {
    var onRequest: (ImportRequest?) -> Void
    @State private var link = ""

    static let songTypes: [UTType] = {
        var t: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .midi, .pdf, .xml]
        for ext in ["musicxml", "mxl", "mid", "midi", "m4a", "flac", "kar", "ogg"] { if let u = UTType(filenameExtension: ext) { t.append(u) } }
        return t
    }()

    /// Folders (a level, a folder of levels, AstroDX's levels folder) and archives. `.data` keeps .adx files
    /// selectable even when another app (AstroDX) owns the .adx type.
    static let chartTypes: [UTType] = {
        var t: [UTType] = [.zip, .data]
        if let u = UTType("com.astrodx.adx") { t.append(u) }
        if let u = UTType(filenameExtension: "adx") { t.append(u) }
        return t
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                MaiBackground(animated: false)
                ScrollView {
                    VStack(spacing: 14) {
                        source("Song audio", "MP3 · M4A · WAV · OGG · FLAC. MP3s are kept bit-exact; the beat grid and offset are detected automatically.", "waveform", MaiColor.pink, .song)
                        source("MIDI or MusicXML", "Exact notes and tempo. Rendered to a 320 kbps MP3 with the built-in SoundFont.", "pianokeys", MaiColor.cyan, .song)
                        source("PDF sheet music", "Printed scores are read with on-device optical music recognition, then rendered.", "doc.richtext", MaiColor.yellow, .song)
                        source("maimai chart (.adx / .zip)", "AstroDX / Majdata level archives — several at once. Play them here or send them to AstroDX.", "square.stack.3d.up.fill", MaiColor.violet, .chart)
                        source("maimai chart folder", "A level folder (maidata.txt + track.mp3/ogg + bg) or a folder of levels, e.g. a copy of AstroDX's levels folder.", "folder.fill", MaiColor.violet, .chartFolder)
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "From a link", icon: "link")
                            TextField("https://…/song.mp3", text: $link)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.9)))
                            Text("Direct links to audio, MIDI, MusicXML or PDF files. Video sites such as YouTube aren't supported — import audio you own instead.")
                                .font(MaiFont.body(11)).foregroundColor(.white.opacity(0.7))
                            Button("Download & chart") { onRequest(.link(link)) }
                                .buttonStyle(MaiButtonStyle(kind: .secondary, compact: true))
                                .disabled(link.isEmpty)
                        }
                        .maiPanel(accent: MaiColor.mint)
                        Button("Use the demo song") { onRequest(.demo) }
                            .buttonStyle(MaiButtonStyle(kind: .secondary, compact: true))
                    }
                    .padding(16)
                }
            }
            .navigationTitle("New chart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { onRequest(nil) } } }
        }
    }

    func source(_ title: String, _ text: String, _ icon: String, _ color: Color, _ request: ImportRequest) -> some View {
        Button { onRequest(request) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 26, weight: .bold)).foregroundColor(.white)
                    .frame(width: 54, height: 54).background(Circle().fill(color))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(MaiFont.heavy(17)).foregroundColor(.white)
                    Text(text).font(MaiFont.body(12)).foregroundColor(.white.opacity(0.75)).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundColor(.white.opacity(0.6))
            }
            .maiPanel(accent: color, padding: 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("import-\(title)")
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showLicenses = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Player")) {
                    stepper("Note speed", value: $settings.noteSpeed, range: 1...10, step: 0.25)
                    stepper("Touch speed", value: $settings.touchSpeed, range: 1...10, step: 0.25)
                    stepper("Timing offset (ms)", value: $settings.playerOffsetMs, range: -200...200, step: 1)
                    Text("Player calibration only — positive if you hit late. Exports use the per-song nudge instead.").font(.caption).foregroundColor(.secondary)
                    Toggle("Hit sounds", isOn: $settings.hitSounds)
                    Toggle("Lane guides", isOn: $settings.showGuides)
                    Toggle("Show touch sensor areas", isOn: $settings.showSensors)
                    VStack(alignment: .leading) { Text("Music volume"); Slider(value: $settings.musicVolume, in: 0...1) }
                    VStack(alignment: .leading) { Text("Effects volume"); Slider(value: $settings.sfxVolume, in: 0...1) }
                }
                Section(header: Text("Rendering")) {
                    Picker("Default renderer", selection: $settings.defaultRenderer) {
                        Text("MaiSynth").tag("MaiSynth")
                        Text("Apple AUSampler").tag("Apple AUSampler")
                    }
                }
                Section(header: Text("About")) {
                    Text("MaiChart Studio \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    Text("Fan-made chart tool for the simai format used by AstroDX. Not affiliated with SEGA or the AstroDX team.").font(.caption)
                    Button("Open-source licences") { showLicenses = true }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showLicenses) { LicensesView() }
        }
    }

    func stepper(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack { Text(title); Spacer(); Text(step < 1 ? String(format: "%.2f", value.wrappedValue) : String(format: "%.0f", value.wrappedValue)).monospacedDigit().foregroundColor(.secondary) }
        }
    }
}

struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(["GeneralUser-GS-LICENSE", "BasicPitch-LICENSE", "LAME-LGPL", "minimp3-CC0", "stb_vorbis-MIT", "SimaiSharp-MIT"], id: \.self) { name in
                    NavigationLink(name) {
                        ScrollView {
                            Text((Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Licenses") ?? Bundle.main.url(forResource: name, withExtension: "txt"))
                                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
                                .font(.system(size: 11, design: .monospaced)).padding()
                        }
                        .navigationTitle(name)
                    }
                }
            }
            .navigationTitle("Licences")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Document picker that imports a *local copy* of each picked file (asCopy: true): iOS copies it into the
/// app's own tmp/Inbox, so reading it needs no security scope and iCloud files are downloaded first.
struct CopyingDocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let multiple: Bool
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        vc.allowsMultipleSelection = multiple
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onPick([]) }
    }
}
