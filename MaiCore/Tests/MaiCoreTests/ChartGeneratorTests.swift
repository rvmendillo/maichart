import XCTest
@testable import MaiCore

final class ChartGeneratorTests: XCTestCase {
    static func resource(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources").appendingPathComponent(name)
    }

    func generate(_ file: String, seed: UInt64 = 1) throws -> GeneratedChartSet {
        let score = try MIDIFile.parse(data: Data(contentsOf: Self.resource(file)), title: file)
        var o = GeneratorOptions()
        o.seed = seed
        return ChartGenerator.generate(FeatureExtractor.features(from: score), options: o)
    }

    func testAllDifficultiesNestedPlayableAndParsable() throws {
        for file in ["pop160.mid", "ballad_tempo.mid", "piano_solo.mid"] {
            let set = try generate(file)
            XCTAssertEqual(set.charts.count, 6, file)
            var previous: Chart? = nil
            for chart in set.charts {
                XCTAssertFalse(chart.notes.isEmpty, "\(file) \(chart.difficulty) empty")
                let report = set.reports[chart.difficulty]!
                XCTAssertTrue(report.isPlayable, "\(file) \(chart.difficulty) not playable: \(report)")
                XCTAssertEqual(report.unequalEachHolds, 0, "\(file) \(chart.difficulty) unequal simultaneous holds")
                XCTAssertLessThanOrEqual(report.maxSimultaneous, 2)
                if let p = previous {
                    // nesting: every lower-difficulty moment exists in the next difficulty
                    let higher = Set(chart.notes.map { $0.tick })
                    let lower = Set(p.notes.map { $0.tick })
                    XCTAssertTrue(lower.isSubset(of: higher), "\(file): \(p.difficulty) not nested in \(chart.difficulty) (\(lower.subtracting(higher).count) extra)")
                    XCTAssertGreaterThanOrEqual(chart.notes.count, p.notes.count)
                    XCTAssertGreaterThanOrEqual(chart.levelValue, p.levelValue)
                    // related layouts: most shared moments keep the same button
                    var same = 0, total = 0
                    let hiByTick = Dictionary(grouping: chart.notes, by: { $0.tick })
                    for n in p.notes {
                        guard let b = n.button, let hs = hiByTick[n.tick] else { continue }
                        total += 1
                        if hs.contains(where: { $0.button == b || $0.touchArea?.nearestButton == b }) { same += 1 }
                    }
                    if total > 10 { XCTAssertGreaterThan(Double(same) / Double(total), 0.6, "\(file) \(p.difficulty) layout unrelated to \(chart.difficulty)") }
                }
                previous = chart
            }
            // the written maidata parses back with identical note counts and timing
            let text = set.maidata.text()
            let m = MaidataFile(text: text)
            for chart in set.charts {
                let body = try XCTUnwrap(m.chartBody(chart.difficulty))
                let parsed = try SimaiParser.parse(body)
                XCTAssertEqual(parsed.notes.count, chart.notes.count, "\(file) \(chart.difficulty) round trip")
                let firstNote = parsed.notes.map { $0.time }.min() ?? 0
                XCTAssertGreaterThanOrEqual(firstNote + m.first, 1.2 - 1e-6, "notes must not start before 1.2 s of audio")
            }
            XCTAssertEqual(m.level(.remaster), set.chart(.remaster)?.level)
        }
    }

    func testReMasterUsesTricksAndIsHarderThanMaster() throws {
        let set = try generate("pop160.mid")
        let rm = try XCTUnwrap(set.chart(.remaster))
        let ma = try XCTUnwrap(set.chart(.master))
        XCTAssertGreaterThan(rm.notes.count, ma.notes.count)
        XCTAssertGreaterThan(rm.levelValue, ma.levelValue)
        let touchesOffCentre = rm.notes.filter { if case .touch(let a) = $0.kind { return !a.isCenter } else { return false } }
        XCTAssertGreaterThan(touchesOffCentre.count, 10, "touch notes should sit on A/B/D/E sensors, not only the centre")
        XCTAssertTrue(rm.notes.contains { if case .touchHold(.c, _) = $0.kind { return true } else { return false } }, "centre touch hold expected")
        let eachTicks = Dictionary(grouping: rm.notes, by: { $0.tick }).filter { $0.value.count == 2 }
        XCTAssertGreaterThan(eachTicks.count, 8, "EACH pairs expected")
        // circle runs: at least one run of 4 consecutive notes stepping around the ring one button at a time
        let taps = rm.notes.compactMap { n -> (Int, Int)? in if case .tap(let b) = n.kind { return (n.tick, b) } else { return nil } }
        var longest = 1, run = 1
        for k in 1..<taps.count {
            let d = Geometry.wrap(taps[k].1 - taps[k - 1].1 + 8)
            if (d == 1 || d == 7) && taps[k].0 - taps[k - 1].0 <= ticksPerBeat / 2 { run += 1; longest = max(longest, run) } else { run = 1 }
        }
        XCTAssertGreaterThanOrEqual(longest, 4, "expected circle-run streams")
        XCTAssertGreaterThan(rm.notes.filter { $0.isBreak }.count, 0)
        // slides stay rare
        XCTAssertLessThanOrEqual(rm.notes.filter { $0.isSlide }.count, 4)
    }

    func testDeterministicAndRemixChanges() throws {
        let a = try generate("pop160.mid", seed: 7).maidata.text()
        let b = try generate("pop160.mid", seed: 7).maidata.text()
        let c = try generate("pop160.mid", seed: 8).maidata.text()
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testLowerLevelsUseSimpleRhythms() throws {
        let set = try generate("pop160.mid")
        let easy = try XCTUnwrap(set.chart(.easy))
        XCTAssertTrue(easy.notes.allSatisfy { $0.tick % ticksPerBeat == 0 }, "EASY should only use quarter-note positions")
        XCTAssertTrue(easy.notes.allSatisfy { !$0.isTouch && !$0.isSlide })
        let basic = try XCTUnwrap(set.chart(.basic))
        XCTAssertTrue(basic.notes.allSatisfy { $0.tick % (ticksPerBeat / 2) == 0 }, "BASIC should only use eighth-note positions")
        XCTAssertEqual(Dictionary(grouping: basic.notes, by: { $0.tick }).filter { $0.value.count > 1 }.count, 0, "no EACH in BASIC")
    }
}
