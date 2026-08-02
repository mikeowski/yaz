# Security

## Reporting

Email **burakmahyk@gmail.com** with `yaz security` in the subject. Please do not
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

## Known limitations

- **Not notarised.** Releases are signed with a self-signed certificate, so
  Gatekeeper treats the app as unidentified. Build from source if that matters
  to you.
- **The clipboard path is observable.** Any app with clipboard access can read
  the transcript during the paste window. `"inject_mode": "type"` avoids the
  clipboard but is slower and drops characters in some Electron apps.
