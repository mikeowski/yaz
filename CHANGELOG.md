# Changelog

Notable changes to yaz. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[semver](https://semver.org/).

## [Unreleased]

Version 0.2.0 (build 2) in `Resources/AppInfo.plist`, not yet released.

### Fixed

- **Fixes were missed.** The field was read once, 12 s after a paste: a fix
  followed by Return (the field already empty) and a fix made later were
  lost. Electron apps (Slack, VS Code, Notion, Discord) exposed no field text
  at all, and in a short dictation a deleted and retyped word left too
  little to recognise. yaz now watches the field for up to a minute, anchors
  the dictation on the text around it, asks Electron apps for their text,
  and says in the menu what it noted, learned or rejected.

### Added

- **Per-app settings.** Under `apps` in the config, by bundle id: `language`,
  `refine`, `numbers`, `voice_commands`, `screen_context`, `code` and the new
  `style` (`chat` drops a one-sentence message's full stop). Turkish in
  Slack, English in GitHub, the language model only in Mail. `yaz apps`
  lists them and the running apps' ids.
- **`yaz mcp`, for coding agents.** A Model Context Protocol server over
  stdio. `wait_for_dictation` lets Claude Code, Cursor or Codex ask you
  something you answer by voice: the dictation goes to the agent instead of
  being pasted. `last_dictation`, `recent_dictations` and `search_dictations`
  read the history. The hand-off is two 0600 files: no socket, no port.
- **Voice commands.** "yeni satır", "yeni paragraf", "soru işareti", "ünlem
  işareti", "iki nokta üst üste" at the end of a sentence; "Yeni satır
  ekledim." stays a sentence. "geri al" on its own (and **Remove Last
  Dictation** in the menu) removes the last dictation through Accessibility,
  only if it still ends at the cursor. No line breaks in code apps or when
  typing. `"voice_commands": false` turns them off.
- **Names on screen.** When the key goes down, yaz reads the front window's
  visible text through Accessibility and adds the words that look like names
  (`PaymentGateway`, `CORS`, "Pull Request") to the vocabulary for that
  dictation only. These terms need a closer match (0.86), and any that would
  change one of the fixed set's everyday sentences is dropped first. Nothing
  is saved. `"screen_context": false` turns it off.
- **Your own test set.** Every fix you make after a dictation and every
  dictation you keep as pasted becomes a private case in `personal.json`.
  A learned rule must also leave these no worse, so it can never break one of
  your own sentences. `yaz eval --personal` shows how many of your fixes yaz
  now gets right. Stored only while history and learning are on.
- **Turkish numbers as digits.** "saat on beş otuzda" → "saat 15.30'da",
  "yüzde elli" → "%50", "on beş bin dolar" → "15.000 dolar", "iki bin yirmi
  altıda" → "2026'da". The suffix follows the reading. Words that only look
  like numbers (onu, altında, yedi, bin, yüzünü, bir) stay words: 29
  conversions and 23 look-alikes are in the `yaz eval` score. `yaz numbers`
  shows the result; `"numbers": false` turns it off.
- **German term repair.** Set `"language": "de"` and the vocabulary repairs
  English terms in German dictation, guarded by a German lexicon. Without the
  lexicon, 6 of 30 ordinary sentences changed (`Morgen` → merge, `Doktor` →
  Docker). With it, none of them change, and neither do 38 sentences held out
  from making the list. `Släck` → Slack. Casing commands stop at German
  words, and "Datei" triggers a file mention. `yaz eval --language de` scores
  the German set.
- **Learning from your fixes.** yaz reads the field back after a paste and
  learns a term you fix twice. A rule is kept only if the fixed evaluation
  (`EvalCorpus`: false matches × 3 + misses) does not get worse, so it can
  never learn to turn `doktor` into `Docker`. A repair you undo is blocked at
  once. `yaz learned` shows and forgets rules; `yaz eval` prints the score;
  `research/program.md` runs the same keep-or-revert loop offline with an
  agent, in the manner of Karpathy's autoresearch.
- **A new icon, in every macOS appearance.** `Resources/AppIcon.icon` is an
  Icon Composer document: a vermilion fill and two Liquid Glass layers, a
  voice and a caret. `bundle.sh` compiles it with `actool`, so macOS 26 draws
  it in Default, Dark (system-dark fill, vermilion voice), Clear and Tinted,
  following System Settings → Appearance. yaz's colour moves from indigo to
  vermilion, on the website too, which now also follows light and dark mode
  for its icons.
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
