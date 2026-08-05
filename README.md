# yaz

Push-to-talk dictation for macOS. Hold a key, speak, release — the text appears
at your cursor. Nothing leaves the machine.

Built on the skeleton of [parrot](https://github.com/digimata/parrot), aimed at
the three things it deliberately refuses: a **multilingual default**,
**reliable text insertion**, and **post-processing**.

**Requires:** macOS 26+ on Apple Silicon.

## Install

**Download the DMG** from
[Releases](https://github.com/mikeowski/yaz/releases/latest), open it, drag
`yaz.app` to Applications. It lives in the menu bar.

The build is signed with a Developer ID certificate and notarised by Apple, so
it opens normally — no right-click → Open, no Gatekeeper warning. To check the
download before opening it:

```sh
shasum -a 256 -c SHA256SUMS.txt
spctl --assess --type execute --verbose /Applications/yaz.app
# accepted · source=Notarized Developer ID
```

**Or build it yourself:**

```sh
./scripts/bundle.sh --dmg     # produces dist/yaz-0.1.0.dmg
```

Your own build is signed with a local certificate rather than a Developer ID,
so Gatekeeper calls it unidentified — expected, and it changes nothing about
how the app behaves.

Installing as an app also solves a permissions problem. macOS attributes an
Accessibility grant to the *responsible process*, and for a CLI run in a
terminal that is the terminal — the prompt asks about "Terminal", and the grant
does not reach shells that are already running. As a `.app`, yaz has its own
identity: the prompt says "yaz", and the grant sticks.

**As a CLI:**

```sh
./scripts/install.sh              # build and install into /usr/local/bin
./scripts/install.sh --login      # also start at login
./scripts/install.sh --uninstall

yaz doctor --request              # request permissions
yaz models download               # pre-fetch the model (~1.6 GB)
yaz                               # start the daemon
```

The script is deliberately not a `curl | sh` one-liner: it asks for sudo and
installs a daemon that requests TCC permissions. Read it first.

## Which languages does this work for?

Two different answers, and the difference matters.

**Transcription is fully multilingual.** The engine is Whisper; set `language`
to anything it supports. Measured, English, untouched by any Turkish logic:

```
$ yaz transcribe --language en sample.wav
  latency 520 ms · RTF 0.107
  Today I reviewed the pull request and merged it into main after the CI pipeline turned green.
```

**Term repair is Turkish-only** — and that is a safety boundary, not a
limitation waiting to be lifted. The guard that stops the layer replacing a
word you actually said is a list of ordinary Turkish words. Point it at another
language and nothing is protected. Measured on English before the boundary was
enforced:

```
"into main"       → "Notion"
"merged"          → "merge"
"the CI pipeline" → "CI pipeline"
```

So the pipeline skips it outside Turkish and says so. Supporting another
language means writing its common-word list and phonetic normalisation — not
flipping a flag.

## Term repair

Whisper transcribes plain Turkish well. What it mangles is English technical
terms inside Turkish speech — which is most of what a developer dictates:

```
$ yaz transcribe --vocabulary fixtures/t2.wav
  vocabulary: Sılacık → Slack (0.749, skeleton)
  vocabulary: Puhrıkı Esti'de → pull request'de (0.832, skeleton)
  vocabulary: C.I.P. eline → CI pipeline (0.799, skeleton)
  Yarın saat 14'te toplantı var. Ahmet'e Slack üzerinden mesaj atmayı unutma.
  pull request'de merge etmem lazım. CI pipeline yeşile döndüğünde deploy ederiz.
```

Turkish suffixes survive (`Puhrıkı Esti'de` → `pull request'de`), and 30
ordinary Turkish sentences come through untouched — that corpus is what set
every threshold in the matcher.

Two standard approaches were tried first and both failed here: Whisper's
`promptTokens` biasing returns empty output on `large-v3-turbo`, and Apple's
on-device model could not repair `Sılacık` even when handed the target list.
So repair is deterministic, and can only ever produce words you put in the
vocabulary yourself.

## Quality gates

The output goes straight to your cursor, so wrong text costs more than no text.

Before inference, recordings shorter than 0.35 s or below a silence threshold
are dropped — Whisper returns nothing for the first and invents sentences for
the second. After inference, the decoder's own confidence signals catch
hallucinations:

```
$ yaz transcribe --strict fixtures/t1.wav fixtures/silence-3s.wav fixtures/tiny-100ms.wav
═══ t1.wav (5.57 s) ═══
  latency 567 ms · RTF 0.102 · peak 0.702 · rms 0.151
  noSpeech 0.00 · logProb -0.21 · compression 1.07
  Bugün Pilot Projesini inceledim ve On Device Transcription Mimarisini çözdüm.

═══ silence-3s.wav ═══
  ✗ no sound in the recording (peak 0.0000, threshold 0.0050)

═══ tiny-100ms.wav ═══
  ✗ recording too short (0.10 s, needs at least 0.35 s)
```

## Post-processing

Two tiers. The deterministic one is the default and free:

```
$ yaz vocab refine --mode fillers "ıı yarın ee saat ikide mmm toplantımız var"
after : yarın saat ikide toplantımız var        (1 ms)
```

The language model (Apple FoundationModels, already on macOS 26) also handles
contextual filler words and punctuation, at 0.3–1.4 s per utterance — so it is
opt-in:

```
$ yaz vocab refine --mode llm "ıı yarın şey saat ikide yani toplantımız var hani o proje için ee hazırlık lazım"
after : Yarın saat ikide toplantımız var. O proje için hazırlık lazım.
```

Model output has to earn its way in: summarising, adding, answering a question,
or losing content is rejected and the deterministic result is kept. A cleanup
step must never cost you the dictation.

## History

What you dictated, **which app it went into**, when, and how long it took —
`~/Library/Application Support/yaz/history.jsonl`.

**No audio is stored**, only text. Keeping recordings would make this a
surveillance tool by accident.

```sh
yaz history                    # last 20 entries
yaz history --search slack     # search text or app name
yaz history --clear
```

Also available from the menu bar, with search and copy. Turn it off with
`"history": false`.

## Permissions — there are two, and a third thing that isn't one

**Accessibility** lets yaz paste text at your cursor.
**Input Monitoring** lets yaz *see* the push-to-talk key. Different list, same
Settings pane. Granting only the first produces a tap that installs cleanly and
never fires — measured here as: permission granted, tap created, zero events,
no error anywhere.

Then there is the **fn key itself**. macOS claims the globe key as soon as a
second keyboard layout exists or Dictation is on, and consumes the press before
any app sees it. Two ways out:

```
System Settings → Keyboard → "Press 🌐 key to" → Do Nothing
```

or click **"⚠︎ fn is claimed by macOS — use right option"** in the menu bar,
which switches the hotkey and saves it.

```sh
yaz doctor          # reports all three
yaz logs --follow   # the app writes the same to ~/Library/Logs/yaz.log
```

### "It says granted, and still nothing happens"

Replacing an app bundle can leave macOS holding a permission record that no
longer matches the binary. The system then reports the permission as granted,
the app believes it, and events are **silently never delivered**.

Nothing in macOS reports this, so silence is the signal: if the keyboard
listener sees no events for 75 seconds, yaz says so in the log and in the menu.

```sh
yaz reset-permissions     # clears the records
# quit and reopen yaz — macOS will ask again
```

### Grant it once, not every build

macOS keys a permission to the **code signing identity**. An ad-hoc signature
has no identity beyond the binary's own hash, so every rebuild invalidates what
you granted. `scripts/bundle.sh` picks the best identity available, in order:

| | Gatekeeper | Permissions survive a rebuild |
|---|---|---|
| **Developer ID Application** | opens anywhere, once notarised | yes |
| **Self-signed local certificate** | unidentified developer | yes |
| **Ad-hoc** | unidentified developer | **no** |

Contributors want the middle one, created once:

```sh
./scripts/signing-identity.sh    # one-time; asks for your login password
```

That is the difference between granting permission once and granting it on
every build.

### Releases: signed, notarised, stapled

Released builds are signed with a Developer ID Application certificate under the
Hardened Runtime, notarised by Apple and stapled — so the DMG opens with no
warning and no right-click → Open.

```sh
./scripts/bundle.sh        # picks up the Developer ID automatically
./scripts/notarize.sh      # notarise + staple the app, then the DMG
```

Notarising needs credentials once. The password is an **app-specific password**
from [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security →
App-Specific Passwords; your account password will not work:

```sh
xcrun notarytool store-credentials yaz \
    --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>
```

The only entitlement requested is microphone access — see
[SECURITY.md](SECURITY.md) for what is deliberately not requested, and how to
verify a download yourself.

## Models — downloaded, not bundled

`yaz.app` is 14 MB; `whisper large-v3-turbo` is 1.6 GB. Bundling the weights
would make the app a hundred times larger and pin everyone to one checkpoint,
so the first run fetches them **automatically, with progress** — the menu bar
shows `downloading — 412 MB of 1.6 GB (26%)`.

```sh
yaz models download          # fetch and compile ahead of time
yaz models list              # what is on disk
```

Weights land in `~/Documents/huggingface` (WhisperKit's choice, not ours). If
iCloud Documents sync is on they will be uploaded — `yaz doctor` says so.

Models carry their own licences; see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Configuration

`~/.config/yaz/config.json` — optional, and CLI flags win over it. The settings
window writes this same file, so it stays hand-editable.

```json
{
  "engine": "whisper",
  "whisper_model": "large-v3-turbo",
  "language": "tr",
  "hotkey": "fn",
  "inject_mode": "paste",
  "refine": "fillers",
  "keep_model_loaded": true,
  "overlay": true,
  "menu_bar": true,
  "history": true,
  "history_limit": 2000,
  "on_transcript": "my-hook",
  "vocabulary": [
    "Slack", "pull request", "CI pipeline", "Kubernetes",
    { "term": "PostgreSQL", "aliases": ["postgres"], "min_similarity": 0.85 }
  ]
}
```

`on_transcript` runs a shell command with the transcript as its only argument.

## CLI

```sh
yaz                                    # daemon (default)
  --hotkey fn|right-option|right-command|right-control|right-shift
  --inject-mode paste|type
  --language tr
  --verbose

yaz doctor [--request]                 # permissions, model, settings
yaz logs [--follow]                    # ~/Library/Logs/yaz.log
yaz reset-permissions                  # clear stale permission records
yaz history [--search <text>] [--json] [--clear]
yaz settings [--history]               # settings or history window
yaz preview                            # try the recording indicator, no mic needed
yaz models list
yaz models download [--force]
yaz install --launch-at-login | --uninstall | --status

yaz vocab test "<text>"                # try term repair, see the scores
yaz vocab refine --mode llm "<text>"   # try post-processing
yaz vocab explain "<term>" "<heard>"   # compare phonetic keys

yaz transcribe <file...>               # audio → text, with latency
  --engine-name whisper|parakeet
  --whisper-model large-v3-turbo|large-v3
  --language tr
  --vocabulary --refine off|fillers|llm
  --strict                             # enforce the quality gates
  --repeat-count 3 --max-seconds 3600
```

## Measured on an M4 Pro (24 GB, macOS 26.5)

Reproducible against the fixed audio in `fixtures/`.

| | whisper large-v3-turbo |
|---|---|
| First model load (Core ML compile) | ~115–210 s, once |
| Every later launch | ~6.5–7 s |
| 5.6 s of speech → text | **506 ms** (RTF 0.091) |
| 12.1 s of speech → text | **855 ms** (RTF 0.071) |
| Resident memory | ~210–260 MB |

## Development

```sh
swift build
swift test              # ~1 s, offline, no microphone
./scripts/bundle.sh     # dist/yaz.app
```

262 tests. See [CONTRIBUTING.md](CONTRIBUTING.md) for the parts that are easy
to break, and [docs/architecture.md](docs/architecture.md) for why things are
the way they are — including the failures that shaped them.

## Stack

- **Swift 6.2** — one SPM executable target, no `.app` bundle required
- **WhisperKit** — Whisper on Core ML / ANE (default engine)
- **FluidAudio** — Parakeet TDT on Core ML / ANE (optional, no Turkish)
- **FoundationModels** — macOS 26 on-device LLM for cleanup (no download)
- **AVAudioEngine**, **CGEventTap**, **AppKit**, **SwiftUI**

## Licence

MIT — see [LICENSE](LICENSE). Dependencies and model weights carry their own
terms: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
