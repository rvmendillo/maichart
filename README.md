# MaiChart Studio

An iOS app that turns songs and sheet music into **maimai-style charts for AstroDX** (simai `maidata.txt`), for **all six difficulties** (EASY → Re:MASTER), with a built-in AstroDX-like player, Piano Tiles, a SoundFont synthesizer and an MP3 pipeline that keeps the audio timeline sample-exact.

> Fan-made tool. Not affiliated with SEGA or the AstroDX team. Only chart songs you have the rights to use.

## Install (unsigned IPA)

1. Download `MaiChartStudio-unsigned.ipa` (GitHub Actions → *iOS build* → artifact `MaiChartStudio-unsigned-ipa`).
2. Sideload it with AltStore / SideStore / Sideloadly (they sign it with your Apple ID) or TrollStore.
3. Requires iOS 16+, iPhone or iPad.

## Using it

1. **New chart** → pick a song (MP3, M4A/AAC, WAV, AIFF, FLAC), a **MIDI** file, **MusicXML** (`.musicxml`, `.xml`, `.mxl`) or a **PDF** score, or paste a direct file link.
2. MaiChart Studio detects the beat grid and offset (or uses the score's exact timing), transcribes melody (Basic Pitch, on-device CoreML) and drums, and writes EASY / BASIC / ADVANCED / EXPERT / MASTER / Re:MASTER.
3. Preview any difficulty with **autoplay** (eye button) or **play it** yourself (play button).
4. **Share .adx** → open with AstroDX, or **Save to Files** → choose the AstroDX folder. The archive contains `Song/maidata.txt`, `Song/track.mp3`, `Song/bg.jpg` — never the internal WAV.

### Sync
* Audio: tempo (incl. mid-song tempo changes), first downbeat and `&first` are detected from calibrated onsets (≈2–9 ms of the real attacks in tests).
* MP3s you import are kept **bit-exact** (only the Xing/Info header frame is removed so every decoder starts on the same sample).
* MIDI/MusicXML/PDF renders: WAV → 320 kbps CBR MP3 with the encoder delay pre-compensated; the MP3 is decoded again and cross-correlated with the WAV (lag, correlation, SNR, spectral distance, length, clipping are shown in the app and in **Studio**).
* If a chart still feels early/late in AstroDX, use **Sync & offset** (±1/5/10 ms nudges written into `&first`).

## Chart design

* **Hierarchical:** Re:MASTER is laid out first; every lower difficulty keeps a subset of the same moments on the same buttons (verified by tests), simplifying EACH, touch and slides on the way down — so lower charts are direct practice for higher ones. EASY uses only quarter-note positions, BASIC only eighths.
* **Human-like, not robotic:** melody contour mapped to height on the ring, circle runs for scalar runs, zig-zags and trills for fast alternation, mirrored/moving EACH pairs on accents, phrase echo (repeated music returns mirrored/rotated), seeded randomness (Remix gives a new variation).
* **Drums + melody:** kick/snare/cymbal hits and melody notes both drive the rhythm; breaks land on crashes/section starts.
* **maimai tricks:** touch notes on A/B/D/E sensors (with the closing-triangle timer), centre touch holds (`Ch`) during sustains, fireworks, EACH, circle runs; slides kept rare (adjustable).
* **Playable:** a two-hand simulator (hand speed, travel distance, busy hands during holds/slides) checks and repairs every difficulty; ≤ 2 simultaneous notes; simultaneous holds always have equal length.
* Options: slides / touch / EACH / BREAK amounts, Re:MASTER density, extra 16th stream fills, mirror.

## Other features

* **Player** (AstroDX-like): judgement ring, lane guides, button pads that light under your fingers, optional sensor map, taps/EACH/BREAK/EX, holds, stars + slide arrows that disappear as you trace, touch notes with closing triangles, centre touch-hold progress ring, fireworks, CRITICAL/PERFECT/GREAT/GOOD/MISS pop-ups with FAST/LATE, combo, live achievement (101% scale with break bonus), DX score, rank, FC/AP, autoplay, pause/retry, speed and timing calibration.
* **Piano Tiles:** 4 lanes of falling black tiles from the score (or the transcription of an audio song); max two tiles at once with the same length; hold tiles; tap plays the notes with any instrument of the SoundFont; auto mode.
* **Soundfont Studio:** bundled GeneralUser GS (GM/GS), import your own `.sf2`; audition instruments on a keyboard; choose renderer **MaiSynth** (pure Swift, full SoundFont 2 model, matches FluidSynth) or **Apple AUSampler**; WAV vs MP3 waveform overlay.
* **PDF scores:** on-device optical music recognition for clean engraved scores (staves, clefs, key signatures, accidentals, noteheads, chords, stems, beams/flags, dots, rests, barlines, grand staves).

## Project layout

```
MaiCore/        Swift package (platform independent, tested on Linux + iOS)
  Sources/MaiCore/  Music (MIDI, MusicXML, Score), Simai (writer/parser), Chart (generator),
                    Analysis (beat grid, drums, Basic Pitch post-processing), Synth (SF2),
                    Audio (WAV, MP3, alignment), Player (judge engine), PianoTiles, OMR, Export
  Sources/CLAME     LAME 3.100 MP3 encoder (LGPL)
  Sources/CMiniMP3  minimp3 decoder (CC0)
  Sources/maicli    developer CLI (chart/render/analyze/omr/mp3...)
App/            SwiftUI iOS app
project.yml     XcodeGen spec; .github/workflows/ios.yml builds the unsigned IPA
```

Build locally on a Mac: `brew install xcodegen && xcodegen generate && open MaiChartStudio.xcodeproj`.
Core tests: `cd MaiCore && swift test`.

## Credits & licences

GeneralUser GS (S. Christian Collins), Basic Pitch (Spotify, Apache-2.0), LAME (LGPL), minimp3 (CC0), simai syntax compatibility checked against SimaiSharp (Reflektone, MIT). Licences are included in the app (Settings → Open-source licences).
