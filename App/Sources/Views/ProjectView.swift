import SwiftUI
import UIKit
import MaiCore

/// Everything needed to open the player or Piano Tiles for a project.
struct PlayLaunch: Identifiable {
    let id = UUID()
    let session: PlayerSession
}

struct TilesLaunch: Identifiable {
    let id = UUID()
    let session: TilesSession
    let presets: [PresetItem]
}

struct ProjectView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: AppSettings
    @State var project: SongProject
    @State private var playLaunch: PlayLaunch? = nil
    @State private var tilesLaunch: TilesLaunch? = nil
    @State private var shareURL: URL? = nil
    @State private var exportPickerURL: URL? = nil
    @State private var showOptions = false
    @State private var showStudio = false
    @State private var showMaidata = false
    @State private var loadingPlayer = false
    var autoOpen: String? = nil

    var body: some View {
        ZStack {
            MaiBackground()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    difficultyList
                    syncPanel
                    actionsPanel
                    audioPanel
                }
                .padding(16)
                .padding(.bottom, 40)
            }
            if loadingPlayer { ProgressView().tint(.white).scaleEffect(1.6) }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showMaidata = true } label: { Label("View maidata.txt", systemImage: "doc.text") }
                    Button(role: .destructive) { library.delete(project) } label: { Label("Delete project", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle").foregroundColor(.white) }
            }
        }
        .fullScreenCover(item: $playLaunch) { launch in PlayerView(session: launch.session).environmentObject(settings) }
        .fullScreenCover(item: $tilesLaunch) { l in PianoTilesView(session: l.session, title: project.title, presets: l.presets) }
        .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
        .sheet(item: $exportPickerURL) { url in ExportPicker(url: url) }
        .sheet(isPresented: $showOptions) { OptionsSheet(project: $project, onApply: { p in Task { if let np = await library.regenerate(p) { project = np } } }) }
        .sheet(isPresented: $showStudio) { StudioView(project: $project).jobHost().environmentObject(library).environmentObject(settings) }
        .sheet(isPresented: $showMaidata) { MaidataSheet(text: ProjectStore.maidataText(project) ?? "") }
        .onReceive(library.$projects) { list in if let p = list.first(where: { $0.id == project.id }) { project = p } }
        .onAppear {
            if autoOpen == "player" { openPlayer(project.hasChart(.master) ? .master : (Difficulty.allCases.last { project.hasChart($0) } ?? .master), autoplay: true, autostart: true) }
            if autoOpen == "tiles" { openTiles() }
        }
    }

    var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(project: project).frame(width: 118, height: 118)
            VStack(alignment: .leading, spacing: 6) {
                Text(project.title).font(MaiFont.title(24)).foregroundColor(.white).lineLimit(2).minimumScaleFactor(0.7)
                Text(project.artist.isEmpty ? "Unknown artist" : project.artist).font(MaiFont.bold(14)).foregroundColor(MaiColor.cyan)
                HStack(spacing: 6) {
                    Label(project.source.label, systemImage: project.source.icon).font(MaiFont.bold(11))
                    Text("BPM \(SimaiWriter.formatBPM((project.bpm * 100).rounded() / 100))").font(MaiFont.bold(11))
                }
                .foregroundColor(.white.opacity(0.85))
                Text(project.notesSummary).font(MaiFont.body(11)).foregroundColor(.white.opacity(0.6)).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .maiPanel()
    }

    var difficultyList: some View {
        VStack(spacing: 10) {
            SectionHeader(title: "Charts", icon: "star.fill")
            ForEach(Difficulty.allCases.filter { !project.isImportedChart || project.hasChart($0) }) { d in
                let i = d.rawValue - 1
                let available = project.hasChart(d)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        DifficultyBadge(difficulty: d, level: available ? project.levels[i] : "-")
                        Text(caption(for: d))
                            .font(MaiFont.bold(12)).foregroundColor(.white.opacity(0.8))
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .padding(.leading, 4)
                    }
                    Spacer(minLength: 6)
                    Button { openPlayer(d, autoplay: true) } label: { Image(systemName: "eye.fill") }
                        .buttonStyle(MaiButtonStyle(kind: .secondary, compact: true))
                        .disabled(!available)
                    Button { openPlayer(d, autoplay: false) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(MaiButtonStyle(kind: .difficulty(d), compact: true))
                        .disabled(!available)
                        .accessibilityIdentifier("play-\(d.rawValue)")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 16).fill(MaiColor.difficulty(d).opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(MaiColor.difficulty(d).opacity(0.7), lineWidth: 1.5))
                .opacity(available ? 1 : 0.55)
            }
        }
        .maiPanel(accent: MaiColor.violet)
    }

    /// "312 notes · internal 13.1" (generated) / "312 notes · level 13.7" (imported) / "No chart".
    func caption(for d: Difficulty) -> String {
        guard project.hasChart(d) else { return "No chart" }
        let i = d.rawValue - 1
        let notes = i < project.noteCounts.count ? project.noteCounts[i] : 0
        var text = "\(notes) notes"
        if i < project.levelValues.count, project.levelValues[i] > 0 {
            let label = project.isImportedChart ? "level" : "internal"
            text += " · \(label) " + String(format: "%.1f", project.levelValues[i])
        }
        return text
    }

    var syncPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Sync & offset", icon: "metronome.fill")
            HStack {
                StatPill(label: "&first", value: String(format: "%.3fs", project.first))
                if project.isImportedChart {
                    StatPill(label: "BPM", value: SimaiWriter.formatBPM((project.bpm * 100).rounded() / 100))
                } else {
                    StatPill(label: "BEAT GRID", value: project.gridConfidence.map { String(format: "%.0f%%", $0 * 100) } ?? "-")
                }
                StatPill(label: "NUDGE", value: String(format: "%+.0f ms", project.userOffsetMs), color: MaiColor.yellow)
            }
            Text("If notes feel early or late in AstroDX, nudge the chart. The change is written into &first; the notes themselves stay on the beat grid.")
                .font(MaiFont.body(12)).foregroundColor(.white.opacity(0.7))
            HStack(spacing: 8) {
                ForEach([-10, -5, -1, 1, 5, 10], id: \.self) { ms in
                    Button(ms > 0 ? "+\(ms)" : "\(ms)") { nudge(Double(ms)) }.buttonStyle(MaiButtonStyle(kind: .secondary, compact: true))
                }
            }
            if project.userOffsetMs != 0 {
                Button("Reset nudge") { nudge(-project.userOffsetMs) }.buttonStyle(MaiButtonStyle(kind: .danger, compact: true))
            }
        }
        .maiPanel(accent: MaiColor.cyan)
    }

    var actionsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: project.isImportedChart ? "Play & export" : "Create & export", icon: "sparkles")
            if project.isImportedChart {
                Text("This chart is kept exactly as imported. MaiChart Studio can also write its own EASY → Re:MASTER charts for the same song.")
                    .font(MaiFont.body(12)).foregroundColor(.white.opacity(0.7))
                Button { Task { if let p = await library.chartAudio(of: project) { library.openRequest = p } } } label: {
                    Label("Make my own charts for this song", systemImage: "wand.and.stars")
                }
                .buttonStyle(MaiButtonStyle(kind: .primary))
                .disabled(library.isBusy)
            } else {
                HStack(spacing: 10) {
                    Button { Task { if let p = await library.remix(project) { project = p } } } label: { Label("Remix", systemImage: "shuffle") }
                        .buttonStyle(MaiButtonStyle(kind: .primary))
                    Button { showOptions = true } label: { Label("Options", systemImage: "slider.horizontal.3") }
                        .buttonStyle(MaiButtonStyle(kind: .secondary))
                }
                HStack(spacing: 10) {
                    Button { openTiles() } label: { Label("Piano Tiles", systemImage: "pianokeys") }
                        .buttonStyle(MaiButtonStyle(kind: .secondary))
                    Button { showStudio = true } label: { Label("Studio", systemImage: "waveform.path.ecg") }
                        .buttonStyle(MaiButtonStyle(kind: .secondary))
                }
            }
            Divider().overlay(Color.white.opacity(0.2))
            Text(project.isImportedChart
                 ? "AstroDX: open the .adx with AstroDX, or save it into the AstroDX folder in the Files app. The level keeps its folder name, audio, background and video."
                 : "AstroDX: open the .adx with AstroDX, or save it into the AstroDX folder in the Files app. The export contains maidata.txt, track.mp3 and bg.jpg (no WAV).")
                .font(MaiFont.body(12)).foregroundColor(.white.opacity(0.7))
            HStack(spacing: 10) {
                Button { shareURL = library.exportADX(project) } label: { Label("Share .adx", systemImage: "square.and.arrow.up") }
                    .buttonStyle(MaiButtonStyle(kind: .primary))
                Button { exportPickerURL = library.exportADX(project) } label: { Label("Save to Files", systemImage: "folder") }
                    .buttonStyle(MaiButtonStyle(kind: .secondary))
            }
            Button { if let u = library.exportFolder(project) { exportPickerURL = u } } label: { Label("Export plain folder", systemImage: "folder.badge.plus") }
                .buttonStyle(MaiButtonStyle(kind: .secondary, compact: true))
        }
        .maiPanel(accent: MaiColor.pink)
    }

    var audioPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Audio quality check", icon: "waveform")
            if project.isImportedChart {
                Text("\((project.trackFile as NSString).lastPathComponent) is the level's original audio. It is played as-is and exported byte-for-byte.")
                    .font(MaiFont.body(12)).foregroundColor(.white.opacity(0.8))
            } else if project.trackIsOriginal == true {
                Text("track.mp3 is your original MP3: every audio frame is copied bit-exactly (only the Xing/Info header frame is removed so all players start on the same sample). The beat grid was measured on exactly this file.")
                    .font(MaiFont.body(12)).foregroundColor(.white.opacity(0.8))
            } else if let a = project.alignment {
                HStack {
                    StatPill(label: "LAG", value: "\(a.lagSamples) smp", color: a.aligned ? MaiColor.mint : MaiColor.orange)
                    StatPill(label: "CORRELATION", value: String(format: "%.4f", a.correlation))
                    StatPill(label: "SNR", value: String(format: "%.1f dB", a.snrDB))
                }
                HStack {
                    StatPill(label: "SPECTRAL DIFF", value: String(format: "%.2f dB", a.spectralDistanceDB))
                    StatPill(label: "LENGTH", value: String(format: "%.2fs/%.2fs", a.referenceDuration, a.decodedDuration))
                    StatPill(label: "CLIPPED", value: "\(a.clippedSamples)", color: a.clippedSamples == 0 ? MaiColor.mint : MaiColor.orange)
                }
                Text("track.mp3 (320 kbps CBR) was decoded again with iOS's MP3 decoder and compared with the \(project.source == .audio ? "source audio" : "internal WAV render"): \(a.aligned ? "the waveforms line up sample-exactly" : String(format: "a %.1f ms codec delay is compensated in &first", a.lagMilliseconds)).")
                    .font(MaiFont.body(12)).foregroundColor(.white.opacity(0.7))
            } else {
                Text("No report yet.").font(MaiFont.body(12)).foregroundColor(.white.opacity(0.6))
            }
        }
        .maiPanel(accent: MaiColor.mint)
    }

    func nudge(_ ms: Double) {
        var p = project
        p.userOffsetMs = (p.userOffsetMs + ms).rounded()
        Task { if let np = await library.regenerate(p) { project = np } }
    }

    func openPlayer(_ d: Difficulty, autoplay: Bool, autostart: Bool = false) {
        guard let text = ProjectStore.maidataText(project) else { library.errorMessage = "maidata.txt missing"; return }
        loadingPlayer = true
        let p = project
        Task.detached(priority: .userInitiated) {
            do {
                let m = MaidataFile(text: text)
                guard let body = m.chartBody(d) else { throw AppError.message("No \(d.displayName) chart") }
                let chart = PlayChart(try SimaiParser.parse(body))
                let audio = try AudioIO.decode(url: ProjectStore.file(p, p.trackFile), asIs: p.isImportedChart)
                await MainActor.run {
                    let s = PlayerSession(chart: chart, audio: audio, first: m.firstOffset(d), title: p.title, difficulty: d,
                                          level: m.level(d) ?? "", settings: settings, autoplay: autoplay)
                    loadingPlayer = false
                    playLaunch = PlayLaunch(session: s)
                    if autostart { s.start() }
                }
            } catch {
                await MainActor.run { loadingPlayer = false; library.errorMessage = error.localizedDescription }
            }
        }
    }

    func openTiles() {
        let p = project
        loadingPlayer = true
        let custom = settings.customSoundFont
        Task.detached(priority: .userInitiated) {
            do {
                let score: Score
                if let d = try? Data(contentsOf: ProjectStore.file(p, "score.mid")) {
                    score = try MIDIFile.parse(data: d, title: p.title)
                } else if let f = ProjectStore.loadFeatures(p) {
                    // audio projects: build a score from the transcribed melody/harmony
                    let notes = f.melody.map { MusicNote(pitch: $0.pitch, startBeat: $0.beat, durationBeats: $0.duration, velocity: Int(60 + 60 * $0.strength)) }
                        + f.harmony.map { MusicNote(pitch: $0.pitch, startBeat: $0.beat, durationBeats: $0.duration, velocity: 70, channel: 1) }
                    score = Score(title: p.title, tempo: f.tempo.withOffset(0), timeSignatures: f.timeSignatures, notes: notes)
                } else { throw AppError.message("No notes available for Piano Tiles.") }
                let tiles = PianoTilesBuilder.build(score: score)
                let sf = try? SoundFontLibrary.load(custom: custom).0
                await MainActor.run {
                    loadingPlayer = false
                    let session = TilesSession(tiles: tiles, soundFont: sf)
                    tilesLaunch = TilesLaunch(session: session, presets: PresetItem.list(sf))
                    if autoOpen == "tiles" { session.auto = true; session.start() }
                }
            } catch {
                await MainActor.run { loadingPlayer = false; library.errorMessage = error.localizedDescription }
            }
        }
    }
}

struct CoverImage: View {
    let project: SongProject
    var body: some View {
        Group {
            if let f = project.coverFile, let img = UIImage(contentsOfFile: ProjectStore.file(project, f).path) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [MaiColor.pink, MaiColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note").font(.system(size: 34, weight: .black)).foregroundColor(.white))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.9), lineWidth: 3))
        .shadow(color: MaiColor.pink.opacity(0.4), radius: 8, y: 4)
    }
}

struct OptionsSheet: View {
    @Binding var project: SongProject
    var onApply: (SongProject) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = GeneratorOptions()

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Note mix")) {
                    slider("Slides", value: $draft.slideAmount, hint: "Low = mostly quantised taps")
                    slider("Touch notes", value: $draft.touchAmount, hint: "A/B/D/E sensors with closing timers + centre holds")
                    slider("EACH (two at once)", value: $draft.eachAmount, hint: "Simultaneous pairs")
                    slider("BREAK notes", value: $draft.breakAmount, hint: "Accents on crashes / section starts")
                }
                Section(header: Text("Re:MASTER")) {
                    slider("Density", value: $draft.remasterBoost, range: 0.8...1.5, hint: "Higher = more melody notes and streams (still human-playable)")
                    Toggle("Extra 16th stream fills", isOn: $draft.streamFills)
                }
                Section(header: Text("Layout")) {
                    Toggle("Mirror (left ↔ right)", isOn: $draft.mirror)
                }
            }
            .navigationTitle("Chart options")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        var p = project
                        p.options = draft
                        onApply(p)
                        dismiss()
                    }
                }
            }
            .onAppear { draft = project.options }
        }
    }

    func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double> = 0...1, hint: String) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().foregroundColor(.secondary) }
            Slider(value: value, in: range)
            Text(hint).font(.caption).foregroundColor(.secondary)
        }
    }
}

struct MaidataSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { Text(text).font(MaiFont.mono(11)).textSelection(.enabled).padding() }
                .navigationTitle("maidata.txt")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
