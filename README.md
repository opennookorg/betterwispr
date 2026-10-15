<div align="center">

![BetterWispr: hold to talk, release to type](docs/assets/hero.png)

# BetterWispr

**Free, open-source voice dictation for macOS.** Hold **⌥ Space**, speak, release, and the text lands in whatever app you were typing in.

BetterWispr is a private, offline speech-to-text app and an open-source alternative to Wispr Flow. It transcribes on your Mac with Whisper, NVIDIA Parakeet or Apple's on-device speech recognition, so your voice never leaves your computer unless you add an API connection yourself.

[Download the latest release](https://github.com/opennookorg/betterwispr/releases/latest) · [Website](https://betterwispr.com) · [Changelog](CHANGELOG.md)

[![Buy me a coffee](https://shieldcn.dev/badge/Buy%20me%20a%20coffee-Support-FFDD00.svg?logo=buymeacoffee&variant=branded)](https://buymeacoffee.com/code_kartik)

</div>

## Features

- **Dictate anywhere**: hold-to-talk or press-to-toggle, with a shortcut you choose.
- **On-device models**: Apple speech, Parakeet v3 (25 European languages), Parakeet v2 (English) and Whisper large-v3 turbo.
- **Vocabulary**: spelling hints and phrase replacements for names and jargon.
- **Learns your corrections**: fix a misheard word once (in History, or right after it's pasted) and it's spelled right next time.
- **Voice commands**: say "comma", "new line", "scratch that" or "sorry, remove that", and "at the rate KV" for "@KV".
- **Meetings**: live transcript of you and the other side, plus on-device titles, summaries and action items with Apple Intelligence or a local Ollama model.
- **Transcribe files and links**: drop in an audio or video file or paste a video link and get a timestamped transcript with the model you choose, to copy or export as text or Markdown. Links use yt-dlp, which BetterWispr installs only when you click Install.
- **Connected apps**: let Claude, Cursor and other apps that support MCP list, search and read your meeting notes and transcripts. Off by default and read-only.
- **History**: raw and corrected transcripts, stored locally (can be turned off).
- **Bring your own model**: optional Sarvam AI, Smallest AI or any OpenAI-compatible endpoint.

## Requirements

- macOS 14 or later
- Apple Silicon recommended

## Getting started

1. Download the DMG from [Releases](https://github.com/opennookorg/betterwispr/releases/latest) and drag BetterWispr to Applications.
2. Open it and follow the welcome guide.
3. Pick a model in **Models**. Apple on-device needs no download; Parakeet and Whisper download once, then work offline.
4. Grant **Microphone** access, and **Accessibility** access so BetterWispr can paste for you.
5. Click into a text field in any app, hold **⌥ Space**, speak, and release.

If paste can't safely reach the previous app, the text is copied to your
clipboard instead, so you never lose a dictation. Recordings stop automatically
after ten minutes, with a countdown in the last 30 seconds.

## Bring your own model

**Models → Bring your own model → Add connection.** Choose a provider, enter the
model ID and API key, save, then click **Use**.

| Provider | Default model | Notes |
| --- | --- | --- |
| Sarvam AI | `saaras:v4` | Long recordings are sent in 25-second chunks |
| Smallest AI | `pulse` | Set an explicit spoken language in Settings |
| OpenAI-compatible | any | Full URL, e.g. `http://localhost:8000/v1/audio/transcriptions`. HTTPS required except on localhost |

When a connection is in use, your audio goes to that endpoint and its pricing
and retention policies apply. Keys are stored in the macOS Keychain. Switch back
to a built-in model to return to fully local transcription. BetterWispr never
falls back to a cloud provider on its own.

## Privacy

- Settings, vocabulary and history live in `~/Library/Application Support/BetterWispr/workspace.json` (not encrypted).
- Models live in the `Models` folder next to it.
- With Remember named voices on, voice profiles of the speakers you name live in `Voices.json` next to it (not encrypted). Forget Voices in Models deletes them, and deleting a meeting deletes the profiles named in it.
- Audio is written to temporary files and deleted after each recording.
- Built-in models only touch the network when you explicitly download one.
- Connected apps is off by default. When you turn it on, apps you connect read your meetings through `BetterWispr --mcp` on this Mac and send what they read to their own AI provider.

## Troubleshooting

- **Paste stopped working after an update or rebuild**: remove and re-add BetterWispr in System Settings → Privacy & Security → Accessibility.
- **Apple on-device model unavailable**: your language or OS speech assets may not support it. Install Parakeet or Whisper instead.
- **First transcription is slow**: large models take time to load the first time.

## Contributing

Build instructions, project layout and guidelines are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Star history

<p align="center">
  <a href="https://www.star-history.com/#opennookorg/betterwispr&Date"><picture><source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=opennookorg/betterwispr&type=Date&theme=dark" /><img alt="Star history of opennookorg/betterwispr" src="https://api.star-history.com/svg?repos=opennookorg/betterwispr&type=Date" /></picture></a>
</p>

## License

[Apache-2.0](LICENSE). Third-party code and model weights keep their own terms;
