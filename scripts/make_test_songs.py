#!/usr/bin/env python3
"""Generate deterministic synthetic test songs (MIDI + ground-truth JSON).

These are original procedurally composed pieces used to test chart generation,
audio rendering and audio analysis with exact ground truth.
Usage: make_test_songs.py OUTDIR
"""
import json
import os
import random
import sys

import mido

PPQ = 480


class Song:
    def __init__(self, name, bpm, ts=(4, 4)):
        self.name = name
        self.events = {}  # track -> list of (tick, msg)
        self.tempo = [(0, bpm)]
        self.ts = [(0, ts)]
        self.sections = []
        self.programs = {}

    def note(self, track, ch, pitch, beat, dur, vel=100):
        t0 = int(round(beat * PPQ))
        t1 = int(round((beat + dur) * PPQ))
        ev = self.events.setdefault((track, ch), [])
        ev.append((t0, 1, mido.Message("note_on", channel=ch, note=pitch, velocity=vel)))
        ev.append((max(t0 + 1, t1), 0, mido.Message("note_off", channel=ch, note=pitch, velocity=0)))

    def program(self, track, ch, prog):
        self.programs[(track, ch)] = prog

    def save(self, path):
        mid = mido.MidiFile(ticks_per_beat=PPQ, type=1)
        t0 = mido.MidiTrack()
        t0.append(mido.MetaMessage("track_name", name=self.name, time=0))
        meta = []
        for beat, bpm in self.tempo:
            meta.append((int(beat * PPQ), mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(bpm))))
        for beat, (n, d) in self.ts:
            meta.append((int(beat * PPQ), mido.MetaMessage("time_signature", numerator=n, denominator=d)))
        meta.sort(key=lambda x: x[0])
        last = 0
        for t, m in meta:
            m.time = t - last
            last = t
            t0.append(m)
        mid.tracks.append(t0)
        names = {0: "Melody", 1: "Bass", 2: "Chords", 3: "Drums", 4: "Lead2"}
        for (track, ch), evs in sorted(self.events.items()):
            tr = mido.MidiTrack()
            tr.append(mido.MetaMessage("track_name", name=names.get(track, f"T{track}"), time=0))
            if (track, ch) in self.programs:
                tr.append(mido.Message("program_change", channel=ch, program=self.programs[(track, ch)], time=0))
            evs.sort(key=lambda x: (x[0], x[1]))
            last = 0
            for t, _, m in evs:
                m = m.copy(time=t - last)
                last = t
                tr.append(m)
            mid.tracks.append(tr)
        mid.save(path)


SCALE = [0, 2, 4, 5, 7, 9, 11]


def degree_to_pitch(root, deg):
    octv, d = divmod(deg, 7)
    return root + 12 * octv + SCALE[d]


def pop_song(out):
    rnd = random.Random(42)
    s = Song("Neon Skyline (test)", 160)
    s.program(0, 0, 81)   # saw lead
    s.program(1, 1, 38)   # synth bass
    s.program(2, 2, 89)   # warm pad
    root = 62  # D
    chords = [[0, 2, 4], [5, 7, 9], [3, 5, 7], [4, 6, 8]]  # I vi IV V (degrees)
    bar = 0
    beats_per_bar = 4

    def drums(b0, bars, style):
        for k in range(bars):
            base = (b0 + k) * 4
            for q in range(4):
                if style in ("verse", "chorus", "final"):
                    if style == "verse":
                        if q in (0, 2):
                            s.note(3, 9, 36, base + q, 0.25, 118)
                    else:
                        s.note(3, 9, 36, base + q, 0.25, 122)
                    if q in (1, 3):
                        s.note(3, 9, 38 if style == "verse" else 39, base + q, 0.25, 112)
                    for e in range(2):
                        if style == "verse":
                            s.note(3, 9, 42, base + q + e * 0.5, 0.2, 70)
                        elif e == 1:
                            s.note(3, 9, 46, base + q + 0.5, 0.3, 85)
                elif style == "intro":
                    s.note(3, 9, 42, base + q, 0.2, 60)
                    if q == 0:
                        s.note(3, 9, 36, base, 0.25, 100)
            if style in ("chorus", "final") and k % 4 == 0:
                s.note(3, 9, 49, base, 1.0, 120)

    def chords_part(b0, bars, sustain=False):
        for k in range(bars):
            ch = chords[k % 4]
            base = (b0 + k) * 4
            for d in ch:
                s.note(2, 2, degree_to_pitch(root - 12, d), base, 4.0 if sustain else 3.9, 70)
            # bass
            bp = degree_to_pitch(root - 24, ch[0])
            if sustain:
                s.note(1, 1, bp, base, 4.0, 90)
            else:
                for e in range(8):
                    s.note(1, 1, bp + (12 if e % 4 == 3 else 0), base + e * 0.5, 0.45, 95)

    def melody(b0, bars, style):
        deg = 7
        for k in range(bars):
            base = (b0 + k) * 4
            if style == "verse":
                pattern = rnd.choice([[1, 0.5, 0.5, 1, 1], [0.5, 0.5, 1, 0.5, 0.5, 1], [1.5, 0.5, 1, 1], [2, 1, 0.5, 0.5]])
            elif style == "chorus":
                pattern = rnd.choice([[0.25] * 8 + [1, 1], [0.5, 0.25, 0.25, 0.5, 0.5, 1, 1], [0.25] * 4 + [0.5] * 2 + [2],
                                      [0.75, 0.75, 0.5, 1, 1]])
            elif style == "bridge":
                pattern = [2, 2] if k % 2 == 0 else [3, 1]
            else:
                pattern = [4]
            t = 0.0
            for dur in pattern:
                step = rnd.choice([-2, -1, -1, 1, 1, 2, 0, 3, -3])
                if dur <= 0.25:
                    step = rnd.choice([1, 1, -1, 1])  # runs
                deg = max(3, min(13, deg + step))
                vel = 100 if t == 0 else rnd.randint(78, 96)
                s.note(0, 0, degree_to_pitch(root, deg), base + t, dur * 0.95, vel)
                t += dur
        return

    plan = [("intro", 4), ("verse", 8), ("build", 4), ("chorus", 8), ("bridge", 4), ("final", 8), ("outro", 2)]
    for name, bars in plan:
        start_beat = bar * 4
        s.sections.append({"name": name, "start_beat": start_beat, "bars": bars})
        if name == "intro":
            drums(bar, bars, "intro")
            chords_part(bar, bars, sustain=True)
        elif name == "verse":
            drums(bar, bars, "verse")
            chords_part(bar, bars)
            melody(bar, bars, "verse")
        elif name == "build":
            chords_part(bar, bars)
            melody(bar, bars, "verse")
            for k in range(bars):
                base = (bar + k) * 4
                div = 2 if k < 2 else (4 if k < 3 else 8)
                for e in range(4 * div // 2 * 2 // 2 * 1):
                    pass
                n = 4 * (div // 2) if div > 2 else 8
                for e in range(n):
                    s.note(3, 9, 38, base + e * 4.0 / n, 0.1, 70 + int(50 * (k * n + e) / (bars * n)))
                s.note(3, 9, 36, base, 0.25, 110)
        elif name in ("chorus", "final"):
            drums(bar, bars, name)
            chords_part(bar, bars)
            melody(bar, bars, "chorus")
        elif name == "bridge":
            chords_part(bar, bars, sustain=True)
            melody(bar, bars, "bridge")
            for k in range(bars):
                s.note(3, 9, 42, (bar + k) * 4 + 2, 0.2, 60)
        elif name == "outro":
            s.note(0, 0, degree_to_pitch(root, 7), bar * 4, 6, 100)
            for d in chords[0]:
                s.note(2, 2, degree_to_pitch(root - 12, d), bar * 4, 6, 80)
            s.note(1, 1, root - 24, bar * 4, 6, 90)
            s.note(3, 9, 49, bar * 4, 2, 120)
            s.note(3, 9, 36, bar * 4, 0.25, 120)
        bar += bars
    path = os.path.join(out, "pop160.mid")
    s.save(path)
    return {"file": "pop160.mid", "bpm": 160, "sections": s.sections, "bars": bar}


def ballad(out):
    rnd = random.Random(7)
    s = Song("Paper Lanterns (test)", 90)
    s.tempo.append((32, 120))  # tempo change at bar 9
    s.ts.append((64, (3, 4)))  # waltz section at beat 64 (bar 13 at 4/4: 48..64?)
    s.program(0, 0, 73)  # flute
    s.program(2, 2, 48)  # strings
    root = 60
    # 8 bars 4/4 at 90, 8 bars 4/4 at 120 (beats 32..64), then 8 bars of 3/4 (beats 64..88)
    beat = 0.0
    deg = 7
    for b in range(16):
        base = b * 4
        for d in [0, 2, 4]:
            s.note(2, 2, degree_to_pitch(root - 12, d + (b % 4) * 1), base, 3.9, 64)
        s.note(3, 9, 36, base, 0.25, 100)
        s.note(3, 9, 38, base + 2, 0.25, 96)
        for e in range(4):
            s.note(3, 9, 42, base + e, 0.2, 60)
        pat = rnd.choice([[1, 1, 2], [2 / 3, 2 / 3, 2 / 3, 2], [0.5, 0.5, 1, 2], [1.5, 0.5, 2]])
        t = 0
        for dur in pat:
            deg = max(3, min(12, deg + rnd.choice([-1, 1, 2, -2, 0])))
            s.note(0, 0, degree_to_pitch(root, deg), base + t, dur * 0.9, 92)
            t += dur
    for b in range(8):
        base = 64 + b * 3
        s.note(3, 9, 36, base, 0.25, 100)
        s.note(3, 9, 42, base + 1, 0.2, 60)
        s.note(3, 9, 42, base + 2, 0.2, 60)
        for d in [0, 2, 4]:
            s.note(2, 2, degree_to_pitch(root - 12, d), base, 2.9, 60)
        for t, dur in [(0, 1), (1, 1), (2, 1)] if b % 2 == 0 else [(0, 2), (2, 1)]:
            deg = max(3, min(12, deg + rnd.choice([-1, 1, 0])))
            s.note(0, 0, degree_to_pitch(root, deg), base + t, dur * 0.9, 90)
    path = os.path.join(out, "ballad_tempo.mid")
    s.save(path)
    return {"file": "ballad_tempo.mid", "tempo": [[0, 90], [32, 120]], "time_signatures": [[0, 4, 4], [64, 3, 4]]}


def piano(out):
    rnd = random.Random(3)
    s = Song("Glass Garden (test)", 120)
    s.program(0, 0, 0)
    root = 60
    for b in range(16):
        base = b * 4
        # left hand broken chords
        ch = [[0, 4, 7], [-3, 0, 4], [-7, -3, 0], [-5, -1, 2]][b % 4]
        for e in range(8):
            s.note(0, 0, root - 12 + ch[e % 3], base + e * 0.5, 0.45, 62)
        # right hand melody with occasional dyads
        t = 0.0
        pat = rnd.choice([[1, 1, 1, 1], [0.5, 0.5, 1, 2], [1, 0.5, 0.5, 1, 1], [0.25, 0.25, 0.5, 1, 2]])
        deg = 9
        for dur in pat:
            deg = max(5, min(14, deg + rnd.choice([-1, 1, 2, -2])))
            p = degree_to_pitch(root, deg)
            s.note(0, 0, p, base + t, dur * 0.95, 96)
            if dur >= 1 and rnd.random() < 0.4:
                s.note(0, 0, p - 4 if p - 4 > root else p - 3, base + t, dur * 0.95, 80)
            t += dur
    path = os.path.join(out, "piano_solo.mid")
    s.save(path)
    return {"file": "piano_solo.mid", "bpm": 120}


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    meta = [pop_song(out), ballad(out), piano(out)]
    with open(os.path.join(out, "truth.json"), "w") as f:
        json.dump(meta, f, indent=1)
    print(json.dumps(meta)[:400])
