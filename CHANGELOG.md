# Changelog

Notable changes to yaz. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[semver](https://semver.org/).

## [Unreleased]

Nothing yet.

## [0.1.0] — 2026-08-02

First working version. Push-to-talk dictation, on-device, nothing leaves the
machine.

### Added

- **Transcription** on the Apple Neural Engine via WhisperKit. Multilingual;
  Turkish by default. Measured on an M4 Pro: 5.6 s of speech → 506 ms,
  12.1 s → 855 ms. Parakeet available as a faster engine for the 25 languages
  it covers (Turkish is not among them).
- **Term repair** for Turkish. Whisper mangles English technical terms in
  Turkish speech — `Slack` → `Sılacık`, `pull request` → `Puhrıkı Esti`. A
  deterministic layer repairs them from a user vocabulary using consonant
  skeletons and phonetic normalisation, preserving Turkish suffixes
  (`Puhrıkı Esti'de` → `pull request'de`).
- **Quality gates.** Recordings that are too short or silent are dropped before
  inference; hallucinated output is caught after it using the decoder's own
  confidence signals.
- **Post-processing.** Deterministic hesitation removal (~1 ms), plus optional
  cleanup through Apple's on-device model (0.3–1.4 s).
- **Text insertion** by clipboard paste, restoring the previous contents.
  Typing remains available as a fallback.
- **Menu bar app** with a recording indicator, settings window, and history.
- **History** — transcript text, the app it was pasted into, and a timestamp.
  No audio is ever stored.
- **`yaz` CLI** — `doctor`, `logs`, `history`, `models`, `transcribe`, `vocab`,
  `settings`, `preview`, `install`, `reset-permissions`.
- **Packaging** — `.app` bundle and DMG, launch-at-login, and a stable
  self-signed identity so macOS permissions survive rebuilds.

### Known limitations

- Term repair and hesitation removal are Turkish-only, and are skipped for
  other languages rather than applied. The guard against overwriting a real
  word is a Turkish word list; elsewhere it corrupts text.
- Not notarised. Gatekeeper treats the app as unidentified.
- Model weights (~1.6 GB) download on first use into `~/Documents/huggingface`,
  which iCloud may sync.
- macOS can claim the fn key when a second keyboard layout or Dictation is
  enabled. The app detects this and offers right-option instead.
