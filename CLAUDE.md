# yaz: notes for Claude

macOS push-to-talk dictation (hold the hotkey, speak, release; the text is written at the cursor). Turkish first, plus
English, German, Spanish and French language packs. Architecture: `docs/architecture.md`. Site: `site/`
(yaz.mike4.dev).

**Latest handoff:** `docs/handoff/2026-11-14.md`: the plan in force. 0.2.1 (term-repair precision; its release deploy
also fixes the empty update feed), then 0.3.0 (runtime hardening, language packs after an audio check), then
coding-agent dictation. Read it before continuing. Site deploys and the feed: `docs/handoff/2026-11-03.md`.

## Working here
- CI: `.github/workflows/ci.yml` (`lint`, `test`) runs on pull requests; it can also be started by hand
  (`workflow_dispatch`). From a session without a Mac, CI is the only way to build and test Swift changes.
- Lint rules enforced by CI: no Turkish characters in quoted strings in `Yaz.swift`, `Doctor.swift`, `Daemon.swift` and
  `UI/`; test names in English.
- Language packs (`Sources/yaz/Language/`) are measured by the evaluator and `EvalCorpus`
  (metric: false matches × 3 + misses); a rule set lands only when precision checks stay clean.
- Site deploys: Cloudflare Workers Builds runs `scripts/site-build.sh` on every push to main (it carries the release
  downloads over from the live site, or takes a newer GitHub release). Releases: `scripts/release.sh` on the Mac (signing,
  notarization, the Sparkle feed signed with the key in the login Keychain).
- Every example on the site's language section is covered by `Tests/yazTests/SiteExamplesTests.swift`.
