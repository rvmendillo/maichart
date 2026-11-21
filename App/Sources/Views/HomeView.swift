import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MaiCore

struct HomeView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: AppSettings
    @State private var showImport = false
    @State private var showSettings = false
    @State private var path: [SongProject] = []
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
                    }
                    .padding(16)
                }
            }
            .navigationDestination(for: SongProject.self) { p in
                ProjectView(project: p, autoOpen: initialScreen == "player" || initialScreen == "tiles" ? initialScreen : nil)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill").foregroundColor(.white) }
                        .accessibilityIdentifier("settings")
                }
            }
            .sheet(isPresented: $showImport) {
                ImportSheet { p in
                    showImport = false
                    if let p { path = [p] }
                }
                .environmentObject(library)
            }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(settings) }
        }
        .task {
            if let s = initialScreen, s != "home" {
                if library.projects.isEmpty { _ = await library.createDemo() }
                if s != "import", let p = library.projects.first { path = [p] }
                if s == "import" { showImport = true }
                if s == "settings" { showSettings = true }
            }
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
            Text("Import a song (MP3, M4A, WAV), a MIDI / MusicXML score or a PDF score. MaiChart Studio finds the beat, follows the melody and drums, and writes EASY → Re:MASTER charts that build on each other.")
                .font(MaiFont.body(14)).foregroundColor(.white.opacity(0.85))
            Button { showImport = true } label: { Label("New chart", systemImage: "plus.circle.fill") }
                .buttonStyle(MaiButtonStyle(kind: .primary))
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
        }
        .frame(maxWidth: .infinity)
        .maiPanel(accent: MaiColor.cyan)
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
                    ForEach(Difficulty.allCases.filter { $0 >= .advanced }) { d in
                        let i = d.rawValue - 1
                        if i < project.levels.count {
                            Text(project.levels[i])
                                .font(MaiFont.heavy(12))
                                .foregroundColor(d == .remaster ? MaiColor.violet : .white)
                                .frame(minWidth: 28)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(d == .remaster ? Color.white : MaiColor.difficulty(d)))
                        }
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
    @EnvironmentObject var library: Library
    var onDone: (SongProject?) -> Void
    @State private var pick = false
    @State private var link = ""

    static let types: [UTType] = {
        var t: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .midi, .pdf, .xml]
        for ext in ["musicxml", "mxl", "mid", "midi", "m4a", "flac", "kar"] { if let u = UTType(filenameExtension: ext) { t.append(u) } }
        return t
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                MaiBackground(animated: false)
                ScrollView {
                    VStack(spacing: 14) {
                        source("Song audio", "MP3 · M4A · WAV · FLAC. MP3s are kept bit-exact; the beat grid and offset are detected automatically.", "waveform", MaiColor.pink)
                        source("MIDI or MusicXML", "Exact notes and tempo. Rendered to a 320 kbps MP3 with the built-in SoundFont.", "pianokeys", MaiColor.cyan)
                        source("PDF sheet music", "Printed scores are read with on-device optical music recognition, then rendered.", "doc.richtext", MaiColor.yellow)
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "From a link", icon: "link")
                            TextField("https://…/song.mp3", text: $link)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.9)))
                            Text("Direct links to audio, MIDI, MusicXML or PDF files. Video sites such as YouTube aren't supported — import audio you own instead.")
                                .font(MaiFont.body(11)).foregroundColor(.white.opacity(0.7))
                            Button("Download & chart") { Task { onDone(await library.importLink(link)) } }
                                .buttonStyle(MaiButtonStyle(kind: .secondary, compact: true))
                                .disabled(link.isEmpty)
                        }
                        .maiPanel(accent: MaiColor.mint)
                        Button("Use the demo song") { Task { onDone(await library.createDemo()) } }
                            .buttonStyle(MaiButtonStyle(kind: .secondary, compact: true))
                    }
                    .padding(16)
                }
            }
            .navigationTitle("New chart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { onDone(nil) } } }
            .fileImporter(isPresented: $pick, allowedContentTypes: Self.types, allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let u = urls.first { Task { onDone(await library.importFile(u)) } }
            }
        }
    }

    func source(_ title: String, _ text: String, _ icon: String, _ color: Color) -> some View {
        Button { pick = true } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 26, weight: .bold)).foregroundColor(.white)
                    .frame(width: 54, height: 54).background(Circle().fill(color))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(MaiFont.heavy(17)).foregroundColor(.white)
                    Text(text).font(MaiFont.body(12)).foregroundColor(.white.opacity(0.75)).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .maiPanel(accent: color, padding: 12)
        }
        .buttonStyle(.plain)
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
                ForEach(["GeneralUser-GS-LICENSE", "BasicPitch-LICENSE", "LAME-LGPL", "minimp3-CC0", "SimaiSharp-MIT"], id: \.self) { name in
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
