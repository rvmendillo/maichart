import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MaiCore

struct StudioView: View {
    @Binding var project: SongProject
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [PresetItem] = []
    @State private var program: Int? = nil
    @State private var renderer = "MaiSynth"
    @State private var synth: SynthPlayer? = nil
    @State private var pickSoundFont = false
    @State private var wave: (ref: [Float], mp3: [Float])? = nil
    @State private var waveError: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                MaiBackground(animated: false)
                ScrollView {
                    VStack(spacing: 14) {
                        soundfontPanel
                        keyboardPanel
                        if project.source != .audio { renderPanel }
                        wavePanel
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Soundfont Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { synth?.allOff(); dismiss() } } }
            .fileImporter(isPresented: $pickSoundFont, allowedContentTypes: [UTType(filenameExtension: "sf2") ?? .data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let u = urls.first { importSoundFont(u) }
            }
            .onAppear(perform: load)
            .onDisappear { synth?.allOff() }
        }
    }

    var soundfontPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Soundfont", icon: "pianokeys.inverse")
            Picker("Soundfont", selection: Binding(get: { settings.customSoundFont ?? "" }, set: { settings.customSoundFont = $0.isEmpty ? nil : $0; load() })) {
                Text("GeneralUser GS (built-in)").tag("")
                ForEach(SoundFontLibrary.installed, id: \.self) { Text(($0 as NSString).deletingPathExtension).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(.white)
            Button { pickSoundFont = true } label: { Label("Import .sf2 (e.g. a Yamaha/Roland-style bank you own)", systemImage: "plus.circle") }
                .buttonStyle(MaiButtonStyle(kind: .secondary, compact: true))
            Text("MIDI, MusicXML and PDF scores are rendered with this bank. MaiSynth implements the full SoundFont 2 model (all 16 channels, drums, program changes, modulators), so no notes go missing.")
                .font(MaiFont.body(12)).foregroundColor(.white.opacity(0.7))
        }
        .maiPanel(accent: MaiColor.violet)
    }

    var keyboardPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Instrument test", icon: "music.quarternote.3")
            Picker("Instrument", selection: Binding(get: { program ?? -1 }, set: { program = $0 < 0 ? nil : $0 })) {
                Text("Score's own instruments").tag(-1)
                ForEach(presets) { p in Text("\(p.program + 1). \(p.name)").tag(p.program) }
            }
            .pickerStyle(.menu)
            .tint(.white)
            MiniKeyboard { key, on in
                guard let s = synth else { return }
                if on { s.noteOn(channel: 0, key: key, velocity: 100, program: program ?? 0) } else { s.noteOff(channel: 0, key: key) }
            }
            .frame(height: 120)
        }
        .maiPanel(accent: MaiColor.cyan)
    }

    var renderPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Render to track.mp3", icon: "waveform.badge.plus")
            Picker("Renderer", selection: $renderer) {
                Text("MaiSynth (recommended)").tag("MaiSynth")
                Text("Apple AUSampler").tag("Apple AUSampler")
            }
            .pickerStyle(.segmented)
            Text("Both renderers read the same SoundFont. MaiSynth matches FluidSynth's reference output; AUSampler is Apple's engine (one sampler per channel/program so drums and program changes still play).")
                .font(MaiFont.body(12)).foregroundColor(.white.opacity(0.7))
            Button {
                let r = renderer, p = program
                Task {
                    if let np = await library.rerender(project, renderer: r, program: p) { project = np; loadWave() }
                }
            } label: { Label("Render & re-chart", systemImage: "arrow.triangle.2.circlepath") }
                .buttonStyle(MaiButtonStyle(kind: .primary))
        }
        .maiPanel(accent: MaiColor.pink)
    }

    var wavePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "WAV vs MP3 waveform", icon: "waveform.path")
            if let w = wave {
                WaveCompare(reference: w.ref, mp3: w.mp3).frame(height: 160)
                HStack(spacing: 12) {
                    Label("internal WAV", systemImage: "circle.fill").foregroundColor(MaiColor.cyan)
                    Label("track.mp3 decoded", systemImage: "circle.fill").foregroundColor(MaiColor.pink)
                }
                .font(MaiFont.bold(11))
                if let a = project.alignment { Text(a.description).font(MaiFont.mono(10)).foregroundColor(.white.opacity(0.75)) }
            } else if let e = waveError {
                Text(e).font(MaiFont.body(12)).foregroundColor(.white.opacity(0.7))
            } else {
                ProgressView().tint(.white)
            }
        }
        .maiPanel(accent: MaiColor.mint)
        .onAppear(perform: loadWave)
    }

    func load() {
        renderer = project.renderer
        program = project.instrumentProgram
        if let loaded = try? SoundFontLibrary.load(custom: settings.customSoundFont) {
            let sf = loaded.0
            presets = PresetItem.list(sf)
            if let s = synth { s.setSoundFont(sf) } else { synth = try? SynthPlayer(soundFont: sf) }
        }
    }

    func loadWave() {
        let p = project
        Task.detached {
            do {
                let mp3 = try AudioIO.decode(url: ProjectStore.file(p, p.trackFile))
                let refURL = ProjectStore.file(p, "reference.wav")
                let ref: AudioSamples
                if FileManager.default.fileExists(atPath: refURL.path) { ref = try WAVFile.read(url: refURL) }
                else { ref = try AudioIO.decode(url: ProjectStore.file(p, p.sourceFile)) }
                // a short loud excerpt (aligned by the measured lag) at 1:1 sample resolution
                let lag = p.alignment?.lagSamples ?? 0
                let r = ref.mono(), m = mp3.mono()
                var start = 0, best: Float = 0
                var i = 0
                while i + 2048 < r.count { let v = abs(r[i]); if v > best { best = v; start = i }; i += 997 }
                start = max(0, start - 400)
                let n = min(1200, r.count - start, m.count - start - max(0, lag))
                guard n > 100 else { throw AppError.message("Audio too short to compare") }
                // the encoder may have applied ~1 dB of headroom: show the reference at the encoded level
                let refPeak = ref.peak
                let g: Float = refPeak > 0 ? min(1, (p.alignment?.referencePeak ?? refPeak) / refPeak) : 1
                let a = r[start..<(start + n)].map { $0 * g }
                let b = Array(m[(start + lag)..<(start + lag + n)])
                await MainActor.run { wave = (a, b) }
            } catch {
                await MainActor.run { waveError = "Waveform view unavailable: \(error.localizedDescription)" }
            }
        }
    }

    func importSoundFont(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = ProjectStore.soundFontsDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            _ = try SoundFont(url: dest) // validate
            settings.customSoundFont = dest.lastPathComponent
            load()
        } catch {
            try? FileManager.default.removeItem(at: dest)
            library.errorMessage = error.localizedDescription
        }
    }
}

struct WaveCompare: View {
    let reference: [Float]
    let mp3: [Float]
    var body: some View {
        Canvas { ctx, size in
            func path(_ x: [Float]) -> Path {
                var p = Path()
                let n = x.count
                for i in 0..<n {
                    let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(max(1, n - 1)), y: size.height / 2 - CGFloat(x[i]) * size.height * 0.45)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                return p
            }
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 12), with: .color(.black.opacity(0.35)))
            var mid = Path(); mid.move(to: CGPoint(x: 0, y: size.height / 2)); mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(mid, with: .color(.white.opacity(0.15)), lineWidth: 1)
            ctx.stroke(path(reference), with: .color(MaiColor.cyan), lineWidth: 2.2)
            ctx.stroke(path(mp3), with: .color(MaiColor.pink.opacity(0.85)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 2]))
        }
    }
}

struct MiniKeyboard: View {
    var onKey: (Int, Bool) -> Void
    @State private var down: Set<Int> = []
    let base = 60
    var body: some View {
        GeometryReader { geo in
            let whites = [0, 2, 4, 5, 7, 9, 11, 12, 14, 16, 17, 19, 21, 23]
            let w = geo.size.width / CGFloat(whites.count)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(whites, id: \.self) { off in key(base + off, black: false).frame(width: w) }
                }
                ForEach([1, 3, 6, 8, 10, 13, 15, 18, 20, 22], id: \.self) { off in
                    let idx = whites.lastIndex { $0 < off } ?? 0
                    key(base + off, black: true).frame(width: w * 0.62, height: geo.size.height * 0.6)
                        .offset(x: w * CGFloat(idx + 1) - w * 0.31)
                }
            }
        }
    }

    func key(_ k: Int, black: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(down.contains(k) ? AnyShapeStyle(MaiColor.pink) : AnyShapeStyle(black ? Color.black : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.6), lineWidth: 1))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down.contains(k) { down.insert(k); onKey(k, true) } }
                .onEnded { _ in down.remove(k); onKey(k, false) })
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// "Save to Files" — lets the user pick the AstroDX folder (or anywhere) as destination.
struct ExportPicker: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
}
