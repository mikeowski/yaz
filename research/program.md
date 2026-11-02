# yaz autoresearch

This is the program an agent follows to improve yaz's term repair on its own,
in the shape of Karpathy's [autoresearch](https://github.com/karpathy/autoresearch):
a human writes this file, the agent edits a small surface, a fixed evaluation
decides, git keeps or reverts.

## The metric

```
swift run yaz eval --quiet
```

prints one integer: `false matches × 3 + misses` over `Sources/yaz/Eval/EvalCorpus.swift`.
**Lower is better.** A false match costs three misses because it is invisible:
a missed term stays visibly mangled, a wrong replacement looks like what the
user said.

`swift run yaz eval` without `--quiet` lists every offending replacement.

## What you may change

- `Vocabulary.defaultThreshold`, `Vocabulary.defaultSkeletonThreshold`
  (`Sources/yaz/Vocabulary/Vocabulary.swift`). Try values with
  `yaz eval --threshold X --skeleton-threshold Y` before editing.
- `PhoneticKey` normalisation rules (`Sources/yaz/Vocabulary/PhoneticKey.swift`).
- `TurkishLexicon.common` and its suffix list.
- `Learner.minimumSimilarity`, `Learner.promoteAfter`.

## What you must not change

- `Sources/yaz/Eval/EvalCorpus.swift` and `Sources/yaz/Eval/Evaluator.swift`.
  They are `prepare.py`. A change that only passes because the set or the
  metric moved is not a change. New cases are added by a human, from real
  measured transcripts, in a commit of their own.
- Existing tests. `swift test` must stay green.

## The loop

1. Work on a branch `autoresearch/<date>`.
2. Record the baseline: `swift run yaz eval --quiet`.
3. Make one change. Run `swift run yaz eval --quiet` and `swift test`.
4. If the score went **down** and the tests pass, commit with the score in
   the message. Otherwise `git checkout -- .` and try something else.
   Equal is not better: it adds code for nothing.
5. Append a line to `research/results.tsv`:
   `date	commit	score	kept	what you tried`. Log the reverted tries
   too; they stop the next run from repeating them.
6. Repeat. Stop after 20 tries or when the score is 0 and a new idea would
   need new cases.

## The online half

The app runs the same keep-or-revert on the user's Mac (`Learner`): a fix the
user makes twice becomes a candidate rule, and `Evaluator.gate` keeps it only
if it fixes its own case and does not raise the score. A repair the user
undoes is blocked at once. `yaz learned` shows what was kept, blocked and
rejected; `yaz eval --learned` scores the set with those rules included.
