# yaz — architecture

## Why it exists

parrot (digimata) built an excellent dictation skeleton for macOS, and refuses
three things by design. For a Turkish-speaking developer those three are
exactly what is needed:

1. **A multilingual default** — parrot ships `whisper-base.en`; Turkish does
   not work at all.
2. **Reliable text insertion** — parrot types 20-character `CGEvent` chunks,
   and Electron apps (Slack, Notion, Cursor) drop characters.
3. **No post-processing** — "No custom vocabulary, prompts, or
   post-processing." The output arrives raw: filler words, mangled technical
   terms.

yaz aims at those three. The skeleton comes from parrot; the goals do not.

## Measured facts (M4 Pro, 24 GB, macOS 26.5)

These numbers are not claims — they were measured on this machine, and are
reproducible through `yaz transcribe` against the fixed Turkish audio under
`fixtures/`.

| | whisper large-v3-turbo |
|---|---|
| First model load (Core ML compile) | ~115–210 s, once |
| Every later launch | ~6.5–7 s |
| 5.6 s of speech → text | **506 ms** (RTF 0.091) |
| 12.1 s of speech → text | **855 ms** (RTF 0.071) |
| Resident memory | ~210–260 MB |
| A 0.6 s utterance | comes back empty |

## Choosing an engine — and why not Parakeet

The first plan was to move to Parakeet TDT v3: 600 MB against Whisper's 1.6 GB,
far faster on the ANE, "25 European languages". **That plan was wrong.**

Parakeet TDT v3's language list is 25 EU languages plus Russian and Ukrainian:
bg, hr, cs, da, nl, en, et, fi, fr, de, el, hu, it, lv, lt, mt, pl, pt, ro, sk,
sl, es, sv, ru, uk. **Turkish is not among them.** Verified against two
independent sources: NVIDIA's model card, and FluidAudio's own `Language` enum
(no `tr` case; across the whole library `"tr"` appears only in a TTS constant
list).

So **Whisper is the only on-device option for Turkish.** The price is 1.6 GB of
weights and 500–900 ms per utterance. Parakeet stays available behind
`--engine-name parakeet`; it is still much faster for English dictation.

## Custom vocabulary — why it could not be solved at the ASR level

The real accuracy problem is not plain Turkish, it is English technical terms:

```
in  : "Ahmet'e Slack üzerinden yaz, pull request'i merge et, CI pipeline yeşile dönsün"
out : "Ahmet'e Sılacık üzerinden yaz, Puhrıkı Esti'de merge et, C.I.P. eline yeşile dönsün"
```

Two routes were tried and **eliminated**:

1. **Whisper initial-prompt biasing** (`DecodingOptions.promptTokens`) — the
   standard way to teach an ASR your jargon. In WhisperKit with
   `large-v3-turbo` it returns **empty output every time** (0 segments, zero
   statistics). `prefixTokens` echoes the prompt back verbatim — that is a
   different feature.
2. **Handing an LLM the vocabulary and asking it to repair** — Apple
   FoundationModels was given the list of target terms and still could not fix
   "Sılacık", after spending 1.40 s. A ~3B on-device model cannot do this
   kind of fuzzy phonetic matching in Turkish.

So the custom vocabulary is a **deterministic post-processing layer**: phonetic
normalisation plus edit-distance matching against the user's own list. It works
from what the user supplied, not from what a model guessed.

## Post-processing — where the LLM genuinely is good

The same FoundationModels is very good at filler removal (**0.46 s**):

```
in  : "ıı yarın şey saat ikide yani toplantımız var hani o proje için ee hazırlık yapmamız lazım"
out : "Yarın saat ikide toplantımız var. O proje için hazırlık yapmamız lazım."
```

So the split between the layers is clean:

| Problem | Solved by |
|---|---|
| A mangled proper noun or technical term | deterministic vocabulary matching |
| Filler words, stuttering, punctuation | FoundationModels (on-device, no download) |

FoundationModels ships with macOS 26 — zero download, zero dependency. That is
why the package declares `platforms: [.macOS(.v26)]`.

## Layers

```
hotkey (CGEventTap)
   ↓ .pressed / .released
AudioCapture (AVAudioEngine → 16 kHz mono Float32)
   ↓ [Float]
Transcriber  ← protocol; the engine plugs in here
   ├── WhisperTranscriber   (default, Turkish)
   └── ParakeetTranscriber  (optional, fast, English)
   ↓ TranscriptionOutput
Vocabulary   (deterministic term repair)
   ↓
Refiner      (FoundationModels: filler removal, punctuation)
   ↓ String
TextInjector (clipboard paste; CGEvent typing as fallback)
```

The `Transcriber` protocol is deliberately small: `prepare / transcribe /
release`. `transcribe` takes `[Float]`, not a file URL — dictation utterances
are seconds long and already in memory, and writing them to disk just to read
them back adds latency to the one path where latency *is* the product.

`release()` is in the protocol because yaz is a daemon that stays open all day
and must not keep hundreds of megabytes of Core ML weights resident while idle.


## The hardening layer

The engine layer moved from "it works" to "it is trustworthy". Dictation writes
its output straight to the user's cursor: wrong text costs more than an error
message. Hence three lines of defence.

### 1. Before inference — `SpeechGate`

Two measured facts: a 0.6 s utterance comes back **empty** from Whisper, and
given silence the model does not stay quiet — it produces `[BLANK_AUDIO]`,
`(müzik)`, or an outright invented sentence.

Dropping a short or silent buffer here takes microseconds; dropping it after
inference takes ~500 ms. The gates: at least 0.35 s of duration, at least
0.005 peak amplitude.

These rejections are marked `isBenignInput` — brushing the hotkey by accident
is not an error, and the daemon should discard them quietly.

### 2. After inference — `TranscriptionQuality`

Whisper never says "I don't know"; it always returns text. But the decoder
gives three signals per segment, and parrot drops them on the floor:

| Signal | What it catches |
|---|---|
| `noSpeechProb` > 0.6 | that was not speech |
| `compressionRatio` > 2.4 | a repeat loop ("teşekkürler teşekkürler…") |
| `avgLogprob` < -1.0 | invented text |
| `avgLogprob` < -0.7 | low confidence (usable, but flagged) |

There is also direct word-repetition detection: on a short utterance a loop can
form without the compression ratio ever crossing its threshold.

The thresholds come from OpenAI's reference decoder. Segment signals are
averaged weighted by duration, so a one-word segment cannot drag the verdict.
The compression ratio is the exception — there the **worst** segment is taken:
a single segment that falls into a loop condemns the whole utterance and must
not dissolve into an average.

### 3. At the boundaries — typed errors and a timeout

`YazError` names every failure. The reason is concrete: in the first prototype
an `AVAudioFile` call blew up, Foundation turned it into a bare
`_GenericObjCError.nilError`, and the CLI printed `Error: nilError`. That tells
nobody anything.

`withTranscriptionTimeout` stops a wedged Core ML call from locking up the
daemon. It is an honest boundary: the caller is released, the ANE does not stop
immediately.

### Language validation — an error beats a silent wrong answer

Parakeet does not reject Turkish audio; it produces confident nonsense:

```
$ yaz transcribe --engine-name parakeet --language en fixtures/t1.wav
Bugun Parot Krojesini in Jeledimweon device transcription mimari sinichosdum.
```

So `supportedLanguages` is part of the engine protocol, and an unsupported pair
is refused before the model is even downloaded:

```
$ yaz transcribe --engine-name parakeet --language tr fixtures/t1.wav
Error: the parakeet engine does not support 'tr' (supported: bg, hr, cs, da, nl, en, et, fi…)
```

### Audio loading — windowed and bounded

An hour of 48 kHz stereo is ~690 MB in a single Float32 buffer. `AudioLoader`
reads and converts the source in 32768-frame windows, holding one window in
memory at a time. `maxSeconds` puts a ceiling on it.

**A bug found here:** `AVAudioFile.read(into:)` does not return 0 frames at end
of file, it **throws** — and Foundation turns that into `nilError` again. The
loop has to be driven by `framePosition < length`, not `frameLength == 0`. The
test suite caught this the day it was written.

File existence is also checked up front: AVAudioFile reports a missing file as
`Code=2003334207`, which buries the one thing the user needs to know.

### Test suite

37 tests, 5 suites (`swift test`). Coverage: gate thresholds, quality verdicts,
the sanitising regexes, audio loading, and whether the error messages are
readable.

Adversarial fixtures live under `fixtures/`: complete silence, a 100 ms
utterance, sub-threshold noise. The proof of hardening is that these are
eliminated end to end:

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

`sanitize` was tightened too. parrot deletes the contents of every `(...)`,
which also takes away real dictated parentheticals. yaz removes only known
annotation words (`sessizlik`, `müzik`, `applause`…) and only spans no longer
than 40 characters; "toplantı (yarın değil, öbür gün) yapılacak" survives
intact.


## Hardening — round two

The first round defended the input and the output. The second round defends the
code against itself: three real bugs, all three found by reading it.

### Actor reentrancy — loading the model twice

```swift
func prepare() async throws {
    guard box.kit == nil else { return }        // ← the first call passes here
    box.kit = try await WhisperKit(...)         // ← and suspends here
}                                               //   the second call passes the guard!
```

Actors serialise **statements**, not **operations** that cross a suspension
point. During the `await`, a second caller walked in and loaded the same 1.6 GB
model again.

`SingleFlight` collapses that into one flight; waiters see the winner's result.
A failed load is **not cached** — the cause is usually a transient download
failure, and the next call should retry.

### Absent signals ≠ perfect signals

Every field of `Signals` defaults to zero. But `avgLogProb: 0` = log(1.0) = the
**highest confidence possible**, and `noSpeechProb: 0` = definitely speech. So a
zeroed `Signals` was reporting "no data" as "a flawless decode".

Parakeet gives no per-segment confidence and was passing exactly that — with
the result that **every Parakeet transcript sailed through the quality gates.**

Now the type says so: `signals: Signals?`. When `nil` is passed, only the
text-based checks apply (empty output, repeat loop) — the failure modes that
reach the cursor regardless of engine. The CLI states the situation rather than
printing zeros:

```
  (the engine reports no confidence signals — the verdict is text-only)
```

### Two real data races

`PipelineBox` was `@unchecked Sendable` with no synchronisation. `box.kit` was
written on the actor by `prepare()`/`release()` and read from the timeout
wrapper's **task-group child task**. It is `NSLock`-protected now, and
`current()` returns a strong reference: a concurrent `release()` cannot pull the
pipeline out from under an in-flight transcription.

The second is subtler: the actor does not serialise `transcribe()`. Once the
method suspends at an `await`, a second call could enter and reach the Core ML
pipeline **in parallel**. WhisperKit makes no reentrancy guarantee — that is
undefined behaviour, not merely slowness. `SerialGate` queues work in arrival
order, and work that throws does not break the chain.

`release()` no longer drops the weights without draining the queue first.

### The measurement gate must not be worth measuring

`SpeechGate.level` was a scalar loop. This gate runs on every utterance, and on
a long file the buffer holds tens of millions of samples (an hour at 16 kHz is
57.6 M). A check whose whole point is being cheaper than inference must not
become the cost itself — it moved to `vDSP_maxmgv` / `vDSP_rmsqv`, and a test
asserts it matches the scalar reference exactly.

### Real microphone formats

Real inputs are not 16 kHz mono: built-in microphones are 48 kHz, USB
interfaces 44.1 kHz, headsets sometimes 8 kHz, and quill's rca-001 found a
**nine-channel** route. Stereo 44.1 kHz, mono 48 kHz and mono 8 kHz variants
were added to the fixtures.

The test verifies not only the duration but that **the signal survived** —
rca-001's trap was exactly a file of the right duration that was digitally
silent. A stereo 44.1 kHz input yields a transcript identical to 16 kHz mono.

### Numbers

57 tests, 10 suites. New coverage: single-flight loading, the serial queue,
absent signals, vDSP accuracy, four input formats, frame loss at a window
boundary.


## M2 + M3 — the dictation loop closes

After two rounds of hardening the engine layer is solid enough to build on.
This round closes the loop: hotkey → microphone → transcription → cursor.

### A configurable hotkey

parrot's README documents `--hotkey right-option`, but no such flag exists and
the monitor is hard-wired to Fn. In yaz, `Hotkey` is a real type: fn, right
option, right command, right control, right shift.

Left and right cannot be told apart by mask — `.maskAlternate` lights up for
both option keys. Hence `Hotkey.keyCode`, verified against the event's keycode.
Fn has no separate keycode, and there the mask is enough.

**A self-healing tap.** macOS disables taps that run long or block. parrot's
answer is a comment: *"we'll need to re-enable. For now just no-op and let the
user restart parrot."* For a daemon that stays open all day that is a silent
death. yaz re-enables the tap on `tapDisabledByTimeout` /
`tapDisabledByUserInput`.

### Clipboard insertion — parrot's real weak point

parrot types with `CGEventKeyboardSetUnicodeString`, and since the API accepts
~20 UTF-16 units per event, a sentence becomes dozens of synthetic key events.
Two consequences, both where a dictation tool is used most: Electron apps
(Slack, Notion, Cursor) drop characters under bursts like that, and the
duration grows with the length of what you said.

yaz writes to the clipboard and sends ⌘V: one event, no length limit, and the
target app sees an ordinary paste. The previous clipboard contents are saved
**with every type** (per `NSPasteboardItem`) and restored 0.25 s later — not
just text, but images and files too. Losing your clipboard to a dictation is
worse than the dictation failing.

The ⌘V events are posted from `privateState` with an explicit `.maskCommand`:
the user may still be holding the push-to-talk key, and that modifier must not
turn the paste into some other shortcut.

Key-by-key typing is still there behind `--inject-mode type`, with one fix:
parrot slices the UTF-16 sequence blindly, which can cut through a composed
character. yaz splits on grapheme cluster boundaries — Turkish text and emoji
are full of them.

### The microphone — voice processing deliberately off

`AudioCapture` installs an `AVAudioEngine` tap, listens in the device's own
format, and converts to 16 kHz mono inside the callback. Asking the tap for a
format the hardware does not produce is the road to an empty file.

Voice processing is **not enabled**. rca-001's cost is on record: setting up the
duplex I/O unit wrongly produces a recording of the right duration that is
digitally silent, with no error anywhere. Its only benefit is echo
cancellation, and push-to-talk dictation has no echo to cancel.

The liveness check stayed anyway, because the underlying failure is not
specific to voice processing: a device can send callbacks full of zeros.
`didSeeSignal` separates "you stayed quiet" from "the microphone is dead".

**A ceiling.** A stuck modifier key grows the buffer until the machine swaps —
16 kHz mono Float32 is 3.7 MB per minute. It cuts off at ten minutes.

### Ordering — cheap failures first

The first version of `run` loaded the 1.6 GB model and only then installed the
hotkey. Without Accessibility permission the user waited 7 seconds to be told
about a permission error. The tap is installed first now: it fails in
**0.54 s**.

Because the tap exists before loading finishes, a `ready` flag was added; a
press that arrives before the model is up is not swallowed silently, the state
is reported.

### The config file

parrot's architecture document describes `~/.config/parrot/config.toml`; there
is **no** `Config` type in the source and the file is never read. A daemon
started by a LaunchAgent can only be reconfigured by editing the plist.

yaz reads `~/.config/yaz/config.json`. An unrecognised *value* is written to
stderr — falling back to a default silently leaves the user asking "why did my
hotkey not change?"

### doctor

Permissions, model integrity, insertion mode and the Fn key setting in one
place. Every failed check says what to do about it. The Accessibility line
**names the parent process** — macOS attributes the grant to whatever launched
the binary, not the binary, and that is the difference between an actionable
message and a riddle.

The model check now looks at integrity: the presence of a folder was counting a
half download as complete, and the failure surfaced minutes later as a Core ML
load error. `ModelStore` verifies each component and its size.


## M4 — the vocabulary layer

The accuracy problem this project exists for. The measurement was the same from
the start:

```
in  : "Ahmet'e Slack üzerinden yaz, pull request'i merge et, CI pipeline yeşile dönsün"
out : "Ahmet'e Sılacık üzerinden yaz, Puhrıkı Esti'de merge et, C.I.P. eline yeşile dönsün"
```

Plain Turkish is fine; what collapses is the English technical terms — which is
half of every sentence a developer dictates.

### Why not at the ASR level

Two standard routes were tried and neither works on this stack:

1. **Whisper initial-prompt biasing** (`DecodingOptions.promptTokens`) —
   **empty output** on every variant tried with `large-v3-turbo`.
2. **Handing the vocabulary to an LLM** — Apple FoundationModels was given the
   list of target terms and `Sılacık` still came back unrepaired, after 1.40 s.

So repair is rule-based, and that has a side benefit: the engine can only ever
produce words the user put in their own list. It cannot invent.

### The consonant skeleton

Turkish phonotactics dislike consonant clusters, and both the speaker and the
acoustic model insert a vowel to break them: `sl` → `sıl`. So **vowels are the
least trustworthy part of the signal and consonants the most.**

```
Slack        → slk    ·  Sılacık      → slkk
pull request → plrkst ·  Puhrıkı Esti → phrkst
CI pipeline  → sppln  ·  C.I.P. eline → spln
```

Normalisation covers Turkish I/İ folding, diacritic folding, and mapping
English graphemes (`ck`, `ph`, `qu`, `x`) onto their Turkish equivalents.

**The English C rule** is a separate win: English `c` is /k/ before a back vowel
or a consonant and /s/ before a front vowel. `Cursor` → `kursor` → skeleton
`krsr`; what was heard, `Körsır` → `krsr`. **An exact match (1.000).** Without
this rule the c/k difference made the two words look unrelated.

Order matters: diacritic folding runs **after** the C rule. Had it run first,
Turkish `ç` (a sound in its own right) would collapse to `c`, then be converted
to `k`, and the word "saç" would start to resemble "Slack" — which is exactly
what happened, and was fixed.

### Why a ratio threshold is not enough

The measurement settled this beyond argument. Compared as skeletons:

```
Slack  (slk)  vs  Sılacık (slkk)  → 0.75   ← must be replaced
Docker (dkr)  vs  Doktor  (dktr)  → 0.75   ← must NEVER be replaced
Sentry (sntr) vs  sonra   (snr)   → 0.75   ← must NEVER be replaced
```

**The same score, the opposite expectation.** No threshold can separate them.
What separates them is this: `doktor` and `sonra` are ordinary Turkish words the
speaker plainly said, while `Sılacık` is not a word in any language — it exists
only because the acoustic model broke an English consonant cluster with a vowel.

Three defences work together:

1. **A common-Turkish-word veto** (`TurkishLexicon`) — if the window contains an
   ordinary Turkish word, it can only be replaced on 0.90+ full-form evidence,
   never on a skeleton guess. ~450 words, with suffix stripping so inflected
   forms are caught too.
2. **A first-consonant constraint** — epenthesis inserts a vowel but does not
   change what a word starts with. `Redis (rds)` / `neredeyse (nrds)` scored
   0.75; it is rejected because `r ≠ n`.
3. **A span expansion limit** — a short single-word term cannot match a
   two-word window. Without this rule "ama kargo" became "merge", swallowing
   the "et" in "merge et".

### Preserving Turkish suffixes

Turkish attaches suffixes to proper nouns with an apostrophe. Repairing
`Sılacık'ten` and dropping the `'ten` breaks the sentence. `Tokenizer` splits
each word into leading punctuation / stem / apostrophe suffix / trailing
punctuation, and only the stem is replaced. The typographic apostrophe (`’`) is
recognised too — Whisper emits it.

On a multi-word term the suffix stays on the last word: `Puhrıkı Esti'de` →
`pull request'de`.

### The measured result

End to end on a real audio file:

```
$ yaz transcribe --vocabulary fixtures/t2.wav
  vocabulary: Sılacık → Slack (0.749, skeleton)
  vocabulary: Puhrıkı Esti'de → pull request'de (0.832, skeleton)
  vocabulary: C.I.P. eline → CI pipeline (0.799, skeleton)
  Yarın saat 14'te toplantı var. Ahmet'e Slack üzerinden mesaj atmayı unutma.
  pull request'de merge etmem lazım. CI pipeline yeşile döndüğünde deploy ederiz.
```

All three manglings repaired, the Turkish suffix preserved, the Turkish text
untouched.

### The false-match test

The real risk is replacing a word the user actually said: a mangled term stays
visible, a wrong replacement does not. There is a 30-sentence corpus of ordinary
Turkish (everyday sentences containing no technical terms), tested against two
vocabularies — one of real developer terms, one deliberately full of terms that
resemble Turkish (`Docker`, `Redis`, `Vercel`, `Sentry`, `Linear`, `Figma`).
Zero false matches.

That corpus is what set the thresholds: a 0.74 skeleton threshold produced five
false matches on the first attempt, and at a full-form threshold of 0.72 "Saç"
became "Slack".

### Tuning tools

Thresholds are set against real mangled output rather than guesswork, so these
live in the CLI:

```
yaz vocab test "Sılacık'ten yazdım"      # repair it and show the scores
yaz vocab explain "Cursor" "Körsır"      # compare the phonetic keys
```

### A known limit

The veto is only as strong as the lexicon's coverage. `TurkishLexicon` is a list
of common words, not a dictionary; a rare Turkish word that is not in the list
can still be replaced wrongly if it collides phonetically with a term. The
user-side remedy is raising the per-term threshold with `min_similarity`.


## M5 — the post-processing layer

Dictation arrives raw: stutters, hesitation sounds, no punctuation. parrot
refuses this by design ("No AI post-processing"). yaz does it in two tiers,
because part of the job is risk-free and part is not.

### Tier 1 — deterministic, ~1 ms

`FillerFilter` removes only sounds that are **not words in any language**: `ııı`,
`eee`, `mmm`, `hmm`. The scope is deliberately narrow. In Turkish `yani`, `şey`,
`hani`, `işte`, `falan` are real words depending on context, and a blind "filler
word list" that deletes them changes what the user said.

Single-letter vowels are a separate trap: `o` is a pronoun, `a` a particle.
Those are removed only when they sit next to another hesitation (`ı ı yarın`).

This tier is the default. It is free, model-free, and cannot change meaning.

### Tier 2 — the language model, optional

Apple FoundationModels handles context-dependent fillers, punctuation and
sentence boundaries. It ships with macOS 26 — no download, no second runtime;
the same argument that makes on-device transcription worth the trouble.

```
in  : ıı yarın şey saat ikide yani toplantımız var hani o proje için ee hazırlık yapmamız lazım
out : Yarın saat ikide toplantımız var. O proje için hazırlık yapmamız lazım.
```

**Measured cost:** 0.3–1.4 s on an M4 Pro depending on length, on top of the
0.5–0.9 s the engine already spends. Hence opt-in.

### Guards — model output has to earn its way in

Telling a language model to "tidy this" means it may also summarise it,
translate it, answer a question in it, or refuse. If any of those reach the
user's cursor it is worse than the stutter we were trying to remove.

`RefinementGuard` rejects:

| Check | What it catches |
|---|---|
| Length ratio < 0.55 | summarising |
| Length ratio > 1.25 | the model added material / answered the question |
| Content-word retention < 0.75 | a clause was dropped, the voice changed |
| Empty output | the model refused |

The wrappers chat models like are also stripped: a `"Here is the corrected
text:"` preamble and surrounding quotes.

**Every failure is soft.** On an error, a timeout or a rejection it falls back
to the deterministic result. A cleanup step can never cost you the dictation.

### The guard's own bug

The first version threw away a good cleanup. The model had correctly dropped
`yani` and `hani`; the retention check counted those as 4+ letter "content
words" and reported 30% loss.

So the guard was punishing the behaviour we **wanted** from the model.
Contextual fillers were excluded from the retention calculation. Real content
loss is still caught — both are tested.

### Ordering: vocabulary first, post-processing second

`TranscriptPipeline` fixes the order as a decision.

The vocabulary runs **first** so the model sees correctly spelled terms: a
language model handed `Sılacık` may well replace it with something else
plausible, and from that point the deterministic layer can no longer recognise
it. Handed `Slack`, it finds nothing to fix.

The reverse risk is closed too: after post-processing, every term the vocabulary
repaired is verified to still be present. If one is gone, the refinement is
discarded. The deterministic layer wins in both directions.

The full chain, measured:

```
$ yaz transcribe --vocabulary --refine llm fixtures/t2.wav
  latency 907 ms · RTF 0.075
  vocabulary: Sılacık → Slack (0.749, skeleton)
  vocabulary: Puhrıkı Esti'de → pull request'de (0.832, skeleton)
  vocabulary: C.I.P. eline → CI pipeline (0.799, skeleton)
  post-processing 1310 ms
  Yarın saat 14'te toplantı var. Ahmet'e Slack üzerinden mesaj atmayı unutma.
  Pull request'de merge etmem lazım. CI pipeline yeşile döndüğünde deploy ederiz.
```

The model capitalised `pull` at the start of a sentence — a legitimate fix, and
the term verification did not count it as loss because it compares normalised.

### Tuning tool

```
yaz vocab refine --mode llm "ıı yarın şey toplantı var"
```


## M6 — the recording indicator and the menu bar

Push-to-talk has one honest failure mode: you hold the key, you speak, and
nobody was listening. Without feedback you only find out when no text arrives.
The indicator is the entire answer to that.

### A testable core, kept separate

`LevelMeter` and `IndicatorState` contain no AppKit at all. The interesting part
— how a raw peak becomes a bar height — is arithmetic that can be exercised
without starting a window server.

Speech peaks land roughly in 0.05–0.7 on a built-in microphone. Drawn linearly
that is a dead flat line, so levels are compressed with `sqrt` and scaled by a
gain of 3.4: a shout does not pin the meter to the ceiling and flatten it, and a
quiet sentence stays visible.

A non-finite value rests at the **floor**, not the ceiling. `NaN` or `infinity`
arriving here means the reading is broken, not that the room is loud — a meter
slammed against the ceiling would be a more confident lie than a flat one.

`showsWaveform` is true only in `.recording`. A waveform still animating after
recording ends is lying: the audio has already been captured by then.

### The pill — a click-through panel

A borderless, `nonactivatingPanel` `NSPanel`. Three settings carry it:

- `ignoresMouseEvents` — clicks pass through to the app underneath.
- `orderFrontRegardless`, not `makeKeyAndOrderFront` — the panel must **never**
  take key state from the field being dictated into. If it did, the product
  itself would break, because the text is pasted wherever the cursor is.
- `canJoinAllSpaces` + `fullScreenAuxiliary` — visible over a full-screen app.

It is positioned at the bottom centre of whichever screen holds the pointer: on
a multi-monitor desk the pill follows the user rather than staying on the
laptop.

### The menu bar

yaz is an `.accessory` process with no dock icon and no window. Run from a
terminal the log is enough; **for a LaunchAgent that starts at login it is
not** — the user needs a way to see the daemon is there and to quit it.

SF Symbols are used, with a drawn fallback: an image that fails to load leaves a
zero-width status item, which looks exactly like "the daemon did not start".

### The UI code was not just compiled, it was run

The overlay and the menu bar are the one piece the tests cannot reach: they need
a run loop, a screen, and Accessibility permission via the daemon. `yaz preview`
drives them directly — no microphone, no hotkey — walking through the states and
feeding the waveform realistic values.

```
$ yaz preview
indicator preview — look at the bottom of the screen and at the menu bar
  listening
  transcribing
  refining
preview done
```

That moves the AppKit/SwiftUI path from "it compiles" to "it runs".

### Config

`overlay` and `menu_bar` can be switched off independently. For a foreground
terminal run both may be redundant; the log already says everything.


## M7 — installation and starting at login

### The embedded Info.plist — parrot's omission

yaz is a single binary with no `.app` bundle. The only way for TCC to attribute
the microphone prompt to **yaz** and to show an explanation written for the user
is to embed the plist into the binary's `__TEXT,__info_plist` section with the
linker.

quill does this; parrot does not — and parrot's own document leaves code signing
as an "open question". Under launchd that difference decides whose permission
prompt it is.

Verified:

```
$ launchctl plist __TEXT,__info_plist .build/release/yaz
{
    "CFBundleIdentifier" = "com.mikeowski.yaz";
    "NSMicrophoneUsageDescription" = "yaz listens to the microphone while you hold…";
    "LSBackgroundOnly" = true;
};
```

`CFBundleIdentifier` and the LaunchAgent label are deliberately identical: the
launchd job and the TCC identity must point at the same thing. A test asserts
it.

### The launchd job definition

Not `SMAppService` — that wants a real `.app` bundle, and yaz is a single binary
under `/usr/local/bin`. A plain launchd plist is the honest equivalent.

Plist generation is kept separate from the filesystem and the `launchctl` calls,
because **a daemon that fails to start at login gives the user nothing to
debug.** Two decisions are tested:

- `KeepAlive` restarts only on a **failed** exit. "Quit" from the menu bar is a
  clean exit and must stay quit; an unconditional `KeepAlive` would make that
  menu item a lie.
- `EnvironmentVariables.PATH` is set. launchd hands login agents a bare
  environment, and without PATH the `on_transcript` hook cannot find any
  command.

### A stale record — the source of a silent failure

The worst case: the plist is still there but the binary has moved. launchd keeps
retrying and the user sees nothing. `LaunchAgent.status()` reports this as its
own state and `doctor` fails hard on it.

Actually tried: the binary was temporarily hidden, and `doctor` correctly said
`✗ registered binary is missing`.

### Two real bugs that only appeared under launchd

These two were not found by reading code, but by actually installing the
LaunchAgent and reading the log.

**1. Split output.** A LaunchAgent's stdout and stderr go to *different files*.
With the startup failure writing "checks failed" to stderr and listing the
reasons on stdout, the user was left with a heading and nothing under it in
`/tmp/yaz.err.log`. `DoctorReport.render` now takes the target stream as a
parameter.

**2. "Enable launchd".** The Accessibility message names the parent process —
correct behaviour from a shell, because macOS attributes the grant to the
terminal. Under launchd the parent is `launchd`, and telling the user to "enable
launchd" is worse than useless, it is wrong: there the grant belongs to yaz,
which has its own identity thanks to the embedded Info.plist. `accessibilityOwner`
was factored out and tested.

### The install script

Deliberately **not** `curl | sh`: this script asks for sudo and installs a daemon
that requests TCC permissions. It should not run unread.

The preconditions are hard: macOS, arm64, macOS 26+. Whisper and Parakeet run on
the ANE; on Intel the model may load but the latency is not usable.

sudo is requested only when genuinely needed. The first version asked for a
password even when installing to a target like `~/bin`, because it treated a
directory that did not exist yet as "not writable" — when a directory is absent
the decision belongs to its parent's writability. The uninstall path had the
same bug, and both were wired to a shared `writable` helper.

An ad-hoc signature is applied (`codesign -s -`). It is not a distribution
signature; it merely slows down the rate at which an unsigned binary loses its
TCC identity on every build. The real fix is signing with a Developer ID — an
open item for this project at the time.

### Verification

Install and uninstall were actually run, with zero net effect on the machine:

- `yaz install --launch-at-login` → the plist was written, `launchctl print`
  showed the job as `state = running`
- the daemon correctly reported an Accessibility failure under launchd
- the binary was hidden → `doctor` caught the stale record
- `yaz install --uninstall` → the plist was removed, launchd no longer knows it
- `scripts/install.sh` built, installed, signed and ran `doctor` against an
  isolated `PREFIX`; `--uninstall` removed it cleanly


## M8–M11 — the app bundle, history, settings UI, DMG

### The real cause of the permission problem

When the user ran `yaz doctor`, the permission dialog said **"cmux.app"**, and
granting it did not help. The reason was measured, not guessed:

```
cmux.app → login → fish → claude → zsh → yaz
```

macOS attributes the Accessibility grant to the **responsible process**, which
for a CLI run in a terminal is the topmost app. The dialog naming cmux.app was
correct. The grant did not work either, because shells that were already running
carried the old denial.

This is not fixable from inside the CLI. **The fix is a `.app` bundle:** yaz
gets its own TCC identity, the dialog says "yaz", and the grant is independent
of which terminal happens to be open. So the problem the user hit and the
feature they asked for were the same thing.

### The bundle

`Resources/AppInfo.plist` + `scripts/bundle.sh` → `dist/yaz.app`. `LSUIElement`
means no dock icon, only the menu bar. The bundle identifier matches the
binary's embedded `__TEXT,__info_plist` section (`com.mikeowski.yaz`), so the
CLI and the app point at a single identity.

`scripts/bundle.sh --dmg` produces a DMG with drag-and-drop installation (4.8
MB; the models download on first run).

### The permission flow as a bundle

For a double-clicked app a missing permission **must not be fatal** — exiting
quietly looks like a broken app. Running as a bundle:

1. The menu bar item appears immediately.
2. The `AXIsProcessTrustedWithOptions` prompt appears *as yaz*.
3. A timer polling once a second waits for the grant — the moment the user
   ticks the box it starts listening, with **no need to restart the app.**

The explanatory alert was deferred until after `app.run()`. Run modally at
startup it also blocked the model load: the app sat behind its own dialog doing
nothing. That surfaced by running the bundle and watching it.

### History — text, not audio

`~/Library/Application Support/yaz/history.jsonl`. Per dictation: the time, the
text, **which app** it was written into, the duration, the engine/model, and the
terms the vocabulary repaired.

**No audio is stored.** Keeping recordings would turn yaz into a surveillance
tool by accident: a folder holding everything its owner said, indefinitely. What
is useful later is the text, and it is a far smaller thing to leak. A test
enforces this structurally — it verifies no `audio`, `wav` or `pcm` field
appears in a record.

JSONL, not a database: one dictation per line, readable with `tail`, and a last
line left half-written by a crash costs a single entry rather than the whole
file — which is also tested.

Which app it went into is read **before** the paste. The overlay is a
non-activating panel, so at that moment the window holding the cursor is still
frontmost; that is the only instant when the answer is correct.

`yaz history [--limit] [--search] [--json] [--clear]`.

### The settings UI

SwiftUI, opened from the menu bar: hotkey picker, engine/model, language,
insertion mode, post-processing mode, vocabulary editor, indicator and history
switches.

**The config file remains the source.** The window reads and writes the same
`~/.config/yaz/config.json`. A UI with its own store would have meant two
quietly conflicting ways to configure the app. `Config.save()` produces the key
names `apply()` reads, and round-trip tests verify every field — plain terms are
written as plain strings so the file stays hand-editable.

`yaz settings` and `yaz settings --history` open the windows directly. That is
not just convenience: since clicking through the menu cannot be automated here,
it is the only way to verify the SwiftUI paths **run** rather than merely
compile.


## An unusable app — three bugs

The user ran the `.app` and said "nothing happens when I press it". There were
three separate bugs, and only one of them was findable by reading code.

### 1. The model never loaded (the root cause)

```swift
Task { [weak self] in await self?.loadModel() }   // ← never runs
```

`Daemon` is a `@MainActor` type, so a `Task { }` inside it inherits the main
actor. The main actor is then busy for the life of the process on the next line,
in `NSApplication.run()`. The task queues and **its turn never comes.**

The result: the app says "listening", the menu bar appears, but there is no
engine behind it — `ready` stays `false` forever. Even with permission granted,
pressing the hotkey would have done nothing.

`Task.detached` runs on the cooperative pool and hops back to the main actor to
touch the UI. The proof is two lines that now appear on stderr:

```
listening · hold fn (🌐) · clipboard (⌘V) · ^C to quit
loading model…
✓ large-v3-turbo ready — 7.0 s
```

### 2. The daemon was destroyed while running

```swift
try await Daemon(config: config, verbose: verbose).run()
```

ARC may release a temporary **after its last use**, and `self` is never touched
again inside `app.run()`. The daemon was being destroyed the moment the run loop
began; `deinit` pulled the status item out of the menu bar and `[weak self]`
tasks found nil.

A strong reference is held for the life of the process now. The
`MainActor.assumeIsolated` inside `deinit` was removed too: deinit may not run on
the main actor, and cleaning up there was hiding this bug.

### 3. The run loop did not start until the model finished

`app.run()` was last, so the menu bar did not respond to clicks until the model
had loaded. On a first install the Core ML compile takes minutes — and for all
that time the app looks broken. Loading now happens inside the run loop.

### A false alarm: "there is no menu bar icon"

Searching for the status item with `CGWindowListCopyWindowInfo` and not finding
it led to the belief that the icon was never created. That was wrong — status
items are not listed as a window owned by the app. Direct measurement showed the
truth:

```
[diag] status item installed · button=true · length=-1.0 · visible=true · image=(18.0, 18.0)
```

The icon had been there all along. The verification method was faulty, not the
code.

### Permission is now resolvable from the menu

A menu that says "waiting for permission" and offers no action leaves the user
to press the hotkey and conclude the app is broken. The menu now carries a
clickable item while permission is missing:

```
⚠︎  Grant Accessibility permission…
```

## The menu bar icon

Three candidates were drawn and compared **printed at actual size**; judging an
18 pt mark from source code is guesswork.

- A cursor whose stem is a sine wave — striking at 8×, illegible mush at 18 pt.
- A waveform of rounded bars — legible but entirely generic; every audio app on
  the machine has one, and it says nothing about text coming out the other end.
- **The winner:** two arcs opening to the left, with a heavy I-beam cursor on
  the right. "Sound → text" in a single shape.

The states share that skeleton: the cursor never moves, only what sits to its
left changes. One arc when idle (no arc reads as "broken"), two while recording,
three dots while working. The dots touched the cursor stem on the first attempt;
they were right-aligned against the cursor and given real clearance.

It is drawn with `NSBezierPath` rather than shipped as an asset: crisp at every
scale, the states share one geometry, and since the CLI binary has no resource
bundle an asset catalog would work inside the `.app` and fail silently outside
it.


## Why nothing was happening — four separate causes

A single symptom ("the app is open, permissions are granted, pressing the key
does nothing") was covering four separate bugs. None of them produced an error
message.

### 0. There was no evidence

The stderr of an `.app` launched from Finder goes nowhere. Fixing that came
first: `Log` writes every line to both stderr and `~/Library/Logs/yaz.log`, and
`yaz logs --follow` reads it. Everything below was found by reading that file.

### 1. Input Monitoring

Accessibility permission is not enough to **listen** to the keyboard. A
`CGEventTap` watching keyboard events also needs `kTCCServiceListenEvent` — a
separate list, a separate key. Without it the tap is created, the run loop
source attaches, `tapEnable` returns success, and **not one event is
delivered.**

parrot checks only Accessibility, and hits the same wall.

### 2. macOS claims the fn key

The globe key is bound to switching input source when a second keyboard layout
is defined, and to Dictation when Dictation is on. This machine had both
(Turkish-QWERTY + U.S., `AppleDictationAutoEnable=1`). The system consumes the
key **below** the session tap.

`AppleFnUsageType` being **unset** is not the safe state, it is the dangerous one
— treating "could not read" as a warning was letting exactly this configuration
through. It fails hard now, and the menu bar switches to right option in one
click.

### 3. Stale TCC records

When a bundle is replaced repeatedly, macOS can hold a permission record that no
longer matches the binary. The system reports the permission as granted, the app
believes it, and events are silently never delivered. Measured:
`accessibility=true inputMonitoring=granted`, a live tap, zero events — and
after `tccutil reset` the same app said `accessibility=false
inputMonitoring=notDetermined`.

No API reports this, so **silence is the signal**: if the listener sees no event
for 75 seconds it reports itself, and the menu points at `yaz
reset-permissions`. The first real event cancels the watchdog.

### 4. The MainActor lock — the root cause

`NSApplication.run()` never returns. Called from inside an
`AsyncParsableCommand` it permanently blocks a Swift task that owns the
MainActor — and the cooperative executor runs **no other MainActor work** until
that task finishes.

The measurement that pinned it down: CFRunLoop timers were firing normally,
while the GCD main queue was never drained once. Two different mechanisms, one
working and one not, gave the diagnosis.

The consequences: `engineBecameReady()` never ran, so `ready` stayed `false`
permanently — even with the tap fixed, pressing the key would have done nothing.

The fix: the whole command tree is a synchronous `ParsableCommand`. It hands the
main thread to AppKit with no task owning it. Async subcommands are bridged with
`runBlocking`.

**The bridge has its own trap:** using `runBlocking` in a command that needs the
MainActor is a deadlock — the main thread waits on a semaphore while the work
tries to hop to the actor it is blocking. `preview --write-iconset` hung exactly
that way. `preview` and `settings` use `MainActor.assumeIsolated` now, since a
synchronous command already runs on the main thread.

### The result

```
17:06:49  modifier event: flags=80140 keycode=61 wanted=80000 match=true
17:06:49  hotkey down · ● recording
17:06:52  → 0.45 s · Bugün Slack'tan seni arayacağım.
```


## Signing and notarisation

An ad-hoc signature has no identity beyond the binary's own hash, so every
rebuild invalidates the TCC grant the user just gave. That is the difference
between granting permission once and granting it every single build.

`scripts/bundle.sh` picks the best identity available, in order: a Developer ID
Application certificate, then a local self-signed certificate, then ad-hoc.
Releases take the first path — signed with the Hardened Runtime, notarised by
Apple through `scripts/notarize.sh`, and stapled.

Stapling happens **twice on purpose**: to the `.app` first, then to the DMG
built from the already-stapled app. Stapling only the DMG leaves the copy the
user drags to Applications without its own ticket, which then needs a network
round trip on first launch and fails closed offline.

The only entitlement requested is `com.apple.security.device.audio-input`.
Deliberately absent: the App Sandbox (it would break the global event tap and
cut off `~/Documents`, where the model weights live),
`allow-unsigned-executable-memory` and `allow-jit` (Core ML loads `.mlmodelc` as
data), `disable-library-validation`, and Apple Events. Hotkey watching and
pasting need no entitlement at all — TCC governs them.

Two failures worth recording, because both read as something they were not:

**`bundle.sh` silently fell back to ad-hoc.** The signing step was written as
`cmd && note ... || { fallback }` with stderr sent to `/dev/null`, so codesign's
actual error was discarded and the only visible symptom was permissions
resetting on every rebuild. The error is captured and printed now, and the exit
status is read from codesign rather than from a pipeline's last stage — `if cmd
| sed` takes sed's status, which is always 0, and would have reintroduced the
same bug.

**Stapling failed immediately after a successful notarisation.** notarytool
reporting `Accepted` means Apple finished scanning, not that the ticket has
reached the servers stapler pulls from. The first attempt failed with error 73,
which reads like a rejected build; the identical command succeeded 15 seconds
later. `notarize.sh` retries six times over 90 seconds.


## The language boundary

Transcription is fully multilingual — the engine is Whisper and `language` can
be set to anything it supports. The layers on top are not, and this is a safety
boundary rather than a missing feature.

Vocabulary repair is Turkish-only because its guard against replacing a word the
user really said is a list of ordinary Turkish words. Point it at another
language and nothing is protected. Measured on English before the boundary was
enforced:

```
"into main"       → "Notion"
"merged"          → "merge"
"the CI pipeline" → "CI pipeline"
```

Post-processing is Turkish-only for the same kind of reason: `FillerFilter`'s
hesitation set is Turkish and contains bare vowels that are ordinary English
words, and the model instructions open with "Sen bir Türkçe dikte temizleme
asistanısın" — handing that English asks a Turkish-primed model to tidy text it
was never described.

**A bug found here:** `FillerFilter.isSupported` existed and was never called.
`Refiner` had no language at all, so both cleanup tiers ran on every transcript
regardless of language — while the README claimed they were skipped. The
documentation described a boundary the code did not have. The gate now lives in
`Refiner`, which takes the language; for a non-Turkish transcript the model is
not called at all rather than called and second-guessed, and the CLI says it
skipped instead of returning identical text that looks like a broken cleanup.

Supporting another language means writing its common-word list and phonetic
normalisation. It is not a flag.


## Status

- **M1 — done.** The engine layer, the `Transcriber` protocol, the Whisper and
  Parakeet conformances, the `yaz transcribe` measurement harness, fixed Turkish
  fixtures.
- **M1.5 — done.** Hardening round 1: `SpeechGate`, `TranscriptionQuality`,
  `YazError`, the timeout, language validation, the windowed `AudioLoader`.
- **M1.6 — done.** Hardening round 2: the actor reentrancy fix (`SingleFlight`),
  inference serialisation (`SerialGate`), closing the data races, the `Signals?`
  distinction, vDSP measurement, multi-format audio tests. 57 tests.
- **M2 — done.** `AudioCapture`, a configurable `Hotkey`, a self-healing event
  tap.
- **M3 — done.** Clipboard insertion (plus a grapheme-safe typing fallback),
  `Config`, `doctor`, `models`, `Daemon`. 87 tests.
- **M4 — done.** The vocabulary layer: phonetic skeleton matching, the Turkish
  word veto, suffix preservation, `vocab test` / `vocab explain`. 126 tests.
- **M5 — done.** Post-processing: `FillerFilter` (deterministic), `Refiner` +
  FoundationModels (optional), `RefinementGuard`, `TranscriptPipeline`. 156
  tests.
- **M6 — done.** `LevelMeter`, `IndicatorState`, the click-through overlay pill,
  `MenuBarController`, `yaz preview`. 176 tests.
- **M7 — done.** The embedded Info.plist, `LaunchAgent`, `yaz install`,
  `scripts/install.sh`. 197 tests.
- **M8 — done.** The `yaz.app` bundle, `LSUIElement`, the in-bundle permission
  flow.
- **M9 — done.** `TranscriptHistory`, `yaz history`.
- **M10 — done.** The settings and history windows, `Config.save()`, `yaz
  settings`.
- **M11 — done.** `scripts/bundle.sh --dmg`. 221 tests.
- **M12 — done.** Developer ID signing, notarisation and stapling
  (`scripts/notarize.sh`), the entitlements file, the language boundary fix.
  262 tests.

The one thing still outstanding is a live dictation round: microphone permission
needs the user's approval.

## Measurement discipline

`yaz transcribe` was written before the daemon, deliberately. Every change —
engine version, vocabulary, post-processing — is measured against the fixed
audio under `fixtures/`, not against whatever was said into the microphone at
the time. That is the only way an accuracy claim becomes comparable.

The fixtures were produced with macOS `say -v Yelda`, so they are synthetic.
Real speech differs; in particular, results in practice can be expected to be
slightly better on English loanwords, since the synthetic voice reads them with
Turkish phonetics. The *kind* of error is real regardless.
