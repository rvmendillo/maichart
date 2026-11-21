import Foundation

/// 8-bit grayscale page image (0 = black ink, 255 = white paper).
public struct GrayImage {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    @inline(__always) public func isInk(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height && pixels[y * width + x] < 128
    }
}

/// Optical music recognition for clean, printed (engraved) scores.
/// Handles staves, treble/bass clefs, key signatures, accidentals, filled/hollow noteheads, chords,
/// stems, beams/flags, augmentation dots, common rests and barlines. Complex polyphony, tuplets,
/// grace notes and handwritten scores are out of scope (MusicXML import is exact for those).
public enum OMR {
    public struct Result {
        public var score: Score
        public var pages: Int
        public var staves: Int
        public var systems: Int
        public var notes: Int
        public var warnings: [String]
    }

    struct Staff {
        var lines: [Double]       // y of the 5 lines, top to bottom
        var space: Double
        var thickness: Double
        var x0: Int
        var x1: Int
        var clef: Clef = .treble
        var keyFifths = 0
        var contentStart: Int = 0
        var top: Double { lines[0] }
        var bottom: Double { lines[4] }
    }

    enum Clef { case treble, bass }

    struct Glyph {
        enum Kind { case note(filled: Bool, stemmed: Bool), rest(Double) }
        var x: Double
        var y: Double
        var step: Int             // half-spaces above the bottom line
        var kind: Kind
        var duration: Double = 1  // quarter notes
        var accidental: Int? = nil
    }

    // MARK: Entry

    public static func recognize(pages: [GrayImage], title: String = "", tempoBPM: Double = 100,
                                 progress: ((Int, Double) -> Void)? = nil) -> Result {
        var notes: [MusicNote] = []
        var warnings: [String] = []
        var beat = 0.0
        var staffCount = 0, systemCount = 0
        var meterVotes: [Double: Int] = [:]
        for (pi, page) in pages.enumerated() {
            progress?(pi + 1, Double(pi) / Double(max(1, pages.count)))
            let bin = binarize(page)
            var staves = findStaves(bin)
            if staves.isEmpty { warnings.append("Page \(pi + 1): no staves found"); continue }
            staffCount += staves.count
            let clean = removeStaffLines(bin, staves)
            let integral = Integral(clean)
            let systems = groupSystems(clean, staves)
            systemCount += systems.count
            for sys in systems {
                for si in sys { analyseStaffHeader(clean, &staves[si], systemSize: sys.count, index: sys.firstIndex(of: si)!) }
                // barlines shared by the system
                var bars = findBarlines(clean, staves, sys)
                let left = sys.map { staves[$0].contentStart }.max() ?? 0
                let right = sys.map { staves[$0].x1 }.min() ?? clean.width
                bars = bars.filter { $0 > left + 4 && $0 < right - 4 }
                let edges = [left] + bars + [right]
                var perStaffMeasures: [[[Glyph]]] = []
                for si in sys {
                    let glyphs = findGlyphs(clean, integral, staves[si], original: bin)
                    var measures: [[Glyph]] = []
                    for k in 0..<(edges.count - 1) {
                        measures.append(glyphs.filter { $0.x >= Double(edges[k]) && $0.x < Double(edges[k + 1]) })
                    }
                    perStaffMeasures.append(measures)
                }
                let measureCount = edges.count - 1
                // first pass: musical length of each measure (sum of durations of the busiest staff)
                var sums: [Double] = []
                for m in 0..<measureCount {
                    var best = 0.0
                    for k in sys.indices {
                        let gs = perStaffMeasures[k][m].sorted { $0.x < $1.x }
                        var t = 0.0, i = 0
                        while i < gs.count {
                            var j = i + 1
                            while j < gs.count && abs(gs[j].x - gs[i].x) < staves[sys[k]].space * 0.7 { j += 1 }
                            t += gs[i..<j].map { $0.duration }.min() ?? 1
                            i = j
                        }
                        best = max(best, t)
                    }
                    sums.append(best)
                    if best > 0 { meterVotes[(best * 4).rounded() / 4, default: 0] += 1 }
                }
                let meterHere = meterVotes.max { $0.value < $1.value }?.key ?? 4
                for m in 0..<measureCount {
                    let isPickup = m == 0 && sums[m] > 0 && sums[m] < meterHere - 0.01 && beat == 0
                    let measureLen = isPickup ? sums[m] : meterHere
                    var events: [[(start: Double, glyph: Glyph, staff: Int)]] = []
                    let xa = Double(edges[m]), xb = Double(edges[m + 1])
                    for (k, si) in sys.enumerated() {
                        let gs = perStaffMeasures[k][m].sorted { $0.x < $1.x }
                        // chords: noteheads within 0.7 space horizontally share an onset
                        var groups: [[Glyph]] = []
                        var i = 0
                        let sp = staves[si].space
                        while i < gs.count {
                            var j = i + 1
                            while j < gs.count && abs(gs[j].x - gs[i].x) < sp * 0.7 { j += 1 }
                            groups.append(Array(gs[i..<j]))
                            i = j
                        }
                        let total = groups.reduce(0.0) { $0 + ($1.map { $0.duration }.min() ?? 1) }
                        var list: [(Double, Glyph, Int)] = []
                        if abs(total - measureLen) < 0.01 || groups.isEmpty {
                            var t = 0.0
                            for g in groups {
                                let dur = g.map { $0.duration }.min() ?? 1
                                for x in g { list.append((t, x, si)) }
                                t += dur
                            }
                        } else {
                            // durations don't add up: place by horizontal position, quantised to 16ths
                            let span = max(1, xb - xa - sp)
                            for g in groups {
                                let f = max(0, min(0.999, (g[0].x - xa - sp * 0.6) / span))
                                let t = (f * measureLen * 4).rounded(.down) / 4
                                for x in g { list.append((t, x, si)) }
                            }
                        }
                        events.append(list)
                    }
                    // key signature + accidentals carried through the measure
                    for (k, list) in events.enumerated() {
                        let st = staves[sys[k]]
                        var carried: [Int: Int] = [:] // diatonic index -> alteration
                        for (start, g, _) in list {
                            guard case .note = g.kind else { continue }
                            let (diatonic, basePitch) = pitch(step: g.step, clef: st.clef)
                            if let acc = g.accidental { carried[diatonic] = acc }
                            let alter = carried[diatonic] ?? keyAlteration(diatonic: diatonic, fifths: st.keyFifths)
                            notes.append(MusicNote(pitch: basePitch + alter, startBeat: beat + start, durationBeats: g.duration * 0.98,
                                                   velocity: 88, channel: 0, track: st.clef == .treble ? 0 : 1, program: 0))
                        }
                    }
                    beat += max(measureLen, 0.5)
                }
            }
        }
        let meter = meterVotes.max { $0.value < $1.value }?.key ?? 4
        let num = max(1, Int(meter.rounded()))
        let score = Score(title: title, tempo: TempoMap(bpm: tempoBPM),
                          timeSignatures: [TimeSignature(beat: 0, numerator: num == 0 ? 4 : num, denominator: 4)], notes: notes,
                          tracks: [TrackInfo(index: 0, name: "Right hand", channel: 0, program: 0, isDrum: false, noteCount: notes.filter { $0.track == 0 }.count),
                                   TrackInfo(index: 1, name: "Left hand", channel: 0, program: 0, isDrum: false, noteCount: notes.filter { $0.track == 1 }.count)])
        if notes.isEmpty { warnings.append("No notes recognised — the PDF may be scanned at low resolution or handwritten.") }
        return Result(score: score, pages: pages.count, staves: staffCount, systems: systemCount, notes: notes.count, warnings: warnings)
    }

    // MARK: Binarisation (Otsu)

    static func binarize(_ img: GrayImage) -> GrayImage {
        var hist = [Int](repeating: 0, count: 256)
        for p in img.pixels { hist[Int(p)] += 1 }
        let total = img.pixels.count
        var sum = 0.0
        for i in 0..<256 { sum += Double(i * hist[i]) }
        var sumB = 0.0, wB = 0, best = 0.0, threshold = 128
        for i in 0..<256 {
            wB += hist[i]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(i * hist[i])
            let mB = sumB / Double(wB), mF = (sum - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = i }
        }
        threshold = max(90, min(200, threshold))
        return GrayImage(width: img.width, height: img.height, pixels: img.pixels.map { Int($0) <= threshold ? 0 : 255 })
    }

    // MARK: Staves

    static func findStaves(_ img: GrayImage) -> [Staff] {
        let w = img.width, h = img.height
        var rowInk = [Int](repeating: 0, count: h)
        for y in 0..<h {
            var c = 0
            let base = y * w
            for x in 0..<w where img.pixels[base + x] == 0 { c += 1 }
            rowInk[y] = c
        }
        let maxInk = rowInk.max() ?? 0
        guard maxInk > w / 5 else { return [] }
        let thr = Int(Double(maxInk) * 0.5)
        // runs of line rows
        var lines: [(y: Double, t: Double)] = []
        var y = 0
        while y < h {
            if rowInk[y] >= thr {
                var e = y
                while e + 1 < h && rowInk[e + 1] >= thr { e += 1 }
                lines.append((Double(y + e) / 2, Double(e - y + 1)))
                y = e + 1
            } else { y += 1 }
        }
        var staves: [Staff] = []
        var i = 0
        while i + 4 < lines.count {
            let five = Array(lines[i..<(i + 5)])
            let gaps = (1..<5).map { five[$0].y - five[$0 - 1].y }
            let mean = gaps.reduce(0, +) / 4
            if mean > 3, gaps.allSatisfy({ abs($0 - mean) < max(1.5, mean * 0.18) }) {
                let ys = five.map { $0.y }
                // horizontal extent of the staff: columns where the middle line has ink
                let midY = Int(ys[2])
                var x0 = 0, x1 = w - 1
                while x0 < w && !img.isInk(x0, midY) && !img.isInk(x0, midY - 1) && !img.isInk(x0, midY + 1) { x0 += 1 }
                while x1 > 0 && !img.isInk(x1, midY) && !img.isInk(x1, midY - 1) && !img.isInk(x1, midY + 1) { x1 -= 1 }
                staves.append(Staff(lines: ys, space: mean, thickness: five.map { $0.t }.reduce(0, +) / 5, x0: x0, x1: x1))
                i += 5
            } else {
                i += 1
            }
        }
        return staves
    }

    static func removeStaffLines(_ img: GrayImage, _ staves: [Staff]) -> GrayImage {
        var out = img
        let w = img.width
        for s in staves {
            let half = Int((s.thickness / 2).rounded(.up))
            // ledger-line positions too (2 above, 2 below) are erased only where isolated
            var ys = s.lines
            for k in 1...3 { ys.append(s.top - Double(k) * s.space); ys.append(s.bottom + Double(k) * s.space) }
            for (li, ly) in ys.enumerated() {
                let yc = Int(ly.rounded())
                let isStaffLine = li < 5
                for x in max(0, s.x0 - 2)...min(w - 1, s.x1 + 2) {
                    let above = img.isInk(x, yc - half - 1) || img.isInk(x, yc - half - 2)
                    let below = img.isInk(x, yc + half + 1) || img.isInk(x, yc + half + 2)
                    if above && below { continue } // a symbol crosses the line here
                    if !isStaffLine && (above || below) { continue }
                    for dy in -half...half {
                        let yy = yc + dy
                        if yy >= 0 && yy < img.height { out.pixels[yy * w + x] = 255 }
                    }
                }
            }
        }
        return out
    }

    /// Groups staves joined at their left edge by a bracket/brace/barline into systems.
    static func groupSystems(_ img: GrayImage, _ staves: [Staff]) -> [[Int]] {
        var systems: [[Int]] = []
        var current: [Int] = []
        for i in staves.indices {
            if let last = current.last {
                let a = staves[last], b = staves[i]
                var connected = false
                // span barlines (or a straight system bracket) connect the staves of one system
                for x in max(0, min(a.x0, b.x0) - Int(a.space * 2))...min(img.width - 1, min(a.x1, b.x1)) {
                    var ink = 0
                    let y0 = Int(a.bottom), y1 = Int(b.top)
                    guard y1 > y0 else { continue }
                    for y in y0...y1 where img.isInk(x, y) { ink += 1 }
                    if Double(ink) > Double(y1 - y0) * 0.9 { connected = true; break }
                }
                if connected && current.count < 2 { current.append(i); continue }
                systems.append(current)
                current = [i]
            } else {
                current = [i]
            }
        }
        if !current.isEmpty { systems.append(current) }
        return systems
    }

    // MARK: Connected components

    struct Component {
        var minX: Int, maxX: Int, minY: Int, maxY: Int, count: Int
        var width: Double { Double(maxX - minX + 1) }
        var height: Double { Double(maxY - minY + 1) }
        var cx: Double { Double(minX + maxX) / 2 }
        var cy: Double { Double(minY + maxY) / 2 }
        var fill: Double { Double(count) / (width * height) }
    }

    /// 8-connected components of ink inside a rectangle.
    static func components(_ img: GrayImage, x0: Int, x1: Int, y0: Int, y1: Int) -> [Component] {
        let ax = max(0, x0), bx = min(img.width - 1, x1), ay = max(0, y0), by = min(img.height - 1, y1)
        guard bx > ax, by > ay else { return [] }
        let w = bx - ax + 1, h = by - ay + 1
        var label = [Int32](repeating: 0, count: w * h)
        var comps: [Component] = []
        var stack: [Int] = []
        for y in 0..<h {
            for x in 0..<w where label[y * w + x] == 0 && img.isInk(ax + x, ay + y) {
                var c = Component(minX: ax + x, maxX: ax + x, minY: ay + y, maxY: ay + y, count: 0)
                let id = Int32(comps.count + 1)
                label[y * w + x] = id
                stack.append(y * w + x)
                while let cur = stack.popLast() {
                    let cyy = cur / w, cxx = cur % w
                    c.count += 1
                    c.minX = min(c.minX, ax + cxx); c.maxX = max(c.maxX, ax + cxx)
                    c.minY = min(c.minY, ay + cyy); c.maxY = max(c.maxY, ay + cyy)
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let nx = cxx + dx, ny = cyy + dy
                            guard nx >= 0, ny >= 0, nx < w, ny < h, label[ny * w + nx] == 0, img.isInk(ax + nx, ay + ny) else { continue }
                            label[ny * w + nx] = id
                            stack.append(ny * w + nx)
                        }
                    }
                }
                comps.append(c)
            }
        }
        return comps
    }

    // MARK: Clef, key signature

    static func analyseStaffHeader(_ img: GrayImage, _ s: inout Staff, systemSize: Int, index: Int) {
        let sp = s.space
        let comps = components(img, x0: s.x0, x1: min(s.x1, s.x0 + Int(sp * 22)), y0: Int(s.top - sp * 3.5), y1: Int(s.bottom + sp * 3.5))
            .filter { $0.count > 6 && $0.maxY >= Int(s.top - sp) && $0.minY <= Int(s.bottom + sp) }
            .sorted { $0.minX < $1.minX }
        // skip braces/brackets and the system start line (very tall or very thin)
        let candidates = comps.filter { !($0.height > sp * 8.5) && !($0.width < sp * 0.35 && $0.height > sp * 3.5) }
        guard let clefC = candidates.first(where: { $0.height > sp * 2 && $0.width > sp * 0.8 }) else {
            s.contentStart = s.x0 + Int(sp * 2)
            return
        }
        // clef: treble spans ~7 spaces, bass ~3 spaces in the upper part of the staff
        if clefC.height > sp * 5 { s.clef = .treble }
        else if Double(clefC.maxY) < s.lines[3] + sp * 0.6 { s.clef = .bass }
        else { s.clef = (systemSize == 2 && index == 1) ? .bass : .treble }
        var cursor = clefC.maxX
        // bass clef dots are separate small components right of the clef
        var rest = candidates.filter { $0.minX > cursor }
        while let d = rest.first, d.height < sp * 0.6, d.width < sp * 0.6, Double(d.minX - cursor) < sp * 1.2 {
            cursor = d.maxX
            rest.removeFirst()
        }
        var sharps = 0, flats = 0
        while let a = rest.first, Double(a.minX - cursor) < sp * 1.6 {
            let ratio = a.height / max(1, a.width)
            guard a.height > sp * 1.8, a.height < sp * 3.8, a.width < sp * 1.25, ratio >= 1.9 else { break }
            // flats carry their mass (bowl) in the lower half, sharps are symmetric
            var top = 0, bottom = 0
            let mid = Int(a.cy)
            for y in a.minY...a.maxY { for x in a.minX...a.maxX where img.isInk(x, y) { if y < mid { top += 1 } else { bottom += 1 } } }
            if Double(bottom) > Double(top) * 1.35 { flats += 1 } else { sharps += 1 }
            cursor = a.maxX
            rest.removeFirst()
        }
        s.keyFifths = sharps >= flats ? sharps : -flats
        // time signature: stacked digits (two components in one column) or a C / cut-C symbol
        if let t = rest.first, Double(t.minX - cursor) < sp * 2.5 {
            let column = rest.filter { abs($0.cx - t.cx) < sp * 0.8 && Double($0.minX - cursor) < sp * 3 }
            let top = column.map { $0.minY }.min() ?? t.minY, bot = column.map { $0.maxY }.max() ?? t.maxY
            let centred = abs(Double(top + bot) / 2 - (s.top + s.bottom) / 2) < sp * 0.9
            let wide = column.map { $0.width }.max() ?? t.width
            let looksDigits = column.count >= 2 && Double(bot - top) > sp * 3.2
            let looksC = column.count == 1 && t.height > sp * 1.5 && t.height < sp * 3.0 && t.width > sp * 0.9 && t.fill < 0.55
            if centred && wide < sp * 2.4 && (looksDigits || looksC) {
                cursor = column.map { $0.maxX }.max() ?? t.maxX
            }
        }
        s.contentStart = cursor + Int(sp * 0.6)
        if ProcessInfo.processInfo.environment["MAICHART_OMR_DEBUG"] != nil {
            print("staff x0=\(s.x0) clefEnd=\(clefC.maxX) clef=\(s.clef) key=\(s.keyFifths) contentStart=\(s.contentStart) space=\(s.space)")
        }
    }

    /// Alteration implied by the key signature for a diatonic index (0 = C ... 6 = B).
    static func keyAlteration(diatonic: Int, fifths: Int) -> Int {
        let sharpOrder = [3, 0, 4, 1, 5, 2, 6] // F C G D A E B
        let flatOrder = [6, 2, 5, 1, 4, 0, 3]  // B E A D G C F
        if fifths > 0 { return sharpOrder.prefix(fifths).contains(diatonic) ? 1 : 0 }
        if fifths < 0 { return flatOrder.prefix(-fifths).contains(diatonic) ? -1 : 0 }
        return 0
    }

    /// (diatonic index 0-6, MIDI pitch without accidentals) for a staff position.
    static func pitch(step: Int, clef: Clef) -> (Int, Int) {
        // bottom line: treble E4 (diatonic 2, octave 4), bass G2 (diatonic 4, octave 2)
        let (baseDia, baseOct) = clef == .treble ? (2, 4) : (4, 2)
        let total = baseDia + step + baseOct * 7
        let oct = Int(floor(Double(total) / 7))
        let dia = ((total % 7) + 7) % 7
        let semis = [0, 2, 4, 5, 7, 9, 11]
        return (dia, 12 * (oct + 1) + semis[dia])
    }

    // MARK: Barlines

    static func findBarlines(_ img: GrayImage, _ staves: [Staff], _ sys: [Int]) -> [Int] {
        var result: [Int] = []
        let first = staves[sys[0]]
        let lo = sys.map { staves[$0].x0 }.max() ?? 0, hi = sys.map { staves[$0].x1 }.min() ?? img.width
        var x = lo
        while x <= hi {
            var allStaves = true
            for si in sys {
                let s = staves[si]
                var ink = 0
                for y in Int(s.top)...Int(s.bottom) where img.isInk(x, y) { ink += 1 }
                if Double(ink) < (s.bottom - s.top) * 0.92 { allStaves = false; break }
                // not a stem: nothing notehead-like right next to it
                var side = 0
                for dx in [-Int(s.space * 0.9), Int(s.space * 0.9)] {
                    for y in Int(s.top)...Int(s.bottom) where img.isInk(x + dx, y) { side += 1 }
                }
                if Double(side) > (s.bottom - s.top) * 0.6 { allStaves = false; break }
            }
            if allStaves {
                // also check the thin width
                var wdt = 1
                while x + wdt <= hi && img.isInk(x + wdt, Int((first.top + first.bottom) / 2)) { wdt += 1 }
                if Double(wdt) < first.space * 0.6 || wdt > 2 { result.append(x + wdt / 2) }
                x += max(wdt, Int(first.space * 0.8))
                continue
            }
            x += 1
        }
        // merge double barlines
        var merged: [Int] = []
        for b in result { if let l = merged.last, Double(b - l) < first.space * 1.2 { merged[merged.count - 1] = b } else { merged.append(b) } }
        return merged
    }

    // MARK: Noteheads, stems, beams, rests

    struct Integral {
        let w: Int, h: Int
        var sum: [Int32]
        init(_ img: GrayImage) {
            w = img.width; h = img.height
            sum = [Int32](repeating: 0, count: (w + 1) * (h + 1))
            for y in 0..<h {
                var row: Int32 = 0
                for x in 0..<w {
                    if img.pixels[y * w + x] == 0 { row += 1 }
                    sum[(y + 1) * (w + 1) + x + 1] = sum[y * (w + 1) + x + 1] + row
                }
            }
        }
        /// Ink ratio inside the rectangle [x0, x1) x [y0, y1).
        func ratio(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Double {
            let a = max(0, min(w, Int(x0))), b = max(0, min(w, Int(x1)))
            let c = max(0, min(h, Int(y0))), d = max(0, min(h, Int(y1)))
            guard b > a, d > c else { return 0 }
            let s = sum[d * (w + 1) + b] - sum[c * (w + 1) + b] - sum[d * (w + 1) + a] + sum[c * (w + 1) + a]
            return Double(s) / Double((b - a) * (d - c))
        }
    }

    static func findGlyphs(_ img: GrayImage, _ I: Integral, _ s: Staff, original: GrayImage) -> [Glyph] {
        let sp = s.space
        let hw = sp * 0.62, hh = sp * 0.46 // notehead half sizes
        var candidates: [(x: Double, step: Int, score: Double, filled: Bool)] = []
        let x0 = Double(s.contentStart), x1 = Double(s.x1) - sp * 0.5
        for step in -7...15 {
            let y = s.bottom - Double(step) * sp / 2
            var x = x0
            while x < x1 {
                let inner = I.ratio(x - hw * 0.55, y - hh * 0.5, x + hw * 0.55, y + hh * 0.5)
                let outer = I.ratio(x - hw, y - hh, x + hw, y + hh)
                // beams extend sideways; noteheads don't
                let left = I.ratio(x - hw * 2.1, y - hh * 0.4, x - hw * 1.35, y + hh * 0.4)
                let right = I.ratio(x + hw * 1.35, y - hh * 0.4, x + hw * 2.1, y + hh * 0.4)
                let aboveBelow = (I.ratio(x - hw * 0.4, y - hh * 2.2, x + hw * 0.4, y - hh * 1.4) + I.ratio(x - hw * 0.4, y + hh * 1.4, x + hw * 0.4, y + hh * 2.2)) / 2
                let sideways = min(left, right)
                if inner > 0.82 && outer > 0.62 && sideways < 0.55 && aboveBelow < 0.65 {
                    candidates.append((x, step, inner + outer - sideways, true))
                } else if inner < 0.5 && outer > 0.3 && outer < 0.8 && sideways < 0.4 {
                    // hollow notehead: ring of ink around a (slanted) white centre
                    let centre = I.ratio(x - hw * 0.18, y - hh * 0.18, x + hw * 0.18, y + hh * 0.18)
                    let ringTop = I.ratio(x - hw * 0.7, y - hh * 1.05, x + hw * 0.7, y - hh * 0.45)
                    let ringBot = I.ratio(x - hw * 0.7, y + hh * 0.45, x + hw * 0.7, y + hh * 1.05)
                    let ringL = I.ratio(x - hw * 1.05, y - hh * 0.5, x - hw * 0.55, y + hh * 0.5)
                    let ringR = I.ratio(x + hw * 0.55, y - hh * 0.5, x + hw * 1.05, y + hh * 0.5)
                    if centre < 0.3 && ringTop > 0.25 && ringBot > 0.25 && ringL > 0.35 && ringR > 0.35 {
                        candidates.append((x, step, outer + 0.5 + (ringL + ringR) * 0.2, false))
                    }
                }
                x += 1
            }
        }
        // notes outside the staff need ledger lines (rejects tempo marks, text, dynamics)
        let originalImage = original
        candidates = candidates.filter { c in
            if c.step >= -1 && c.step <= 9 { return true }
            let ledgerSteps: [Int] = c.step > 9 ? Array(stride(from: 10, through: c.step, by: 2)) : Array(stride(from: -2, through: c.step, by: -2))
            for ls in ledgerSteps {
                let ly = s.bottom - Double(ls) * sp / 2
                // a short horizontal line wider than the notehead
                var hits = 0
                for dx in stride(from: -hw * 1.25, through: hw * 1.25, by: 1) {
                    if (-1...1).contains(where: { dy in originalImage.isInk(Int(c.x + dx), Int(ly) + dy) }) { hits += 1 }
                }
                if Double(hits) < hw * 2.5 * 0.85 { return false }
            }
            return true
        }
        // non-maximum suppression (same step, within one notehead width)
        candidates.sort { $0.score > $1.score }
        var heads: [(x: Double, step: Int, filled: Bool)] = []
        for c in candidates {
            if heads.contains(where: { abs($0.x - c.x) < hw * 1.6 && abs($0.step - c.step) <= 1 }) { continue }
            heads.append((c.x, c.step, c.filled))
        }
        // refine the vertical position with the ink centroid of the head (stems excluded)
        heads = heads.map { h in
            let yGuess = s.bottom - Double(h.step) * sp / 2
            var sum = 0.0, cnt = 0.0
            for yy in Int(yGuess - sp * 0.75)...Int(yGuess + sp * 0.75) {
                for xx in Int(h.x - hw * 0.55)...Int(h.x + hw * 0.45) where img.isInk(xx, yy) { sum += Double(yy); cnt += 1 }
            }
            guard cnt > 4 else { return h }
            let cy = sum / cnt
            let refined = Int(((s.bottom - cy) / (sp / 2)).rounded())
            return (h.x, abs(refined - h.step) <= 1 ? refined : h.step, h.filled)
        }
        // merge duplicates created by the refinement
        var uniq: [(x: Double, step: Int, filled: Bool)] = []
        for h in heads where !uniq.contains(where: { abs($0.x - h.x) < hw * 1.2 && $0.step == h.step }) { uniq.append(h) }
        heads = uniq
        var glyphs: [Glyph] = []
        for h in heads {
            let y = s.bottom - Double(h.step) * sp / 2
            // stem: vertical ink run at the right (up) or left (down) edge
            func stemLength(_ sx: Double, _ dir: Double) -> Double {
                var len = 0.0
                var yy = y
                while len < sp * 5 {
                    yy += dir
                    let hit = (-1...1).contains { dx in img.isInk(Int(sx) + dx, Int(yy)) }
                    if !hit { break }
                    len += 1
                }
                return len
            }
            var upLen = 0.0, downLen = 0.0, upX = h.x + hw * 0.85, downX = h.x - hw * 0.85
            for dx in stride(from: hw * 0.45, through: hw * 1.35, by: 1) {
                let u = stemLength(h.x + dx, -1)
                if u > upLen { upLen = u; upX = h.x + dx }
                let d = stemLength(h.x - dx, 1)
                if d > downLen { downLen = d; downX = h.x - dx }
            }
            let stemmed = max(upLen, downLen) > sp * 2.2
            var duration: Double
            if h.filled {
                duration = 1
                if stemmed {
                    // count beams/flags near the stem end
                    let up = upLen >= downLen
                    let sx = up ? upX : downX
                    let endY = up ? y - upLen : y + downLen
                    var bands = 0
                    var inBand = false
                    let probeX = Int(sx + (up ? -sp * 0.35 : sp * 0.35))
                    var yy = endY + (up ? -sp * 1.0 : sp * 1.0)
                    for _ in 0..<Int(sp * 3.4) {
                        let ink = img.isInk(probeX, Int(yy)) || img.isInk(probeX + (up ? -1 : 1), Int(yy))
                        if ink && !inBand { bands += 1; inBand = true }
                        if !ink { inBand = false }
                        yy += up ? 1 : -1
                    }
                    // also probe on the other side of the stem (beams continue to the next note)
                    var bands2 = 0
                    inBand = false
                    let probe2 = Int(sx + (up ? sp * 0.35 : -sp * 0.35))
                    yy = endY + (up ? -sp * 1.0 : sp * 1.0)
                    for _ in 0..<Int(sp * 3.4) {
                        let ink = img.isInk(probe2, Int(yy))
                        if ink && !inBand { bands2 += 1; inBand = true }
                        if !ink { inBand = false }
                        yy += up ? 1 : -1
                    }
                    let beams = min(3, max(bands, bands2))
                    duration = 1 / pow(2, Double(beams))
                }
            } else {
                duration = stemmed ? 2 : 4
            }
            // augmentation dot
            let dotY = h.step % 2 == 0 ? y - sp * 0.5 : y
            if I.ratio(h.x + hw * 1.3, dotY - sp * 0.18, h.x + hw * 2.1, dotY + sp * 0.18) > 0.35 &&
                I.ratio(h.x + hw * 2.3, dotY - sp * 0.18, h.x + hw * 2.8, dotY + sp * 0.18) < 0.2 {
                duration *= 1.5
            }
            // accidental immediately to the left
            var acc: Int? = nil
            let ax0 = h.x - hw * 3.3, ax1 = h.x - hw * 1.25
            let tallInk = I.ratio(ax0, y - sp * 1.2, ax1, y + sp * 1.2)
            let gap = I.ratio(h.x - hw * 1.3, y - sp * 0.3, h.x - hw * 1.05, y + sp * 0.3)
            if tallInk > 0.18 && gap < 0.25 && I.ratio(ax0, y - sp * 1.2, ax1, y - sp * 0.6) > 0.08 && I.ratio(ax0, y + sp * 0.6, ax1, y + sp * 1.2) > 0.03 {
                let topMass = I.ratio(ax0, y - sp * 1.4, ax1, y), botMass = I.ratio(ax0, y, ax1, y + sp * 1.2)
                if botMass > topMass * 1.4 { acc = -1 } else { acc = 1 }
                if I.ratio(ax0, y - sp * 1.6, ax1, y - sp * 1.2) < 0.05 && I.ratio(ax0, y + sp * 1.2, ax1, y + sp * 1.6) < 0.05 && tallInk < 0.3 { acc = 0 }
            }
            if ProcessInfo.processInfo.environment["MAICHART_OMR_DEBUG"] != nil {
                print(String(format: "head x=%.0f step=%d filled=%@ up=%.1f down=%.1f dur=%.2f acc=%@", h.x, h.step, h.filled ? "y" : "n", upLen / sp, downLen / sp, duration, acc.map { "\($0)" } ?? "-"))
            }
            var g = Glyph(x: h.x, y: y, step: h.step, kind: .note(filled: h.filled, stemmed: stemmed))
            g.duration = duration
            g.accidental = acc
            glyphs.append(g)
        }
        // rests: compact ink blobs inside the staff that are not noteheads/stems
        glyphs.append(contentsOf: findRests(img, I, s, heads: heads.map { $0.x }))
        return glyphs
    }

    static func findRests(_ img: GrayImage, _ I: Integral, _ s: Staff, heads: [Double]) -> [Glyph] {
        let sp = s.space
        var rests: [Glyph] = []
        let comps = components(img, x0: s.contentStart, x1: s.x1, y0: Int(s.top - sp * 0.5), y1: Int(s.bottom + sp * 0.5))
        let mid = (s.top + s.bottom) / 2
        for c in comps where c.count > 8 {
            if heads.contains(where: { abs($0 - c.cx) < sp * 1.2 }) { continue }
            // quarter rest: zig-zag ~3 spaces tall, ~1 space wide, partially filled, centred
            if c.height > sp * 2.2 && c.height < sp * 3.4 && c.width > sp * 0.6 && c.width < sp * 1.4 && c.fill > 0.25 && c.fill < 0.65 && abs(c.cy - mid) < sp * 0.8 {
                rests.append(Glyph(x: c.cx, y: mid, step: 4, kind: .rest(1), duration: 1))
                if ProcessInfo.processInfo.environment["MAICHART_OMR_DEBUG"] != nil { print("rest quarter x=\(Int(c.cx))") }
                continue
            }
            // eighth rest: "7" shape ~2 spaces tall with a dot on top
            if c.height > sp * 1.4 && c.height < sp * 2.4 && c.width > sp * 0.6 && c.width < sp * 1.3 && c.fill < 0.5 && abs(c.cy - mid) < sp * 1.0 {
                rests.append(Glyph(x: c.cx, y: mid, step: 4, kind: .rest(0.5), duration: 0.5))
                continue
            }
            // half / whole rests: solid bars of ~0.5 space on the middle lines
            if c.height > sp * 0.3 && c.height < sp * 0.7 && c.width > sp * 0.9 && c.width < sp * 1.8 && c.fill > 0.8 {
                if abs(Double(c.maxY) - s.lines[2]) < sp * 0.3 { rests.append(Glyph(x: c.cx, y: s.lines[2], step: 4, kind: .rest(2), duration: 2)) }
                else if abs(Double(c.minY) - s.lines[1]) < sp * 0.3 { rests.append(Glyph(x: c.cx, y: s.lines[1], step: 6, kind: .rest(4), duration: 4)) }
            }
        }
        return rests
    }
}
