# Open-source provenance

Reviewed 2026-10-08. BetterWispr's original code remains Apache-2.0. Third-party
components retain their own licenses; model weights have separate terms from
their inference engines.

## Code actually adapted

`Sources/BetterWisprCore/Speech/LocalWhisperTokenizer.swift` adapts the
`WhisperTokenizer` implementation from
[`Sources/WhisperKit/Core/Models.swift`](https://github.com/argmaxinc/argmax-oss-swift/blob/1e2a163736dfa5a198e637ae44c114e1c6d5cc2d/Sources/WhisperKit/Core/Models.swift#L1165),
Argmax OSS v1.1.0, revision `1e2a163736dfa5a198e637ae44c114e1c6d5cc2d`.
The upstream MIT license and copyright 2024 argmax, inc. are retained in the
adapted source. Changes accept a locally loaded `TokenizerWrapper`, validate
required tokens and handle Unicode scalar offsets safely while preserving the
upstream language-aware word grouping. The adaptation is needed because the
upstream initializer is internal and its convenience tokenizer loader may fall
back to a network request. BetterWispr injects a tokenizer constructed from local
files before model loading; it does not use that network fallback during dictation.

`Sources/BetterWisprCore/Speech/ParakeetProvider.swift` uses
[FluidAudio](https://github.com/FluidInference/FluidAudio) 0.17.5 (Apache-2.0)
as a SwiftPM dependency to run NVIDIA Parakeet TDT on the Neural Engine. No
FluidAudio source is copied. Models load with `AsrModels.loadLocal`, which never
fetches missing files; downloads only run from an explicit model installation.

`Sources/BetterWisprCore/Speech/SpeakerDetection.swift` uses SpeakerKit from
[argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) 1.1.0 (MIT,
license and notices shipped in the app bundle) as a SwiftPM dependency to tell
meeting speakers apart. No SpeakerKit source is copied. It loads with
`download: false`, so a missing or damaged model fails instead of downloading.
The weights are Argmax's Core ML conversion of pyannote
speaker-diarization-community-1, from
[argmaxinc/speakerkit-coreml](https://huggingface.co/argmaxinc/speakerkit-coreml)
at revision `556fc52a13327837688f02289457cded017802e9`, published under
CC-BY-4.0. Each model folder's README links the original weights' license:
pyannote segmentation-3.0, WeSpeaker and VBx. BetterWispr does not bundle them;
they download only from the explicit Speaker detection installation. Remember
named voices stores the speaker embeddings these models compute in `Voices.json`
on the user's Mac. CC-BY-4.0 sets conditions on sharing the licensed material,
and BetterWispr shares neither the weights nor the embeddings. Its comparison
of embeddings, Euclidean distance after scaling to unit length against
SpeakerKit's default clustering threshold of 0.6, is written in BetterWispr and
copies no SpeakerKit source.

`Sources/BetterWisprCore/Notes/LlamaEngine.swift` uses
[llama.swift](https://github.com/mattt/llama.swift) 2.10549.0 (MIT, copyright
2025 Mattt) as a SwiftPM dependency for its `LlamaSwift` module. That package
wraps the prebuilt
[llama.cpp](https://github.com/ggml-org/llama.cpp) release `b10549`
xcframework (MIT, copyright 2023-2026 The ggml authors), which
`scripts/build-app.sh` embeds as `llama.framework`. Neither project's source is
copied; BetterWispr calls the llama.cpp C API directly. llama.swift's license
comes from its checkout, and llama.cpp's, which the xcframework does not carry,
is kept at `Resources/Licenses/llama.cpp-MIT.txt` as published at tag `b10549`.
Both ship in the app bundle. The weights are `Qwen3.5-2B-Q4_K_M.gguf` from
[unsloth/Qwen3.5-2B-GGUF](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF) at
revision `f6d5376be1edb4d416d56da11e5397a961aca8ae`, a quantization of
[Qwen/Qwen3.5-2B](https://huggingface.co/Qwen/Qwen3.5-2B). Its model card lists
Apache-2.0 and links Qwen's license. BetterWispr does not bundle the weights;
they download only from the explicit built-in model installation and are
checked against a pinned size and SHA-256.

`Sources/BetterWispr/App/AppUpdater.swift` uses
[Sparkle](https://github.com/sparkle-project/Sparkle) 2.10.0 (MIT) as a SwiftPM
dependency for in-app updates. No Sparkle source is copied; its license ships in
the app bundle. `scripts/build-app.sh` removes Sparkle's XPC services because
they exist only for sandboxed apps and BetterWispr is not sandboxed.

Local sound files can be installed in
`~/Library/Application Support/BetterWispr/SoundOverrides/` as `started.wav`,
`finished.wav`, `cancelled.wav` and `attention.wav`. A cue without an override
plays a macOS system sound loaded by name from `/System/Library/Sounds`
(`Tink`, `Purr`, `Bottle` and `Basso`); nothing is copied into the repository
or the app bundle. These user-local override files are not copied into app
bundles or distributed by this project. The previous generated and Kenney
sound packs have been removed.

`scripts/release.sh` follows the separate-architecture signing and notarization
workflow in the sibling BetterShot project's `scripts/release.sh`
(BSD-3-Clause, copyright 2026 Kartik Labhshetwar, the same author). BetterWispr
uses SwiftPM builds, verifies the executable architecture and publishes a
Sparkle feed for both downloads instead of BetterShot's Xcode build commands.

`Sources/BetterWispr/App/ToastWindow.swift` adapts `ToastWindow` and its glass
surface from BetterShot (`Sources/Views/ToastWindow.swift` and
`Sources/Views/GlassSurface.swift`), BSD-3-Clause, copyright 2026 Kartik
Labhshetwar, the same author as BetterWispr. Changes take a typed `Toast`, ignore
mouse events, announce the toast to VoiceOver and use an opaque surface before
macOS 26.

`Sources/BetterWisprCore/Audio/SystemAudioTap.swift` adapts the Core Audio
process tap from Muesli's
[`CoreAudioSystemRecorder.swift`](https://github.com/Muesli-HQ/muesli/blob/d9ef2ace6f0eca41dd76302a32ea57d4ca65a4ce/native/MuesliNative/Sources/MuesliNativeApp/CoreAudioSystemRecorder.swift)
(MIT, copyright 2026 Pranav Hari) and AudioCap's
[`AudioCap/ProcessTap/ProcessTap.swift`](https://github.com/insidegui/AudioCap/blob/6f609e8ad1b1e11fa0e8edbe91864cb099f00de3/AudioCap/ProcessTap/ProcessTap.swift)
(BSD-2-Clause, copyright 2024 Guilherme Rambo), revision
`6f609e8ad1b1e11fa0e8edbe91864cb099f00de3`. Both notices are retained in the
adapted source. The adapted parts are the global tap description, the private
aggregate device that carries the tap, reading `kAudioTapPropertyFormat`, the
IOProc block and the teardown order. The tap excludes BetterWispr's own process
and leaves other apps audible. The tap and the aggregate device are private, and
the device gets a fresh UID for each meeting. Reading the tap format retries
briefly, the IOProc hands each buffer to the meeting chunk writer without
copying, and a tap failure leaves the meeting recording the microphone only.

`betterwispr-frontend/apps/web/src/components/apple-logo.tsx` copies the Apple
logo path from [Simple Icons](https://github.com/simple-icons/simple-icons)
16.34.0 (CC0-1.0). The logo is a trademark of Apple Inc. and only labels the
Download for macOS buttons.

`betterwispr-frontend/apps/web/src/components/github-stars.tsx` adapts
[Chánh Đại's GitHub Stars](https://chanhdai.com/components/github-stars),
installed with `npx shadcn@latest add @ncdai/github-stars`. The upstream MIT
license and copyright 2026 Chánh Đại are retained in the source and deployed
with the site at `/licenses/github-stars.txt`. Changes use
the existing shared UI imports, supply the tooltip provider and add an
accessible link label and singular-star wording. The existing GitHub action
supplies BetterWispr's live count to the new compact header variant and retains
a link when that count is unavailable. The hero keeps its original appearance.

`betterwispr-frontend/apps/web/src/components/ui/cards.tsx` and `demo.tsx`
adapt the card and two-row marquee snippets supplied in the integration request.
The request did not include an upstream source page or license notice. Changes
use the existing site typography, Lucide icons, typed X post data, source links,
empty-list hiding, pause controls and reduced-motion support. Sample quotes and
Unsplash portraits appear only in the explicitly labeled demo, not as endorsements.

`Sources/BetterWisprCore/Transcription/VoiceCommands.swift` adapts spoken
punctuation, line breaks and "scratch that" from Scribe
[`mac/Sources/Scribe/VoiceCommands.swift`](https://github.com/kumard3/scribe/blob/3c69a914a2767f5d3a3917f7b8b609b082d09164/mac/Sources/Scribe/VoiceCommands.swift),
revision `3c69a914a2767f5d3a3917f7b8b609b082d09164`, MIT. The upstream license
and copyright are retained in the source. Changes delete back to the previous
sentence, accept "remove that" only when set off by punctuation or an apology,
keep phrases like "the Oxford comma" as prose, turn "at the rate KV" into "@KV"
and add the # and % symbols and spoken email addresses. `SpokenNumbers.swift`
is original BetterWispr code.

`Sources/BetterWisprCore/Speech/WordAgreementEngine.swift` and
`Sources/BetterWisprCore/Speech/LiveTranscriber.swift` adapt the streaming
word-agreement preview from [VoiceInk](https://github.com/Beingpax/VoiceInk),
revision `c09cc1f677f40f2ee665843a61f07670210f012e`, GPL-3.0, files
`VoiceInk/Infrastructure/Providers/Transcription/FluidAudio/Streaming/WordAgreementEngine.swift`
and
`VoiceInk/Infrastructure/Providers/Transcription/FluidAudio/Streaming/FluidAudioStreamingProvider.swift`,
plus the startup buffering of `RealtimeAudioChunkGate` in
`VoiceInk/Features/Recording/Workflows/VoiceInkEngine.swift`. The repository
owner allowed copying VoiceInk code for this feature. Kept: the longest common
prefix over normalized words, three agreeing passes, the five-word minimum, the
third-last sentence ender as the confirmation cut, the pass and boundary
confidence thresholds, the SentencePiece token merge, and the one-second pass
over audio after the hypothesis start with a second of trailing silence and a
fresh decoder state. Changed: the engine is a value type with fixed thresholds
that returns confirmed and provisional text; the provider's locks, buffer
trimming and event stream became a main-actor state machine (idle, buffering,
running, stopping, stopped) over a capped sample buffer; each pass runs through
`ParakeetProvider.liveTranscribe` under the existing busy guard; and the
preview never reaches the pasted text, history or correction learning.

`Sources/BetterWisprCore/Transcription/CorrectionLearner.swift` ports
[`src/utils/correctionLearner.js`](https://github.com/OpenWhispr/openwhispr/blob/4881a74d7273e3d12ca91a0b46204ad80ea03e9a/src/utils/correctionLearner.js)
from OpenWhispr, revision `4881a74d7273e3d12ca91a0b46204ad80ea03e9a`, MIT,
copyright 2024 OpenWhispr Team, retained in the source. It keeps the word-level
LCS diff, the rewrite cutoff, the common-word list and the 0.65 edit-distance
ratio, and adds multi-word substitutions and case-only fixes such as "kv" to "KV".
`Sources/BetterWisprCore/Integrations/CorrectionWatcher.swift` arms after a paste,
as Scribe and OpenWhispr do, and finds the edited dictation with code adapted from
[VoiceInk](https://github.com/Beingpax/VoiceInk), revision
`c09cc1f677f40f2ee665843a61f07670210f012e`, GPL-3.0.
`CorrectionWatcher.edit(of:from:to:)` adapts the 16-character anchors of
`VoiceInk/Features/Dictionary/AutoLearn/FinalSnapshotDiffEngine.swift`: each side
of the dictation must appear exactly once in the final text, the right side must
not come before the left, and an empty side means the field boundary.
`CorrectionWatcher.comparable(_:)` adapts `AutoLearnTextNormalizer.accessibilityComparable`
from `VoiceInk/Features/Dictionary/AutoLearn/AutoLearnTypes.swift`. Changes keep
BetterWispr's polling and settle rules instead of VoiceInk's focus-change
snapshots, and normalize both the pasted text and every field read.

`Sources/BetterWisprCore/Transcription/CorrectionReviewer.swift` adapts the review
prompt and the reply validation of
`VoiceInk/Features/Dictionary/AutoLearn/AutoLearnAIReviewer.swift` from the same
VoiceInk revision, GPL-3.0. It reviews only the corrections `CorrectionLearner`
already accepted, only for English text at Medium cleanup with a ready notes
model, and sends each edit with up to three words on each side. Changes ask for
exactly one decision per candidate and drop batch canonicalization, and allow a
misheard brand or product such as "post hog" to "PostHog". The review can only
narrow what the rules found: each returned term must be whole words of its excerpt
that include the rules' own term, everyday words are rejected, and terms are capped
at 100 characters to match Vocabulary instead of VoiceInk's 256. Two deliberate
divergences from VoiceInk's validation: a case-only replacement such as "posthog"
to "PostHog" is learned as vocabulary instead of being rejected, and a reply
wrapped in a code fence is accepted instead of being rejected. Any invalid reply
counts as no review, so BetterWispr learns by its rules alone. The Undo action on the
"Learned" toast follows VoiceInk's undo for learned words in
`VoiceInk/Features/Dictionary/AutoLearn/AutoLearnService.swift`; no code is
copied for it.

The speech model warm-up in `Sources/BetterWispr/App/AppModel.swift` and
`Sources/BetterWisprCore/Speech/WarmUpClip.swift` adapts
`VoiceInk/App/Lifecycle/ModelPrewarmService.swift` and
`VoiceInk/Infrastructure/SystemIntegration/Lifecycle/LifecycleObserver.swift`
from [VoiceInk](https://github.com/Beingpax/VoiceInk), revision
`c09cc1f677f40f2ee665843a61f07670210f012e`, GPL-3.0. It keeps the throwaway
transcription of a local model after launch and 3 seconds after wake or screen
unlock. Changes replace the bundled sound with a generated second of quiet
noise, also warm after a model switch, run only while no dictation is in
progress and make the next dictation cancel and wait for the warm-up instead of
sharing the model. Loading the editing model 450 ms into a recording follows
`VoiceInk/Features/Recording/Workflows/VoiceInkEngine.swift`; BetterWispr loads
an Ollama model with an empty chat request at the edit's context length, so
Ollama does not load it again for the edit, prewarms Apple Intelligence and
leaves API and CLI models alone.
`APINotesModel.lowLatencyFields` adapts the per-model reasoning settings in
`VoiceInk/Infrastructure/Providers/Enhancement/ReasoningConfig.swift` and the
throughput routing in
`VoiceInk/Infrastructure/Providers/Enhancement/OpenRouterRequestPolicy.swift`.
Changes match on the endpoint host as well as the model, send the fields only
for dictation edits, skip OpenRouter's `:nitro` endpoints and pass
`--effort low` to Claude Code or `model_reasoning_effort="low"` to Codex.

`Sources/BetterWisprCore/Transcription/TranscriptPolisher.swift` adapts the AI
enhancement prompt of [VoiceInk](https://github.com/Beingpax/VoiceInk) revision
`c09cc1f677f40f2ee665843a61f07670210f012e`, GPL-3.0. Its system prompt is the
`SYSTEM_INSTRUCTIONS` template from
[`VoiceInk/Core/Enhancement/AIPrompts.swift`](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Core/Enhancement/AIPrompts.swift)
with the Default prompt from
[`VoiceInk/Features/Enhancement/Templates/PromptTemplates.swift`](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Features/Enhancement/Templates/PromptTemplates.swift)
inlined as its task instructions. The vocabulary and context sections follow
[`VoiceInk/Features/Enhancement/Workflows/AIEnhancementService.swift`](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Features/Enhancement/Workflows/AIEnhancementService.swift)
and the reply filter follows
[`VoiceInk/Core/Enhancement/AIEnhancementOutputFilter.swift`](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Core/Enhancement/AIEnhancementOutputFilter.swift).
Changes remove the prompt's own tags from vocabulary, context and transcript text,
add a one-line reminder after the transcript to return only the cleaned text,
which llama3.1:8b otherwise prefaced with commentary, cap each context part at a
word boundary, drop window and then clipboard text to
fit Apple's smaller context window after counting the vocabulary and mode
instructions, give a notes CLI only the fixed instructions as its system prompt
and send the vocabulary, mode instructions and context with the transcript, so
none of it reaches Claude Code's command line, and keep BetterWispr's check that
rejects replies that are not edits, which now ignores list markers. On timeouts
and transient network errors it makes up to three attempts of 7 seconds plus 1
second per 10 words each; CLI models get one attempt of 10 seconds plus 1 second
per 10 words. A failure keeps the light cleanup.
`Sources/BetterWisprCore/Integrations/ContextCapture.swift` adapts the window
matching and Vision text recognition of
[`VoiceInk/Infrastructure/SystemIntegration/ScreenCapture/ScreenCaptureService.swift`](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Infrastructure/SystemIntegration/ScreenCapture/ScreenCaptureService.swift)
at the same revision. Changes read the focused window's Accessibility text first
and recognize screen text only when that finds under 200 characters, the user
turned screen text on and Screen Recording is already allowed. Dictation never
asks for Screen Recording. Capture skips secure fields, reads nothing while secure
input is on and ignores clipboard items marked concealed, transient or
auto-generated. Context capture is off by default and runs only for Medium cleanup.
`DictationContext.swift` and `AccessibilityReader.swift` are original BetterWispr
code.

`Sources/BetterWisprCore/Domain/WritingMode.swift` adapts writing modes per app
and per website from
[`VoiceInk/Features/Modes/State/ModeConfig.swift`](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Features/Modes/State/ModeConfig.swift)
and spoken trigger words from
[`VoiceInk/Features/Modes/Models/ModeTriggerWordDetectionService.swift`](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Features/Modes/Models/ModeTriggerWordDetectionService.swift)
in [VoiceInk](https://github.com/Beingpax/VoiceInk) (GPL-3.0) at the same
revision. Kept: a trigger word wins over a website and a website over an app,
the longest trigger word is tried first, and the word is removed from the start
or end of the dictation as a whole word. Changes resolve the three tiers from
one table that only counts enabled modes, keep the sentence's closing period,
question mark or exclamation mark when a trailing trigger word is removed, and
match websites by host or subdomain plus a path prefix instead of VoiceInk's
substring check, so `x.com` no longer matches `dropbox.com`. A mode only
overrides cleanup, tone, screen context and Medium instructions; its unset
fields inherit the app's settings. `Sources/BetterWisprCore/Integrations/WebsiteReader.swift`
takes its browser list from
[`VoiceInk/Infrastructure/SystemIntegration/Context/BrowserURLService.swift`](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Infrastructure/SystemIntegration/Context/BrowserURLService.swift)
but replaces its AppleScript with Accessibility reads, so BetterWispr asks for no
Automation permission. It takes the window's document address, then walks up from
the focused element to the outermost web area so an iframe's address is ignored,
then falls back to the window's first web area when focus is in the toolbar. It
reads the address only while some enabled mode lists a website, reads it while
the microphone starts, waits at most half a second, and never stores, logs or
sends it. Recording starts only after the mode is known, and an unknown address
captures no screen context. Changes also leave capitalization alone when a
trailing trigger word is removed, let a trigger word turn screen context off but
not on, accept `*.github.com` and `github.com/org/*` patterns, and make a saved
mode with an unknown cleanup or tone leave the workspace unreadable and untouched
instead of dropping the value.

## Runtime engines and alternatives reviewed

The 0.1.3 microphone follow-up reviewed Handy revision
`f6b3f8297061acaa763a48c4cdefbbf342c814ac`, especially its
[recorder](https://github.com/cjpais/Handy/blob/f6b3f8297061acaa763a48c4cdefbbf342c814ac/src-tauri/src/audio_toolkit/audio/recorder.rs)
and [audio manager](https://github.com/cjpais/Handy/blob/f6b3f8297061acaa763a48c4cdefbbf342c814ac/src-tauri/src/managers/audio.rs):
first-sample readiness, draining pending audio at stop, and retaining device
preparation. VoiceInk revision `c09cc1f677f40f2ee665843a61f07670210f012e`'s
[Core Audio recorder](https://github.com/Beingpax/VoiceInk/blob/c09cc1f677f40f2ee665843a61f07670210f012e/VoiceInk/Infrastructure/Audio/CoreAudioRecorder.swift)
was reviewed for prepared capture and shutdown draining. BetterWispr implements
readiness and timestamp-boundary completion with an input-only Core Audio queue
shared by dictation and meetings. Apple Audio Queue Services supplies buffer
ownership and callback dispatch instead of adding a custom real-time ring buffer. No recorder source was copied or translated from either project;
the VoiceInk code adapted elsewhere is listed in the entries above.

| Project | Upstream terms | Use in this project / useful pattern |
| --- | --- | --- |
| [WhisperKit / Argmax OSS](https://github.com/argmaxinc/argmax-oss-swift) | [MIT](https://github.com/argmaxinc/argmax-oss-swift/blob/main/LICENSE); bundled third-party notices also apply | Native Swift on-device inference; use the OSS library rather than copying an entire app. The old WhisperKit repository URL redirects here. Argmax Pro is a separate product and is not included. |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | [Apache-2.0](https://github.com/FluidInference/FluidAudio/blob/main/LICENSE) | Core ML Parakeet TDT inference, used for the Parakeet models. |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | [MIT](https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE) | Local C/C++ inference and CLI integration; useful for a separately installed local engine and GGML models. |
| [Handy](https://github.com/cjpais/Handy) | [MIT](https://github.com/cjpais/Handy/blob/afe5a6310534ffb178794365f31abb8b9fd435a7/LICENSE) | Reviewed its separation of recording, model management and transcription. Its [VAD smoother](https://github.com/cjpais/Handy/blob/afe5a6310534ffb178794365f31abb8b9fd435a7/src-tauri/src/audio_toolkit/vad/smoothed.rs) buffers speech onset and trailing frames. No Handy source is vendored by this research task. |
| [VoiceInk](https://github.com/Beingpax/VoiceInk) | [GPL-3.0](https://github.com/Beingpax/VoiceInk/blob/main/LICENSE) | Adapted at revision `c09cc1f677f40f2ee665843a61f07670210f012e`, as described above: the dictation edit prompt with vocabulary, selected text, clipboard and window context; AutoLearn's anchored edit reading, AI reviewer and Undo; the speech and editing model warm-ups and low-latency reasoning settings; the Parakeet word-agreement live preview; and writing modes per app, per website and by trigger word. Its per-app Power Mode also informed the per-app writing styles, whose rules and app registry were written for BetterWispr. |
| [Muesli](https://github.com/Muesli-HQ/muesli) | MIT | Native meeting recorder. Its Core Audio system recorder is adapted for meeting notes, as described above. |
| [AudioCap](https://github.com/insidegui/AudioCap) | BSD-2-Clause | Minimal process tap sample. Its tap and aggregate device setup is adapted for meeting notes, as described above. |
| [OpenOats](https://github.com/yazinsai/OpenOats) | MIT | Reviewed for labelling the microphone as Me and system audio as Them, and for removing microphone text that repeats overlapping remote speech. BetterWispr's word-run echo filter is original code. No source copied. |
| [Recap](https://github.com/RecapAI/Recap) | MIT | Native meeting summaries reviewed for product shape. No source copied. |
| [anarlog (formerly Hyprnote)](https://github.com/fastrepl/anarlog) | MIT | Rust meeting notes app, reference only. Its short pause-ended chunks informed the 3 to 20 second meeting chunks. No source copied. |
| [Meetily](https://github.com/Zackriya-Solutions/meetily) | MIT | Rust meeting minutes app, reference only. No source copied. |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Unlicense | Fetches the audio of a pasted link for the Transcribe page and `BetterWisprCLI --media`. Not bundled. The `yt-dlp_macos` release binary is downloaded at runtime only when the user installs or updates it, and is checked against the release's `SHA2-256SUMS`. No source copied. |

The research table is not the dependency lock file: the actual compiled versions
are recorded in `Package.swift` and `Package.resolved`, and a separately installed
CLI has its own version. Keep upstream license files and notices in packaged
releases when distributing those dependencies. A model installation needs its
own model ID, version/hash and license record.

Whisper's released code and weights use [MIT](https://github.com/openai/whisper/blob/main/LICENSE).
[NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
and [v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) weights use CC-BY-4.0
according to the publisher's model cards. BetterWispr downloads the
[FluidInference Core ML conversions](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml),
which keep that attribution obligation. The optional Parakeet phrase booster
downloads [FluidInference/parakeet-ctc-110m-coreml](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml),
a conversion of [nvidia/parakeet-tdt_ctc-110m](https://huggingface.co/nvidia/parakeet-tdt_ctc-110m)
that its model card lists as CC-BY-4.0. Do not infer weight terms
from an ONNX/Core ML/MLX conversion library's license.

The copied BetterShot development skills have separate provenance documented in
[`skills.md`](skills.md).
