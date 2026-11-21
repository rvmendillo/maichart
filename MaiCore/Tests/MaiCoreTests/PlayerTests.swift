import XCTest
@testable import MaiCore

final class PlayerTests: XCTestCase {
    func chart(_ s: String) throws -> PlayChart { PlayChart(try SimaiParser.parse(s)) }

    func testAutoplayAchievesAllPerfect101() throws {
        let set = ChartGenerator.generate(FeatureExtractor.features(from: try MIDIFile.parse(data: Data(contentsOf: ChartGeneratorTests.resource("pop160.mid")))))
        let m = MaidataFile(text: set.maidata.text())
        for d in [Difficulty.basic, .master, .remaster] {
            let pc = PlayChart(try SimaiParser.parse(m.chartBody(d)!))
            let eng = JudgeEngine(chart: pc)
            var t = -1.0
            while t < pc.finishTime + 2 { _ = eng.autoplay(t); t += 1.0 / 120 }
            XCTAssertTrue(eng.isFinished, "\(d) not finished")
            XCTAssertEqual(eng.judgedObjects, eng.totalObjects, "\(d)")
            XCTAssertEqual(eng.counts[.miss] ?? 0, 0, "\(d) autoplay missed")
            XCTAssertTrue(eng.fullCombo)
            XCTAssertGreaterThanOrEqual(eng.achievement, 100.9, "\(d) autoplay achievement \(eng.achievement)")
            XCTAssertEqual(JudgeEngine.rank(eng.achievement), "SSS+")
        }
    }

    func testTimingWindowsAndMisses() throws {
        let pc = try chart("(120){4}1,2,3,4,E")   // taps at 0, .5, 1, 1.5 s
        let e = JudgeEngine(chart: pc)
        let p = { (b: Int) in Vec2.polar(angle: Geometry.buttonAngle(b), radius: 1) }
        XCTAssertEqual(e.touchDown(p(1), at: 0.010)?.judgment, .criticalPerfect)
        XCTAssertEqual(e.touchDown(p(2), at: 0.525)?.judgment, .perfect)
        XCTAssertEqual(e.touchDown(p(3), at: 0.93)?.judgment, .great)
        XCTAssertNil(e.touchDown(p(4), at: 1.2), "too early / wrong time must not consume")
        e.update(1.8)
        XCTAssertEqual(e.counts[.miss], 1)
        XCTAssertEqual(e.combo, 0)
        XCTAssertEqual(e.maxCombo, 3)
        XCTAssertEqual(e.fastCount, 1)
        XCTAssertEqual(e.lateCount, 1)
    }

    func testWrongButtonDoesNotHit() throws {
        let e = JudgeEngine(chart: try chart("(120){4}1,E"))
        XCTAssertNil(e.touchDown(Vec2.polar(angle: Geometry.buttonAngle(5), radius: 1), at: 0))
        XCTAssertNotNil(e.touchDown(Vec2.polar(angle: Geometry.buttonAngle(1), radius: 0.9), at: 0))
    }

    func testSlidePathsEndOnTargetButtons() throws {
        for shape in ["-", ">", "<", "^", "v", "p", "q", "pp", "qq", "V", "w"] {
            for start in 1...8 {
                var target = Geometry.wrap(start + 3)
                var verts = [target]
                if shape == "V" { verts = [Geometry.wrap(start + 2), Geometry.wrap(start + 4)]; target = verts.last! }
                let (pts, _) = SlideGeometry.path(start: start, segments: [SlideSegment(shape: shape, vertices: verts)])
                XCTAssertLessThan(pts.first!.distance(to: Vec2.polar(angle: Geometry.buttonAngle(start), radius: 1)), 1e-6)
                XCTAssertLessThan(pts.last!.distance(to: Vec2.polar(angle: Geometry.buttonAngle(target), radius: 1)), 1e-6, "\(start)\(shape)\(target)")
            }
        }
        // '>' from button 1 goes clockwise (through button 2)
        let (cw, _) = SlideGeometry.path(start: 1, segments: [SlideSegment(shape: ">", vertices: [4])])
        XCTAssertTrue(cw.contains { $0.distance(to: Vec2.polar(angle: Geometry.buttonAngle(2), radius: 1)) < 0.05 })
        // '>' from button 4 (bottom half) goes counter-clockwise
        let (ccw, _) = SlideGeometry.path(start: 4, segments: [SlideSegment(shape: ">", vertices: [1])])
        XCTAssertTrue(ccw.contains { $0.distance(to: Vec2.polar(angle: Geometry.buttonAngle(3), radius: 1)) < 0.05 })
    }

    func testSensorAreasAndHolds() throws {
        XCTAssertEqual(SensorLayout.area(at: Vec2(0, 0)), .c)
        for i in 1...8 {
            XCTAssertEqual(SensorLayout.area(at: Vec2.polar(angle: Geometry.buttonAngle(i), radius: 0.48)), .b(i))
            XCTAssertEqual(SensorLayout.area(at: Vec2.polar(angle: Geometry.buttonAngle(i), radius: 0.9)), .a(i))
            XCTAssertEqual(SensorLayout.area(at: Vec2.polar(angle: Double(i - 1) * 45, radius: 0.9)), .d(i))
            XCTAssertEqual(SensorLayout.area(at: Vec2.polar(angle: Double(i - 1) * 45, radius: 0.6)), .e(i))
        }
        // hold released early is downgraded
        let e = JudgeEngine(chart: try chart("(60){4}1h[4:2],E")) // 2 s hold
        let p1 = Vec2.polar(angle: Geometry.buttonAngle(1), radius: 1)
        e.touchDown(p1, at: 0)
        var t = 0.0
        while t < 0.8 { e.touches([p1], at: t); t += 0.05 }
        e.touches([], at: 0.85)
        e.update(2.5)
        XCTAssertEqual(e.events.last?.judgment, .great)
    }

    func testSlideTracingJudgesByCompletionTime() throws {
        let pc = try chart("(60){4}1-5[4:1],E") // star at 0, slide 1..2 s
        let e = JudgeEngine(chart: pc)
        e.touchDown(pc.notes[0].position, at: 0)
        let s = pc.notes[0].slides[0]
        var t = 1.0
        while t <= 2.0 {
            e.touches([s.point(atDistance: s.totalLength * (t - 1.0))], at: t)
            t += 1.0 / 60
        }
        XCTAssertEqual(e.events.count, 2)
        XCTAssertEqual(e.events.last?.judgment, .criticalPerfect)
    }
}
