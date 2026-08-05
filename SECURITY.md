# Security

## Reporting

Email **hi@mike4.dev** with `yaz security` in the subject. Please do not
open a public issue for anything exploitable.

Expect an acknowledgement within a week. This is a personal project, not a
funded one — there is no bounty and no formal SLA.

## What yaz touches

Worth knowing before you audit it:

- **Microphone.** Recorded only while the push-to-talk key is held. Audio stays
  in memory, is transcribed on-device, and is never written to disk or sent
  anywhere.
- **Keyboard events.** A listen-only `CGEventTap` watching modifier keys. It
  does not read what you type, and it does not modify the event stream.
- **Clipboard.** Text insertion copies the transcript, synthesises ⌘V, and
  restores the previous contents after 0.25 s. A clipboard manager running at
  the same time will see the transcript.
- **History.** Transcript text, the app it was pasted into, and a timestamp go
  to `~/Library/Application Support/yaz/history.jsonl`. **No audio is stored.**
  Turn it off with `"history": false`.
- **Network.** Only to download model weights from Hugging Face on first use.
  Transcription itself never touches the network.
- **Shell execution.** The optional `on_transcript` hook runs a command you
  configure, with the transcript as its argument. Whatever you put there runs
  with your privileges.

## What it deliberately does not do

- Store audio.
- Send transcripts anywhere.
- Read the keyboard beyond the modifier key you configured.

## How releases are signed

Released builds are signed with a **Developer ID Application** certificate
(team `XMCHPUCJS2`), with the Hardened Runtime enabled, then notarised by Apple
and stapled. You can check any download before opening it:

```sh
codesign --verify --deep --strict --verbose=2 /Applications/yaz.app
spctl --assess --type execute --verbose /Applications/yaz.app
xcrun stapler validate /Applications/yaz.app
```

The expected result is `Authority=Developer ID Application: BURAK MIKE
(XMCHPUCJS2)` and `source=Notarized Developer ID`. Anything else — an ad-hoc
signature, a different team identifier, a missing ticket — means the build did
not come from this project. Please report it rather than opening it.

The only entitlement requested is `com.apple.security.device.audio-input`.
Notably absent, and deliberately so: `allow-unsigned-executable-memory`,
`allow-jit`, `disable-library-validation`, and Apple Events. Microphone access,
Accessibility and Input Monitoring are all governed by TCC, so you can revoke
any of them at any time in System Settings.

Builds you make yourself are signed with a local self-signed certificate and are
not notarised — that is expected and only affects Gatekeeper, not behaviour.

## Known limitations

- **The clipboard path is observable.** Any app with clipboard access can read
  the transcript during the paste window. `"inject_mode": "type"` avoids the
  clipboard but is slower and drops characters in some Electron apps.
