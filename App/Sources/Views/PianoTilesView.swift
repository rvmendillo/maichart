import SwiftUI
import UIKit
import QuartzCore
import MaiCore

struct PresetItem: Identifiable, Hashable {
    let program: Int
    let name: String
    var id: Int { program }

    static func list(_ sf: SoundFont?) -> [PresetItem] {
        (sf?.melodicPresets ?? []).map { PresetItem(program: $0.program, name: $0.name) }
    }
}

@MainActor
final class TilesSession: ObservableObject {
    let tiles: [Tile]
    private(set) var judge: TilesJudge
    let synth: SynthPlayer?
    @Published var program: Int? = nil
    @Published var auto = false
    @Published var running = false
    @Published var finished = false
    var startHost: Double = 0
    var lastResults: [(lane: Int, text: String, time: Double, color: Color)] = []
    var pressedLanes: Set<Int> = []
    private var autoHit = Set<Int>()
    let approach: Double = 1.5
    let lead: Double = 2.0
    private var finishing = false

    init(tiles: [Tile], soundFont: SoundFont?) {
        self.tiles = tiles
        judge = TilesJudge(tiles: tiles)
        synth = soundFont.flatMap { try? SynthPlayer(soundFont: $0) }
    }

    var time: Double { running ? CACurrentMediaTime() - startHost - lead : -lead }
    var endTime: Double { (tiles.map { $0.time + $0.duration }.max() ?? 0) + 1.5 }

    func start() {
        judge = TilesJudge(tiles: tiles)
        autoHit.removeAll()
        lastResults.removeAll()
        finished = false
        finishing = false
        startHost = CACurrentMediaTime()
        running = true
    }

    func stop() {
        running = false
        synth?.allOff()
    }

    func play(_ tile: Tile) {
        guard let synth else { return }
        for s in tile.sounds { synth.play(s, programOverride: program) }
    }

    func tick() {
        guard running else { return }
        let t = time
        if auto {
            for tile in tiles where !autoHit.contains(tile.id) && tile.time <= t {
                autoHit.insert(tile.id)
                if let hit = judge.tap(lane: tile.lane, at: tile.time) {
                    play(hit.tile)
                    lastResults.append((tile.lane, hit.result.rawValue, t, .white))
                }
            }
            for tile in tiles where tile.isLong && autoHit.contains(tile.id) && t >= tile.time + tile.duration { judge.release(lane: tile.lane, at: t) }
        }
        judge.update(t)
        lastResults.removeAll { t - $0.time > 0.6 }
        if t > endTime && !finishing {
            finishing = true
            DispatchQueue.main.async { [weak self] in
                self?.running = false
                self?.finished = true
            }
        }
    }

    func touch(began: [(CGPoint, Double)], active: [CGPoint], size: CGSize) {
        let laneW = size.width / 4
        let nowLanes = Set(active.map { max(0, min(3, Int($0.x / laneW))) })
        guard running, !auto else { pressedLanes = nowLanes; return }
        let now = CACurrentMediaTime()
        for (p, ts) in began {
            let lane = max(0, min(3, Int(p.x / laneW)))
            let t = time - (now - ts)
            if let hit = judge.tap(lane: lane, at: t) {
                play(hit.tile)
                let c: Color = hit.result == .perfect ? MaiColor.yellow : (hit.result == .great ? MaiColor.pink : MaiColor.mint)
                lastResults.append((lane, hit.result.rawValue, time, c))
            } else {
                lastResults.append((lane, "✕", time, .gray))
            }
        }
        for lane in pressedLanes.subtracting(nowLanes) { judge.release(lane: lane, at: time) }
        pressedLanes = nowLanes
    }
}

struct PianoTilesView: View {
    @StateObject var session: TilesSession
    @Environment(\.dismiss) private var dismiss
    let title: String
    let presets: [PresetItem]

    var body: some View {
        ZStack {
            Color(red: 0.96, green: 0.96, blue: 0.98).ignoresSafeArea()
            GeometryReader { geo in
                ZStack {
                    TimelineView(.animation) { tl in
                        Canvas { ctx, size in
                            _ = tl.date
                            session.tick()
                            TilesRenderer.draw(&ctx, size: size, s: session)
                        }
                    }
                    TouchSurface { began, active, _ in session.touch(began: began, active: active, size: geo.size) }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button { session.stop(); dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .black)).foregroundColor(.white)
                            .frame(width: 38, height: 38).background(Circle().fill(Color.black.opacity(0.6)))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(MaiFont.heavy(14)).foregroundColor(.black).lineLimit(1)
                        Text("Score \(session.judge.score) · Combo \(session.judge.combo)").font(MaiFont.bold(12)).foregroundColor(.gray)
                    }
                    Spacer()
                    Menu {
                        Button("Original instruments") { session.program = nil }
                        ForEach(presets) { p in
                            Button("\(p.program + 1). \(p.name)") { session.program = p.program }
                        }
                    } label: {
                        Label(instrumentName, systemImage: "pianokeys")
                            .font(MaiFont.bold(13)).foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(LinearGradient(colors: [MaiColor.violet, MaiColor.pink], startPoint: .leading, endPoint: .trailing)))
                    }
                }
                .padding(.horizontal, 12)
                Spacer()
                if !session.running {
                    VStack(spacing: 12) {
                        if session.finished {
                            Text("Score \(session.judge.score)").font(MaiFont.title(30)).foregroundColor(.black)
                            Text("Max combo \(session.judge.maxCombo) / \(session.tiles.count)").font(MaiFont.bold(15)).foregroundColor(.gray)
                        } else {
                            Text("PIANO TILES").font(MaiFont.title(30)).foregroundColor(.black)
                            Text("Tap the black tiles on the line. Hold long tiles.\nTwo tiles at once share the same length.").font(MaiFont.body(13)).foregroundColor(.gray).multilineTextAlignment(.center)
                        }
                        Toggle("Auto play", isOn: $session.auto).font(MaiFont.bold(15)).tint(MaiColor.pink).frame(maxWidth: 220)
                        Button(session.finished ? "Play again" : "Start") { session.start() }.buttonStyle(MaiButtonStyle(kind: .primary))
                    }
                    .padding(22)
                    .background(RoundedRectangle(cornerRadius: 24).fill(Color.white).shadow(radius: 12))
                    .padding(.bottom, 80)
                }
            }
        }
        .statusBarHidden(true)
        .onDisappear { session.stop() }
    }

    var instrumentName: String {
        guard let p = session.program else { return "Original" }
        return presets.first { $0.program == p }?.name ?? "Program \(p + 1)"
    }
}

@MainActor
enum TilesRenderer {
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, s: TilesSession) {
        let w = size.width, h = size.height
        let laneW = w / 4
        let hitY = h * 0.84
        let speed = Double(hitY) / s.approach
        let t = s.time
        for lane in 0..<4 {
            let r = CGRect(x: CGFloat(lane) * laneW, y: 0, width: laneW, height: h)
            ctx.fill(Path(r), with: .color(s.pressedLanes.contains(lane) ? MaiColor.cyan.opacity(0.12) : Color.white))
            var line = Path(); line.move(to: CGPoint(x: r.maxX, y: 0)); line.addLine(to: CGPoint(x: r.maxX, y: h))
            ctx.stroke(line, with: .color(.gray.opacity(0.35)), lineWidth: 1)
        }
        var hit = Path(); hit.move(to: CGPoint(x: 0, y: hitY)); hit.addLine(to: CGPoint(x: w, y: hitY))
        ctx.stroke(hit, with: .color(MaiColor.pink.opacity(0.85)), lineWidth: 3)
        for tile in s.tiles {
            let yBottom = hitY - CGFloat((tile.time - t) * speed)
            let height = max(laneW * 0.9, CGFloat(tile.duration * speed))
            let yTop = yBottom - height
            guard yBottom > -10, yTop < h + 10 else { continue }
            let rect = CGRect(x: CGFloat(tile.lane) * laneW + 2, y: yTop, width: laneW - 4, height: height)
            let result = s.judge.results[tile.id]
            let path = Path(roundedRect: rect, cornerRadius: 6)
            if let r = result {
                if r == .miss {
                    ctx.fill(path, with: .color(Color.red.opacity(0.7)))
                } else {
                    ctx.fill(path, with: .color(Color.black.opacity(tile.isLong ? 0.55 : 0.18)))
                    if tile.isLong {
                        let held = max(0, min(1, (t - tile.time) / tile.duration))
                        let fill = CGRect(x: rect.minX, y: rect.maxY - rect.height * CGFloat(held), width: rect.width, height: rect.height * CGFloat(held))
                        ctx.fill(Path(roundedRect: fill, cornerRadius: 6), with: .linearGradient(Gradient(colors: [MaiColor.cyan, MaiColor.pink]), startPoint: CGPoint(x: fill.midX, y: fill.maxY), endPoint: CGPoint(x: fill.midX, y: fill.minY)))
                    }
                }
            } else {
                ctx.fill(path, with: .linearGradient(Gradient(colors: [Color(white: 0.18), Color(white: 0.02)]), startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                if tile.isLong {
                    var spine = Path(); spine.move(to: CGPoint(x: rect.midX, y: rect.minY + 12)); spine.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 12))
                    ctx.stroke(spine, with: .color(MaiColor.cyan.opacity(0.8)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    ctx.fill(Path(ellipseIn: CGRect(x: rect.midX - 9, y: rect.maxY - 26, width: 18, height: 18)), with: .color(MaiColor.cyan))
                }
                if tile.partner != nil {
                    ctx.stroke(path, with: .color(MaiColor.yellow), lineWidth: 2)
                }
            }
        }
        for r in s.lastResults {
            let age = t - r.time
            let x = CGFloat(r.lane) * laneW + laneW / 2
            ctx.opacity = max(0, 1 - age / 0.6)
            ctx.draw(Text(r.text).font(.system(size: 20, weight: .black, design: .rounded)).foregroundColor(r.color == .white ? MaiColor.pink : r.color),
                     at: CGPoint(x: x, y: hitY - 40 - CGFloat(age * 60)))
            ctx.opacity = 1
        }
    }
}
