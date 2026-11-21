import Foundation
import SwiftUI
import UIKit
import QuartzCore
import MaiCore

/// Multi-touch input surface reporting all active touches with their hardware timestamps.
struct TouchSurface: UIViewRepresentable {
    var onTouches: (_ began: [(CGPoint, Double)], _ active: [CGPoint], _ time: Double) -> Void

    func makeUIView(context: Context) -> TouchView {
        let v = TouchView()
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        v.onTouches = onTouches
        return v
    }

    func updateUIView(_ uiView: TouchView, context: Context) { uiView.onTouches = onTouches }

    final class TouchView: UIView {
        var onTouches: ((_ began: [(CGPoint, Double)], _ active: [CGPoint], _ time: Double) -> Void)?
        private var active: [ObjectIdentifier: CGPoint] = [:]

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            var began: [(CGPoint, Double)] = []
            for t in touches {
                let p = t.location(in: self)
                active[ObjectIdentifier(t)] = p
                began.append((p, t.timestamp))
            }
            onTouches?(began, Array(active.values), touches.first?.timestamp ?? CACurrentMediaTime())
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { active[ObjectIdentifier(t)] = t.location(in: self) }
            onTouches?([], Array(active.values), touches.first?.timestamp ?? CACurrentMediaTime())
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { active[ObjectIdentifier(t)] = nil }
            onTouches?([], Array(active.values), touches.first?.timestamp ?? CACurrentMediaTime())
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchesEnded(touches, with: event) }
    }
}

struct HitEffect {
    var position: Vec2
    var judgment: Judgment
    var offset: Double
    var time: Double
    var isBreak: Bool
    var firework: Bool
    var isSlide: Bool
}

@MainActor
final class PlayerSession: ObservableObject {
    enum State { case ready, playing, paused, finished }

    let chart: PlayChart
    let first: Double
    let title: String
    let difficulty: Difficulty
    let level: String
    private(set) var engine: JudgeEngine
    private let audio: ChartAudio
    let settings: AppSettings
    @Published var state: State = .ready
    @Published var autoplay: Bool
    var lastJudgment: Judgment? = nil
    private var finishing = false
    var effects: [HitEffect] = []
    var fingers: [Vec2] = []
    var touchPoints: [CGPoint] = []
    var fieldCenter: CGPoint = .zero
    var fieldRadius: CGFloat = 1
    private var processedEvents = 0
    private var startChartTime: Double = -2

    init(chart: PlayChart, audio: AudioBuffer, first: Double, title: String, difficulty: Difficulty, level: String, settings: AppSettings, autoplay: Bool) {
        self.chart = chart
        self.first = first
        self.title = title
        self.difficulty = difficulty
        self.level = level
        self.settings = settings
        self.autoplay = autoplay
        engine = JudgeEngine(chart: chart)
        self.audio = ChartAudio(audio: audio)
        self.audio.setVolumes(music: settings.musicVolume, sfx: settings.sfxVolume)
    }

    /// Visual / judgement clock in chart seconds (includes the player calibration offset).
    var chartTime: Double { audio.audioTime - first - settings.playerOffsetMs / 1000 }

    var approachTime: Double { 4.0 / max(1, settings.noteSpeed) }
    var touchApproachTime: Double { 4.4 / max(1, settings.touchSpeed) }

    func start(fromChartTime t: Double? = nil) {
        let begin = t ?? min(-1.5, (chart.notes.first?.time ?? 0) - 2.5)
        startChartTime = begin
        engine = JudgeEngine(chart: chart)
        if let t, t > 0 {
            // practice from a point: everything before it is skipped
            engine.update(t - 0.2)
        }
        processedEvents = engine.events.count
        effects.removeAll()
        finishing = false
        audio.start(from: begin + first + settings.playerOffsetMs / 1000)
        state = .playing
    }

    func pause() {
        guard state == .playing else { return }
        audio.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        audio.resume()
        state = .playing
    }

    func stop() { audio.stop() }

    /// Called every frame by the renderer.
    func tick() {
        guard state == .playing else { return }
        let t = chartTime
        if autoplay {
            fingers = engine.autoplay(t)
        } else {
            engine.update(t)
        }
        consumeEvents(at: t)
        effects.removeAll { t - $0.time > 0.7 }
        if t > chart.finishTime + 1.5 && !finishing {
            // never publish state while SwiftUI is rendering the canvas
            finishing = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.audio.stop()
                self.state = .finished
            }
        }
    }

    private func consumeEvents(at t: Double) {
        let evs = engine.events
        guard processedEvents < evs.count else { return }
        for e in evs[processedEvents...] {
            let note = chart.notes.first { $0.id == e.noteID }
            effects.append(HitEffect(position: e.position, judgment: e.judgment, offset: e.offset, time: t, isBreak: e.isBreak,
                                     firework: note?.firework ?? false, isSlide: e.slideIndex != nil))
            if settings.hitSounds && e.judgment != .miss {
                if e.isBreak { audio.play(sound: "break") }
                else if note?.firework == true { audio.play(sound: "firework") }
                else if e.slideIndex != nil { audio.play(sound: "slide") }
                else if note?.kind == .touch || note?.kind == .touchHold { audio.play(sound: "touch") }
                else { audio.play(sound: e.judgment >= .perfect ? "tap" : "great") }
            }
            lastJudgment = e.judgment
        }
        processedEvents = evs.count
    }

    func toUnit(_ p: CGPoint) -> Vec2 {
        Vec2(Double((p.x - fieldCenter.x) / fieldRadius), Double((p.y - fieldCenter.y) / fieldRadius))
    }

    func handleTouches(began: [(CGPoint, Double)], active: [CGPoint], time: Double) {
        touchPoints = active
        guard state == .playing, !autoplay else { return }
        // touch timestamps share CACurrentMediaTime's clock; convert to chart time
        let now = CACurrentMediaTime()
        for (p, ts) in began {
            let t = chartTime - (now - ts)
            engine.touchDown(toUnit(p), at: t)
        }
        engine.touches(active.map { toUnit($0) }, at: chartTime)
        consumeEvents(at: chartTime)
    }
}
