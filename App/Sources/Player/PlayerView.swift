import SwiftUI
import UIKit
import MaiCore

struct PlayerView: View {
    @StateObject var session: PlayerSession
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settings: AppSettings
    var autostart = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MaiBackground(animated: false).opacity(0.5)
            GeometryReader { geo in
                ZStack {
                    TimelineView(.animation) { tl in
                        Canvas { ctx, size in
                            _ = tl.date
                            session.tick()
                            PlayfieldRenderer.draw(&ctx, size: size, s: session)
                        }
                    }
                    TouchSurface { began, active, time in
                        session.handleTouches(began: began, active: active, time: time)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .ignoresSafeArea()
            VStack {
                hud
                Spacer()
            }
            if session.state == .ready { startOverlay }
            if session.state == .paused { pauseOverlay }
            if session.state == .finished { ResultsView(session: session, onRetry: { session.start() }, onExit: { session.stop(); dismiss() }) }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { if autostart { session.start() } }
        .onDisappear { session.stop() }
    }

    var hud: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { session.pause() } label: {
                Image(systemName: "pause.fill").font(.system(size: 18, weight: .black)).foregroundColor(.white)
                    .frame(width: 42, height: 42).background(Circle().fill(Color.white.opacity(0.15)))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(MaiFont.heavy(14)).foregroundColor(.white).lineLimit(1)
                DifficultyBadge(difficulty: session.difficulty, level: session.level, compact: true)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.4f%%", session.engine.achievement))
                        .font(MaiFont.title(20)).foregroundColor(.white).monospacedDigit()
                    HStack(spacing: 6) {
                        if session.autoplay { Text("AUTO").font(MaiFont.heavy(10)).foregroundColor(MaiColor.cyan) }
                        Text("DX \(session.engine.dxScore)").font(MaiFont.heavy(11)).foregroundColor(MaiColor.yellow)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    var startOverlay: some View {
        VStack(spacing: 18) {
            MaiTitle(text: "READY?", size: 44)
            Toggle(isOn: $session.autoplay) { Text("Autoplay (watch the chart)").font(MaiFont.bold(16)).foregroundColor(.white) }
                .tint(MaiColor.pink)
                .frame(maxWidth: 320)
            Button("START") { session.start() }.buttonStyle(MaiButtonStyle(kind: .primary))
            Button("Back") { dismiss() }.buttonStyle(MaiButtonStyle(kind: .secondary, compact: true))
        }
        .maiPanel()
        .padding(30)
    }

    var pauseOverlay: some View {
        VStack(spacing: 16) {
            MaiTitle(text: "PAUSE", size: 38)
            Button("Resume") { session.resume() }.buttonStyle(MaiButtonStyle(kind: .primary))
            Button("Retry") { session.start() }.buttonStyle(MaiButtonStyle(kind: .secondary))
            Toggle(isOn: $session.autoplay) { Text("Autoplay").font(MaiFont.bold(15)).foregroundColor(.white) }.tint(MaiColor.pink).frame(maxWidth: 240)
            Button("Quit") { session.stop(); dismiss() }.buttonStyle(MaiButtonStyle(kind: .danger, compact: true))
        }
        .maiPanel()
        .padding(30)
    }
}

struct ResultsView: View {
    @ObservedObject var session: PlayerSession
    var onRetry: () -> Void
    var onExit: () -> Void

    var body: some View {
        let e = session.engine
        let rank = JudgeEngine.rank(e.achievement)
        VStack(spacing: 14) {
            Text("RESULT").font(MaiFont.heavy(16)).foregroundColor(MaiColor.yellow).tracking(3)
            Text(rank)
                .font(MaiFont.title(64))
                .foregroundStyle(LinearGradient(colors: rank.hasPrefix("SSS") ? [MaiColor.yellow, MaiColor.pink, MaiColor.cyan] : [.white, MaiColor.yellow], startPoint: .leading, endPoint: .trailing))
                .shadow(color: MaiColor.pink.opacity(0.7), radius: 12)
            Text(String(format: "%.4f%%", e.achievement)).font(MaiFont.title(30)).foregroundColor(.white).monospacedDigit()
            HStack(spacing: 8) {
                if e.allPerfect { badge("ALL PERFECT", MaiColor.yellow) } else if e.fullCombo { badge("FULL COMBO", MaiColor.mint) }
                badge("DX \(e.dxScore)/\(e.maxDXScore)", MaiColor.cyan)
            }
            HStack(spacing: 8) {
                StatPill(label: "CRITICAL", value: "\(e.counts[.criticalPerfect] ?? 0)", color: MaiColor.yellow)
                StatPill(label: "PERFECT", value: "\(e.counts[.perfect] ?? 0)", color: MaiColor.orange)
                StatPill(label: "GREAT", value: "\(e.counts[.great] ?? 0)", color: MaiColor.pink)
                StatPill(label: "GOOD", value: "\(e.counts[.good] ?? 0)", color: MaiColor.mint)
                StatPill(label: "MISS", value: "\(e.counts[.miss] ?? 0)", color: .gray)
            }
            HStack(spacing: 8) {
                StatPill(label: "MAX COMBO", value: "\(e.maxCombo)")
                StatPill(label: "FAST", value: "\(e.fastCount)", color: MaiColor.cyan)
                StatPill(label: "LATE", value: "\(e.lateCount)", color: MaiColor.pink)
            }
            HStack(spacing: 12) {
                Button("Retry", action: onRetry).buttonStyle(MaiButtonStyle(kind: .primary))
                Button("Exit", action: onExit).buttonStyle(MaiButtonStyle(kind: .secondary))
            }
        }
        .frame(maxWidth: 460)
        .maiPanel(accent: MaiColor.yellow)
        .padding(20)
    }

    func badge(_ text: String, _ c: Color) -> some View {
        Text(text).font(MaiFont.heavy(12)).foregroundColor(.black)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(c))
    }
}
