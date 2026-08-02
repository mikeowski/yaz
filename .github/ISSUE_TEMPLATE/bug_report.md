---
name: Bug report
about: Something does not work
labels: bug
---

## What happened

## What you expected

## Log

Most failures in this app are silent by nature — a permission that reports as
granted, a hotkey macOS has taken. The log is usually the only evidence:

```sh
yaz doctor
yaz logs --lines 60
```

Paste both. Redact any dictated text you would rather not share.

## Setup

- macOS version:
- Mac model (must be Apple Silicon):
- yaz version (`yaz --version` or the commit):
- Installed as: `.app` / CLI
- Hotkey:
- Language:

## If the hotkey does nothing

Please check these first — they account for most reports:

- [ ] `yaz doctor` shows accessibility **and** input monitoring granted
- [ ] The log shows `hotkey listener installed`
- [ ] The log shows `modifier event` lines when you press the key
- [ ] If it says permissions are granted but no events arrive, `yaz
      reset-permissions`, then quit and reopen
