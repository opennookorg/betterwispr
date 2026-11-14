<div align="center">

![BetterWispr: hold to talk, release to type](docs/assets/hero.png)

# BetterWispr

**Free, open-source voice dictation for macOS.** Hold **⌥ Space**, speak, release, and the text lands in the app you're typing in.

Transcription runs on your Mac with Whisper, NVIDIA Parakeet, Cohere Transcribe or Apple speech. Your voice leaves your Mac only if you select an API connection or Codex subscription transcription.

[Download](https://github.com/opennookorg/betterwispr/releases/latest) · [Website](https://betterwispr.com) · [Changelog](CHANGELOG.md)

[![Buy me a coffee](https://shieldcn.dev/badge/Buy%20me%20a%20coffee-Support-FFDD00.svg?logo=buymeacoffee&variant=branded)](https://buymeacoffee.com/code_kartik)

</div>

## Features

- **Dictate anywhere** with hold-to-talk or toggle, on a shortcut you choose.
- **Dictate and format** (**fn ⌃**) shapes English text for the app: an email, a Slack message, a plain AI prompt. Uses Claude Code, Codex, an API connection or Ollama.
- **Clean up selected text** in any app with your cleanup provider.
- **On-device models**: Parakeet (English, Japanese, 25 European languages), Whisper (about 100 languages), Cohere Transcribe (14 languages, macOS 15+) and Apple speech.
- **Vocabulary and corrections**: fix a word once and it's spelled right next time.
- **Voice commands** such as "comma", "new line" and "scratch that".
- **Meeting notes** without a bot: live transcript, on-device speaker labels, summaries, and Ask with cited answers.
- **Calendar**: see your Mac's calendars, join calls and take notes in one click. Read-only.
- **Transcribe files and links** to timestamped text or Markdown.
- **Send to Claude** and **Send keys** press Return (or your key) after pasting. Off by default.
- **Connected apps** let MCP apps like Claude and Cursor read your meetings. Off by default, read-only.
- **Bring your own model**: Sarvam AI, Smallest AI or any OpenAI-compatible endpoint.

## Getting started

Requires macOS 14 or later. Apple Silicon recommended.

1. Download the DMG from [Releases](https://github.com/opennookorg/betterwispr/releases/latest) and drag BetterWispr to Applications.
2. Open it, follow the welcome guide and pick a model in **Models**.
3. Grant **Microphone** and **Accessibility** access.
4. Click into any text field, hold **⌥ Space**, speak and release.

If paste can't safely reach the app, the text is copied to your clipboard instead.

## Privacy

- Settings, vocabulary and history are stored locally in `~/Library/Application Support/BetterWispr/` (not encrypted). History can be turned off.
- Built-in models use the network only when you download one. BetterWispr never falls back to a cloud provider on its own.
- API keys are stored in the macOS Keychain. With an API connection, your audio goes to that provider.
- Codex subscription transcription uses an unofficial ChatGPT endpoint. See [setup](docs/codex-subscription.md).
- Audio is deleted after each recording. A failed dictation is kept for up to 7 days so you can retry it from History.

## Troubleshooting

- **Paste stopped working after an update**: remove and re-add BetterWispr in System Settings → Privacy & Security → Accessibility.
- **Apple on-device model unavailable**: install Parakeet or Whisper instead.
- **First transcription is slow**: large models take time to load the first time.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Star history

<p align="center">
  <a href="https://www.star-history.com/#opennookorg/betterwispr&Date"><picture><source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=opennookorg/betterwispr&type=Date&theme=dark" /><img alt="Star history of opennookorg/betterwispr" src="https://api.star-history.com/svg?repos=opennookorg/betterwispr&type=Date" /></picture></a>
</p>

## License

[Apache-2.0](LICENSE). Third-party code and model weights keep their own terms.
