## What this changes

## Why

## What you measured

Accuracy and latency claims are measured against `fixtures/`, not against
whatever was said into a microphone. If this touches an engine, a threshold or
a correction rule, show before and after:

```sh
swift test
./.build/release/yaz transcribe --strict fixtures/t1.wav fixtures/t2.wav
```

If it touches `Vocabulary`, the precision corpus must still come through clean —
those 30 ordinary Turkish sentences are what set every threshold in that file.

## Checklist

- [ ] `swift test` passes
- [ ] New behaviour has a test that fails without the change
- [ ] README updated if user-visible
- [ ] `docs/architecture.md` updated if it is a decision worth remembering
