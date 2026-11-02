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

## Releasing

**Maintainer only.** This section is documentation of how the released
artefacts are produced, not an invitation — a release needs a Developer ID
Application private key and notarisation credentials, both of which live in a
Keychain and neither of which can be committed. Running these scripts without
them produces a locally-signed build, which is fine for development and is not
a release.

Notarisation credentials are stored once:

```sh
xcrun notarytool store-credentials yaz \
    --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
```

The password is an **app-specific password** from
[appleid.apple.com](https://appleid.apple.com) → Sign-In and Security →
App-Specific Passwords; an account password will not work. A `401 — the account
does not exist` almost always means the wrong Apple ID rather than the wrong
password.

One command does a release. It builds, signs, notarises, writes the download
manifest, and signs the Sparkle update feed:

```sh
swift test                            # 283 tests, ~1 s
./scripts/release.sh                  # dist/yaz-<version>.dmg + site/downloads/
./scripts/release.sh --github         # also a GitHub release (tag pushed first)
./scripts/release.sh --deploy         # also the site + feed to yaz.mike4.dev
```

Before a release:

1. Raise `CFBundleShortVersionString` **and** `CFBundleVersion` in
   `Resources/AppInfo.plist`. Sparkle compares `CFBundleVersion`; a release
   that does not raise it is never offered, and `release.sh` refuses one that
   the feed already lists.
2. Write the notes to `dist/notes-<version>.md`. They are the GitHub release
   body and the text in Sparkle's update window.
3. `git tag v<version> && git push origin v<version>` (for `--github`).

The feed is signed with the Sparkle EdDSA key in the login Keychain — the same
key as Kare's. `release.sh` compares it with `SUPublicEDKey` in
`Resources/AppInfo.plist` and stops if they differ: a feed signed with another
key is one that every installed copy rejects, and nobody updates again. It also
runs `yaz updates --require` on the finished bundle, so a build whose updater
does not work is never published.

`--deploy` publishes `site/` to Cloudflare (`wrangler.jsonc`, the Worker `yaz`
with the custom domain `yaz.mike4.dev`). Run `npx wrangler login` once. DMGs
are not committed; commit `site/downloads/appcast.xml`, `latest.json` and
`site/_redirects` after a release.

The steps inside `release.sh`, for when one of them fails:

```sh
./scripts/bundle.sh         # picks up the Developer ID automatically
./scripts/notarize.sh       # app + DMG, notarised and stapled
```

Then check what a stranger's Mac would see, which is not the same as the build
machine's view — the build machine trusts certificates it holds locally:

```sh
spctl --assess --type execute --verbose dist/yaz.app     # source=Notarized Developer ID
xcrun stapler validate dist/yaz.app                      # ticket present offline
```

Validate the app **inside** the mounted DMG too, not just the DMG. Stapling the
DMG alone leaves the copy the user drags to Applications without its own
ticket, which then needs a network round trip on first launch — and fails
closed if the machine is offline.

The version lives in `Resources/AppInfo.plist`; `bundle.sh`, `notarize.sh` and
`release.sh` all read it from there. Move the `CHANGELOG.md` entry from
Unreleased to the new version in the same commit.
