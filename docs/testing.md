# Verification checklist

The validation record below lists checks actually performed. The remaining
unchecked items are procedures, not passed tests. Record the commit, macOS
version, Mac model, input device, engine/model and date for future runs. A
successful build does not verify microphone capture, clipboard behavior or
general recognition accuracy.

## Built-in notes model check, 2026-10-15, version 0.1.6

Apple M4 Pro with 48 GB, macOS 27.0.1, debug builds. `swift build`, all 242
tests in `swift test` and `./scripts/build-app.sh` passed. The new tests use
fake weights and small files, so none needs the download. They cover settings
round trips, the install marker, prompt injection through control tokens,
prompts and replies that overflow the window, timeouts, lane pauses, idle
unload, a request that arrives while the weights close, shutdown during a load
and shutdown waiting for an unload to finish.

Memory figures below come from `/usr/bin/time -l`. Resident size counts the
1.28 GB weights file, which is mapped rather than copied; the peak footprint is
the process's own memory.

- `BetterWisprCLI --download-builtin-model` downloaded 1,280,835,840 bytes in
  116.55 s and passed the size, SHA-256 and load checks, exit 0. Its peak
  footprint was 1,346,930,488 bytes because every 8 MB hash read stayed alive
  until the loop ended. Reading each chunk in its own autorelease pool cut a
  standalone hash of the file from 1,286 MB to 11 MB. Rerunning the checks on
  the downloaded file then took 2.29 s, with 1,495,678,976 bytes resident and a
  268,339,216-byte footprint.
- `--meeting` with `--notes-model builtin` on the JSONL transcript of a scripted
  four-person launch meeting exited 0 in 10.00 s, with 1,522,106,368 bytes
  resident and a 293,799,928-byte footprint. After rebasing onto main it took
  52.74 s, of which 42.35 s was Parakeet preparation (0.24 s in the earlier
  runs). A CLI built from main at `aa1f9c2` also took 22 s and 23 s to prepare,
  so the slowdown is not from this change. The run had
  1,551,171,584 bytes resident and a 275,974,208-byte footprint. The notes
  repeated items and gave Priya's slides to Marco.
- `--bench` with `--cleanup medium --notes-model builtin` on two `say` clips
  exited 0. The edits took 2.37 s, including loading the weights, and 1.63 s,
  with 1,602,142,208 bytes resident and a 292,407,360-byte footprint. The first
  clip's edit changed "Friday" to "Thursday" but kept "Actually, no, by
  Thursday."
- A temporary probe, since removed, used the same engine code. Loading took
  0.24 s, and a 31,500-character prompt prefilled in 3.82 and 3.81 s.
  Cancelling 150, 400, 700 and 1,000 ms into that prefill stopped it after 0.19,
  0.28, 0.30 and 0.32 s, about one 256-token batch. A Medium-lane request sent
  during the prefill finished in 0.58 s, with 1,586,462,720 bytes resident and
  a 364,742,696-byte footprint. With `shutdown()` removed, the CLI exited 134
  at `GGML_ASSERT([rsets->data count] == 0)` in `ggml-metal-device.m`; every
  run above calls it and exited 0.
- The app bundle passed `codesign --verify --deep --strict`, carries
  `Contents/Frameworks/llama.framework` and links
  `@rpath/llama.framework/Versions/Current/llama` with the
  `@executable_path/../Frameworks` run path. Launched with a separate home
  folder (`CFFIXED_USER_HOME`) so the installed BetterWispr kept running, it
  loaded the embedded framework in two launches. Each quit through
  `NSRunningApplication.terminate()`, after 94 s and 129 s, exited 0 and left
  no crash report.

The Download, Cancel, Remove and Test buttons, Medium dictation, meeting notes
and Ask in the app, quitting during a load, offline loading in the app, macOS
14, an Intel Mac, a Mac with 8 GB and a notarized build have not been exercised.

- [ ] In Models, download the built-in model. Progress moves, and Cancel leaves
  no `Models/models/unsloth/Qwen3.5-2B-GGUF` folder and no Remove button.
  Download again; it finishes, becomes the notes provider and Test notes model
  returns a summary.
- [ ] Choose Medium with Use screen context, dictate an English sentence with a
  self-correction into a text field and check the edit is pasted. Repeat with a
  long selected text.
- [ ] Record a real meeting with the built-in model selected. Notes are written,
  and Activity Monitor shows BetterWispr's memory falling back after five idle
  minutes.
- [ ] Ask a question about a saved meeting with Ask set to the built-in model.
- [ ] Start a Medium dictation and quit from the menu bar within a second, while
  the weights load. BetterWispr quits and leaves no crash report.
- [ ] Quit, turn off networking, relaunch and run a Medium dictation and meeting
  notes. Both work without network access.
- [ ] Remove the model while it is selected. Notes, Medium and Ask say it isn't
  downloaded and never use another model.
- [ ] Repeat the download, Test and a meeting on macOS 14 and on an Intel Mac.

## File and link transcription check, 2026-10-15

Apple M4 Pro, macOS 27.0.1, Parakeet Ultra, English. Speaker detection was not
installed for the checks below until the last one. The CLI checks used a
release build of `BetterWisprCLI --media`, which runs the same `MediaAudio`,
`MediaTranscriber` and `YTDLP` code as the Transcribe page.
[Accuracy](accuracy.md) has the numbers.

- `--media` on the 20-minute TED talk as m4a, mp3 and an mp4 with H.264 video,
  and on two more TED videos as m4a. Every run exited 0 and was scored against
  the captions. Rerunning the TED m4a gave the same text and timings.
- `--download-yt-dlp` installed yt-dlp 2026.08.19 into
  `Application Support/BetterWispr/Tools` after the checksum matched.
- `--media` on an 81-second YouTube link downloaded and transcribed it in 6.3
  seconds. `javascript:alert(1)` and `not a link` were refused before any
  download. A link that returns 404 and a YouTube video that doesn't exist
  failed with yt-dlp's last error line. No `betterwispr-media-` folder or file
  was left in the temporary directory after any of these runs.
- Stopping `--media` with SIGTERM while it transcribed left one
  `betterwispr-media-*.caf` chunk. Launching the debug app bundle with
  `CFFIXED_USER_HOME` pointed at an empty folder removed it.
- `swift test` covers the cut rule, chunk coverage of a file with silent gaps,
  unreadable files, cleanup and deletion of every chunk, cancellation and a
  failed chunk leaving no audio, the link rule, the checksum check, yt-dlp's
  arguments, progress and error lines, its private folder after success, error
  and cancel, and the app's job saving, cancelling and connection lock.
- After rebasing onto main with the SpeakerKit speaker detection from #34, its
  models installed, `--media` ran on the TED m4a and the interview. Both
  exited 0 and ended with Finding speakers. [Accuracy](accuracy.md) has the
  labels.
- `swift build`, `swift test` and `./scripts/build-app.sh` passed. The
  Transcribe page was rendered offscreen with two saved transcripts, a running
  job and an open transcript, and the renders were checked by eye.

Not exercised in the app: the sidebar entry, dropping or choosing a file,
pasting a link, the Install and Update buttons, Cancel, the model menu, an API
connection, Copy all, Export, Delete, Speaker detection labels, and quitting
during a job. The dashboard did not open during the launch check. AIFF, CAF,
FLAC, MOV and M4V files were not tried, and a WAV file was tried only in
`swift test`. Pressing Control-C on a running `--media` was not tried.

- [ ] Open Transcribe from the sidebar. Drop an m4a and a mov onto the drop
  area, and choose a WAV with Choose File. Each shows Reading audio, then
  Transcribing with a percentage, and is listed under Today when done.
- [ ] Remove `Application Support/BetterWispr/Tools/yt-dlp` and have no
  Homebrew copy. The page shows Install yt-dlp and Transcribe stays off for a
  pasted link. Nothing downloads until Install yt-dlp is clicked. After it
  installs, Transcribe a YouTube link.
- [ ] Click Update with yt-dlp installed. The version only changes when a newer
  release exists.
- [ ] Press Cancel while a link downloads and again while a file transcribes.
  Nothing is saved, and no `betterwispr-media-` folder or `.caf` file stays in
  the temporary directory.
- [ ] Pick another installed model in the menu and transcribe. With a
  dictation model that is not installed and nothing picked, drop a file. The
  app opens Models and downloads nothing.
- [ ] Pick an API connection in the menu and transcribe a short file. Models
  disables connection edits while the job runs.
- [ ] Open a transcript. Copy all puts timestamped lines on the clipboard.
  Export as Plain Text and as Markdown writes both files. Delete asks first,
  then removes the transcript.
- [ ] With Speaker detection installed, transcribe a two-person interview. The
  lines show Speaker 1 and Speaker 2, and never Them.
- [ ] Quit BetterWispr while a link downloads and again while a file
  transcribes. No yt-dlp process keeps running after the quit, and after a
  relaunch no chunk audio is left.

## Speaker detection check, 2026-10-14, version 0.1.6

Apple M4 Pro, macOS 27.0.1, debug builds. `swift build`, all 180 tests in
`swift test` and `./scripts/build-app.sh` passed. Tests cover the install check
(the marker and every pinned model folder must exist) and a cancelled wait
returning within 5 seconds while the work behind it keeps running.
`swift run BetterWisprCLI --download-speaker-detection` installed 15,468,430
bytes of models into
`~/Library/Application Support/BetterWispr/Models/models/argmaxinc/speakerkit-coreml`
and its verification load passed. A stand-in 0.1.5 folder at
`~/Library/Application Support/FluidAudio/Models/speaker-diarization` holding
the BetterWispr install marker was removed after the install, and the Parakeet
folder beside it was left alone. `--model parakeet-110m --meeting` ran on
16 kHz WAV files made with `say`, alternating Samantha and Daniel. With 0.5 s
pauses the four lines were labelled 1, 2, 1, 2. With no pauses, the 20-second
chunks were cut at 10.3, 21.1 and 30.8 s, within 0.15 s of the real voice
changes, into five lines labelled 1, 2, 2, 1, 2, which matches who spoke. These
are synthetic voices, not people on a call. macOS 14, an Intel Mac, a real
call, Skip and quitting during detection in the app, and the Models download
button have not been exercised.

- [ ] On macOS 14.2 or later, install Speaker detection in Models. Hold a call
  with at least two remote people, stop the meeting and check that "Telling the
  speakers on the call apart" appears, then Speaker 1, Speaker 2 labels and name
  fields. Type a name and check the transcript, Copy transcript and regenerated
  notes.
- [ ] Press Skip during detection. The notes start at once and the meeting keeps
  Them.
- [ ] Quit during detection, relaunch and check no `betterwispr-meeting-voices-`
  file is left in the temporary folder.
- [ ] With 0.1.5's Speaker detection installed, update to 0.1.6. Models shows
  Speaker detection as not downloaded. Download it and check that
  `~/Library/Application Support/FluidAudio/Models/speaker-diarization` is gone.
- [ ] Turn off Wi-Fi after installing and run a meeting. Speakers are labelled
  without network access.

## Accuracy and meetings check, 2026-10-12, version 0.1.5

Apple M5, macOS 27.0.1, release builds of `BetterWisprCLI`. Every check below
ran through the CLI, which reuses the app's providers, cleanup, meeting chunker,
Speaker detection and notes writer. [Accuracy](accuracy.md) has the numbers.

- `--bench` on 597 held-out EdAcc segments with Parakeet v3 and Ultra, Light
  cleanup, with and without vocabulary, before and after the phrase booster and
  cleanup changes.
- `--meeting` on four 10-minute AMI meetings and six EdAcc calls with v3 and
  Ultra, scored by `scripts/evaluate_meetings.py`. It replaces
  `--find-speakers` from the check below. Rebuilding the corpus with
  `fetch_bench_corpus.py --meetings` gave the same AMI speaker turns and the
  same number of samples, with a few samples differing by 1 in 16 bits. The
  scored EdAcc calls came from an earlier fetcher, and the rebuilt ones scored
  within 0.3 points of them.
- `--meeting SEGMENTS.jsonl --notes` with Apple Intelligence on seven meetings,
  three runs each, before and after the notes changes. The filler filter was
  checked against every decision and action item from those runs and 21 more.
- Light cleanup re-run on the raw text of 290 dictations saved on this Mac.
- `swift build`, `swift test`, `python3 Tests/evaluate_check.py`,
  `python3 Tests/release_check.py` and `./scripts/build-app.sh` passed on a
  copy of exactly the committed files, 111 tests in `swift test`.

Not exercised in the app: the global shortcut, microphone capture and paste
with the changed cleanup and booster, a live meeting with call audio, Speaker
detection and notes after a real call, and the Home "Try Parakeet Ultra" detail
and Recommended badge.

- [ ] With Parakeet v3 selected, Home shows "Try Parakeet Ultra" and Models
  marks Ultra Recommended. Nothing downloads until Download is clicked.
- [ ] Add "Claude" to Vocabulary and dictate "it runs in the cloud". "cloud"
  stays.
- [ ] Dictate "Let's meet at 5, no, at 6 pm" with Light cleanup. Expect "Let's
  meet at 6 pm".

## Dock visibility check, 2026-10-11

On arm64 macOS 26.6.1, `swift build`, all 110 tests in `swift test`, and
`./scripts/build-app.sh` passed. Settings tests cover the visible-Dock default
for older workspaces and persistence of the hidden preference. A live launch of
`.build/out/Products/Debug/BetterWispr.app` with `showInDock: false` finished
launching and reported `.accessory` activation policy through
`NSRunningApplication`. The rebuilt app was left running with that preference
off. The visible preference also produced `.regular` during an earlier launch
probe. A probe attempting another Carbon hotkey registration was inconclusive;
it does not establish whether the app receives Option–Space events.

Not exercised: changing the toggle through the UI, reopening from the menu bar,
dictation/paste with the dashboard closed, login-item launch, or macOS 14.
UI automation was not enabled for this session.

## Speaker detection check, 2026-10-11, version 0.1.5

macOS 27.0.1. `swift run BetterWisprCLI --download-speaker-detection` installed
21 MB into `~/Library/Application Support/FluidAudio/Models/speaker-diarization`
and its verification load passed. `--find-speakers`, since replaced by
`--meeting`, ran the app's
`SpeakerRecording` path on two 35.5 second WAV files made with `say`, cut into
5-second pieces. Lines were Samantha (0 to 9.8 s), Daniel (to 21.6 s), Samantha
(to 26.6 s) and a third voice. With Rishi as the third voice the pieces were
labelled 1, 1, 2, 2, 1, 3, 3, 3, as expected. With Karen as the third voice,
Karen was merged into Samantha (1, 1, 2, 2, 1, 1, 1, 1): two similar synthetic
female voices became one speaker. Each run took about 3 seconds and left no
temporary files. These are synthetic voices, not people on a call. A real call,
Skip, quitting during detection, renaming in the app and macOS 14 hiding the
download have not been exercised. The remaining steps moved to the 0.1.6 check
above.

## Speaker correction check, 2026-10-14, version 0.1.6

`swift test` covers `Meeting.assign`, `Meeting.mergeParticipant`,
`Meeting.nextParticipant`, the labels and summary fingerprint after a change, and
loading settings saved before `dismissedSpeakerDetectionOffer`. The menus and the
download card have not been exercised in the app, and no download was run.

- [ ] Open a finished meeting with Them lines and no speaker detection. Click a
  Them line's speaker name, choose New speaker, and check it reads Speaker 1 and a
  name field appears. Right-click the line's bubble and check the same menu opens
  rather than only the text menu.
- [ ] Move a line to another speaker and back to Them. Me lines show no speaker
  menu, and right-clicking a Me line's selected text still offers Copy.
- [ ] With two or more speakers, use Merge into on one. Its lines take the other
  speaker's label, a typed name moves across when the target has none, and the
  summary shows as out of date.
- [ ] While a meeting records, transcribes or finds speakers, no speaker menu or
  Merge into menu shows.
- [ ] Without speaker detection, a finished meeting with Them lines
  shows the download card. Download shows progress, Cancel stops it, a failure
  shows Retry, and success hides the card. Don’t show again hides it in every
  meeting after relaunch. Nothing downloads until Download is clicked.
- [ ] With speaker detection installed, the card never shows.

## Live meeting capture recheck, 2026-10-10, version 0.1.4

Same Mac, model and kind of script as the check below, after the start, idle
flush and echo changes, on the MacBook Pro microphone and speakers. Each run
played five `say` lines 4 seconds apart, the first 1 second after Start Meeting
Notes was clicked.

- After a relaunch, the first line was fully transcribed and its entry appeared
  0.97 seconds after it ended, while the model was still loading when it played.
  The other entries took 0.7 to 1.1 seconds, except one at 2.5 to 2.75 seconds.
- After a rebuild, "Them" entries appeared 0.87, 1.72, 1.0, 0.96 and 0.92
  seconds after each line ended.
- In the first meeting after another rebuild, the first two entries were on
  time, then every later entry appeared together 55 to 57 seconds after the
  start, about 10 seconds after Stop. This was seen once and did not happen in
  the run after the next rebuild. The cause was not found; contention with the
  launch warm-up compiling the same models is a guess.
- The echo filter, run on copies of the three saved meetings, hid 11 of 13 "Me"
  echoes completely. The other two kept words the model invented from the echo,
  "it's a good idea." and "in the video.", which do not appear in the remote
  text. Before the run start fix, those two also kept a leading "The".
- A 10 second sample during a meeting with the notetaker window and the pill
  showing found the main thread idle 48% of the time and in window server
  commits in 17% of samples, against 15% and about 60% in the earlier check.
  Nothing in the meters changed between the two, and the difference is not
  explained.

Not exercised: AirPods in these runs (the user reported a working AirPods test),
a USB microphone, a real call and the user's own speech.

## Live meeting capture check, 2026-10-10, version 0.1.4

On an Apple M5 with macOS 26.6.2, a debug app bundle with Parakeet TDT v3 and
one vocabulary term was driven from the menu bar by a script. It played seven
`say` lines, alternating two output paths, and read the saved meeting file every
0.1 seconds to time each entry. Every line plays through the system output, so the
tap records all seven as "Them" and the microphone hears them from the speakers.
These runs check timing, chunking and echo removal, not the user's own speech.

- AirPods Pro as input and output: the microphone opened at 24 kHz and once
  switched to 48 kHz mid-meeting; the recorder restarted it and the meeting
  continued. The AirPods were not worn, so their microphone also heard the Mac
  speakers. Before the noise floor change, idle AirPods noise was 0.003 to
  0.005 RMS, above the 0.002 threshold, and the headset's exact-zero dropout
  slices made the old quietest-slice estimate zero, so every slice counted as
  speech. After it, "Me" chunks were 3 to 11 seconds, except one 20.02 second
  first chunk. The first remote line was cut short once as the microphone
  started; a Bluetooth profile switch is a guess, not measured.
- "Them" entries appeared 0.9 to 6.2 seconds after a line ended across three
  AirPods runs, 0.9 to 1.6 seconds in the last. A 6.2 second wait was seen once
  and is not explained.
- "Them" chunks were stamped 3.7 seconds early, because the tap delivers nothing
  until something plays and chunk times counted only delivered audio. One echo
  fragment, "Friday morning.", fell outside the 3 second overlap window and
  stayed under "Me". With chunks stamped by capture time, on the built-in
  microphone and speakers, "Them" chunks started when each line played. The echo
  filter hid five of seven "Me" echoes in the first meeting after launch and six
  of seven in the next. The rest kept misrecognized words that do not match the
  remote text: "the first time.", "you a little bit of a little bit" and
  "campaign budget today.".
- With the app already warm, "Them" entries appeared 0.9 to 1.0 seconds after a
  line ended. The first entry took 11.3 seconds in the first meeting after the
  app was rebuilt and 2.9 seconds after a plain relaunch. The command line tool
  spent 21.1 seconds loading the models the first time after a rebuild and
  0.24 seconds the next time, and recognized each 3 to 6 second chunk in 0.05 to
  0.07 seconds. The cause of the 2 seconds after a relaunch was not found.
- During a meeting with the notetaker window and the pill showing, a 10 second
  sample found the main thread idle 15% of the time and waiting on window server
  commits in about 60% of samples, from the animated level meters. Capping the
  waveform at 30 frames per second raised idle time to 23% in one run and was
  not kept.

Not exercised: a USB microphone, a real call, AirPods worn in the ears, the
user's own speech overlapping remote speech, and AirPods as input with the Mac
speakers as output.

## Meeting chunks and echo filter check, 2026-10-09, version 0.1.4

On an Apple M5 with macOS 26.6.2, a temporary test replayed a real 8.9 second
microphone recording (48 kHz mono, speech with short pauses) four times in a row
through `MeetingChunkWriter` in 20 ms buffers. Before the change it produced
chunks of 30.00 and 5.60 seconds, so the first words waited 30 seconds and a
sentence was cut at the boundary. After it, the chunks were 8.82, 8.90, 8.90 and
8.90 seconds, each ending at a pause, plus a 0.08 second chunk with no speech
that was discarded. The echo filter was run on a copy of a saved real meeting
with 41 segments: 11 "Me" segments were trimmed and two were hidden because
fewer than three of their words were left. In two of three trimmed segments
checked by hand, every removed word appeared in order in the overlapping "Them"
text. In the third, a "yes yes" that may have been the user's own reply was
removed with the remote question it sat between. In a release build
that took about 1 ms, and about 9 ms for a synthetic 410 segment meeting. The two
new tests fail on the previous code. A live meeting with AirPods or a USB
microphone, speaker playback picked up during a live call, and changing the output
device during a meeting have not been exercised.

## Email command, "sorry" repairs and Style apps check, 2026-10-09, version 0.1.4

On an Apple M5 with macOS 26.6.2, Parakeet TDT v3 transcribed eight
`say`-synthesized clips through `BetterWisprCLI`. They were then run through
Light cleanup, voice commands and the email composer in a test. "I live in
Mdabad, sorry, in Delhi." became "I live in Delhi." and "Let's meet at 5 sorry
at 6." became "Let's meet at 6.". "Thanks for coming, sorry for the wait."
stayed. Two clips came back as "Mdabadsari", which no text rule can split.
"Write an email to Sarah saying I will be on holiday tomorrow. Thanks. Best
regards, Cardic." became a "Hi Sarah," email with the sign-off on its own lines.
The model heard "Kartik" as "Cardic", which a Vocabulary entry would fix. The
new "sorry" rule changed none of the 190 saved dictations on this Mac. None of
those dictations had a tone applied, because every app they went to (T3 Code,
Chrome, Brave, VS Code, Finder and Slack) uses a context set to Formal.
`swift build`, `swift test` (94 tests), `Tests/evaluate_check.py` and
`scripts/build-app.sh` passed, and the app launched. Screen capture returned a
black image, so the Style page footer, the capsule, toast and page animations
and a live email dictation into Mail have not been seen or exercised.

## Parakeet v3 languages and booster check, 2026-10-09, version 0.1.4

On an Apple M5 with macOS 26.6.2, the release `BetterWisprCLI` ran Parakeet TDT
v3 over 355 read-speech clips in eight languages, once with each clip's language
and once on automatic. [The accuracy notes](accuracy.md#parakeet-tdt-v3-baseline-2026-10-09)
list the per-language results. Before the booster fix, a German clip on
automatic with `--vocabulary` turned "meine" into "Mike" and "Zauber" into
"Zowber". After it, the German output was unchanged and an English clip on
automatic was still boosted. `swift build`, `swift test` and
`Tests/evaluate_check.py` passed. The new language test fails when one listed
code is changed to one FluidAudio does not accept. The Settings language picker
was not opened in the running app, and live dictation in a non-English language
has not been exercised.

## Bluetooth playback check, 2026-10-09, version 0.1.3

The user reported that YouTube audio in their AirPods lost quality while
BetterWispr ran, but not while Wispr Flow ran. Their saved settings chose the
AirPods as the microphone with Keep microphone ready enabled, so the AirPods
input stayed open whenever the app ran. A Core Audio probe on the user's MacBook
Pro read the AirPods output nominal rate as 48000 Hz idle, 24000 Hz while the
AirPods microphone was captured, and 48000 Hz while the built-in microphone was
captured. Keep microphone ready was removed, superseding the standby notes
below, and while the lid is open Automatic now uses the built-in microphone
instead of a Bluetooth default input. With AirPods as the macOS default input and
output, a temporary test ran the shared `MicrophoneInput` path for 2 seconds
per case. Automatic resolved to MacBook Pro Microphone, received 101,760 frames
and left the AirPods output at 48000 Hz. Choosing the AirPods received 49,912
frames and dropped the output to 24000 Hz. The test process had no microphone
permission (status not determined), so this measured device selection and
playback rate, not captured speech. `swift build` and `swift test` (89 tests)
passed, and the new selection test fails when the Bluetooth check is reverted.
Selection with the lid closed, and closing the lid during a recording, have not
been exercised on hardware.

## Microphone recovery check, 2026-10-08, version 0.1.3

Audio follow-up: the user reported that engine recovery alone still clipped
speech. Local diagnostics then measured 100 ms AVAudioEngine tap batches,
Bluetooth format changes from 48 to 24 kHz, and a hardware startup call blocking
the main thread for 2.56 seconds. The replacement input-only Audio Queue uses
20 ms buffers and starts off the main actor. It leaves a running queue alone
when the native rate changes. Live short dictations showed roughly 0.1–0.25 s
recognition time, while cold AirPods starts delivered about half a second of
zeros before nonzero input. These are individual diagnostic observations, not
latency or recognition benchmarks. A short recording passed the volume gate
but returned empty recognition, so lowering the gate alone would not solve it.

The user explicitly chose the new opt-in “Keep microphone ready” setting to
avoid repeated hardware wake-up. Its idle callback discards audio without any
file or speech-provider access. Existing settings default to disabled.
Automated coverage includes first-buffer/stop-boundary waiting, cancellation,
timeout, quiet speech across buffer sizes, digital-silence waveform recovery,
format conversion and the setting's backward-compatible decoding/round-trip.
`swift build`, `swift test` (87 tests), app packaging, strict signature checking
and both 0.1.3 bundle version fields passed. After enabling standby through the
native Settings switch with the user's permission, no recording file was open
while idle. The next AirPods dictation delivered a nonzero first buffer about
57 ms after startup began and returned nonempty recognition in about 96 ms.
The cold-start silent prelude was absent in that sample. The user subsequently
reported continued clipping, incorrect words and no-speech failures with
standby enabled, so that observation did not establish a fix. Physical
Bluetooth/USB hot-plug remains manual.
On 2026-10-09 the final build passed all 87 tests again and was relaunched;
the saved standby choice reopened the AirPods input queue automatically.

The 2026-10-09 follow-up found complete digital silence in some warm recordings
(including a 12.4-second session), despite fast queue startup. The same synthetic
spoken phrase converted to 24 and 48 kHz CAF transcribed correctly through the
installed Parakeet model at both rates. This rules out a simple rate-conversion
failure for those samples, not a live capture failure. Standby was opening a
different queue from each recording; capture now shares one queue per device.
`swift build` and all 88 tests passed, including delivery to overlapping
subscribers, independent detach and exclusion of audio preceding attachment.
App packaging, strict signature verification and both 0.1.3 version fields
passed. In the launched app, four consecutive AirPods dictations attached to
the original standby queue (two subscribers, no additional hardware starts),
captured nonzero speech and returned nonempty recognition. The user reported
that normal chat now felt like it was working well. This is positive dictation
feedback, not a scored accuracy test. A live meeting with this shared stream
and physical device switching remain unverified.

Capsule follow-up: `swift build`, `swift test` (84 tests; live provider tests
opt-in) and `./scripts/build-app.sh` passed. The rebuilt native app was launched;
its compact 132 × 36 hands-free pill and separate cancel/finish controls were
visually inspected. Clicking × stopped capture and displayed the cancellation
card with Undo and a progress line. Automated checks cover quick-tap conversion,
stale releases, single-use Undo, settings snapshots, dismissal/expiry audio
cleanup and old timers not replacing a newer phase. Live held-shortcut timing,
Undo transcription/paste into another app, sound quality and accessibility
display settings remain manual checks.

Further capsule refinement: the hands-free pill is now 108 × 28 points, with
18-point circles inside 24-point hit areas; the notetaker pill is 60 × 26.
Successful paste returns to idle without a completion card or announcement.
Four original, locally bundled soft-pluck cues replace macOS alert sounds.
`swift build`, `swift test` (87 tests), app packaging and strict code-signature
verification passed. A separate app-bundle probe resolved and decoded all four
sounds from its copied Resources folder. The rebuilt app's smaller hands-free
pill and cancellation were visually checked. Live notetaker sizing, listening
quality and successful-paste behavior remain manual checks.

The subsequent refinement widens the notetaker pill to 100 × 26 points and
replaces the synthesized cues with Kenney UI Audio clicks. Build, all 87 tests,
app packaging and strict signature verification passed again; the updated app
was relaunched while dictation and meeting capture were idle.

Final sound refinement removes the generated and Kenney packs, including their
download cache and the stale sound bundle in the packaged app. Only the local
Wispr Flow default cues remain. All four local WAVs match their source bytes
and decode with macOS `afinfo`; missing cues stay silent in the automated check.
`swift build`, all 87 tests, app packaging and strict signature verification
passed. Card expiry now uses an absolute monotonic deadline with zero tolerance
so the Undo countdown and audio cleanup finish together.

The supplied 23:43 crash report identifies a MainActor assertion in the Audio
Queue microphone callback. Its explicit `@Sendable` annotation is retained and
documented. After relaunching the rebuilt app, native microphone startup and
two completed dictations were observed while the user interacted; the reported
crash did not recur. This does not establish recognition accuracy or device
switching behavior. Listening quality remains a user check.

The duplicate-sound follow-up removes the post-insertion completion cue and
its local WAV. Hold and hands-free dictation retain the recording-stop cue;
notetaker has no feedback-sound calls. Build, all 87 tests, app packaging and
strict signature verification passed. The app was relaunched after confirming
both recording modes were idle. Live listening was not exercised in this pass.

- `swift build` and `swift test` passed (82 tests; live notes-provider tests
  remain opt-in). Synthetic checks cover dictation switches between 8, 16, 24,
  44.1 and 48 kHz, mono/stereo conversion, repeated switches, meeting chunk
  formats and offsets, and coalescing/cancelling engine notifications.
- `./scripts/build-app.sh` produced a signed debug bundle with both version
  fields set to `0.1.3`.
- The rebuilt native app started capture with AirPods Pro explicitly selected.
  Its temporary CAF grew beyond 1 MB; Escape returned to idle and removed it.
  The microphone picker was switched to the built-in mic and back during
  capture, with no displayed capture error, then the test was cancelled.
- A separate command-line probe lacked microphone permission and did not
  record. The native app used its existing permission. These checks establish
  capture and cancellation, not speech-recognition accuracy.
- Still pending: physical Bluetooth/USB connect and disconnect, Bluetooth
  profile renegotiation, live meeting microphone/system-audio continuity,
  denied permissions and testing on the minimum supported macOS version.

## Release check — 2026-10-08, version 0.1.0

Base commit: `490ae9787842548c49bd70ad93a200f53062add0`, plus the dashboard
Escape-cancellation fix. Apple M5 MacBook Pro (32 GB), macOS 26.6.2 (25G83),
Swift 6.3.3; built-in MacBook Pro microphone, Parakeet TDT v3, automatic language.

- `swift package clean` removed generated builds, module caches and app bundles.
  Dependency checkouts, installed speech models and saved user data were retained.
- `swift build`, `swift test`, `swift build -c release`, `swift test -c release`
  and both app packaging configurations passed. Each test suite passed 60 test
  functions and skipped the one opt-in live test. Python evaluator checks passed.
- `BETTERWISPR_LIVE_NOTES=1 swift test --skip-build --filter
  liveNotesProvidersGenerateFromSyntheticMeeting` passed all three synthetic
  cases: Claude Code, Codex and the local Ollama-compatible API. The release app's
  own **Test notes model** also succeeded with Claude Code.
- Fresh debug and release CLI processes, with networking denied by
  `sandbox-exec`, transcribed synthetic speech with Parakeet v3 and returned
  empty text for digital silence. Missing audio, unavailable Whisper Turbo,
  unknown models and repeated CLI options failed with the expected errors.
  Whisper Turbo is not installed; its recognition was not exercised.
- The native app opened, restored saved settings/history/meetings and displayed
  Models, Vocabulary, Settings and all three meeting-detail tabs. Microphone
  recording and menu cancellation worked. Escape initially failed to cancel;
  the dashboard now handles the native exit command. Retesting the rebuilt
  release app and a copy extracted from its DMG confirmed Escape returns to
  idle without adding history or leaving new temporary audio files.
- Developer ID signatures, hardened runtime, bundled framework signatures and
  DMG integrity passed. **The initial run was blocked:** `scripts/release.sh` failed
  at notarization with HTTP 403: a required Apple developer agreement is missing
  or expired. That run produced a signed but unnotarized `release/BetterWispr.dmg`;
  no stapling or appcast was produced, and no release was published.

Still pending: real speech through the global hold/toggle shortcut into another
app, paste and clipboard restoration, denied permissions, live system-audio
meetings, microphone hot-plug, long recordings, Apple/Whisper recognition and
minimum-supported-macOS checks. A pre-existing 4 KB dictation CAF from an earlier
run remained in the temporary directory; normal cancellations in this run
cleaned up, but crash/forced-quit cleanup was not exercised.

Local logs are in `.build/release-check/`. The signed, unnotarized DMG SHA-256 is
`b7c46f85a8a17b3cc9dec80eb348cd45bda0d0e7a58d9ddcae75eafe9b7c7a48`.

Shipping workflow follow-up on 2026-10-08:

- `make test` passed, including the new release-script checks. Shell syntax
  checks passed for both release and DMG scripts.
- Real DMG packaging completed and `hdiutil verify` passed for
  `.build/release-check/BetterWispr-packaging-check.dmg`.
- Real `make ship` stopped at preflight because `betterwispr-notary` has not
  been configured in Keychain. Existing artifacts were unchanged. No live
  notarization or stapling was completed in this follow-up.

After credential setup, the script's misleading setup advice for agreement
errors was corrected. Shell syntax and release-script checks passed, including
missing credentials, HTTP 401, agreement-specific HTTP 403, other HTTP 403 and
network failures. A subsequent real `make ship` passed Apple's access check and
completed successfully:

- Apple accepted submission `27bcf9d0-0416-42c9-838f-5cb4c66effaf`.
- Stapling succeeded and Gatekeeper reported `Notarized Developer ID`.
- `release/appcast.xml` was generated; its file length and Sparkle signature
  were verified against the final DMG.
- Final `release/BetterWispr.dmg` SHA-256:
  `a5e6584c55491a04334c6b5bfdf8654fea4cc85fdb5c28d536e0fb56b6abd4f4`.
  These files are ready for publishing; no GitHub release was published.

### Separate Apple Silicon and Intel releases — 2026-10-08

`make ship` completed for both architectures using saved Keychain credentials.
Both DMGs were notarized, stapled and accepted by Gatekeeper. Each was mounted
read-only to check the packaged executable's architecture, version and code
signature. Both appcast signatures were verified with CryptoKit against the
public key embedded in their packaged app, without reading private signing keys.

| Artifact | Apple submission | SHA-256 |
| --- | --- | --- |
| `release/BetterWispr-arm64.dmg` | `c2b32935-0d1b-4d79-8a2a-c34293bdde5b` | `750a5f3ee22fa8848f365e71bf4dfbbf674fff5d514a2324a251826f3f3fb174` |
| `release/BetterWispr-x86_64.dmg` | `d9d9a12c-0e71-4bcf-bde3-2e6962ed6d6f` | `0b7adcb99fa69f58413e128ff06f7d73c893adf99036f88c04c57362c6bd0275` |

- Native `make test` passed, including regression checks for architecture
  selection, separate submissions, feed requirements and failures in either build.
- The website's type checks, production build and all 12 static-page checks
  passed with separate Apple Silicon and Intel download links.
- The Intel CLI ran under Rosetta with networking denied. Parakeet v3 returned
  the synthetic sentence "This is a local release test. The meeting is on Friday."
  and an empty result for digital silence.
- Intel unit tests compiled, but this Xcode installation has an ARM-only
  `swiftpm-testing-helper`, so it cannot load the Intel test bundle. The Intel
  unit suite did not run. Physical Intel hardware and minimum-macOS behavior
  remain unverified; the Rosetta smoke tests do not establish those results.

Logs: `.build/release-check/dual-arch-release.log`, `native-tests.log`,
`intel-tests.log`, `intel-speech.log` and `intel-silence.log`. Neither the GitHub
release nor the updated website has been published in this check.

## Validation record — 2026-10-08

Environment: Apple M5, macOS 26.6.2 (25G83), development working tree.

- Native Swift build succeeded; all three Swift tests and the Python evaluator
  checks passed. The app bundle was packaged, its ad-hoc code signature verified,
  and the native app launched and visually inspected in a screenshot.
- Downloaded Whisper Tiny and its tokenizer explicitly, then ran file recognition
  in a **fresh process with networking denied** by `sandbox-exec`. The public
  [whisper.cpp JFK sample](https://github.com/ggml-org/whisper.cpp/blob/master/samples/jfk.wav)
  (11 seconds, 16 kHz mono Int16) produced:

  > And so my fellow Americans ask not what your country can do for you ask what you can do for your country.

  One run took approximately **1.17 seconds including model loading**. This is
  a single functional smoke test, not a general accuracy or latency benchmark.
- A two-second digital-silence WAV produced an empty transcript with exit code 0
  under the same network restriction after the shared silence guard was added.
- After `--download-phrase-booster` (99 MB), Parakeet v3 with networking denied
  transcribed a `say`-synthesized clip with `--language en --vocabulary
  "Granola,Vercel,Supabase,MDX"` and spelled all four terms as listed. Without
  the vocabulary it wrote "granula", "Versal" and "Superbase". On a second clip,
  `--language de` left the listed names misspelled, as intended for the
  English-only booster. Single runs on synthetic audio, not an accuracy
  measurement.
- **Not exercised:** live microphone dictation, interactive permission prompts,
  automatic paste/clipboard restoration, and a representative accuracy corpus.
  The manual checks below remain pending even where a related file test passed.

Reproduce the local file checks after building the CLI:

```sh
swift build --product BetterWisprCLI
.build/debug/BetterWisprCLI --download-model parakeet-v3
curl -fL https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/samples/jfk.wav -o /tmp/betterwispr-jfk.wav
sandbox-exec -p '(version 1) (allow default) (deny network*)' .build/debug/BetterWisprCLI --transcribe-file /tmp/betterwispr-jfk.wav --model parakeet-v3 --language en
python3 -c 'import wave; w=wave.open("/tmp/betterwispr-silence.wav","wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(64000)); w.close()'
sandbox-exec -p '(version 1) (allow default) (deny network*)' .build/debug/BetterWisprCLI --transcribe-file /tmp/betterwispr-silence.wav --model parakeet-v3 --language en
```

Downloads happen before the restricted process. Test audio is not committed to
the repository. `sandbox-exec` is a macOS development verification tool, not the
app's runtime sandbox or a cross-platform test dependency.

## Phrase booster validation record, 2026-10-10

Environment: Apple M5, macOS 26.6.2 (25G83), debug app bundle from the working
tree on top of 836452d, Parakeet TDT v3 with the phrase booster installed,
English, Light cleanup, Left Option hold-to-talk, MacBook Pro microphone and
speakers.

- `swift build`, `swift test` (98 tests) and `python3 Tests/evaluate_check.py`
  passed. With the guard for widened replacements disabled,
  `boostedReplacementsNeverSwallowNeighbouringWords` failed.
- The running build was quit and the rebuilt bundle launched. Vocabulary showed
  "Phrase booster is on", and "Supabase" and "Vercel" were added through the
  Add a Word form.
- With an empty TextEdit document focused, a script held Left Option, played
  "We deploy the frontend on Vercel and keep the data in Supabase." through the
  speakers with `say -v Samantha` and released. TextEdit received "We deploy the
  front and on Vercel and keep the data in Supabase." about 0.7 s after the
  release, and the history entry recorded 2 vocabulary fixes. The clipboard held
  the dictation briefly, then matched the earlier image clipboard byte for byte
  1.5 s later.
- "We should render the page before the release and say thanks to everyone."
  was pasted unchanged with 0 vocabulary fixes, and the clipboard was restored.
- Holding Left Option, speaking, then pressing Escape in BetterWispr showed
  "Transcript cancelled" with Undo. Nothing reached TextEdit within 7 s, no
  history entry was added and the clipboard was unchanged.
- **Not exercised:** a human voice at the microphone, Bluetooth headsets,
  non-English live dictation, Undo after cancellation, switching apps during
  transcription, and the network-denied run with the new floor. Synthetic
  speech played through speakers is not a measure of accuracy.

## Automated checks

```sh
swift build
swift test
python3 Tests/evaluate_check.py
python3 Tests/release_check.py
./scripts/build-app.sh
```

Inspect failures and preserve exact commands/results. Swift tests cover only the
behaviors asserted in `Tests/BetterWisprCoreTests/`; the Python check covers
scoring, Unicode normalization, empty references, invalid input and the evaluator
CLI. Neither recognizes microphone audio.

Release script checks use stub tools to exercise Keychain setup arguments,
credential preflight, notarization failure handling and bounded Finder-busy
retries. They do not access Keychain, mount disk images or submit to Apple.

## First launch and permissions

- [ ] Launch the packaged app with `./scripts/run.sh`; the dashboard and menu-bar
  entry appear without requiring an account.
- [ ] Start with microphone permission denied. No recording proceeds; the app
  gives a useful recovery path. Grant permission in System Settings and retry.
- [ ] Deny Speech Recognition permission for the Apple provider. It reports the
  denial; Whisper remains usable after its model is installed.
- [ ] Choose a locale without available Apple on-device support. The app reports
  unavailability and does not send audio to a server.
- [ ] Deny Accessibility. Dictation and manual copy remain usable; automatic
  insertion explains its permission requirement rather than pretending it worked.

## Disk image and first launch

- [ ] Run `bash scripts/create-dmg.sh .build/debug/BetterWispr.app /tmp/BetterWispr.dmg`
  and open the DMG in Light and Dark Mode. BetterWispr and Applications sit either
  side of the arrow, their Finder labels are readable, and the install line stays
  visible with Finder's path bar shown.
- [ ] Drag BetterWispr to Applications and open it. The welcome guide appears once.
  Quit on the model step and relaunch; the guide reopens on that step. Finish it,
  quit and relaunch; the dashboard opens. Help > Show Welcome Guide replays it.
- [ ] Upgrade from 0.1.0 after finishing its welcome guide. The dashboard opens and
  `defaults read org.betterwispr.app onboardingCompleted` no longer finds the key.
  Move the workspace folder aside and relaunch; the welcome guide appears.
- [ ] In the welcome guide, download Parakeet TDT v3, then press ⌥ Space and Escape
  while it downloads. The download continues, the percentage only rises, and the
  model becomes active. Cancel a second download and retry it after a network drop.

## Recording, capsule and cancellation

- [ ] Leave Settings → App → Show in Dock off, the default. The Dock icon stays hidden while
  the menu bar icon remains. Close the dashboard and dictate into TextEdit with
  ⌥ Space in hold and toggle modes; the capsule must not steal focus and paste
  must still reach TextEdit. Reopen Dashboard and Settings from the menu bar.
  Quit and relaunch; Dock visibility stays off and the shortcut works. Turn
  Show in Dock back on; the icon returns and stays on after relaunch. Repeat
  with Open at login enabled after logging in.
- [ ] Focus a TextEdit document, press **Option–Space**, speak a distinctive sentence,
  and press it again. The capsule appears at bottom center without stealing focus;
  level animation responds to actual microphone input. Final text is recoverable.
- [ ] Check the built-in mic and one external input. Verify audio rate/channel
  conversion by comparing a short recording with the recognized text.
- [ ] Try 1-second, 10-second and longer dictation. Say a word immediately at start
  and another immediately before stop; neither boundary should disappear.
- [ ] Record silence, fan noise and keyboard clicks. Log any inserted text; do not
  assume an energy threshold is a reliable speech detector.
- [ ] Repeat rapid start/stop, stop while preparation is pending, and cancel during
  recording/recognition. Only one session is active; no later transcript is pasted
  after cancellation. The microphone indicator turns off.
- [ ] With the dashboard focused, click Start Dictating, then press Escape.
  It returns to Start Dictating with "Cancelled.", adds no history entry and
  offers Undo for five seconds when speech was captured, then removes the
  session's temporary audio. Escape still cancels shortcut capture
  in Settings without changing the saved shortcut.
- [ ] With TextEdit focused, speak and press Escape during toggle-mode recording,
  during transcription, and while still holding ⌥ Space in hold mode. Each shows
  "Transcript cancelled" with Undo and pastes nothing. Once the capsule is idle,
  Escape reaches TextEdit again. Escape never stops a running notetaker. With a
  ⌘ ⌥ dictation shortcut, ⌘ ⌥ Escape still opens Force Quit while dictating.
  With an Fn shortcut, pressing Esc while holding Fn cancels.
- [ ] Hold mode: Settings > Shortcut names it "Hold or tap" and its caption
  explains both. Hold ⌥ Space, speak, release. The 96 × 28 point glass capsule
  shows only the wider waveform, with no cancel or finish buttons. Text is
  inserted once. Tap ⌥ Space briefly; recording stays active hands-free and
  expands to the 108 × 28 point pill with separate × and ✓ controls.
  Release before the bars move; it shows "Keep holding ⌥ Space." and pastes nothing.
- [ ] Toggle mode: press ⌥ Space once and speak. The 108 × 28 point capsule has
  nine waveform bars, a gray × button and a white ✓ button. The circles are
  18 points across with 24-point hit areas. Clicking ✓
  finishes, as does pressing ⌥ Space again; clicking the waveform does nothing.
  During preparation/transcription, × works and ✓ is disabled.
- [ ] Cancel capture or transcription using ×, Escape or the menu. The capsule
  morphs into "Transcript cancelled", with Undo when audio is recoverable and
  a five-second progress line. Undo transcribes that audio once with its original
  model/settings/destination. Switching apps still prevents automatic paste.
  Expiry, dismissal, quitting or a new session discard the cancelled audio.
  Cancel before capture starts or after delivery begins: no Undo is offered.
- [ ] With Dictation sounds enabled, a start cue plays once when the capsule
  switches to Listening, and finishing, cancellation and errors play quiet cues
  after microphone capture stops. No start cue plays when starting fails
  (microphone denied, no input, model missing). Turning the setting off silences
  them; recording meeting audio also suppresses them. Start a new dictation during
  a cue: playback stops before capture. Check reduced motion and increased contrast.
- [ ] Dictate past 9:30 in toggle mode with Parakeet, Whisper, Apple and an API
  connection. At 9:30 the capsule shows "Stops in 0:30" and counts down, and
  VoiceOver says "Dictation stops in 30 seconds." At 10:00 dictation finishes on
  its own and pastes the whole transcript. Hold mode behaves the same while held.
- [ ] Meeting recording uses a 100 × 26 point pill, thirteen waveform
  bars, green border and stop square. Clicking it still stops the notetaker.
- [ ] Keep another app focused and hover the microphone, notetaker icon and chevron.
  The tooltip changes to "Dictate" with the shortcut, "Start notetaker" and
  "Open meeting notes" respectively. Move between them and then away; tooltips
  update without flickering and the controls collapse without taking focus.
- [ ] Trigger a dictation error and a notetaker error. Each replaces the pill with
  one rounded glass card, with a warning/title row, message below and a dismiss
  button. Accessibility errors keep the Allow action; errors during a meeting
  retain Stop notetaker. Check reduced motion, reduced transparency and increased contrast.
- [ ] In Settings, click the keyboard shortcut and press a new combination such as
  ⌃⌥D. ⌥ Space no longer starts dictation; the new shortcut works in hold and
  toggle mode and is still set after relaunch. While recording a shortcut, Esc
  cancels and keeps the old one. Held modifiers show on the button as you press
  them. A letter alone or with only ⇧, or multiple modifiers released without
  a key are refused with feedback. An F-key alone such as F5 is accepted.
  A shortcut another app holds shows a toast and the old one keeps
  working. Reset restores ⌥ Space.
- [ ] In Settings, press and release left Option alone. With Accessibility enabled,
  it saves as Left Option, works in hold and toggle mode inside BetterWispr and
  TextEdit, and survives relaunch. Repeat for right Option, Control, Shift and
  Command, and for Fn (🌐), which saves as Fn. Fn with ⌘ or another modifier, and
  arrow or F-key presses while holding Fn, must not start dictation. The
  opposite-side key alone must not trigger dictation. Releasing the
  chosen key must finish hold mode even if another modifier is down. Recording
  ⌥ Space must still save the combination, not Option alone. Cancelling capture,
  leaving Settings and resetting must remove the temporary listeners.
- [ ] With Accessibility denied, selecting a modifier-only shortcut explains the
  required permission and keeps the previous shortcut. Revoke permission with a
  saved modifier shortcut, relaunch, then grant it again and return to BetterWispr;
  the saved shortcut resumes working. Ordinary combinations remain available.
- [ ] On a fresh install, open Settings > Shortcut and confirm the Cancel
  shortcut is empty and its caption says Escape still cancels. Record ⌃⌥K. With
  no dictation running, confirm ⌃⌥K still reaches other apps. Start a dictation
  into another app, press ⌃⌥K, and confirm the capsule shows Cancelled, no text
  is pasted, audio cleanup runs and Undo restores the recording. Confirm ⌃⌥K
  reaches other apps again once the capsule closes, and Escape still cancels.
- [ ] Try to record a modifier alone (such as Left Option) as the Cancel
  shortcut and confirm a toast refuses it and the setting is unchanged. Try the
  dictation shortcut as the Cancel shortcut, and the Cancel shortcut as the
  dictation shortcut, and confirm each is refused with a toast and both stay
  as they were. Try a combination another app holds and confirm the failure
  toast. Clear turns the Cancel shortcut off, and relaunching keeps the setting
  you left, set or cleared.
- [ ] Disconnect the input device during capture; retry after reconnecting.
- [ ] Move between Spaces, fullscreen windows and monitors. Confirm capsule
  positioning, keyboard controls, VoiceOver labels and reduced-motion behavior.

## Pausing music while dictating

Manual checks. Unit tests cover the pause and resume bookkeeping with a fake
player; real playback and the Automation prompt need these steps.

- [ ] Music playing: open Music, turn on Settings → App → Pause music while
  dictating and allow the Automation prompt. Play a track and dictate. Music
  pauses when the capsule appears and resumes as soon as the recording stops.
  Repeat with a dictation cancelled with Escape and with "No speech heard."
- [ ] Spotify playing: repeat the check with Spotify.
- [ ] Nothing playing: with Music and Spotify paused or stopped, dictate. Neither
  starts playing afterwards. With Music paused and Spotify playing, only Spotify
  resumes.
- [ ] Play Music again yourself during a dictation. It keeps playing when the
  dictation ends. Known limit: a track you pause yourself during a dictation
  looks the same as one BetterWispr paused, so it resumes.
- [ ] Automation permission denied: deny the prompt, or turn the app off under
  Privacy & Security → Automation. Dictation works normally, the music keeps
  playing and no prompt or error appears during dictation.
- [ ] App not open when the toggle was turned on: turn the setting on with
  Spotify closed, then open Spotify, play and dictate. No prompt appears during
  dictation and Spotify keeps playing. Turning the setting off and on with
  Spotify open asks for permission. A closed app is never launched.
- [ ] Quit mid-dictation: start dictating while Music plays and quit from the
  menu bar. Music resumes and BetterWispr quits.
- [ ] Quick tap: tap the shortcut, cancel at once and start again. Music is
  paused during the new recording and resumes after it; it never plays while
  the microphone is open.
- [ ] Start meeting notes while Music plays. Music keeps playing.

## Clipboard and insertion

- [ ] Start with a known clipboard string, dictate into TextEdit and verify final
  insertion. Paste manually afterward: with "Copy to clipboard" on the transcript
  pastes again, with it off the prior clipboard was restored.
- [ ] Turn off both "Paste into the active app" and "Copy to clipboard". Dictation
  must leave the clipboard untouched and show no toast.
- [ ] While dictating or transcribing, the capsule must show only the waveform,
  never the recognized text.
- [ ] Finishing dictation plays one stop cue. Successful paste returns directly
  to idle without another sound, message or announcement. Copy-only still shows
  "Copied to clipboard"; with both output options off it shows "Transcript ready".
- [ ] Notetaker starts, stops, finishes its notes and displays errors silently.
- [ ] On a Mac without `SoundOverrides`, start, finish, cancellation and
  attention play the macOS sounds Tink, Purr, Bottle and Basso. Locally
  installed override cues (`started.wav`, `finished.wav`, `cancelled.wav`,
  `attention.wav`) replace them one by one and play from an app moved outside
  the build directory. Check quality and volume on speakers and headphones.
  Listen for the start cue in the transcript of a dictation that begins right
  after the cue on speakers.
- [ ] Repeat with a clipboard image or rich text; the app must preserve supported
  pasteboard representations, not just plain text.
- [ ] Change clipboard contents while recognition/paste is pending. New user
  clipboard contents must not be replaced by an old snapshot.
- [ ] With "Copy to clipboard" off, the pill returns to idle as soon as the text
  appears, without a spinner after the paste. Start a second dictation within
  half a second of the first paste; both transcripts are pasted, and pasting
  manually afterwards gives the clipboard from before the first dictation.
- [ ] Switch to another app while recognition is pending. It must not paste into
  the newly focused app. The capsule shows "Copied, not pasted." with the text
  and a Copy button, with a progress line that empties over five seconds before the card closes.
  ⌘V pastes the text, and Copy copies it again, closes the card and shows the
  "Copied" toast. Start a new dictation while the card is open; the card must
  give way to the recording pill and never show the earlier text again. The
  current guard checks the app process, not changes between fields inside the
  same app; record this limitation when testing.
- [ ] Quit the original destination app before recognition finishes. Verify the
  same card and no paste into a replacement app.
- [ ] Disable automatic paste. Dictation/history still work and no keystroke is
  sent to the frontmost app.
- [ ] Revoke Accessibility and dictate. The capsule shows "Copied, not pasted."
  with an Allow button. Grant it, rebuild with `scripts/build-app.sh`, and check
  that paste still works without granting again.

### Voice commands and learned corrections

- [ ] With English or Auto language, say "hello comma how are you question mark".
  Expect "Hello, how are you?" or the model's casing of it.
- [ ] Say "Send it Monday. Sorry, remove that. Send it Tuesday." Only "Send it
  Tuesday." is pasted. "Please remove that file" stays as spoken.
- [ ] In Mail, say "Write an email to Sarah saying I will be on holiday
  tomorrow, thanks, best regards" and your name. Expect "Hi Sarah,", the body
  and "Best regards," with your name on separate lines. "I will write an email
  later" stays as spoken.
- [ ] Say "I live in Ahmedabad sorry in Delhi". Expect "I live in Delhi". "Sorry
  for the wait" and "sorry in advance" stay as spoken.
- [ ] In Slack, say "ping at the rate KV". Expect "ping @KV". Whether Slack then
  opens its mention picker is Slack's behavior; record what happens.
- [ ] Say "question mark" alone until the model mishears it, for example as
  "Kocia Mark". Add that as a Vocabulary phrase written as "question mark" and
  say it again. Expect "?". "In a coma" and "at the red light" stay as spoken
  unless you added "coma" or "at the red" yourself.
- [ ] Dictate a name into TextEdit, fix the spelling within 30 seconds and wait
  about 4 seconds. Expect a "Learned" toast and a Learned entry in Vocabulary.
  Repeat in Notes and in a freshly launched Electron app such as Claude or
  Slack. The Electron field becomes readable about two seconds after the paste.
- [ ] Dictate into a chat field such as Messages or Slack, fix a word, wait about
  a second and press Return. Expect a "Learned" toast. Fixing and sending
  within a fraction of a second learns nothing, by design.
- [ ] Click Undo on a "Learned" toast. Only the words that toast named leave
  Vocabulary.
- [ ] Dictate at the start of a field that already has text after it, and at
  the end of one that has text before it, then fix a word. Both are learned.
- [ ] With Light cleanup, dictate "we can meet today" and change "meet" to
  "meat". It is learned. Switch to Medium with a notes model set up, delete the
  entry and repeat: expect no toast, while a misheard name fix still shows one
  within about 7 seconds. Stop the notes model (quit Ollama, for example) and a
  name fix is still learned by the rules.
- [ ] Fix a word with the pencil in History. The raw transcription stays
  unchanged and the word appears in Vocabulary as Learned.
- [ ] Turn off "Learn from my corrections" and repeat. Nothing is learned.
- [ ] Type in a password field after dictating. Nothing is read or learned.

### Writing modes

- [ ] In Style, add a mode for TextEdit with Casual tone. Dictate "Hello Sam. I
  will call you tomorrow." into TextEdit and into Notes. Only TextEdit uses the
  Casual tone. Turn the mode off and TextEdit uses its default tone again.
- [ ] Add a mode for `github.com` with Medium cleanup. Dictate in a GitHub tab and
  in another tab of Safari, Chrome, Arc and Brave. Only the GitHub tab uses the
  mode. `gist.github.com` matches; `notgithub.com` does not. Record any browser
  whose address is not read. Click into a page with an embedded iframe and
  confirm the page's address, not the iframe's, picks the mode. Replace the
  entry with `*.github.com` and confirm `gist.github.com` still matches.
- [ ] Check that the empty Trigger word field suggests "casual mode". Give the
  mode the trigger word "casual" and say "casual see you at five" in Notes. The
  mode is used and "casual" is removed. "I like casual clothes" keeps the word
  and uses no mode. "Let's keep it casual." uses the mode and types "Let's keep
  it.", which is expected and matches VoiceInk.
- [ ] A mode with only a trigger word shows no Screen context picker. Give the
  `github.com` mode Medium cleanup and Screen context Off while Use screen
  context is on. Dictate in a GitHub tab in Safari with a notes model that logs
  requests. No selected text, clipboard or window text is sent.
- [ ] Select Parakeet with the phrase booster, Light cleanup and Use screen
  context. Open a Slack or Messages chat that shows an unusual name such as
  Pannekeet or Supabase and say it in a sentence. Expect the on-screen
  spelling when the plain result was misspelled, ordinary words left alone,
  no Vocabulary fix counted in Insights and no request to any notes model or
  speech API. With an API speech connection selected, nothing changes.
- [ ] With Medium cleanup, add the instruction "Use British spelling." Dictate
  "the color of the organization" in the mode. Expect British spelling from the
  notes model; outside the mode, American spelling stays.
- [ ] Revoke Accessibility. Website modes stop matching, app modes still work and
  dictation is not delayed by more than half a second.

### Cleanup provider

- [ ] Choose Medium on the Style page. The Cleanup provider picker shows "Same
  as notes" with the notes model's name. Dictate an English sentence with a
  repair ("at 5, no, at 6"); the capsule says "Editing with" the notes model.
- [ ] Choose another Ollama model or a notes API connection as the cleanup
  provider. Medium dictation uses it while meeting notes and Ask keep theirs.
  The footer under Auto cleanup names that provider and no longer says it is
  the meeting notes model. Remove that API connection; the picker returns to
  "Same as notes".
- [ ] Choose Light and set the selected text shortcut. The Cleanup provider
  picker stays visible, and the footer says the shortcut sends your selection
  to it. Clear the shortcut; the picker and that sentence hide.
- [ ] Choose an unavailable cleanup provider (Apple Intelligence off, or a CLI
  with no model). The Style page shows the reason, Medium dictations get Light
  cleanup and no other provider is asked.

### Selected text cleanup

- [ ] On a fresh install, Settings > Shortcut shows "Clean up selected text"
  with "Set Shortcut…". Record ⌃⌥C. In TextEdit, select "so um we should
  probably ship it on friday i think" and press ⌃⌥C. A "Cleaning up…" toast
  names the cleanup provider, then the edit replaces the selection and the
  toast says "Cleaned up". ⌘Z in TextEdit brings the original back, and the
  clipboard holds what it held before.
- [ ] Press ⌃⌥C with nothing selected, with three words, with a French
  sentence and in a password field. Each shows its own toast and changes
  nothing. With an unavailable cleanup provider the toast gives the reason and
  no other provider is asked.
- [ ] Press ⌃⌥C, then switch apps or change the selection before the edit
  arrives. Nothing is pasted, the toast says "Copied, not pasted" and ⌘V pastes
  the edit. Click Cancel on the progress toast in another run; nothing is
  pasted or copied. Pressing ⌃⌥C while an edit runs shows the progress toast
  again.
- [ ] Press ⌃⌥C during a dictation. The toast says "Finish dictating first" and
  the dictation continues. Press ⌃⌥C with a slow provider, then start a
  dictation before the edit arrives. The same toast appears, and nothing is
  pasted or copied. Revoke Accessibility and press it; the toast offers Allow.
- [ ] Try a modifier alone, Escape with a modifier, the dictation shortcut and
  the Cancel shortcut as this shortcut, and this shortcut as the other two.
  Each is refused with a toast, and Escape's toast says Esc cancels a
  dictation. Clear turns it off, ⌃⌥C reaches other apps again, and relaunching
  keeps the setting you left.
- [ ] Repeat in Safari or Chrome text areas, Notes, Mail and Slack. Record the
  apps whose selection can't be read; they show "No selected text found".

## Dictation languages and Chinese script

- [ ] With a Whisper model and Detect automatically, Dictation languages shows
  under Spoken language; with Parakeet, Apple or a fixed language it hides.
  Pick English and Spanish, quit and relaunch, and the menu still reads
  "English, Spanish". All languages clears the list.
- [ ] With English and Spanish picked, dictate a Spanish and an English
  sentence, then speak a third language you know. The first two come out in
  their language. The third is decoded as English or Spanish, so expect a
  translation or garbled text rather than a transcript in that language.
  Note how much longer stop-to-final takes than with All languages.
- [ ] Set Spoken language to Chinese, choose Simplified, and dictate a Mandarin
  sentence; Whisper may write it in Traditional characters. The pasted text and
  History show Simplified; History's Original transcription shows what the
  model wrote. Repeat with Traditional.
- [ ] On Detect automatically with Simplified chosen, dictate Chinese and then
  Japanese. Only the Chinese dictation is converted.
- [ ] Add a vocabulary entry written in Traditional characters, choose
  Traditional, and dictate the phrase. The entry applies to the converted text.

## Offline models and failure recovery

- [ ] Install a Whisper model/tokenizer explicitly. Verify progress, local storage
  and that cancellation leaves no model falsely marked ready.
- [ ] Quit BetterWispr, disconnect networking, relaunch, select the installed
  model and dictate. A warm already-loaded model alone is not an offline-load test.
- [ ] Monitor outbound connections in an appropriate local network tool while
  preparing with downloads disabled and transcribing. No speech/model request
  should occur; account for unrelated OS traffic separately.
- [ ] With networking disabled, choose an uninstalled model. Get a clear setup
  error instead of a stalled download or silent engine switch.
- [ ] Using a disposable model copy, test a missing tokenizer file, truncated
  weights and failed/incomplete installation. Keep the working model untouched.
- [ ] Install a Parakeet model and confirm the phrase booster arrives with it.
  Delete only the booster folder, then download it from Vocabulary. Verify
  the progress state, the installed confirmation, and that a dictation with a
  listed name uses the listed spelling without relaunching. Cancel a booster
  download and confirm it is not reported as installed.
- [ ] Compare Small, Turbo and Large v3 on the same clips; record peak memory,
  first load, warm inference and stop-to-final time. Test cancellation under load.
- [ ] Set Unload speech model when idle to 5 minutes with Turbo loaded. After
  five idle minutes, Activity Monitor shows BetterWispr's memory drop; the next
  dictation loads the model again, offline, and transcribes. A dictation or
  transcription in progress at the five-minute mark keeps the model until it
  finishes. Waking the Mac or unlocking the screen does not load it again.

## Local history and privacy

- [ ] Enable history, dictate, relaunch and confirm raw/final text and settings
  persist. Dashboard totals derive from actual saved sessions.
- [ ] Disable history, dictate again and relaunch. That new transcript must not
  have been persisted. Delete existing history entries explicitly and verify
  they stay deleted after relaunch.
- [ ] Verify temporary audio removal after success, error and cancellation. Force
  termination is a separate check: record whether recovery removes orphaned files.
- [ ] In a temporary profile, supply malformed JSON or an unsupported schema
  version. The app reports the problem and preserves the original file.
- [ ] Add vocabulary with punctuation, accented letters, Hindi combining marks,
  overlapping phrases and literal `$`/backslash text. Confirm whole-word matching,
  no cascading replacements and access to the original transcription.

## Bring your own model / API connections

Automated coverage uses synthetic audio and stub HTTP responses. It checks old
settings decoding, URL/key validation, the three request/response formats,
48 kHz stereo CAF conversion to 16 kHz mono WAV, Sarvam chunk coverage, real
Keychain insert/read/rotation/deletion using disposable test keys, redirect
refusal, no requests in preparation, and cancellation of an in-flight request.
These checks do not establish live provider acceptance or recognition quality.

- [ ] Add Sarvam and Smallest connections using your own keys. Saving makes no
  request. Select Use and dictate, then start a meeting with each provider.
  For Smallest choose an explicit spoken language; Pulse Pro needs English.
- [ ] Select an unsupported language or Smallest with automatic language. The
  error appears before recording begins, and no audio is uploaded.
- [ ] Dictate longer than 30 seconds with Sarvam. Confirm the full transcript and
  inspect words around each 25-second boundary; fixed cuts may affect recognition.
- [ ] Connect an OpenAI-compatible server over localhost HTTP without a key, then
  an HTTPS endpoint with a Bearer key. Confirm both dictation and meeting chunks.
- [ ] Relaunch with a selected connection. Its selection persists; its key is
  absent from workspace JSON and history exports. Rotating/removing a key takes
  effect on the next recording. Editing the URL requires a new key and selecting
  Use again if the edited connection was active.
- [ ] Try an invalid key, quota error, unsupported model, malformed JSON, stopped
  local server and redirect. Surface a useful error without exposing response
  bodies or credentials. Never switch to another endpoint automatically.
- [ ] Cancel during upload/response and rapidly start another recording. No late
  result enters history or gets pasted; temporary audio is removed. Quit during
  an API meeting and verify the same cleanup.
- [ ] Select a built-in model and disconnect networking. It still runs locally;
  neither saved connections nor Keychain configuration trigger network requests.

## Updates

- [ ] Settings shows the installed version under About. "Check for Updates…" in
  About and in the app menu opens Sparkle's update window and is disabled while
  a check is already running.
- [ ] Change both update toggles, quit and relaunch. Both keep their values, and
  "Download and install automatically" is disabled while automatic checks are off.
- [ ] Install an older signed release, publish a newer GitHub release with its
  `appcast.xml`, then check for updates. The older build downloads, verifies and
  installs the newer one and relaunches at the new version.
- [ ] With automatic installs off, leave the older build running in the
  background past a scheduled check while another app is active. A toast offers
  Update, the menu bar shows "Install BetterWispr" with the new version, and
  either one brings Sparkle's update window to the front.
- [ ] With automatic installs on, let a scheduled check download the update. A
  Restart toast and the menu bar item appear, and either one installs the update
  and relaunches at the new version.
- [ ] Turn off automatic checks and relaunch. A network monitor shows no request
  for the appcast until you choose "Check for Updates…".

## Meeting notes

Validation on 2026-10-08 for BYOK/subscription notes:
- `swift build`, `swift test` (61 tests, live-provider test disabled by default),
  and `./scripts/build-app.sh` passed. Added checks cover old settings/summary
  decoding, real CAF chunk writing and conversion through stubbed speech/notes HTTP,
  raw transcript persistence and export, malformed/failed/truncated responses,
  cancellation, CLI process timeout/large output/interactive replies, model catalog
  parsing and explicit selection persistence, long thoughts and echo filtering.
- `BETTERWISPR_LIVE_NOTES=1 swift test --filter liveNotesProvidersGenerateFromSyntheticMeeting`
  passed all three provider cases using synthetic text: signed-in Claude Code,
  signed-in Codex, and Ollama's OpenAI-compatible HTTP endpoint with `llama3.1:8b`.
  Requires both CLIs already signed in and that Ollama model already installed;
  this command never downloads models. A first local-API run exposed an invalid
  structured response; JSON-object output plus explicit string/array types in the
  prompt fixed the observed schema mismatches before the passing run.
- Native capture test: Parakeet v3 recorded microphone (Me) and synthetic playback
  through the system-audio tap (Them), stopped, and automatically generated a saved
  Ollama summary with decisions and an action item. Speaker audio was also picked
  up by the microphone; the new filter hid the matching Me segment after relaunch.
- The Models “Test notes model” button returned a real Claude summary. The saved
  test meeting was then updated with a synthetic QA thought and regenerated with
  Claude Code. This checks combined thoughts/transcript input, not recognition
  accuracy. No live cloud API key endpoint was exercised.
- Native model pickers showed all 12 Claude and 7 Codex models reported by the
  installed CLIs. Choosing Claude Sonnet and testing returned a summary labeled
  `claude-sonnet-5-5`; live tests also checked explicit default-model generation
  and summary provenance for both CLIs. Catalog counts depend on the CLI/account.
- After relaunching the final packaged app, the saved synthetic meeting regenerated
  with `Claude Code · claude-sonnet-5-5`. Its summary combined the spoken Friday
  launch/$500 budget with the personal QA sign-off thought. The selected model
  survived the relaunch and the summary footer showed the exact model ID.

Additional regression checks:
- [ ] Add a notes API connection using a complete chat-completions URL, custom
  model ID and key. Saving sends nothing; select it under Notes model and test.
  Rotate its key, change its URL, remove it and relaunch. Speech selection stays
  unchanged, keys stay in Keychain, and an edited active URL needs selection again.
- [ ] Add a notes API connection and pick each Provider preset. Name, URL and
  model ID fill in, a typed key clears, and Custom keeps the URL with an empty
  model ID. Save each with its provider's key, select it and test. Editing a
  saved connection shows no Provider menu.
- [ ] Select Claude Code or Codex, choose a discovered model or enter an exact ID,
  and test. Refresh the catalog and relaunch: the chosen ID should stay selected,
  and generated summaries should name it. Signed-out, missing/outdated CLI and subscription-limit failures should
  be actionable without exposing provider output or starting another provider.
- [ ] Edit thoughts during summary generation. The completed summary should be
  marked for update until regenerated with the new text. Cancel generation and
  verify the previous summary remains intact with no late replacement.
- [ ] Take a call on speakers. Stay quiet while the other side talks, then
  answer while they are still talking. The transcript removes your microphone's
  copy of their words and keeps your answer; "Show repeated microphone audio"
  shows the original. Repeat a sentence of theirs a minute later; it stays.
- [ ] Say a sentence, pause for a second, and watch the "Me" entry appear within a
  few seconds, with the built-in microphone, AirPods and a USB microphone, in a
  quiet and a noisy room. Talking without a pause still adds an entry at least
  every 20 seconds.


UI validation on 2026-10-08: inspected the packaged native app in dark appearance
with a temporary synthetic meeting. Verified the meeting sidebar, separate
My thoughts / Transcript / Summary tabs, transcript search, the Parakeet v3
selection, and persisted thoughts and action-item edits. Removed the synthetic
meeting afterwards. `swift build`, all 40 Swift tests, and app packaging passed.
Live capture, summary generation, compact-window layout, and the OS checks below
were not exercised in this UI pass.

- [ ] Resize to the minimum window size; all three tabs and recording controls
  stay usable, and the current-note column hides instead of squeezing the list.
  Search notes, open a note, step with the arrows, and return with the back button.
- [ ] Select an installed model in the Notetaker settings menu, start a meeting, and
  confirm the header identifies that model. Missing models must require an
  explicit installation in Models; starting a meeting never downloads them.

- [ ] Close the dashboard and hover over the floating capsule. The meeting button
  appears in its own capsule beside the microphone, with "Start notetaker" on hover.
  Its chevron opens Meetings without starting a recording. Click the record icon: the
  meeting card docks on the right and recording starts. Move the pointer away: the
  single waveform/stop capsule stays visible and stops capture when clicked;
  the microphone and chevron are hidden throughout notetaker capture.
  The green outline appears only during notetaker recording, never during dictation
  or while the notetaker is still starting. While
  finishing or writing notes, a second meeting cannot be started. With an
  uninstalled model selected, the button opens Models with the download message.
- [ ] Start the first meeting on macOS 14.2 or later. macOS asks for system audio
  access with the `NSAudioCaptureUsageDescription` text. Allow it, play a video
  call or any audio, and confirm "Them" transcript entries appear and the Them meter moves.
- [ ] Deny system audio access, start a meeting and talk for 20 seconds. The
  banner shows the call audio hint, and Open Settings opens Screen & System
  Audio Recording. Me transcript entries still appear.
- [ ] Hold a call through headphones, then through the built-in speakers. With
  speakers, note how often the other side's words also appear as "Me" through
  the microphone. Record the result; do not assume either way.
- [ ] Start a meeting on the built-in microphone, then connect AirPods or another
  headset and choose it from the card menu mid-meeting. Both meters keep moving and new Me and Them entries keep
  appearing after the switch.
- [ ] With Microphone set to Automatic, connect and disconnect AirPods and a USB
  mic during a meeting. The card's microphone label follows the macOS default
  input each time, AirPods included, and Me entries keep appearing. Pick a
  specific mic from the card menu mid-meeting; capture switches to it without
  stopping the meeting.
- [ ] With Microphone set to Automatic and AirPods as the macOS input and
  output, play a video and dictate. The picker shows "Automatic" with the
  AirPods name, the waveform follows your voice, and playback drops to call
  quality only while recording and recovers after it stops. Choose the built-in
  microphone in Settings and repeat; the video keeps full sound quality.
- [ ] With Microphone set to Automatic and AirPods as the macOS input, start a
  meeting with the lid open, then close the lid on an external display. Me
  capture stays on the AirPods and keeps producing entries, before and after
  the lid opens again. Repeat during a dictation; speech from before and after
  closing the lid is transcribed.
- [ ] With the AirPods chosen in Settings, start dictation. Repeat immediately
  after connecting them and after an app starts/stops headset playback. The
  waveform moves and stopping produces a nonempty recording. Repeat with a USB microphone.
- [ ] During dictation, change the macOS default input between the built-in mic
  and a USB mic, then choose the AirPods in Settings and disconnect/reconnect
  the headset. Speech captured before
  and after each switch is retained at the correct speed. Repeat with the AirPods
  as the macOS default; Automatic records from the AirPods.
- [ ] During a meeting, repeat those switches and headset profile changes.
  "Me" capture resumes, earlier chunks remain, offsets stay ordered, and
  "Them" capture continues. Repeat with a specifically selected microphone.
- [ ] Stop or cancel immediately during a device switch in both dictation and
  meetings. No delayed retry reactivates the microphone or adds a stale result.
- [ ] Make every input unavailable during capture. Dictation reports a capture
  failure after its retries; meetings report the microphone issue and keep
  system audio running. Reconnecting an input resumes the meeting microphone.
- [ ] Choose a USB mic in Settings, unplug it, and dictate. Dictation uses
  Automatic; the picker shows the mic as "(not connected)". Plug it back in
  and it is used again without reselecting. Repeat with saved AirPods turned
  off and another Bluetooth headset as the macOS input; dictation records from
  that headset.
- [ ] The microphone list in Settings and in the card matches System Settings,
  Sound, Input, and never lists "CADefaultDeviceAggregate" or
  "BetterWispr Meeting Audio", including while a meeting is recording.
- [ ] Start notetaker from the capsule and from the menu bar with another app
  focused. A card docks to the right edge of the current screen without stealing
  focus. The expand button opens the meeting in the dashboard and closes the
  card; deleting the meeting closes the card.
- [ ] Record a meeting of 30 minutes or more. The transcript keeps up within a
  few chunks, memory stays bounded, notes are written, and the meeting file
  reopens after relaunch.
- [ ] Quit BetterWispr from the menu bar mid-meeting. The meeting is kept with
  the segments transcribed so far and a duration, and no
  `betterwispr-meeting-*.caf` files remain in the temporary folder.
- [ ] With Apple Intelligence on, stop a meeting and confirm the summary, key
  points, decisions and action items. Ticking an action item survives relaunch.
  A title you typed before the notes were written is kept.
- [ ] With Apple Intelligence off or unsupported, stop a meeting. The transcript
  and notes are saved, and Generate summary is disabled with the reason shown.
- [ ] With Apple Intelligence, generate notes for a meeting of 10 or more parts.
  Notes are written for the whole meeting instead of "The model couldn't condense
  this meeting enough". The notes model picker beside Generate summary is
  disabled while any meeting is processing, and choosing another model there
  changes the model that writes the next summary.
- [ ] Start Notetaker from the dashboard. The card docks beside the call, and the
  dashboard stays on the list instead of showing the live transcript. Stop the
  meeting; the dashboard opens the finished note on its Summary tab.
- [ ] With Ollama running and a model pulled, choose it under Notes model in the
  Notetaker settings menu. Stop a meeting; the title and summary are written by
  that model. Embedding and cloud models are not listed. Quit Ollama and Generate
  summary says Ollama isn't running; Apple Intelligence is never used instead.
- [ ] Disconnect networking, then start, record, stop and summarize a meeting with
  an installed model. Everything works and a network monitor shows no requests.
- [ ] Back-to-back meetings: stop a meeting with speech in its last seconds and
  start the next one at once. The capsule offers the next call, the docked card
  switches to the new meeting, and the first meeting's row shows Transcribing,
  Finding speakers and then Writing summary. Its last words stay in its own
  transcript and never appear in the new one. The new meeting records and
  transcribes normally, and the dashboard does not jump to the first note while
  the new one records.
- [ ] Back-to-back meetings: cancel the new meeting while it says Preparing. The
  first meeting still finishes its transcript and notes. Repeat with Cancel on
  the first meeting's Writing summary step; the new meeting keeps recording.
- [ ] Back-to-back meetings: quit mid-overlap. Both meetings are kept with their
  durations and no `betterwispr-meeting-*.caf` files remain in the temporary
  folder.
- [ ] Open a meeting with a transcript and thoughts, choose Ask and ask about
  something said in it. The answer names the lines it used, "Answered with"
  shows the Ask model, and a question the meeting does not cover says so
  instead of inventing an answer.
- [ ] Click a transcript citation: the Transcript tab opens with that line
  tinted and scrolled into view, even with transcript search text entered.
  Click a My thoughts citation: My thoughts opens. Repeat in the docked card.
- [ ] On the Notetaker page, ask a question answered in an older meeting. The
  citation shows that meeting's title, and clicking it opens the meeting on the
  cited line. Go back; the question and answer are still there.
- [ ] Choose a different Ask provider in Models and in the Notetaker settings
  menu. Ask uses it while summaries keep the notes model; "Same as notes"
  follows the notes model again. Select a notes API connection for Ask, then
  remove it or change its URL; Ask returns to "Same as notes".
- [ ] Choose an unavailable Ask provider (Apple Intelligence off, or a CLI with
  no model). The Ask field is disabled with the reason, and no other provider
  is asked.
- [ ] Ask with a slow model, then press Cancel, go back to the list, or open
  another meeting before it answers. The request stops (no CLI process left, no
  late answer appears) and a new question can be asked.
- [ ] Back-to-back meetings: while the first meeting still shows Transcribing,
  Finding speakers or Writing summary, open it and choose Ask. The field reads
  "Ask about the transcript so far", the answer cites lines already shown, and
  the Ask tab stays open when the summary finishes. Ask on the Notetaker page
  during the overlap; lines from both meetings can be cited.
- [ ] Ask about one meeting and about all meetings, then quit and relaunch. Both
  threads come back with their citations and "Answered with" lines, and their
  citations still open the cited lines. A failed or cancelled question is gone.
- [ ] Press Clear on each thread. A confirmation appears, Clear empties only that
  thread, and it stays empty after a relaunch. Clear on a failed question with no
  saved answers removes it without asking.
- [ ] Quit, replace `~/Library/Application Support/BetterWispr/ask.json` with
  invalid JSON and relaunch. The Notetaker page says it couldn't be read, meetings
  still load, asking still works, and the file's bytes are unchanged after quit.
- [ ] Ask on the Notetaker page about two meetings, then delete one of them. The
  answers citing it disappear, and the others remain after a relaunch.
- [ ] While a meeting records for more than five minutes, open its Ask tab and
  press What did I miss?. The answer cites only lines from the last five
  minutes and no My thoughts. Within the first seconds, before any line, it says
  nothing was transcribed. The button is gone once recording stops.
- [ ] On the Notetaker page, set When to Today, Past 7 days and Past 30 days,
  and With to one invitee. Answers cite only matching meetings. A combination
  with no meetings shows "No meetings match these filters." and disables Ask.
  With no Calendar invitees in any meeting, the With menu is hidden.

### Calendar events

Automated tests cover choosing the event, video link detection, the invite text
given to the notes model, invitee names in the meeting's speech hints,
discarding a cancelled event meeting, and loading settings and meetings saved
before Calendar. None of them touches EventKit or the
permission prompt. Run these checks on a Mac whose Calendar app has at least an
iCloud or local calendar, a Google or Exchange account, a calendar shared with
you, and a subscribed calendar. Reset the permission first with
`tccutil reset Calendar org.betterwispr.app`.

- [ ] Launch the packaged app, finish onboarding and start and stop a meeting with
  Use Calendar off. macOS never asks for Calendar access, and Settings lists no
  calendars.
- [ ] Turn on Use Calendar in Settings. macOS asks once, with the
  `NSCalendarsFullAccessUsageDescription` text. Allow it. Every calendar that
  Calendar shows appears under its account, shared and subscribed calendars
  included, each switched on. The Calendar row under Permissions shows granted.
- [ ] Reset the permission, turn Use Calendar on and deny. The toggle turns back
  off, the Calendars pane of Privacy settings opens, and starting a meeting gives
  an untitled note as before. The Calendar row under Permissions opens the same pane.
  Allow BetterWispr there without quitting it, come back and turn Use Calendar on.
  The calendars appear without a relaunch.
- [ ] Grant access, then create a timed event starting in three minutes with two
  invitees and a Zoom link. Start a meeting. The note takes the event title, and
  the meeting header lists the invitees, without you and without rooms. Stop it.
  The written notes keep the event title. Record whether the summary names the
  invitees who spoke and leaves out those who did not; do not assume either way.
- [ ] Overlap that event with one without a video link that started later. The
  meeting takes the event with the Zoom link. Decline the Zoom event, or have its
  organizer cancel it, and start again. The meeting takes the other event.
- [ ] Turn off the event's calendar in Settings and start a meeting. The note is
  untitled and lists no one. Turn it back on and relaunch; the choice persists.
- [ ] Repeat the event check with an event on a shared calendar and on a
  subscribed calendar, then with an all-day event only. Shared and subscribed
  events name the note; the all-day event does not.
- [ ] Disconnect networking and start a meeting during an event already synced.
  The note still takes its title and invitees, and a network monitor shows no
  requests from BetterWispr.
- [ ] Start a meeting during an event and cancel it before anything is
  transcribed. The note is discarded, not kept with only the event title.
- [ ] Revoke access in System Settings while Use Calendar is on and switch back.
  The Permissions row shows Calendar as not granted, the calendar list is gone,
  the Use Calendar caption asks for access, and new meetings are untitled. Allow
  BetterWispr again in System Settings, leaving the toggle on, and switch back.
  The calendars return without a relaunch, and a new meeting takes the event.
- [ ] With access granted and every calendar on, click Start Notetaker during an
  event. The window keeps responding while the note starts. Double-click Start
  Notetaker; only one meeting starts.

### Connected apps

`MCPServerTests` drive `MCPServer.reply(to:)` with temporary folders. They cover
the handshake, the tool list, each tool, paging, date ranges, the refusal while
the setting is off or the workspace is unreadable, skipped meeting files and
protocol errors. `python3 scripts/mcp-smoke.py` runs the built bundle with
`--mcp` against a temporary home with one synthetic meeting and prints the
exchange. Neither one opens Settings or connects a real AI app. Use meetings you
are willing to send to that app's provider.

- [ ] In Settings > Connected apps, the toggle is off on a new install and after
  updating from 0.1.5. Turn it on. The Claude Code, Claude Desktop and Cursor,
  and Other apps rows appear, each with the path of the running app. Each Copy
  button copies its snippet, and VoiceOver reads "Copy Claude Code setup".
- [ ] Run the copied `claude mcp add` line, start Claude Code in a different
  folder and run `/mcp`. betterwispr shows as connected with three tools. Ask for the last meeting's
  action items. Claude calls `list_meetings` and `get_meeting`, and the answer
  matches the meeting in BetterWispr.
- [ ] Add the copied snippet to Claude Desktop's config, keeping any servers
  already there, and restart it. Ask it to search meetings for a phrase said in
  one of them and to open the match. Repeat with Cursor's `~/.cursor/mcp.json`.
- [ ] Turn Connected apps off while Claude Desktop stays open. Its next tool call
  answers that Connected apps is off, without a restart. Turn it back on and the
  next call works.
- [ ] Ask about a meeting longer than an hour. The reply arrives in parts, and
  the app follows the continue offset to the end of the transcript.
- [ ] While an app is connected, record a meeting. BetterWispr keeps recording
  normally, and the new meeting appears in `list_meetings` once it is saved.
- [ ] Watch a network monitor while an app calls the tools. The `BetterWispr
  --mcp` process makes no connections.

## Accuracy

- [ ] Follow [the corpus and scoring protocol](accuracy.md). Use consented natural
  speech and human references; do not use synthetic demo text as an app benchmark.
- [ ] Compare raw/normalized WER and CER, entity/number correctness, silence
  hallucinations, rejected speech and correction time on the same held-out clips.
- [ ] Separate language/accent/device groups and latency measurements. Record
  settings and model hashes; do not report another project's paper numbers as
  BetterWispr results.
