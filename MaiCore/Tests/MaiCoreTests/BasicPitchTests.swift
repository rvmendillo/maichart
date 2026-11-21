import XCTest
@testable import MaiCore

final class BasicPitchTests: XCTestCase {
    func load(_ name: String) throws -> [Float] {
        let d = try Data(contentsOf: ChartGeneratorTests.resource(name))
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func testNoteCreationMatchesReferenceImplementation() throws {
        let note = try load("bp_piano_note.f32")
        let onset = try load("bp_piano_onset.f32")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: ChartGeneratorTests.resource("bp_piano_notes.json"))) as! [String: Any]
        let frames = json["frames"] as! Int
        let ref = (json["notes"] as! [[Any]]).map { r in
            BasicPitch.NoteEvent(startFrame: r[0] as! Int, endFrame: r[1] as! Int, pitch: r[2] as! Int, amplitude: (r[3] as! NSNumber).doubleValue)
        }
        let mine = BasicPitch.notes(note: note, onset: onset, frameCount: frames)
        XCTAssertEqual(mine.count, ref.count)
        // identical events (order-insensitive), amplitudes equal to float precision
        let key = { (e: BasicPitch.NoteEvent) in "\(e.startFrame)-\(e.endFrame)-\(e.pitch)" }
        XCTAssertEqual(Set(mine.map(key)), Set(ref.map(key)))
        let refAmp = Dictionary(ref.map { (key($0), $0.amplitude) }, uniquingKeysWith: { a, _ in a })
        for e in mine { XCTAssertEqual(e.amplitude, refAmp[key(e)] ?? -1, accuracy: 1e-4) }
        let times = json["times"] as! [Double]
        for i in stride(from: 0, to: frames, by: 37) { XCTAssertEqual(BasicPitch.frameTime(i), times[i], accuracy: 1e-9) }
    }

    func testWindowingAndUnwrapRoundTrip() {
        let audio = (0..<100_000).map { Float($0 % 97) }
        let w = BasicPitch.windows(audio)
        XCTAssertTrue(w.allSatisfy { $0.count == BasicPitch.windowSamples })
        // fake model output: frame index encoded as value -> unwrap must be contiguous
        let outs: [[Float]] = w.indices.map { wi in (0..<172).flatMap { f in [Float](repeating: Float(wi * 1000 + f), count: 2) } }
        let u = BasicPitch.unwrap(outs, bins: 2, originalLength: audio.count)
        XCTAssertEqual(u.count / 2, Int(floor(Double(audio.count) * 86 / 22050)))
        XCTAssertEqual(u[0], 15)            // first kept frame of window 0
        XCTAssertEqual(u[2 * 142], 1015)    // first kept frame of window 1
    }
}
