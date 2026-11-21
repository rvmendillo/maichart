import Foundation
import MaiCore

// Developer CLI used to exercise MaiCore on Linux/macOS.
// Commands:
//   maicli chart <song.mid|.musicxml|.mxl> [seed] [outdir]
//   maicli simai-check <maidata.txt>

func fail(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

var args = CommandLine.arguments.dropFirst()
guard let cmd = args.popFirst() else { fail("usage: maicli <command> ...") }

func loadScore(_ path: String) throws -> Score {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return try MIDIFile.parse(data: data, title: url.deletingPathExtension().lastPathComponent)
}

func printChartSet(_ set: GeneratedChartSet) {
    for c in set.charts {
        let st = set.stats[c.difficulty]!
        let rep = set.reports[c.difficulty]!
        let line = String(format: "%-10@ lv %-4@ (%.1f) notes %4d  avgNPS %.2f peak %.1f each %.2f touch %.2f hold %.2f slides %d breaks %d | %@",
                          c.difficulty.displayName as NSString, c.level as NSString, c.levelValue, st.objects, st.avgNPS, st.peakNPS,
                          st.eachRatio, st.touchRatio, st.holdRatio, st.slideCount, st.breakCount, rep.description as NSString)
        print(line)
    }
}

switch cmd {
case "chart":
    guard let path = args.popFirst() else { fail("usage: maicli chart <file> [seed] [outdir]") }
    let seed = UInt64(args.popFirst() ?? "1") ?? 1
    let outDir = args.popFirst()
    do {
        let score = try loadScore(path)
        let feats = FeatureExtractor.features(from: score)
        print("title=\(feats.title) bpm=\(feats.tempo.initialBPM) melody=\(feats.melody.count) harmony=\(feats.harmony.count) drums=\(feats.drums.count) endBeat=\(feats.endBeat)")
        var opts = GeneratorOptions()
        opts.seed = seed
        let set = ChartGenerator.generate(feats, options: opts)
        printChartSet(set)
        if let o = outDir {
            try FileManager.default.createDirectory(atPath: o, withIntermediateDirectories: true)
            try set.maidata.data().write(to: URL(fileURLWithPath: o).appendingPathComponent("maidata.txt"))
            print("wrote \(o)/maidata.txt")
        }
    } catch { fail("error: \(error)") }
case "simai-check":
    guard let path = args.popFirst() else { fail("usage: maicli simai-check <maidata.txt>") }
    do {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let m = MaidataFile(text: text)
        for d in Difficulty.allCases {
            guard let body = m.chartBody(d) else { continue }
            let c = try SimaiParser.parse(body)
            print("\(d.displayName): \(c.notes.count) notes, objects \(c.objectCount), finish \(String(format: "%.2f", c.finishTime))s")
        }
    } catch { fail("error: \(error)") }
default:
    fail("unknown command \(cmd)")
}
