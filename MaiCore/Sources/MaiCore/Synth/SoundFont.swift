import Foundation

public enum SoundFontError: Error, LocalizedError {
    case notSoundFont, corrupt(String)
    public var errorDescription: String? {
        switch self {
        case .notSoundFont: return "This file is not a SoundFont 2 (.sf2) bank."
        case .corrupt(let s): return "The SoundFont is damaged: \(s)"
        }
    }
}

/// SoundFont generator numbers (SF2.04 §8.1.2).
public enum Gen: Int, CaseIterable {
    case startAddrsOffset = 0, endAddrsOffset, startloopAddrsOffset, endloopAddrsOffset, startAddrsCoarseOffset,
         modLfoToPitch, vibLfoToPitch, modEnvToPitch, initialFilterFc, initialFilterQ, modLfoToFilterFc, modEnvToFilterFc,
         endAddrsCoarseOffset, modLfoToVolume, unused1, chorusEffectsSend, reverbEffectsSend, pan, unused2, unused3, unused4,
         delayModLFO, freqModLFO, delayVibLFO, freqVibLFO, delayModEnv, attackModEnv, holdModEnv, decayModEnv, sustainModEnv,
         releaseModEnv, keynumToModEnvHold, keynumToModEnvDecay, delayVolEnv, attackVolEnv, holdVolEnv, decayVolEnv,
         sustainVolEnv, releaseVolEnv, keynumToVolEnvHold, keynumToVolEnvDecay, instrument, reserved1, keyRange, velRange,
         startloopAddrsCoarseOffset, keynum, velocity, initialAttenuation, reserved2, endloopAddrsCoarseOffset, coarseTune,
         fineTune, sampleID, sampleModes, reserved3, scaleTuning, exclusiveClass, overridingRootKey, unused5, endOper
    /// Internal pseudo-generator: destination of the pitch-wheel default modulator ("initial pitch", cents).
    public static let pitch = 60
    public static let count = 61

    public static func defaultValue(_ g: Int) -> Double {
        switch g {
        case Gen.initialFilterFc.rawValue: return 13500
        case Gen.delayModLFO.rawValue, Gen.delayVibLFO.rawValue, Gen.delayModEnv.rawValue, Gen.attackModEnv.rawValue,
             Gen.holdModEnv.rawValue, Gen.decayModEnv.rawValue, Gen.releaseModEnv.rawValue, Gen.delayVolEnv.rawValue,
             Gen.attackVolEnv.rawValue, Gen.holdVolEnv.rawValue, Gen.decayVolEnv.rawValue, Gen.releaseVolEnv.rawValue:
            return -12000
        case Gen.scaleTuning.rawValue: return 100
        case Gen.overridingRootKey.rawValue, Gen.keynum.rawValue, Gen.velocity.rawValue: return -1
        default: return 0
        }
    }
}

/// A SoundFont modulator record.
public struct SFModulator: Equatable {
    public var src: UInt16
    public var dest: UInt16
    public var amount: Int16
    public var amtSrc: UInt16
    public var transform: UInt16

    /// Two modulators are "identical" when everything but the amount matches (SF2.04 §9.5.1).
    public func sameIdentity(_ o: SFModulator) -> Bool {
        src == o.src && dest == o.dest && amtSrc == o.amtSrc && transform == o.transform
    }

    public static let defaults: [SFModulator] = [
        SFModulator(src: 0x0502, dest: 48, amount: 960, amtSrc: 0, transform: 0),          // velocity -> attenuation
        SFModulator(src: 0x0102, dest: 8, amount: -2400, amtSrc: 0, transform: 0),          // velocity -> filter cutoff
        SFModulator(src: 0x000D, dest: 6, amount: 50, amtSrc: 0, transform: 0),             // channel pressure -> vibrato
        SFModulator(src: 0x0081, dest: 6, amount: 50, amtSrc: 0, transform: 0),             // CC1 -> vibrato
        SFModulator(src: 0x0587, dest: 48, amount: 960, amtSrc: 0, transform: 0),          // CC7 -> attenuation
        SFModulator(src: 0x028A, dest: 17, amount: 1000, amtSrc: 0, transform: 0),         // CC10 -> pan
        SFModulator(src: 0x058B, dest: 48, amount: 960, amtSrc: 0, transform: 0),          // CC11 -> attenuation
        SFModulator(src: 0x00DB, dest: 16, amount: 200, amtSrc: 0, transform: 0),          // CC91 -> reverb
        SFModulator(src: 0x00DD, dest: 15, amount: 200, amtSrc: 0, transform: 0),          // CC93 -> chorus
        SFModulator(src: 0x020E, dest: UInt16(Gen.pitch), amount: 12700, amtSrc: 0x0010, transform: 0), // pitch wheel
    ]
}

public struct SFZone {
    /// Generator values set in this zone (nil = not set).
    public var gens: [Int16?] = Array(repeating: nil, count: Gen.count)
    public var keyLo: UInt8 = 0, keyHi: UInt8 = 127, velLo: UInt8 = 0, velHi: UInt8 = 127
    public var mods: [SFModulator] = []
    public var index: Int = -1 // instrument index (preset zones) or sample index (instrument zones)

    func matches(key: Int, vel: Int) -> Bool {
        key >= Int(keyLo) && key <= Int(keyHi) && vel >= Int(velLo) && vel <= Int(velHi)
    }
}

public struct SFSample {
    public var name: String
    public var start: Int, end: Int, loopStart: Int, loopEnd: Int
    public var sampleRate: Double
    public var originalPitch: Int
    public var pitchCorrection: Int
    public var type: Int
}

public struct SFInstrument {
    public var name: String
    public var global: SFZone?
    public var zones: [SFZone]
}

public struct SFPreset {
    public var name: String
    public var program: Int
    public var bank: Int
    public var global: SFZone?
    public var zones: [SFZone]
}

/// A parsed SoundFont 2 bank with 16-bit (or 24-bit) sample data converted to Float.
public final class SoundFont {
    public let name: String
    public let presets: [SFPreset]
    public let instruments: [SFInstrument]
    public let samples: [SFSample]
    /// All sample data as floats in -1...1 (shared by every sample header).
    public let data: [Float]
    private var presetIndex: [Int: Int] = [:] // bank<<8 | program -> preset index

    public init(data fileData: Data) throws {
        let b = [UInt8](fileData)
        func u32(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24 }
        func u16(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 }
        func s16(_ p: Int) -> Int16 { Int16(bitPattern: UInt16(b[p]) | UInt16(b[p + 1]) << 8) }
        func tag(_ p: Int) -> String { String(bytes: b[p..<p + 4], encoding: .ascii) ?? "" }
        func str(_ p: Int, _ n: Int) -> String {
            let raw = b[p..<p + n].prefix { $0 != 0 }
            return String(bytes: raw, encoding: .ascii) ?? String(bytes: raw, encoding: .isoLatin1) ?? ""
        }
        guard b.count > 12, tag(0) == "RIFF", tag(8) == "sfbk" else { throw SoundFontError.notSoundFont }
        var chunks: [String: (Int, Int)] = [:]
        var bankName = ""
        // walk LIST chunks
        var p = 12
        while p + 8 <= b.count {
            let id = tag(p), len = u32(p + 4)
            if id == "LIST", p + 12 <= b.count {
                let listType = tag(p + 8)
                var q = p + 12
                let end = min(b.count, p + 8 + len)
                while q + 8 <= end {
                    let cid = tag(q), clen = u32(q + 4)
                    let key = listType == "INFO" ? "INFO." + cid : cid
                    chunks[key] = (q + 8, min(clen, end - q - 8))
                    q += 8 + clen + (clen & 1)
                }
            }
            p += 8 + len + (len & 1)
        }
        if let (o, l) = chunks["INFO.INAM"] { bankName = str(o, min(l, 256)) }
        name = bankName
        guard let (smplOff, smplLen) = chunks["smpl"] else { throw SoundFontError.corrupt("missing sample data") }
        let nSamples = smplLen / 2
        var floats = [Float](repeating: 0, count: nSamples)
        let sm24 = chunks["sm24"]
        b.withUnsafeBufferPointer { bp in
            floats.withUnsafeMutableBufferPointer { fp in
                if let (o24, l24) = sm24, l24 >= nSamples {
                    for i in 0..<nSamples {
                        let v = Int32(Int16(bitPattern: UInt16(bp[smplOff + 2 * i]) | UInt16(bp[smplOff + 2 * i + 1]) << 8)) << 8 | Int32(bp[o24 + i])
                        fp[i] = Float(v) / 8_388_608
                    }
                } else {
                    for i in 0..<nSamples {
                        let v = Int16(bitPattern: UInt16(bp[smplOff + 2 * i]) | UInt16(bp[smplOff + 2 * i + 1]) << 8)
                        fp[i] = Float(v) / 32768
                    }
                }
            }
        }
        data = floats
        for k in ["phdr", "pbag", "pmod", "pgen", "inst", "ibag", "imod", "igen", "shdr"] where chunks[k] == nil {
            throw SoundFontError.corrupt("missing \(k)")
        }
        func records(_ k: String, _ size: Int) -> (Int, Int) {
            let (o, l) = chunks[k]!
            return (o, l / size)
        }
        // samples
        let (shOff, shN) = records("shdr", 46)
        var smps: [SFSample] = []
        for i in 0..<max(0, shN - 1) {
            let o = shOff + 46 * i
            smps.append(SFSample(name: str(o, 20), start: u32(o + 20), end: u32(o + 24), loopStart: u32(o + 28), loopEnd: u32(o + 32),
                                 sampleRate: Double(max(1, u32(o + 36))), originalPitch: Int(b[o + 40]), pitchCorrection: Int(Int8(bitPattern: b[o + 41])),
                                 type: u16(o + 44)))
        }
        samples = smps
        // generic zone reader
        func readZones(bagKey: String, genKey: String, modKey: String, firstBag: Int, lastBag: Int, terminal: Int) -> (SFZone?, [SFZone]) {
            let (bagOff, _) = chunks[bagKey]!
            let (genOff, genLen) = chunks[genKey]!
            let (modOff, modLen) = chunks[modKey]!
            let genCount = genLen / 4, modCount = modLen / 10
            var zones: [SFZone] = []
            var global: SFZone? = nil
            for bag in firstBag..<lastBag {
                let g0 = u16(bagOff + 4 * bag), g1 = u16(bagOff + 4 * (bag + 1))
                let m0 = u16(bagOff + 4 * bag + 2), m1 = u16(bagOff + 4 * (bag + 1) + 2)
                var z = SFZone()
                for gi in g0..<min(g1, genCount) {
                    let go = genOff + 4 * gi
                    let oper = u16(go)
                    switch oper {
                    case Gen.keyRange.rawValue: z.keyLo = b[go + 2]; z.keyHi = b[go + 3]
                    case Gen.velRange.rawValue: z.velLo = b[go + 2]; z.velHi = b[go + 3]
                    case terminal: z.index = u16(go + 2)
                    case 0..<Gen.count: z.gens[oper] = s16(go + 2)
                    default: break
                    }
                }
                for mi in m0..<min(m1, modCount) {
                    let mo = modOff + 10 * mi
                    let m = SFModulator(src: UInt16(u16(mo)), dest: UInt16(u16(mo + 2)), amount: s16(mo + 4),
                                        amtSrc: UInt16(u16(mo + 6)), transform: UInt16(u16(mo + 8)))
                    if let j = z.mods.firstIndex(where: { $0.sameIdentity(m) }) { z.mods[j] = m } else { z.mods.append(m) }
                }
                if z.index < 0 {
                    if bag == firstBag { global = z } // only the first zone may be global
                } else {
                    zones.append(z)
                }
            }
            return (global, zones)
        }
        let (inOff, inN) = records("inst", 22)
        var insts: [SFInstrument] = []
        for i in 0..<max(0, inN - 1) {
            let o = inOff + 22 * i
            let b0 = u16(o + 20), b1 = u16(o + 22 + 20)
            let (g, z) = readZones(bagKey: "ibag", genKey: "igen", modKey: "imod", firstBag: b0, lastBag: b1, terminal: Gen.sampleID.rawValue)
            insts.append(SFInstrument(name: str(o, 20), global: g, zones: z.filter { $0.index < smps.count }))
        }
        instruments = insts
        let (phOff, phN) = records("phdr", 38)
        var pres: [SFPreset] = []
        for i in 0..<max(0, phN - 1) {
            let o = phOff + 38 * i
            let b0 = u16(o + 24), b1 = u16(o + 38 + 24)
            let (g, z) = readZones(bagKey: "pbag", genKey: "pgen", modKey: "pmod", firstBag: b0, lastBag: b1, terminal: Gen.instrument.rawValue)
            pres.append(SFPreset(name: str(o, 20), program: u16(o + 20), bank: u16(o + 22), global: g, zones: z.filter { $0.index < insts.count }))
        }
        presets = pres
        for (i, pr) in pres.enumerated() where presetIndex[pr.bank << 8 | pr.program] == nil {
            presetIndex[pr.bank << 8 | pr.program] = i
        }
    }

    public convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Finds a preset with GS-style fallbacks (requested bank -> bank 0 / 128 -> any program).
    public func preset(bank: Int, program: Int) -> SFPreset? {
        if let i = presetIndex[bank << 8 | program] { return presets[i] }
        if bank == 128 {
            if let i = presetIndex[128 << 8 | 0] { return presets[i] }
        } else if let i = presetIndex[program] {
            return presets[i]
        }
        return presets.first { $0.bank == (bank == 128 ? 128 : 0) } ?? presets.first
    }

    /// Melodic preset list (bank 0) for instrument pickers.
    public var melodicPresets: [(program: Int, name: String)] {
        presets.filter { $0.bank == 0 }.sorted { $0.program < $1.program }.map { ($0.program, $0.name) }
    }

    public struct VoiceSpec {
        public var sample: SFSample
        public var gens: [Double]          // effective generator values (instrument + preset offsets)
        public var mods: [SFModulator]     // effective modulators
    }

    /// Resolves preset + instrument zones for a note (SF2.04 §9.4/§9.5).
    public func voices(for preset: SFPreset, key: Int, velocity: Int) -> [VoiceSpec] {
        var out: [VoiceSpec] = []
        for pz in preset.zones where pz.matches(key: key, vel: velocity) {
            // global preset zone ranges also restrict
            if let g = preset.global, !g.matches(key: key, vel: velocity) { continue }
            let inst = instruments[pz.index]
            for iz in inst.zones where iz.matches(key: key, vel: velocity) {
                if let g = inst.global, !g.matches(key: key, vel: velocity) { continue }
                guard iz.index < samples.count else { continue }
                var gens = (0..<Gen.count).map { Gen.defaultValue($0) }
                for g in 0..<Gen.count {
                    if let v = iz.gens[g] ?? inst.global?.gens[g] { gens[g] = Double(v) }
                }
                // preset generators are additive (except non-additive ones)
                let nonAdditive: Set<Int> = [Gen.startAddrsOffset.rawValue, Gen.endAddrsOffset.rawValue, Gen.startloopAddrsOffset.rawValue,
                                             Gen.endloopAddrsOffset.rawValue, Gen.startAddrsCoarseOffset.rawValue, Gen.endAddrsCoarseOffset.rawValue,
                                             Gen.startloopAddrsCoarseOffset.rawValue, Gen.endloopAddrsCoarseOffset.rawValue, Gen.keynum.rawValue,
                                             Gen.velocity.rawValue, Gen.sampleModes.rawValue, Gen.exclusiveClass.rawValue,
                                             Gen.overridingRootKey.rawValue, Gen.instrument.rawValue, Gen.sampleID.rawValue,
                                             Gen.keyRange.rawValue, Gen.velRange.rawValue]
                for g in 0..<Gen.count where !nonAdditive.contains(g) {
                    if let v = pz.gens[g] ?? preset.global?.gens[g] { gens[g] += Double(v) }
                }
                // modulators: defaults overridden by instrument (global then local), plus preset ones added
                var mods = SFModulator.defaults
                for m in (inst.global?.mods ?? []) + iz.mods {
                    if let j = mods.firstIndex(where: { $0.sameIdentity(m) }) { mods[j] = m } else { mods.append(m) }
                }
                var pmods: [SFModulator] = preset.global?.mods ?? []
                for m in pz.mods {
                    if let j = pmods.firstIndex(where: { $0.sameIdentity(m) }) { pmods[j] = m } else { pmods.append(m) }
                }
                for m in pmods {
                    if let j = mods.firstIndex(where: { $0.sameIdentity(m) }) {
                        mods[j].amount = Int16(clamping: Int(mods[j].amount) + Int(m.amount))
                    } else {
                        mods.append(m)
                    }
                }
                out.append(VoiceSpec(sample: samples[iz.index], gens: gens, mods: mods))
            }
        }
        return out
    }
}
