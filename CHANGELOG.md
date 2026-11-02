# Changelog

Notable changes to yaz. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[semver](https://semver.org/).

## [Unreleased]

Version 0.2.0 (build 2) in `Resources/AppInfo.plist`, not yet released.

### Added

- **Automatic updates** through Sparkle. The signed app reads
  `https://yaz.mike4.dev/downloads/appcast.xml` once a day and offers a new
  version from the menu bar, without a window over the app you are dictating
  into. `yaz updates` reports whether a copy can update itself. The CLI does
  not update itself.
- **yaz.mike4.dev**, the website: download, install steps, checksum, and a
  replay of a measured dictation. Served from `site/` by Cloudflare.
- **`scripts/release.sh`** builds, notarises and publishes a release: the DMG,
  `latest.json`, the signed update feed, and optionally the GitHub release
  (`--github`) and the site (`--deploy`).

- **Voice activity check.** Silero VAD (FluidAudio, on the Neural Engine) runs
  after the level gate and drops recordings that are loud but hold no speech —
  a fan, typing, a cough — before Whisper can invent text for them. Off by
  default until the 0.3 threshold is measured on real microphones; turn it on
  with `"vad": true`. The model downloads in the background; until it is
  ready, or if it fails to load, every recording is kept. `yaz transcribe`
  always prints the scores, and `--strict` enforces them when `vad` is on.

### Fixed

- **The clipboard is no longer lost.** The restore after a paste was
  unconditional. A copy made in the 250 ms after a dictation was overwritten,
  and two dictations in a row restored the first dictation instead of the
  user's own contents. The restore now checks the pasteboard's change count
  and only the newest dictation restores.

## [0.1.0] — 2026-08-05

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
- **Packaging** — `.app` bundle and DMG, launch-at-login, and a stable signing
  identity so macOS permissions survive rebuilds.
- **Signed and notarised releases.** The DMG is signed with a Developer ID
  Application certificate under the Hardened Runtime, notarised by Apple, and
  stapled twice on purpose — the app first, then the DMG built from the stapled
  app — so the copy dragged to Applications carries its own ticket and opens
  offline. The only entitlement requested is microphone access.
  `scripts/bundle.sh` falls back to a local self-signed certificate, then
  ad-hoc, for builds made without a Developer ID.

### Known limitations

- Term repair and hesitation removal are Turkish-only, and are skipped for
  other languages rather than applied. The guard against overwriting a real
  word is a Turkish word list; elsewhere it corrupts text.
- Model weights (~1.6 GB) download on first use into `~/Documents/huggingface`,
  which iCloud may sync.
- macOS can claim the fn key when a second keyboard layout or Dictation is
  enabled. The app detects this and offers right-option instead.
