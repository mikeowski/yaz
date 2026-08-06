# yaz

[![CI](https://github.com/mikeowski/yaz/actions/workflows/ci.yml/badge.svg)](https://github.com/mikeowski/yaz/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B%20Apple%20Silicon-black.svg)](#install-the-application)

yaz is a dictation tool for macOS. Hold the hotkey. Speak. Release the hotkey.
yaz then writes the text at your cursor. No data goes out of your computer.

yaz uses the structure of [parrot](https://github.com/digimata/parrot). It adds
the three functions that parrot does not have: a default that operates in many
languages, reliable text insertion, and post-processing.

**Requirements:** macOS 26 or a later version, on an Apple Silicon computer.

## Install the application

1. Download the DMG file from the
   [releases page](https://github.com/mikeowski/yaz/releases/latest).
2. Open the DMG file.
3. Move `yaz.app` into the Applications folder.

yaz operates from the menu bar. It has no dock icon and no window.

The maintainer signs each release with a Developer ID certificate. Apple then
notarises it. Therefore the application opens correctly. Gatekeeper does not
show a warning, and you do not have to use right-click → Open.

To examine the file before you open it, obey these steps:

```sh
shasum -a 256 -c SHA256SUMS.txt
spctl --assess --type execute --verbose /Applications/yaz.app
# accepted · source=Notarized Developer ID
```

The application bundle also prevents a permission problem. macOS gives an
Accessibility permission to the *responsible process*. For a CLI in a terminal,
the responsible process is the terminal. Thus the prompt shows the name of the
terminal, and shells that already operate do not get the permission. An
application bundle has its own identity. The prompt then shows the name `yaz`,
and the permission stays correct.

### Build the application

```sh
./scripts/bundle.sh --dmg     # makes dist/yaz-0.1.0.dmg
```

A build that you make yourself has a local certificate, not a Developer ID
certificate. Gatekeeper thus reports an unidentified developer. This is
correct, and it does not change the operation of the application.

### Install the CLI

```sh
./scripts/install.sh              # build and install into /usr/local/bin
./scripts/install.sh --login      # also start at login
./scripts/install.sh --uninstall

yaz doctor --request              # ask for the permissions
yaz models download               # download the model (approximately 1.6 GB)
yaz                               # start the daemon
```

The script is not a `curl | sh` command, because the script asks for sudo. It
also installs a daemon that asks for TCC permissions. Read the script first.

## Which languages does yaz support?

There are two different answers. The difference is important.

**Transcription operates in many languages.** The engine is Whisper. Set
`language` to a code that Whisper supports. This is a measurement in English.
No Turkish function changed the text:

```
$ yaz transcribe --language en sample.wav
  latency 520 ms · RTF 0.107
  Today I reviewed the pull request and merged it into main after the CI pipeline turned green.
```

**Term repair operates only in Turkish.** This is a safety limit, not a
temporary condition.

The guard that prevents an incorrect replacement is a list of usual Turkish
words. In a different language, the guard protects nothing. These are
measurements in English, from before the limit was in the code:

```
"into main"       → "Notion"
"merged"          → "merge"
"the CI pipeline" → "CI pipeline"
```

Therefore yaz does not apply term repair to a different language. It reports
this in the log. Support for a different language needs a list of its usual
words and its phonetic rules. A flag is not sufficient.

## Term repair

Whisper transcribes usual Turkish text correctly. But Whisper makes errors in
the English technical terms in Turkish speech. A developer dictates many such
terms:

```
$ yaz transcribe --vocabulary fixtures/t2.wav
  vocabulary: Sılacık → Slack (0.749, skeleton)
  vocabulary: Puhrıkı Esti'de → pull request'de (0.832, skeleton)
  vocabulary: C.I.P. eline → CI pipeline (0.799, skeleton)
  Yarın saat 14'te toplantı var. Ahmet'e Slack üzerinden mesaj atmayı unutma.
  pull request'de merge etmem lazım. CI pipeline yeşile döndüğünde deploy ederiz.
```

Turkish suffixes stay correct: `Puhrıkı Esti'de` becomes `pull request'de`. A
test corpus of 30 usual Turkish sentences stays fully unchanged. This corpus
set each threshold in the matcher.

Two usual methods failed here. The `promptTokens` function of Whisper gives
empty output on `large-v3-turbo`. The on-device model of Apple did not repair
`Sılacık`, although it received the list of terms. Thus term repair is
deterministic. It can only make words that you put in the vocabulary.

## Quality gates

yaz writes the transcript directly at your cursor. Therefore incorrect text is
worse than no text.

Before inference, yaz rejects a recording that is shorter than 0.35 s. It also
rejects a recording that is below the silence threshold. Whisper gives no
output for the first condition. Whisper invents sentences for the second
condition.

After inference, yaz uses the confidence signals of the decoder. These signals
find invented text:

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

There are two levels. The deterministic level is the default. It has no cost:

```
$ yaz vocab refine --mode fillers "ıı yarın ee saat ikide mmm toplantımız var"
after : yarın saat ikide toplantımız var        (1 ms)
```

The language model is Apple FoundationModels. macOS 26 includes it. This model
also removes filler words that need context, and it corrects the punctuation.
It needs 0.3 s to 1.4 s for each utterance. Therefore you must select it:

```
$ yaz vocab refine --mode llm "ıı yarın şey saat ikide yani toplantımız var hani o proje için ee hazırlık lazım"
after : Yarın saat ikide toplantımız var. O proje için hazırlık lazım.
```

yaz examines the output of the model. yaz rejects output that summarises the
text, adds new text, answers a question, or removes content. yaz then keeps the
deterministic result. Post-processing must not cause a loss of your dictation.

**Note:** post-processing operates only in Turkish. The list of filler sounds
is Turkish, and the instructions to the model are Turkish. For a different
language, yaz does not call the model.

## History

yaz records what you dictated, the application that received the text, the
time, and the duration. The file is
`~/Library/Application Support/yaz/history.jsonl`.

**yaz does not record audio.** It records only text. A collection of audio
records is a risk to your privacy. Text is sufficient for a history.

```sh
yaz history                    # the last 20 entries
yaz history --search slack     # find text or an application name
yaz history --clear
```

The menu bar also shows the history, with a search function and a copy
function. To stop the history, set `"history": false`.

## Permissions

yaz needs two permissions. A third condition is not a permission.

**Accessibility** lets yaz write text at your cursor.

**Input Monitoring** lets yaz read the hotkey. This is a different list in the
same Settings pane. If you give only the Accessibility permission, the keyboard
listener starts correctly but receives no events. The measurement shows this
condition: the permission is correct, the listener exists, there are zero
events, and there is no error.

The third condition is the **fn key**. macOS takes the globe key if a second
keyboard layout exists, or if Dictation is on. macOS then receives the keypress
before an application can read it. There are two solutions.

To keep the fn key, change this setting:

```
System Settings → Keyboard → "Press 🌐 key to" → Do Nothing
```

Or click this item in the menu bar. yaz then changes the hotkey and saves it:

```
⚠︎ fn is claimed by macOS — use right option
```

```sh
yaz doctor          # reports all three conditions
yaz logs --follow   # the application also writes to ~/Library/Logs/yaz.log
```

### The permission is correct, but yaz does not operate

If you replace an application bundle, macOS can keep a permission record that
does not agree with the new binary. macOS then reports that the permission is
correct. The application accepts this report. But macOS does not send the
events, and it gives no error.

No macOS function reports this condition. Therefore silence is the signal. If
the keyboard listener receives no event for 75 seconds, yaz writes a message in
the log and in the menu.

To correct this condition, obey these steps:

1. Run `yaz reset-permissions` to remove the records.
2. Quit yaz.
3. Start yaz again. macOS then asks for the permissions again.

### Give the permission one time, not for each build

macOS connects a permission to the **code signing identity**. An ad-hoc
signature has no identity. Thus each new build removes the permission that you
gave. `scripts/bundle.sh` uses the best available identity:

| Identity | Gatekeeper | The permission stays after a build |
|---|---|---|
| Developer ID Application | opens correctly, if notarised | yes |
| Local self-signed certificate | unidentified developer | yes |
| Ad-hoc | unidentified developer | **no** |

A contributor needs the second identity. Make it one time:

```sh
./scripts/signing-identity.sh    # asks for your login password
```

### Signed and notarised releases

The maintainer signs the builds on the
[releases page](https://github.com/mikeowski/yaz/releases) with a Developer ID
Application certificate and the Hardened Runtime. Apple notarises them, and the
maintainer staples the ticket. yaz asks for one entitlement only: access to the
microphone.

Only the maintainer can make a release. A release needs a private signing key
and notarisation credentials. These are in a Keychain, and they are not in this
repository. A build from a different person has a different signing identity.
This command finds that condition:

```sh
codesign -dvv /Applications/yaz.app 2>&1 | grep Authority
# Authority=Developer ID Application: BURAK MIKE (XMCHPUCJS2)
```

[SECURITY.md](SECURITY.md) gives the full examination steps. It also lists the
entitlements that yaz does not request. [CONTRIBUTING.md](CONTRIBUTING.md#releasing)
gives the release procedure.

## Models

`yaz.app` is 14 MB. The `whisper large-v3-turbo` model is 1.6 GB. yaz does not
include the model, for two reasons. A model in the bundle makes the application
100 times larger. It also keeps all users on one version of the model.

Therefore yaz downloads the model at the first use. The menu bar shows the
progress, for example `downloading — 412 MB of 1.6 GB (26%)`.

```sh
yaz models download          # download and compile the model first
yaz models list              # show the models on the disk
```

WhisperKit puts the model in `~/Documents/huggingface`. If iCloud Documents
sync is on, iCloud uploads the model. `yaz doctor` reports this condition.

Each model has its own licence. Refer to
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Configuration

The configuration file is `~/.config/yaz/config.json`. The file is optional. A
CLI flag has a higher priority than the file. The settings window writes the
same file. Therefore you can also edit the file manually.

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

`on_transcript` runs a shell command. The command receives the transcript as
its only argument.

## CLI

```sh
yaz                                    # the daemon (the default command)
  --hotkey fn|right-option|right-command|right-control|right-shift
  --inject-mode paste|type
  --language tr
  --verbose

yaz doctor [--request]                 # permissions, model, settings
yaz logs [--follow]                    # ~/Library/Logs/yaz.log
yaz reset-permissions                  # remove the old permission records
yaz history [--search <text>] [--json] [--clear]
yaz settings [--history]               # the settings window or the history window
yaz preview                            # show the indicator, without a microphone
yaz models list
yaz models download [--force]
yaz install --launch-at-login | --uninstall | --status

yaz vocab test "<text>"                # test term repair and show the scores
yaz vocab refine --mode llm "<text>"   # test post-processing
yaz vocab explain "<term>" "<heard>"   # compare the phonetic keys

yaz transcribe <file...>               # audio to text, with the latency
  --engine-name whisper|parakeet
  --whisper-model large-v3-turbo|large-v3
  --language tr
  --vocabulary --refine off|fillers|llm
  --strict                             # apply the quality gates
  --repeat-count 3 --max-seconds 3600
```

## Measurements on an M4 Pro (24 GB, macOS 26.5)

These measurements are repeatable. Use the audio files in `fixtures/`.

| | whisper large-v3-turbo |
|---|---|
| First model load (Core ML compile) | 115 s to 210 s, one time |
| Each subsequent start | 6.5 s to 7 s |
| 5.6 s of speech to text | **506 ms** (RTF 0.091) |
| 12.1 s of speech to text | **855 ms** (RTF 0.071) |
| Resident memory | 210 MB to 260 MB |

## Development

```sh
swift build
swift test              # 262 tests, approximately 1 s, no microphone
./scripts/bundle.sh     # makes dist/yaz.app
```

Refer to [CONTRIBUTING.md](CONTRIBUTING.md) for the parts that break easily.
Refer to [docs/architecture.md](docs/architecture.md) for the reasons for each
decision, and for the failures that caused them.

## Stack

- **Swift 6.2** — one SPM executable target
- **WhisperKit** — Whisper on Core ML and the ANE (the default engine)
- **FluidAudio** — Parakeet TDT on Core ML and the ANE (optional, no Turkish)
- **FoundationModels** — the on-device model of macOS 26 (no download)
- **AVAudioEngine**, **CGEventTap**, **AppKit**, **SwiftUI**

## Licence

MIT. Refer to [LICENSE](LICENSE). The dependencies and the model files have
their own conditions. Refer to
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
