# Contributing

## What this project is

Dictation whose output is pasted straight into whatever the user is looking at.
That single fact sets the bar: **wrong text is worse than no text.** A mangled
transcript is visible and annoying; a confidently wrong replacement is invisible
and lands in someone's message. Changes are judged against that.

## Getting set up

```sh
git clone https://github.com/mikeowski/yaz.git && cd yaz
swift build
swift test                       # ~1 s, no network, no microphone
./scripts/bundle.sh              # dist/yaz.app
```

Requires macOS 26+ on Apple Silicon. The engines run on the Apple Neural
Engine; Intel is not supported.

Running the daemon needs two permissions and a hotkey macOS has not claimed —
see the README. `yaz doctor` reports all of it.

## Tests

`swift test` must pass before anything is merged. The suite is fast and offline
by design, so there is no excuse to skip it.

Two things to know about how tests are written here:

- **Fixtures over microphones.** Accuracy claims are measured against the fixed
  audio in `fixtures/`, never against whatever was said into the mic that time.
  If you change an engine, a threshold, or a correction rule, show the before
  and after on those files.
- **Adversarial fixtures are load-bearing.** `silence-3s.wav`,
  `tiny-100ms.wav`, `noise-floor-2s.wav` and the multi-format variants exist
  because each one caught a real bug. Do not delete them to make a test pass.

New behaviour needs a test that fails without the change. Bug fixes need a test
that reproduces the bug.

## The parts that are easy to break

**Correction thresholds.** `Vocabulary` replaces words on fuzzy phonetic
evidence. Its precision corpus (30 ordinary Turkish sentences that must come
through untouched) is not decoration — every threshold in that file was set by
running it. If you loosen a threshold, run the corpus.

**Language boundaries.** The repair layers are Turkish-only, and unsafe rather
than merely useless elsewhere: the guard against overwriting a real word is a
Turkish word list. Adding a language means writing its common-word list and its
phonetic normalisation, not relaxing `isSupported(language:)`.

**Concurrency.** `NSApplication.run()` never returns, so every command is a
synchronous `ParsableCommand` and async work bridges through `runBlocking`.
Using that bridge for anything needing the MainActor deadlocks. If you find
yourself adding `AsyncParsableCommand`, read the comment in `RunBlocking.swift`
first.

## Style

Match the surrounding code. Two conventions worth stating:

- **Comments explain why, not what.** Most comments in this codebase record a
  measurement or a decision — why a threshold is that number, which alternative
  was tried and failed. Keep that.
- **Errors name what the user can act on.** `YazError` exists because an
  earlier version printed `Error: nilError`. Anything thrown should name the
  file, the limit, or the setting involved.

## Pull requests

Say what you measured. "Improves accuracy" is not reviewable; "fixture t2 goes
from 3 corrections to 4, precision corpus still clean" is.

If a change is user-visible, update the README. If it is a design decision worth
remembering, update `docs/architecture.md`.
