import SwiftUI
import MaiCore

@MainActor
enum PlayfieldRenderer {
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, s: PlayerSession) {
        let t = s.chartTime
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = min(size.width, size.height) * 0.42
        s.fieldCenter = c
        s.fieldRadius = R
        func pt(_ v: Vec2) -> CGPoint { CGPoint(x: c.x + CGFloat(v.x) * R, y: c.y + CGFloat(v.y) * R) }
        func polar(_ deg: Double, _ r: Double) -> CGPoint { pt(Vec2.polar(angle: deg, radius: r)) }

        // ---------- field
        let disc = Path(ellipseIn: CGRect(x: c.x - R * 1.02, y: c.y - R * 1.02, width: R * 2.04, height: R * 2.04))
        ctx.fill(disc, with: .radialGradient(Gradient(colors: [Color(red: 0.1, green: 0.08, blue: 0.24), Color(red: 0.03, green: 0.03, blue: 0.1)]),
                                             center: c, startRadius: 0, endRadius: R))
        if s.settings.showSensors { drawSensors(&ctx, c: c, R: R) }
        if s.settings.showGuides {
            for b in 1...8 {
                var p = Path()
                p.move(to: polar(Geometry.buttonAngle(b), 0.26))
                p.addLine(to: polar(Geometry.buttonAngle(b), 1.0))
                ctx.stroke(p, with: .color(.white.opacity(0.09)), lineWidth: 1.5)
            }
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - R * 0.26, y: c.y - R * 0.26, width: R * 0.52, height: R * 0.52)), with: .color(.white.opacity(0.08)), lineWidth: 1.5)
        }
        // judgement ring
        let ringRect = CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)
        ctx.stroke(Path(ellipseIn: ringRect), with: .color(MaiColor.pink.opacity(0.25)), lineWidth: R * 0.06)
        ctx.stroke(Path(ellipseIn: ringRect), with: .color(.white.opacity(0.92)), lineWidth: R * 0.016)
        // button pads (light up under fingers)
        let fingersUnit = s.autoplay ? s.fingers : s.touchPoints.map { s.toUnit($0) }
        for b in 1...8 {
            let a = Geometry.buttonAngle(b)
            let pressed = fingersUnit.contains { SensorLayout.buttonHit(b, $0) }
            let center = polar(a, 1.12)
            var pad = Path(roundedRect: CGRect(x: -R * 0.09, y: -R * 0.035, width: R * 0.18, height: R * 0.07), cornerRadius: R * 0.035)
            pad = pad.applying(CGAffineTransform(rotationAngle: CGFloat(a * .pi / 180)).concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
            ctx.fill(pad, with: .color(pressed ? MaiColor.yellow : Color.white.opacity(0.75)))
            if pressed {
                ctx.stroke(pad, with: .color(MaiColor.yellow.opacity(0.5)), lineWidth: R * 0.05)
            }
        }

        let T = s.approachTime
        let TT = s.touchApproachTime
        func progress(_ hit: Double) -> Double { 1 - (hit - t) / T }
        func laneR(_ p: Double) -> Double { 0.26 + 0.74 * max(0, min(1, p)) }
        func color(_ n: PlayNote) -> Color {
            if n.isBreak { return MaiColor.breakOrange }
            if n.isEach { return MaiColor.eachYellow }
            switch n.kind {
            case .star: return MaiColor.slideBlue
            case .touch, .touchHold: return MaiColor.touchBlue
            default: return MaiColor.tapPink
            }
        }

        // ---------- slide paths (under notes)
        for (ni, n) in s.chart.notes.enumerated() where !n.slides.isEmpty {
            let appear = n.time - T
            guard t >= appear - 0.3 else { continue }
            for (si, sl) in n.slides.enumerated() {
                guard t <= sl.endTime + 0.15 else { continue }
                let fadeIn = max(0, min(1, (t - appear + 0.3) / 0.45))
                let consumed: Double
                if s.autoplay || t >= sl.startTime {
                    let timeProg = max(0, min(1, (t - sl.startTime) / sl.duration))
                    consumed = s.autoplay ? timeProg : max(s.engine.slideProgress(note: ni, slide: si), 0)
                } else { consumed = 0 }
                let col = sl.isBreak ? MaiColor.breakOrange : (sl.isEach ? MaiColor.eachYellow : MaiColor.slideBlue)
                let step = 0.11
                var d = step * 0.5
                while d < sl.totalLength {
                    if d / sl.totalLength >= consumed {
                        let p = sl.point(atDistance: d)
                        let dir = sl.direction(atDistance: d)
                        let ang = atan2(dir.y, dir.x)
                        var chev = Path()
                        chev.move(to: CGPoint(x: -0.035, y: -0.045)); chev.addLine(to: CGPoint(x: 0.02, y: 0)); chev.addLine(to: CGPoint(x: -0.035, y: 0.045))
                        chev = chev.applying(CGAffineTransform(scaleX: R, y: R).concatenating(CGAffineTransform(rotationAngle: CGFloat(ang))).concatenating(CGAffineTransform(translationX: pt(p).x, y: pt(p).y)))
                        ctx.stroke(chev, with: .color(col.opacity(0.9 * fadeIn)), style: StrokeStyle(lineWidth: R * 0.022, lineCap: .round, lineJoin: .round))
                    }
                    d += step
                }
                for branch in sl.extraBranches where branch.count == 2 {
                    var p = Path(); p.move(to: pt(branch[0])); p.addLine(to: pt(branch[1]))
                    ctx.stroke(p, with: .color(col.opacity(0.35 * fadeIn)), style: StrokeStyle(lineWidth: R * 0.012, dash: [R * 0.03, R * 0.04]))
                }
                // travelling star
                if t >= sl.startTime && t <= sl.endTime {
                    let f = (t - sl.startTime) / sl.duration
                    let p = pt(sl.point(atDistance: sl.totalLength * f))
                    drawStar(&ctx, at: p, radius: R * 0.075, rotation: t * 4, color: col, alpha: 0.95)
                }
            }
        }

        // ---------- notes (later first so earlier notes are on top)
        for (ni, n) in s.chart.notes.enumerated().reversed() {
            let col = color(n)
            switch n.kind {
            case .tap, .star, .hold:
                guard let b = n.button else { continue }
                let p = progress(n.time)
                if p < -0.15 { continue }
                let judged = s.engine.headJudged(note: ni)
                let ang = Geometry.buttonAngle(b)
                if n.kind == .hold {
                    let endP = progress(n.time + n.length)
                    if t > n.time + n.length + 0.05 { continue }
                    if judged && !s.engine.isHolding(note: ni) && !s.autoplay && t > n.time + 0.15 { continue }
                    let head = laneR(p), tail = laneR(endP)
                    drawHold(&ctx, c: c, R: R, angle: ang, head: min(1, head), tail: min(head, tail), color: col,
                             active: s.engine.isHolding(note: ni) || (s.autoplay && t >= n.time), alpha: min(1, (p + 0.15) * 4))
                    continue
                }
                if judged || p > 1.08 { continue }
                let scale = CGFloat(0.45 + 0.55 * min(1, max(0, p) * 1.8))
                let alpha = min(1, (p + 0.15) * 4)
                let pos = polar(ang, laneR(p))
                if n.kind == .star {
                    drawStar(&ctx, at: pos, radius: R * 0.085 * scale, rotation: -t * 2.2, color: col, alpha: alpha)
                } else {
                    drawTap(&ctx, at: pos, radius: R * 0.078 * scale, color: col, alpha: alpha, ex: n.isEx, isBreak: n.isBreak, t: t)
                }
            case .touch, .touchHold:
                guard let area = n.area else { continue }
                let p = 1 - (n.time - t) / TT
                if p < 0 { continue }
                let pos = pt(SensorLayout.position(area))
                if n.kind == .touchHold {
                    if t > n.time + n.length + 0.05 { continue }
                    if s.engine.isJudged(note: ni) { continue }
                    if t >= n.time {
                        let f = max(0, min(1, (t - n.time) / max(0.01, n.length)))
                        drawTouchHoldProgress(&ctx, at: pos, R: R, fraction: f, color: col)
                        continue
                    }
                } else if s.engine.headJudged(note: ni) || p > 1.15 { continue }
                drawTouch(&ctx, at: pos, R: R, closing: max(0, min(1, p)), color: col, alpha: min(1, p * 3), hold: n.kind == .touchHold, firework: n.firework)
            }
        }

        // ---------- effects
        for e in s.effects {
            let age = t - e.time
            let pos = pt(e.position)
            if e.judgment != .miss {
                let ec: Color
                switch e.judgment {
                case .criticalPerfect: ec = MaiColor.yellow
                case .perfect: ec = MaiColor.orange
                case .great: ec = MaiColor.pink
                default: ec = MaiColor.mint
                }
                let f = min(1, age / 0.35)
                let rr = R * CGFloat(0.05 + 0.13 * f)
                ctx.stroke(Path(ellipseIn: CGRect(x: pos.x - rr, y: pos.y - rr, width: 2 * rr, height: 2 * rr)), with: .color(ec.opacity(1 - f)), lineWidth: R * 0.03 * CGFloat(1 - f) + 1)
                if e.isBreak || e.firework {
                    for k in 0..<10 {
                        let a = Double(k) * 36 + age * 60
                        var ray = Path()
                        ray.move(to: CGPoint(x: pos.x + CGFloat(cos(a * .pi / 180)) * rr * 0.6, y: pos.y + CGFloat(sin(a * .pi / 180)) * rr * 0.6))
                        ray.addLine(to: CGPoint(x: pos.x + CGFloat(cos(a * .pi / 180)) * rr * (e.firework ? 2.4 : 1.5), y: pos.y + CGFloat(sin(a * .pi / 180)) * rr * (e.firework ? 2.4 : 1.5)))
                        ctx.stroke(ray, with: .color(ec.opacity(1 - f)), lineWidth: 2)
                    }
                }
            }
            // judgement text pops slightly towards the centre
            let ta = max(0, 1 - max(0, age - 0.35) / 0.3)
            let bounce: CGFloat = age < 0.08 ? CGFloat(1.25 - age * 3) : 1.0
            let dir = e.position.length > 0.01 ? e.position * (1 / e.position.length) : Vec2(0, -1)
            let tp = pt(e.position - dir * 0.22)
            let label: Text
            switch e.judgment {
            case .criticalPerfect:
                label = Text("CRITICAL").font(.system(size: R * 0.075 * bounce, weight: .black, design: .rounded)).foregroundColor(MaiColor.yellow)
            case .perfect:
                label = Text("PERFECT").font(.system(size: R * 0.075 * bounce, weight: .black, design: .rounded)).foregroundColor(MaiColor.orange)
            case .great:
                label = Text("GREAT").font(.system(size: R * 0.07 * bounce, weight: .black, design: .rounded)).foregroundColor(MaiColor.pink)
            case .good:
                label = Text("GOOD").font(.system(size: R * 0.065 * bounce, weight: .black, design: .rounded)).foregroundColor(MaiColor.mint)
            case .miss:
                label = Text("MISS").font(.system(size: R * 0.065 * bounce, weight: .black, design: .rounded)).foregroundColor(.gray)
            }
            ctx.opacity = ta
            ctx.draw(label, at: tp)
            if e.judgment != .criticalPerfect && e.judgment != .miss && abs(e.offset) > 0.0167 {
                let fl = Text(e.offset < 0 ? "FAST" : "LATE").font(.system(size: R * 0.04, weight: .heavy, design: .rounded))
                    .foregroundColor(e.offset < 0 ? MaiColor.cyan : MaiColor.pink)
                ctx.draw(fl, at: CGPoint(x: tp.x, y: tp.y + R * 0.07))
            }
            ctx.opacity = 1
        }

        // ---------- touches
        for f in fingersUnit {
            let p = pt(f)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - R * 0.07, y: p.y - R * 0.07, width: R * 0.14, height: R * 0.14)),
                     with: .radialGradient(Gradient(colors: [Color.white.opacity(0.5), Color.white.opacity(0)]), center: p, startRadius: 0, endRadius: R * 0.07))
        }

        // ---------- centre combo
        let combo = s.engine.combo
        if combo >= 2 {
            ctx.draw(Text("\(combo)").font(.system(size: R * 0.2, weight: .black, design: .rounded)).foregroundColor(.white.opacity(0.92)), at: CGPoint(x: c.x, y: c.y - R * 0.03))
            ctx.draw(Text("COMBO").font(.system(size: R * 0.055, weight: .heavy, design: .rounded)).foregroundColor(MaiColor.yellow.opacity(0.9)), at: CGPoint(x: c.x, y: c.y + R * 0.12))
        }
    }

    static func drawTap(_ ctx: inout GraphicsContext, at p: CGPoint, radius r: CGFloat, color: Color, alpha: Double, ex: Bool, isBreak: Bool, t: Double) {
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        if ex { ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -r * 0.35, dy: -r * 0.35)), with: .color(.white.opacity(0.55 * alpha)), lineWidth: r * 0.25) }
        ctx.stroke(Path(ellipseIn: rect), with: .color(color.opacity(alpha)), lineWidth: r * 0.48)
        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: r * 0.2, dy: r * 0.2)), with: .color(.white.opacity(0.85 * alpha)), lineWidth: r * 0.12)
        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -r * 0.22, dy: -r * 0.22)), with: .color(.white.opacity(0.9 * alpha)), lineWidth: r * 0.1)
        if isBreak {
            let flick = 0.5 + 0.5 * sin(t * 30)
            ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.45 * flick * alpha)), lineWidth: r * 0.2)
        }
    }

    static func starPath(at p: CGPoint, radius r: CGFloat, rotation: Double) -> Path {
        var path = Path()
        for i in 0..<10 {
            let rr = i % 2 == 0 ? r : r * 0.45
            let a = rotation + Double(i) * .pi / 5 - .pi / 2
            let q = CGPoint(x: p.x + CGFloat(cos(a)) * rr, y: p.y + CGFloat(sin(a)) * rr)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        path.closeSubpath()
        return path
    }

    static func drawStar(_ ctx: inout GraphicsContext, at p: CGPoint, radius r: CGFloat, rotation: Double, color: Color, alpha: Double) {
        let path = starPath(at: p, radius: r, rotation: rotation)
        ctx.fill(path, with: .color(color.opacity(alpha)))
        ctx.stroke(path, with: .color(.white.opacity(0.95 * alpha)), style: StrokeStyle(lineWidth: r * 0.16, lineJoin: .round))
        ctx.fill(starPath(at: p, radius: r * 0.45, rotation: rotation), with: .color(.white.opacity(0.7 * alpha)))
    }

    static func drawHold(_ ctx: inout GraphicsContext, c: CGPoint, R: CGFloat, angle: Double, head: Double, tail: Double, color: Color, active: Bool, alpha: Double) {
        let w = 0.06
        func p(_ r: Double, _ side: Double) -> CGPoint {
            let base = Vec2.polar(angle: angle, radius: r)
            let perp = Vec2.polar(angle: angle + 90, radius: side)
            let v = base + perp
            return CGPoint(x: c.x + CGFloat(v.x) * R, y: c.y + CGFloat(v.y) * R)
        }
        var hex = Path()
        hex.move(to: p(tail - w, 0)); hex.addLine(to: p(tail, -w)); hex.addLine(to: p(head, -w))
        hex.addLine(to: p(head + w, 0)); hex.addLine(to: p(head, w)); hex.addLine(to: p(tail, w)); hex.closeSubpath()
        ctx.fill(hex, with: .color(color.opacity((active ? 0.55 : 0.3) * alpha)))
        ctx.stroke(hex, with: .color(color.opacity(alpha)), style: StrokeStyle(lineWidth: R * 0.03, lineJoin: .round))
        ctx.stroke(hex, with: .color(.white.opacity((active ? 0.95 : 0.7) * alpha)), style: StrokeStyle(lineWidth: R * 0.009, lineJoin: .round))
    }

    /// Touch note: four triangles closing in on the sensor like a timer.
    static func drawTouch(_ ctx: inout GraphicsContext, at p: CGPoint, R: CGFloat, closing: Double, color: Color, alpha: Double, hold: Bool, firework: Bool) {
        let dist = R * CGFloat(0.045 + 0.17 * (1 - closing))
        let size = R * 0.055
        for k in 0..<4 {
            let a = Double(k) * .pi / 2 + (hold ? .pi / 4 : 0)
            let dir = CGPoint(x: CGFloat(cos(a)), y: CGFloat(sin(a)))
            let tip = CGPoint(x: p.x + dir.x * dist, y: p.y + dir.y * dist)
            let baseC = CGPoint(x: tip.x + dir.x * size * 1.2, y: tip.y + dir.y * size * 1.2)
            let perp = CGPoint(x: -dir.y, y: dir.x)
            var tri = Path()
            tri.move(to: tip)
            tri.addLine(to: CGPoint(x: baseC.x + perp.x * size, y: baseC.y + perp.y * size))
            tri.addLine(to: CGPoint(x: baseC.x - perp.x * size, y: baseC.y - perp.y * size))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(color.opacity(alpha)))
            ctx.stroke(tri, with: .color(.white.opacity(0.9 * alpha)), style: StrokeStyle(lineWidth: R * 0.008, lineJoin: .round))
        }
        let d = R * 0.022
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - d, y: p.y - d, width: 2 * d, height: 2 * d)), with: .color(.white.opacity(alpha)))
        if firework {
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - dist - size, y: p.y - dist - size, width: 2 * (dist + size), height: 2 * (dist + size))),
                       with: .color(MaiColor.yellow.opacity(0.35 * alpha)), lineWidth: 1.5)
        }
    }

    static func drawTouchHoldProgress(_ ctx: inout GraphicsContext, at p: CGPoint, R: CGFloat, fraction: Double, color: Color) {
        let r = R * 0.13
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.25)), lineWidth: R * 0.035)
        let colors = [MaiColor.pink, MaiColor.yellow, MaiColor.mint, MaiColor.cyan]
        for q in 0..<4 {
            let q0 = Double(q) * 0.25
            guard fraction > q0 else { continue }
            let q1 = min(fraction, q0 + 0.25)
            var arc = Path()
            arc.addArc(center: p, radius: r, startAngle: .degrees(-90 + q0 * 360), endAngle: .degrees(-90 + q1 * 360), clockwise: false)
            ctx.stroke(arc, with: .color(colors[q]), style: StrokeStyle(lineWidth: R * 0.035, lineCap: .round))
        }
        ctx.fill(Path(ellipseIn: rect.insetBy(dx: r * 0.55, dy: r * 0.55)), with: .color(color.opacity(0.8)))
    }

    static func drawSensors(_ ctx: inout GraphicsContext, c: CGPoint, R: CGFloat) {
        let col = Color.white.opacity(0.07)
        for r in [SensorLayout.centerRadius, SensorLayout.innerRadius] {
            let rr = R * CGFloat(r)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)), with: .color(col), lineWidth: 1)
        }
        for k in 0..<8 {
            for off in [-15.0, 15.0] {
                let a = Geometry.buttonAngle(k + 1) + off
                var p = Path()
                p.move(to: CGPoint(x: c.x + CGFloat(sin(a * .pi / 180)) * R * CGFloat(SensorLayout.centerRadius), y: c.y - CGFloat(cos(a * .pi / 180)) * R * CGFloat(SensorLayout.centerRadius)))
                p.addLine(to: CGPoint(x: c.x + CGFloat(sin(a * .pi / 180)) * R * 1.05, y: c.y - CGFloat(cos(a * .pi / 180)) * R * 1.05))
                ctx.stroke(p, with: .color(col), lineWidth: 1)
            }
        }
        let labels: [TouchArea] = (1...8).flatMap { [TouchArea.a($0), .b($0), .d($0), .e($0)] } + [.c]
        for a in labels {
            let v = SensorLayout.position(a)
            ctx.draw(Text(a.simai).font(.system(size: R * 0.035, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.22)),
                     at: CGPoint(x: c.x + CGFloat(v.x) * R, y: c.y + CGFloat(v.y) * R))
        }
    }
}
