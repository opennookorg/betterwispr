# Architecture and extension points

BetterWispr is one Swift package with a `BetterWispr` macOS executable,
`BetterWisprCore` library and `BetterWisprCLI` developer executable. The app owns
presentation and session coordination. The library owns recording, speech
engines, local storage and delivery to other apps. The CLI reuses the local
Whisper provider for explicit model installation and audio-file transcription.
`BetterWisprCoreTests` checks shared behavior.

This is a native macOS application. Core includes platform frameworks where
needed; it is not a promise of Linux/iOS portability. Feature folders are source
organization, not separate packages or a plugin loader.

```text
Sources/
  BetterWispr/
    App/              Lifecycle, session coordination, global shortcut, capsule and toast panels, updater
    Features/         Dashboard, insights, meetings, transcribe, history, models, vocabulary, style, settings and capsule UI
    Design/           Small shared view components and the brand mark, which also renders the app icon
  BetterWisprCore/
    Domain/           AppSettings, writing styles and app categories, usage insights, Transcript, VocabularyEntry and Meeting value types
    Persistence/      SavedState, per-meeting files and atomic local JSON storage
    Audio/            Microphone and system audio capture, temporary recordings, level metering and media file chunks
    Speech/           SpeechProvider contract, model catalog, Apple and WhisperKit
    Transcription/    English filler/stutter cleanup, spoken email layout, optional notes-model polish, writing styles and vocabulary replacements
    Notes/            Meeting notes with Apple Intelligence, the built-in model, Ollama, signed-in CLIs and explicit API connections
    Integrations/     Clipboard and guarded paste delivery, the yt-dlp link downloader and the read-only MCP server
  BetterWisprCLI/      Developer entry point for model and file smoke tests
```

## Dictation flow

The menu bar and global shortcut remain available after the last window closes.
The app delegate starts shortcut and panel services at launch, independently of
dashboard presentation. `AppSettings.showInDock` defaults to false for new and
older workspaces. The bundle launches as an `LSUIElement` agent to avoid a Dock
icon flashing when the saved preference is off; the delegate restores `.regular`
or `.accessory` activation policy before launch finishes. Settings changes apply
the policy immediately and persist through the existing workspace store.

1. A dashboard action or the global shortcut (**Option–Space** unless changed in
   Settings) starts a session. Capture the previously focused external app before
   showing the nonactivating capsule. While the session is preparing, recording
   or transcribing, a second Carbon hot key makes Escape (also with the dictation
   shortcut's held modifiers unless they include Command, so Command-Option-Escape
   stays Force Quit) cancel it from any app through the same Undo path;
   it is unregistered as soon as the session leaves those phases, so other apps
   keep Escape.
2. Validate the selected provider and check microphone permission. Apple speech
   authorization and API-key checks still precede capture. Installed neural-model
   warm-up runs independently, so it need not delay capture; readiness is checked
   again before transcription. Model downloads are separate user actions.
3. Record microphone audio locally and publish levels to the capsule. Stopping
   drains the in-flight input buffer and closes the file before preparing the
   selected provider and recognizing it.
4. Pass the recording URL, selected language and vocabulary hints to the provider.
   Entries written as a voice command ("question mark", "at the rate") are not
   hints, because boosting command words drops neighbouring words.
   With "Use screen context" on, Parakeet with the phrase booster installed and
   English or automatic language, up to 20 names from the selected text and
   window text also go to the provider as screen terms
   (`DictationContext.spellingTerms`). These are mixed-case words such as
   WhisperKit and capitalized words that macOS spell checking rejects, most
   frequent first. The clipboard is not used. Recognition waits at most
   300 ms for the capture and leaves it running for Medium. Other providers
   ignore screen terms, so they never
   reach a speech API. A screen term only replaces decoded words that macOS
   spell checking rejects, because a name on screen is no evidence it was said.
   With no vocabulary hints, the phrase booster pass runs only when the first
   pass has a misspelled word. Screen-term replacements are not vocabulary fixes.
   Provider partial callbacks are provisional text during recognition, not audio
   streaming while capture is still running. The Parakeet live preview is the
   one exception: `LiveTranscriber` re-recognizes the unconfirmed tail of the
   16 kHz capture copy about once a second while recording and shows the
   agreed words in the capsule, but the pasted text is always this batch pass.
   With automatic language and a Whisper model, a non-empty
   `AppSettings.dictationLanguages` limits detection. `WhisperKitProvider`
   runs Whisper's language detection once on the first 30 seconds, allowing
   only those language tokens, and transcribes every chunk in the winner.
   Codes the model's tokenizer lacks are dropped, and with none left detection
   runs unrestricted. Other providers ignore the list.
5. Post-process the recognized text in a fixed order. With a Chinese script
   chosen, `ChineseScript` first converts Chinese text to Simplified or
   Traditional, so cleanup and vocabulary see that script; the raw text keeps
   the model's characters. Auto cleanup **None**
   only trims; **Light** (the default) removes English filled pauses and
   unpunctuated stutters. Apply vocabulary entries written as a voice command,
   so a misheard "Kocia Mark" becomes "question mark". Then apply voice
   commands, spoken numbers as digits and the @, # and % symbols for English
   and Auto. For English
   text, **Medium** then asks the notes model the user chose in Models (Apple
   Intelligence, the built-in model, Ollama, a signed-in CLI or an API connection) for a clarity edit
   with `TranscriptPolisher` instructions, plus the selected text, clipboard and
   window text when "Use screen context" is on and the dictation started in
   Medium. Screen context is captured when it is on and either Parakeet with
   the phrase booster is selected for English or automatic language, or Medium
   has an available notes model. Only the Medium case reads the clipboard. The edit is bounded by a timeout and
   rejected when it answers the dictation, adds new words or changes length too
   much; any failure keeps the Light text, and Medium never picks a different
   model than the one selected.
   Next apply the writing tone chosen for the destination app's style context
   (`AppCategory` maps bundle IDs; browsers count as Other). A `WritingMode`
   can override cleanup, tone, screen context and Medium instructions. A spoken
   trigger word at the start or end of the dictation picks a mode first, then
   the website open in a supported browser (`WebsiteReader` reads its address
   through Accessibility and never stores it), then the destination app. The
   website is read while the microphone starts, and recording begins only once
   the mode is known; an unknown address captures no screen context. Screen
   context is captured for the mode chosen at the start, so a trigger word can
   turn it off but not on. A saved mode with an unknown cleanup or tone makes the
   workspace unreadable and leaves the file untouched.
   Vocabulary runs last so it can restore names a tone lowercased.
   Keep both raw and final text, plus the destination bundle ID and vocabulary
   fix count for Insights; save a transcript only when history is enabled.
6. Deliver through clipboard/guarded paste when enabled. Only paste if the
   original destination is still suitable; never treat a changed focus as consent
   to paste elsewhere. With "Copy to clipboard" on, leave the transcript on the
   clipboard. With it off, restore clipboard contents without overwriting newer
   user clipboard changes. Make failed insertion recoverable through copy either way.
7. Remove temporary audio on completion/error/cancellation and return to idle.

With "Pause music while dictating" on, `MediaPauser` sends Apple Events to pause
Music and Spotify when the phase enters preparing, only if they report playing.
When the phase leaves recording for any other phase it resumes only the apps it
paused that still report paused. Operations run one at a time, address the
running process so a closed app is never launched, and never prompt during
dictation; consent is asked once when the setting turns on. Quitting waits for
the resume through `terminateLater`. Meeting capture does not pause media.

Swift UI-facing state and speech-provider methods are isolated to `@MainActor`.
Audio callbacks must not mutate view state unsafely. Cancelled operations must
not publish stale text or paste a result from a prior session. Keep these
invariants when changing the implementation; the manual checklist covers OS
behavior that unit tests cannot establish.

## Meeting notes flow

`MeetingModel` owns meetings and is separate from dictation. Each meeting loads
its own speech provider with `download: false` and releases it once its last
chunks are transcribed and its speakers are found.
The Notetaker page's settings menu exposes the same model and microphone
selection as dictation, plus the notes model; both use `SpeechModel.makeProvider()` with independent
provider instances. The model name is captured when recording starts. The page
lists notes by day beside the current note (the one recording, otherwise the
latest); `MeetingModel.selectedID` opens one full page, and nil returns to the
list. Starting a meeting docks its card beside the call and leaves the dashboard
on the list; the finished note opens there once notes are written, unless
another meeting is recording by then. Personal thoughts, the transcript, and the generated summary have separate
tabs backed by the existing meeting fields.

1. Starting a meeting saves an empty `Meeting`, named after the Calendar event
   under way when Use Calendar is on (see [Calendar events](#calendar-events)),
   checks microphone permission and starts `MeetingRecorder`. The microphone becomes "Me". On macOS 14.2 and later
   a private Core Audio process tap on a private aggregate device records every
   other app as "Them". If the tap fails, the meeting records the microphone only
   and says so. Recording starts before the speech provider finishes loading, so
   the first words are kept; their chunks wait in the queue until it is ready.
2. Each source writes 3 to 20 second chunk files to the temporary folder. A chunk
   ends at the first 0.6 second pause after 3 seconds, or at 20 seconds. A 20 ms
   slice counts as speech when it is above the silence threshold and at least
   10 dB above the background noise, the 20th percentile of the last 10 seconds,
   so steady room or headset noise does not hold a chunk open and the brief
   near-silent dropouts of Bluetooth headsets do not pull the estimate to zero.
   The first 3 seconds use the silence threshold alone. Chunks without speech are
   deleted unread. Each chunk starts at the host time its first buffer was
   captured, measured from the meeting start, so "Me" and "Them" share one clock.
   System audio stops arriving while nothing plays, so a buffer more than
   0.5 seconds later than expected starts a new chunk at its real time, and each
   microphone buffer closes an open "Them" chunk that has received nothing for
   0.5 seconds, so the remote speaker's last line does not wait for the next sound.
3. One serial queue transcribes chunks in order, applies the same cleanup and
   vocabulary as dictation, keeps raw and final text, inserts the segment by start
   time and saves. A failed chunk shows a message and the meeting continues.
   When speaker detection is installed, each transcribed "Them" chunk is also
   resampled to 16 kHz mono and appended to one `SpeakerRecording` file, which
   remembers where each segment sits in it. With
   `AppSettings.separateRoomVoices` on, "Me" chunks are appended too.
4. Stopping closes both sources and transcribes the remaining chunks. The next
   meeting can start as soon as the recorder has handed those chunks off, while
   the stopped one keeps transcribing, finding speakers and writing notes. If a
   `SpeakerRecording` exists, Argmax SpeakerKit's pyannote pipeline runs on it
   with models that `SpeakerDetection.installedDiarizer(from:)` loads from disk; it never
   downloads. The models are pinned to one revision of
   `argmaxinc/speakerkit-coreml` and live in
   `BetterWispr/Models/models/argmaxinc/speakerkit-coreml`. Each "Them"
   segment gets the voice heard longest within it, numbered 1, 2, 3 by first
   appearance, in `MeetingSegment.participant`. When "Me" segments were
   appended, the voice heard longest in them, outside the lines
   `MeetingTranscript.removingEchoes` drops, stays Me. A "Me" segment with any
   other voice gets a number the same way and keeps `speaker == .me`, so echo
   removal still treats it as microphone audio. Skip stops waiting at once and
   leaves the segments as "Them"; detection already running finishes in the
   background on audio held in memory, so the recording file is deleted
   normally. An error also leaves the segments as "Them". Names typed above the transcript are saved in
   `Meeting.participantNames`, and `MeetingSegment.label(names:)` renders the
   transcript, Markdown and notes input with them. Then it writes
   notes with the explicitly chosen notes model: Apple Intelligence by default,
   the [built-in model](#built-in-notes-model), local Ollama, Claude Code, Codex, or an OpenAI-compatible chat API. Transcription
   selection remains independent. `NotesWriter` combines the transcript and all
   personal thoughts, condensing long inputs before the final structured summary.
   If condensing stalls above the budget, it drafts notes for each remaining
   chunk and merges them in order, so every part reaches the model and nothing
   is truncated. Provider failure never selects another engine; the
   transcript, thoughts and previous summary remain saved.
5. Each meeting is one JSON file in `Application Support/BetterWispr/Meetings`.
   Unreadable files are reported and left untouched. Chunk files are deleted after
   transcription, on cancel and at quit, and leftovers are removed at launch. The
   speaker detection file is deleted after detection, on cancel and at quit, and
   shares the chunk prefix, so launch cleanup removes it too.

Speaker labels can be fixed after a meeting. A line's speaker name in the
transcript opens a menu, also on right-click, that calls
`Meeting.assign(segment:toParticipant:)` to move that line to another speaker, to
a new speaker numbered by `Meeting.nextParticipant`, the lowest number no line or
non-blank saved name uses, or back to nil. Nil shows "Me" on a microphone line
and "Them" on a remote line, which the menu offers only while some remote lines
have no speaker. A line keeps its `speaker`, so echo removal is unaffected. The
invitee menu beside each name lists `Meeting.unusedAttendees`, the invitees no
speaker is named after yet, and fills the name field with one. The Merge into menu beside each name
calls `Meeting.mergeParticipant(_:into:)`, which relabels every line of one
speaker as another, moves the name across when the target has none and drops the
old number's name. The speaker and merge menus are hidden while the meeting is
active, because detection replaces the segments when it finishes. A relabel
changes `summarySourceFingerprint`, so an existing summary shows as out of date.
When the Mac supports speaker detection but it is not installed, a meeting with
remote lines shows a card that downloads it only when tapped. It applies from the
next meeting, because chunk audio is already deleted. "Don’t show again" sets
`AppSettings.dismissedSpeakerDetectionOffer`. Onboarding offers the same download
below the speech model. Clicking it while another download runs sets
`AppModel.speakerDetectionQueued`, and the download starts only if that one
succeeds.

With `AppSettings.rememberVoices` on, `MeetingModel` keeps each detected
meeting's speaker embeddings in memory as a `HeardVoices`, never in the meeting
file. `SpeakerRecording.voiceTurns()` runs SpeakerKit with
`SpeakerDetection.sameVoiceDistance`, 0.6, as `clusterDistanceThreshold`. That
value is SpeakerKit's own default, so diarization is unchanged, and the
constant states it once for both uses. The embeddings are
`DiarizationResult.speakerCentroidEmbeddings`, one mean per speaker. After
detection, `SpeakerDetection.recognise` compares each new speaker with every
stored voice by Euclidean distance between length-normalised embeddings, the
measure SpeakerKit clusters with. It matches a speaker to the nearest stored
voice within 0.6, giving each name to one speaker. SpeakerKit's doc comment on
`speakerCentroidEmbeddings` says there is no universal same-speaker threshold
across runs and asks callers to calibrate one. BetterWispr has no corpus to
calibrate against, so a match is only a suggestion. While a speaker has no
name, `HeardVoices.suggestion(for:in:)` puts "Sounds like" and the stored name
first in that speaker's name menu. Nothing writes `participantNames` until the
user picks a name, so the transcript and the notes prompt hold only names the
user chose.

When a meeting saves, `HeardVoices.remember(in:to:)` passes each speaker that
has a non-blank name and still has lines to
`VoiceStore.replaceVoices(from:with:removing:)`, which replaces that meeting's
entries in `Application Support/BetterWispr/Voices.json`. `VoiceStore.save`
writes the file atomically and then sets it to 0600, as `MeetingStore` does. It
also sets the folder to 0700, even when the folder already exists. A speaker that took its suggested name is not stored again,
so the file grows only when the user names someone new. Saving never
removes a stored voice. When the user commits a speaker's name with Return, by
leaving the field or by picking an invitee, `MeetingModel.commitName(of:in:)`
calls `HeardVoices.reject(_:in:from:)`. A committed name other than the
suggestion removes the stored voice behind it and ends the suggestion, and the
model drops that voice's embedding from the meeting it was remembered in, so
saving that meeting again can't store it back. Merging speakers drops the merged speaker's embedding, so a number
reused later can't inherit it. Deleting a meeting removes its stored voices. A
`Voices.json` that fails to load is reported in `MeetingModel.voicesMessage`
and never overwritten. Forget Voices deletes it, readable or not. Embeddings in
memory are lost at quit, so speakers named after a relaunch are not stored.

Each meeting being captured or processed is a `MeetingRun` in
`MeetingModel.runs`. One run records at a time and any number process. Every
continuation checks that its run is still the one registered for its meeting,
so a cancelled or quit meeting never receives a late segment or summary. The
recorder's chunks go to `recorderOwner`, and a new meeting waits for the stopped
one's `MeetingRecorder.stop()` before it takes the recorder, so a stopped
meeting's last chunks never land in the next one. Cancelling a meeting that is
still starting stops the recorder only if that meeting holds it. While two
meetings overlap, each holds its own loaded speech model.

### Ask

A meeting's Ask tab and the Ask field on the Notetaker page answer questions
from saved meetings. `MeetingQuestion` reads each meeting as `MeetingLine`s:
the transcript rows shown by default, labelled with their timestamp and speaker,
then each nonempty line of My thoughts. When every line fits
`MeetingNotesGenerator.budget`, all of them are sent. Otherwise lines are scored
by the question words they share, rarer words weighing more, and the best lines
are added with their neighbours in the same meeting until the budget is spent.
The chosen lines keep meeting order, are numbered from 1 under a header for each
meeting, and the model is told to cite them as `[n]`. Markers that name a sent
line become `MeetingAnswer.Citation`s; numbers outside the sources are removed
from the answer, so every citation points at a real line. A transcript citation
opens its meeting on the Transcript tab and scrolls to that segment; a thought
citation opens My thoughts.

A meeting that still has a `MeetingRun` can be asked about too. Ask reads the
lines saved when the question is sent, so a meeting that is recording,
transcribing or finding speakers is answered from its transcript so far, and its
Ask field says so. A summary that finishes while the Ask tab is open does not
switch tabs. Speaker detection can later split a cited "Them" row into new rows;
that citation then opens the Transcript tab without a highlighted line.

Ask uses `AppSettings.askSelection`. Nil, the default, follows the notes model.
Another choice reuses the notes providers, their Keychain keys and their
availability checks, and it is never a fallback: an unavailable provider shows
its reason instead of asking another one. Removing the notes connection it
names, or changing that connection's endpoint, resets it to the notes model.

A question waiting for its answer is an `AskQuestion` in view state. The request
runs in a view task, so Cancel, leaving the meeting or leaving the Notetaker page
cancels it, and an answer for a removed question is dropped. An answered
question becomes an `AskExchange` holding its `MeetingAnswer`, citations and
model name. Failed and cancelled questions are never saved. `MeetingModel` keeps
each meeting's thread in the optional `Meeting.askThread`, saved with the
meeting, so meeting files from earlier versions decode with no thread. The
thread about all meetings is `ask.json` beside the `Meetings` folder, written by
`AllMeetingsAskStore` as version 1, atomically, with mode 0600. Keeping it out of
`Meetings` means older versions never report it as an unreadable meeting. An
unreadable or newer `ask.json` is reported and left untouched, and answers about
all meetings then last only until quit. Deleting a meeting removes the answers
about all meetings that cite it. Clear empties one thread after a confirmation.

While a meeting records, its Ask tab offers What did I miss?. It asks a fixed
question about the transcript rows still being spoken in the last
`MeetingQuestion.catchUpWindow`, five minutes, without My thoughts. When those
rows exceed `MeetingNotesGenerator.budget`, the oldest are dropped until the rest
fit, so a busy five minutes is answered from its newest lines.

On the Notetaker page, `MeetingFilter` narrows the meetings Ask reads to those
created today or in the past 7 or 30 days, counted from local midnight, and to
those listing one Calendar invitee in `Meeting.attendees`. There is no folder or
calendar filter, because meetings record neither.

### Calendar events

`CalendarEvents` in `Integrations/` reads, through EventKit, the events that the
Mac's Calendar app has already synced. That covers every account Calendar shows,
such as iCloud, Google and Exchange, including shared and subscribed calendars.
It never contacts a calendar server itself, so it works offline and needs no
account sign-in of its own. It is an actor that owns the one `EKEventStore`, so
EventKit's synchronous queries run off the main thread and only `Sendable`
values such as `CalendarEvent` reach the app.

It is off by default. Only turning on `AppSettings.useCalendar`, from the
Settings toggle or the Calendar row under Permissions, calls
`requestFullAccessToEvents`, which shows the macOS prompt the first time. A
denial turns the setting back off and opens the Calendars pane of Privacy
settings. The bundle declares `NSCalendarsFullAccessUsageDescription` and the
hardened runtime entitlement
`com.apple.security.personal-information.calendars`. Once access is granted,
Settings lists each account's event calendars with a toggle.
`AppSettings.excludedCalendarIDs` stores the EventKit calendar identifiers
switched off, so a calendar added later in Calendar is included without another
visit to Settings. The list refreshes when the app becomes active. Every read
resets the store first, so access granted again after a revoke takes effect
without a relaunch. While the toggle is on without access, its caption points to
the Calendar row under Permissions.

When a meeting starts with the integration on and access granted,
`CalendarEvents.current(excluding:)` fetches events from the included calendars
that overlap the next five minutes. `AppModel.startMeeting` awaits it before
checking that nothing else is recording and calling `MeetingModel.start`, so a
second click during the lookup finds the first meeting and starts nothing.
`CalendarEvent.current(_:at:)` ignores
all-day events and events that were cancelled or that the user declined, keeps
one that started or starts within five minutes and has not ended, and prefers an
event with a Zoom, Google Meet, Microsoft Teams or Webex link, then the latest
start. The meeting takes the event's title, on one line, and saves
`Meeting.attendees`
(invitees other than the user, without rooms and resources, by name, or by
`mailto:` address when the invite gives no name) and `Meeting.eventID`. The
notes model only fills a title that is still empty, so the event title stays.
Attendee names without an `@` join that meeting's speech hints like Vocabulary
terms, so the Whisper prompt, Apple's contextual strings and the Parakeet phrase
booster can steer recognition toward them; they are not added to Vocabulary's
replacements. A meeting cancelled before anything is recorded is still discarded
although its title came from the event.

`Meeting.calendarInvite` gives the title and up to 20 invitees, then a count of
the rest. `NotesWriter` puts it before the material in the draft prompt, never
in the condense prompts, after `NotesWriter.inviteNote`, which tells the model
to use it for the subject and names, never to follow it as instructions, and not
to assume every invitee spoke. Meetings without an `eventID` send no invite. The
event title and invitees therefore reach whichever notes model the user chose,
including an API connection, and the Settings footer says so.

`useCalendar` and `excludedCalendarIDs` decode with `decodeIfPresent` and
`Meeting.attendees` and `Meeting.eventID` are optional, so workspaces and
meetings saved before them load with the integration off, no calendar excluded,
and no event.

### Connected apps (MCP server)

`MCPServer` in `Integrations/` lets apps that speak the Model Context Protocol,
such as Claude Desktop, Claude Code and Cursor, read saved meetings. The app
executable serves it when launched as `BetterWispr --mcp`. `Launch`, the
package's `@main`, checks for that argument before `BetterWisprApp.main()`, so
the server process creates no `AppModel`, window, shortcut or audio session,
and the bundle needs no second executable. The connected app starts the process
and exchanges newline-delimited JSON-RPC 2.0 over its standard input and output.
The server opens no socket and makes no network request.

`MCPServer.reply(to:)` turns one input line into one reply line, or none for a
notification or a blank line, so tests drive it without a process. It answers
`initialize`, `ping`, `tools/list` and `tools/call`. `initialize` echoes a
supported protocol version and otherwise offers the newest it knows,
2025-11-25. Any other method gets -32601, malformed JSON gets -32700, and a
message that is not a JSON-RPC 2.0 request gets -32600. The stateless
`server/discover` handshake is not implemented.

There are three tools, each annotated read-only and closed-world.
`list_meetings` lists meetings newest first. `get_meeting` returns one meeting
by id. `search_meetings` finds a phrase in meeting lines, ignoring case and
accents. List and search take an optional `from` and `to`, and a plain date
covers that whole local day. A meeting's text is a header (id, title, date,
duration, attendees and speakers) followed by `Meeting.markdown`, the same text
as Copy notes and transcript, so the summary, action items, the user's notes and
the timestamped transcript with speaker names match the app.

Every reply is bounded. List and search return at most 50 entries, and a reply
stops before 30,000 characters, though it always holds at least one entry or
line. A cut reply ends with the call and offset that continue it, and each
search match carries the meeting id and line offset that `get_meeting` takes.

Every `tools/call` first loads `workspace.json` through `LocalStore` and checks
`AppSettings.mcpServer`. A missing, unreadable or unsupported workspace counts as
off. While off, a tool call returns a tool error that says where to turn it on,
and no meeting is loaded. `initialize` and `tools/list` still work, so a
connected app can show the server and its tools. Turning the setting off takes
effect on the next call, without restarting the connected app. Meetings load
through `MeetingStore.load()`, which only reads, so an unreadable meeting file is
skipped, counted in list and search replies, and left as it is. Transcriptions
from the Transcribe page are not served.

`AppSettings.mcpServer` decodes with `decodeIfPresent` and defaults to false, so
a workspace saved before it keeps the server off. Settings > Connected apps
holds the toggle. While it is on, the section shows the `claude mcp add` line, an
`mcpServers` snippet for Claude Desktop and Cursor, and the bare command, each
built from `Bundle.main.executablePath` with a Copy button. Its footer says that
a connected app sends what it reads to its AI provider.
`scripts/mcp-smoke.py` runs the built bundle with `--mcp` against a temporary
home holding one synthetic meeting and one unreadable file, checks the replies
with the setting off and on, and checks that the files are unchanged.

### Meeting detection

`MeetingDetector` offers the notetaker in the capsule when a call starts. It is
on by default and turned off by `AppSettings.detectMeetings`. It only reads
local state and never records anything itself.

1. `MicrophoneActivityObserver` listens to Core Audio's process object list and
   to each process's `kAudioProcessPropertyIsRunningInput`. These are reported
   from macOS 14.2. Older systems detect nothing.
2. `MeetingPlatform.app(recording:)` maps the recording processes to known apps.
   Helper processes such as `com.google.Chrome.helper` map to their app, and
   `com.apple.WebKit.GPU` maps to Safari. Unknown apps, BetterWispr included,
   are ignored.
3. Native call apps (Zoom, Teams, Slack, Webex, FaceTime, Discord, WhatsApp,
   Signal and Telegram) count as a call while they record. A browser counts only
   when one of its windows is titled like Google Meet, Teams, Zoom, Slack, Webex,
   Whereby, Jitsi Meet or Discord. Titles are read through Accessibility with a
   0.25 second timeout. While an unmatched browser records, titles are checked
   again every 3 seconds.
4. Each call is offered once. Starting the notetaker, choosing Not now or letting
   the prompt expire after 30 seconds marks that app's call as answered. Calls
   that run while the notetaker records are answered too. A new call is offered
   while an earlier meeting is still processing. An app's answer is forgotten
   when it stops recording.

`AppSettings.notesSelection` resolves the legacy Ollama choice plus the new optional
CLI or notes-connection selection. Old workspaces decode without changing providers.
`notesConnections` reuses `SpeechConnection` metadata and URL/key validation, with
keys stored under a separate notes Keychain service. API generation uses ephemeral
sessions, rejects redirects and checks both HTTP status and completion status.
Any model ID is accepted if the selected server supports OpenAI-compatible chat
completions and JSON-object output. Saving a connection makes no request; selecting
it explicitly enables sending transcript and thoughts. Keys are never inferred
from a speech connection or moved to an edited destination. Adding a connection
offers `NotesAPIPreset.all`, which fills the name, the chat completions URL and a
fast model for OpenAI, Anthropic, Google Gemini or OpenRouter. Picking one makes
no request and clears a typed key. Anthropic's OpenAI compatibility ignores
`response_format`, so notes from it rely on the prompt alone for JSON.

Claude Code uses `claude --print` and its existing Claude subscription sign-in;
Codex uses `codex exec` with ChatGPT authentication required. BetterWispr does not
extract OAuth tokens. These CLI routes strip inherited provider/key environment
variables, run in a private temporary directory, disable tools/customizations as
supported by each CLI, and disable session persistence. Codex also uses read-only
sandboxing. A timeout or cancellation terminates the child and removes temporary
input/output files. Install/update and sign in to the CLIs separately. Subscription
limits and model access remain the provider's responsibility. Models discovers
Claude's model catalog through its stream-JSON initialize response and Codex's
through app-server `model/list`, including pagination. Claude aliases resolve to
exact IDs; an empty legacy choice is pinned to the reported account default.
Refresh never replaces an explicit model choice. Users can also enter an exact ID
when discovery fails or a new model is available. Generation passes that ID with
`--model`, and Claude's reported model usage is recorded in the saved summary.
Models also exposes notes API endpoints and a cancellable synthetic sample test.
CLI flags were verified against the locally installed help and
[Claude's CLI reference](https://code.claude.com/docs/en/cli-reference),
[Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)
and [Codex configuration](https://learn.chatgpt.com/docs/config-file/config-reference).
Model discovery follows [Claude's model configuration](https://code.claude.com/docs/en/model-config)
and [Codex's app-server protocol](https://learn.chatgpt.com/docs/app-server).
The API format follows [Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create).

Summaries record their provider label and a digest of the transcript plus thoughts
used to generate them. Editing thoughts marks an existing summary as needing an
update, including edits made while generation is running. “Update summary” on both
My thoughts and Summary regenerates from both sources using the selected model.
Older summaries without these optional fields remain readable and can be updated.

`MeetingTranscript.removingEchoes` cuts remote speech that the microphone picked
up while it played. Each "Me" segment is compared word by word with the "Them"
segments that overlap it, allowing 3 seconds either side. Runs of three or more
matching words are removed, tolerating one misheard, extra or missing word inside
a run and gaps of up to two words between runs, and the user's own words around
them stay. Words match when equal or when, at four or more letters, they differ
in at most a quarter of their letters ("campaign" and "campage"). A run also takes
the matching words just before it, because the alignment can pair its first word
with an earlier remote occurrence. A "Me"
segment left with fewer than three words is hidden. It runs for transcript
display, copying/export and summary input, while original segments and raw text
stay on disk. “Show repeated microphone audio” shows the segments unchanged. This
is text matching, not acoustic echo cancellation: different recognition can still
leave echoes, and a short reply that repeats the remote speaker's words while they
talk can be cut. Repetitions outside the overlap window are kept. Timestamps are
chunk capture times, not word-level alignment.


Starting a meeting from the capsule or the menu bar docks a floating card
(`NotetakerController`) to the right edge of the screen under the pointer. It
hosts the same `MeetingDetailView` as the dashboard, closes when its meeting is
deleted, and its expand button opens the meeting in the dashboard instead.

## File and link transcription

`TranscriptionModel` owns the Transcribe page and is separate from dictation and
meetings. It runs one job at a time and keeps each finished transcript as a
`Meeting` in its own `MeetingStore` under
`Application Support/BetterWispr/Transcriptions`. The page's model menu lists
installed models and configured API connections and starts on the dictation
model. A model that is not installed sends the user to Models. Each job loads
its own provider with `download: false`, and connections can't be edited while
a job runs.

1. `MediaLink` accepts only http and https links with a host. `YTDLP` runs
   BetterWispr's own copy in `Application Support/BetterWispr/Tools`, otherwise
   one from Homebrew, `/usr/local/bin`, `~/.local/bin` or MacPorts. It installs
   or updates its copy only when the user clicks Install or Update, or runs
   `BetterWisprCLI --download-yt-dlp`. The binary comes from the latest GitHub
   release and is written only after its SHA-256 matches the release's
   `SHA2-256SUMS`. yt-dlp runs with `--no-config`, a reduced environment and the
   link after `--`. It fetches the best m4a or mp4 audio of the first video into
   a private `betterwispr-media-<uuid>` folder, which is deleted after the
   transcript, on error and on cancel. Deno or Node, when found, is passed with
   `--js-runtimes`.
2. `MediaAudio` reads only the first audio track with `AVAssetReader`, so
   alternate-language tracks are not mixed in. It converts to 16 kHz mono and
   writes one `betterwispr-media-<uuid>.caf` chunk at a time, holding about one
   chunk of samples in memory. Each cut lands at the quietest point of a 300 ms
   moving average of 10 ms levels, 30 to 59.5 seconds after the previous cut,
   and the last 59.5 seconds or less become the final chunk. A cut leaves at
   least one second after it, because Parakeet rejects audio under 0.3 seconds
   and a failed chunk fails the job. No chunk is dropped
   for being quiet. Files with no audio track or an unreadable container, such
   as mkv or webm, fail with the list of supported formats.
3. `MediaTranscriber` sends each chunk to the selected provider in order,
   applies the meeting cleanup and vocabulary, keeps the raw text beside the
   cleaned text and deletes the chunk. A failed chunk fails the job, and
   cancellation is checked after each chunk. Every segment is `.them`.
   `participant` is set only when Speaker detection is installed, which labels
   the voices afterwards and splits segments where the voice changes, as it
   does for meetings.
4. A job that found speech is saved and opened, unless another transcript is
   open. A job that found none saves nothing and says so. Launch and quit delete
   leftover `betterwispr-media-*` files and folders.

The detail view names a voice only on segments Speaker detection labeled, so a
transcript never says "Them". Copy all and the .txt and .md exports use the same
timestamped lines. `BetterWisprCLI --media PATH|URL` runs the same pipeline and
prints one JSON segment per line.

## Built-in notes model

The built-in model is a notes provider that runs inside BetterWispr, so meeting
notes, Medium cleanup, correction review and Ask work without Apple
Intelligence, Ollama, a CLI or an API key. `NotesModelSelection.builtIn` is
saved as `AppSettings.notesBuiltIn` and as `askSelection`; a CLI, connection or
Ollama choice in an older workspace still wins, so existing settings decode
unchanged. Like every notes provider it is never a fallback: when it is selected
but missing, notes, Medium and Ask report that instead of asking another model.

`BuiltInModel` pins one file: `Qwen3.5-2B-Q4_K_M.gguf` from
`unsloth/Qwen3.5-2B-GGUF` at revision
`f6d5376be1edb4d416d56da11e5397a961aca8ae`, 1,280,835,840 bytes with a fixed
SHA-256. It downloads only from the Download button in Models or
`BetterWisprCLI --download-builtin-model`, through WhisperKit's
`ModelDownloader` into `BetterWispr/Models/models/unsloth/Qwen3.5-2B-GGUF`.
`install` then checks the size, hashes the file in 8 MB reads, loads it in a
throwaway engine and samples one token under the notes grammar. Only then does
it write `.betterwispr-installed` holding the revision and hash. A failure or
cancel at any step deletes the folder. `isInstalled` compares that marker and
the file size and never reads the file, and loading opens only the local file,
so a missing model fails instead of downloading. A finished install from Models
selects the built-in model unless the user picked another notes model
meanwhile or a meeting is still recording or processing. Remove deletes the
marker first, so a request that arrives meanwhile fails as not downloaded
instead of loading the file. It then frees the weights, deletes the folder and
leaves the selection alone.

`LlamaEngine.shared` runs the file through llama.cpp's C API from the
llama.swift package. One `OSAllocatedUnfairLock` holds its state: idle, loading
(with the requests waiting for it), loaded, draining while running requests
finish, or closing while the weights are freed. A request that arrives while
they close waits and loads them again. The weights are memory-mapped
with every layer on Metal. Each request opens its own 8,192-token context with a
Q8_0 KV cache and frees it on its own thread, so requests share weights but
never a context. Prompts use Qwen's chat template with thinking off. Template
pieces are tokenized with control tokens and message text without them, so a
transcript cannot close a turn. A prompt that leaves fewer than 1,024 tokens for
the reply fails before a context opens, and a reply that fills the window fails
instead of returning cut-off text. Sampling is greedy. Meeting notes add a GBNF
grammar for the five `NotesDraft` fields; the top token is checked first and the
whole vocabulary is masked only when the grammar rejects it.

Requests take one of two lanes. Medium edits and correction review use the
interactive lane, and meeting notes, Ask and the Models Test use the background
lane. Prefill runs in 256-token batches, and each request checks between batches
and between tokens whether to go on: a background request pauses while an
interactive one holds the weights, and a cancelled or timed-out request stops
within one batch. The polisher's character budget for the built-in model is
21,504, derived from its 7,168 prompt tokens at the same 3 characters a token
guessed for Apple's window, so it keeps screen context that Apple's 12,000
would drop.

The weights load on first use, or 450 ms into a Medium dictation through
`MeetingNotesGenerator.warmUp`, and unload after 300 seconds without a request.
`shutdown()` refuses new requests, cancels running ones and blocks until every
llama object is freed. The app calls it last in `applicationWillTerminate` and
the CLI on every exit path, because llama.cpp's Metal backend aborts the process
at exit (status 134) while a model is alive. `scripts/build-app.sh` copies
`llama.framework` into `Contents/Frameworks`, where the executable's
`@executable_path/../Frameworks` run path finds it. Because the weights are a
mapped file, resident size counts the mapped pages while the process's own
footprint stays far smaller; [testing.md](testing.md) records both.

## Microphone selection

`AudioInputs` lists Core Audio devices with an input stream, keyed by UID, and
skips private aggregate devices (Core Audio's per-process default aggregate and
BetterWispr's system audio tap). `AppSettings.microphone` is the saved choice;
nil means Automatic, which is the macOS default input, Bluetooth headsets
included. A chosen microphone is used only while it is connected, otherwise
Automatic is used; there is no other fallback. Recording from a Bluetooth
headset's microphone switches the headset to its call profile (measured 48 to
24 kHz playback on AirPods Pro), so its sound drops to call quality while a
dictation or meeting records from it and recovers when recording stops.
Choosing the built-in microphone in Settings avoids that. Both recorders use
`MicrophoneInput`, an input-only Core Audio queue bound to that UID. It
requests the device's native rate/channel count and 20 ms interleaved Float32
buffers. Audio Queue delivers buffers on a serial
worker, where existing writers handle files and levels. No file writes or locks
run on the hardware's real-time IO thread. Stop disposes the queue
synchronously, so no callback runs after it returns. The microphone is active only during recording.
`MicrophoneInput` shares one queue per device UID between dictation and
meetings, including concurrent startup, so a dictation during a meeting adds a
receiver instead of opening a second queue. A receiver sees only samples at or
after its subscription time, and detaching drains its callback before its file
is finalized. No idle audio is cached or replayed. The last subscriber closes
the queue.

Both recorders wait for an actual audio callback before reporting readiness;
silence counts, so this does not require the user to speak first. Normal finish
waits for the callback whose host timestamp covers the stop request before
closing the file. Startup and finish waits are bounded and cancellable. Each
input restart has a new callback token, rejecting late audio progress from an
older input queue. Speech gating measures 20 ms slices rather than entire hardware
buffers, so a Bluetooth device's larger batches do not dilute brief, quiet
speech. Waveform calibration remembers digital silence and timestamps delivered
slices in the past instead of replaying them with another buffer of delay.

`AudioInputObserver` reports connects, disconnects and default-input changes,
debounced on the main actor. The settings picker and the meeting card's
microphone menu refresh from it. During capture it also listens for the selected
device's stream-format, nominal-rate and alive-state changes, including Bluetooth
profile changes that keep the same UID. The recorders restart when the resolved
device changes or the input queue stops. A running Audio Queue handles native
rate changes internally; restarting it again would add another Bluetooth
wake-up. Notifications that do not change those properties leave capture alone.
Restarts wait for the 300 ms debounce and make up to three attempts if the
device is temporarily unavailable. Stopping or cancelling removes the observers and
pending retries; session tokens reject late callbacks.

Dictation keeps its file open across restarts and uses `AVAudioConverter` when
the new input's format differs, preserving the recorded audio and its duration.
An unrecoverable restart ends dictation with an error. Meetings close and hand
off the current "Me" chunk before restarting, then begin a chunk in the new
format at its actual meeting offset. System audio continues independently; a
microphone failure is reported, and a later device change can resume capture.
Changing the selected microphone also applies to either active recording.

Capture uses Apple's
[Audio Queue Services](https://developer.apple.com/documentation/audiotoolbox/audio-queue-services)
and [device UID routing](https://developer.apple.com/documentation/audiotoolbox/kaudioqueueproperty_currentdevice).
`MicrophoneCapture` diagnostics report startup/callback timing, format and RMS;
`DictationTiming` reports recognition time and whether text was empty. Neither
logs audio samples, microphone names or transcripts. Hardware startup runs away
from the main actor because Bluetooth initialization can block.

## Add a model

Add an entry to `SpeechModel.catalog` in
[`SpeechProvider.swift`](../Sources/BetterWisprCore/Speech/SpeechProvider.swift).
Use a stable ID, a compatible Core ML model folder name, the correct tokenizer
repository, an honest resource description and `.whisperKit` as its engine. Parakeet
entries use `.parakeet` and a `modelName` that `ParakeetProvider.source(for:)` maps
to a FluidAudio version, repository and download size. The `modelName` must equal
the repository's `folderName`, because FluidAudio loads files from that folder.
Model IDs are persisted, so renaming/removing one requires a fallback or migration.

Verify that the model/tokenizer match before presenting the entry as supported.
Download once, quit the app, disconnect networking, then prepare and transcribe
again. Test cancellation, corrupt/incomplete files and insufficient storage.
Record the model revision/hash, upstream license and evaluation results. A catalog
entry alone is not proof of compatibility or acceptable speed/accuracy.

## Add an STT engine

Implement the existing `@MainActor SpeechProvider` protocol in `Speech/`:

```swift
func prepare(model: SpeechModel, download: Bool) async throws
func transcribe(audioURL: URL, language: String?, vocabulary: [String]) async throws -> String
func cancel()
```

The provider also exposes progress and provisional-text callbacks. Add its
`SpeechEngine` case and instantiate it where the app selects providers. Reuse the
shared recorder, vocabulary processor, history and delivery path. Keep engine
configuration inside its provider rather than branching across SwiftUI views.

For built-in engines, `download: false` must load local resources only. `download: true` authorizes an
explicit model setup operation, not future background network use. Validate
files and required tokenizer tokens before marking a model installed. Report
unsupported languages/assets clearly, prevent simultaneous operations, honor
task cancellation and clear callbacks/resources when a session ends. Do not
silently route failures to a cloud service.

### User-configured API connections

`SpeechConnection` metadata lives in `AppSettings.speechConnections`; old saved
settings decode with an empty list. The built-in catalog stays static and local.
`AppModel.models` adds each saved connection as a selectable `.api` speech model.
`SpeechModel.makeProvider()` is shared by dictation and meetings.

`APISpeechProvider.prepare` validates configuration and Keychain access without
network requests. Only transcription through a selected connection uploads audio.
It reuses WhisperKit's audio conversion to produce 16 kHz mono PCM WAV in memory,
off the main actor. Sarvam receives sequential 25-second clips; other APIs receive
the bounded dictation/meeting clip. Fixed cuts can affect words at boundaries.
No partial transcript is delivered on failure. Cancellation stops URLSession
requests; callers retain their generation checks before history and paste.

Sarvam uses multipart uploads and `api-subscription-key`; Smallest uses binary WAV
with Bearer authentication; custom endpoints use OpenAI-compatible multipart and
JSON `text` responses. Smallest requires an explicit spoken language. New model
IDs are editable without a catalog update if they retain the provider's wire
format. Other formats need a concrete adapter, not a generic plugin system.

Keys are stored as nonsynchronizing, device-only Keychain items bound to connection
ID, API format and full endpoint. Connection edits cannot reuse a key at a different
URL. Requests use ephemeral sessions without cookies, cached credentials or disk
cache. HTTPS is required except for literal loopback destinations; every redirect
is rejected. Provider response bodies are not included in errors. Vocabulary
substitution remains local and hints are not uploaded. External providers control
their own audio retention; local history settings do not control that retention.

Wire formats checked against [Sarvam REST](https://docs.sarvam.ai/api-reference/speech-to-text/transcribe),
[Smallest pre-recorded STT](https://docs.smallest.ai/models/speech-to-text/pre-recorded/quickstart),
and [OpenAI transcription](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create).
Automated tests use synthetic audio and stub responses; live provider acceptance
requires the user's own account and credentials.

The Apple provider requires on-device recognition and uses the current locale
when no language is supplied. WhisperKit uses locally loaded Core ML weights and
tokenizers. Its tokenizer adapter exists because the upstream public loader can
fall back to the network; see [source attribution](oss-reuse.md).

Parakeet's phrase booster is FluidAudio's CTC word-spotting model. It downloads
with each explicit Parakeet install, in parallel with the model, or from the
Vocabulary page or `--download-phrase-booster`. A failed booster download leaves
the model installed. It goes into
FluidAudio's shared cache (`CtcModels.defaultCacheDirectory(for: .ctc110m)`),
because FluidAudio reads the booster's tokenizer from that fixed folder. A
`.betterwispr-installed` marker is written after the files load. `prepare`
loads an installed booster with `CtcModels.loadDirect` and never downloads it;
a missing or broken booster leaves plain Parakeet transcription unchanged.
`transcribe` boosts only English or automatic-language dictation with
vocabulary hints or screen terms and keeps the decoder's text when rescoring
changes nothing.

## Add an integration

Put OS/application delivery behavior in `Integrations/` and implement the
existing `TextOutputIntegration.deliver(_:to:)` contract. `ClipboardIntegration`
copies explicitly; `FocusedAppIntegration` checks the captured app's process ID
and sends paste only while it remains frontmost. Otherwise it copies for manual
paste. Its guard tracks the destination app, not the individual text field.
`deliver` returns an `OutputResult` case (`copied`, `copiedForManualPaste` or
`pasted(into:)`). The app shows `copiedForManualPaste` in a capsule card with the
text and a Copy button that closes after five seconds, `copied` as a toast, and
nothing after a successful paste.

Current destinations share the same final transcript; model inference should not
know which app will receive text. Validate prerequisites and expose errors
through the existing session state. Keep clipboard/focus restoration,
Accessibility checks and cancellation behavior in the shared path. Clipboard
restoration after automated paste uses a bounded delay because arbitrary apps
do not acknowledge receipt; slow recipient apps need explicit manual testing.

Add only the concrete integration and its required settings. Do not introduce
per-app speech providers or duplicate recording code. Any future network
integration must require explicit opt-in and preserve the local default.
Integrations that read personal data, like `CalendarEvents`, stay off until the
user turns them on, and only that action may show the macOS permission prompt.

## Updates

`AppUpdater` wraps Sparkle's standard updater and is owned by `AppModel`. Sparkle
reads `appcast.xml` from the latest GitHub release (`SUFeedURL`) and installs an
update only when its EdDSA signature matches `SUPublicEDKey`. Its network use is
limited to update checks and downloads. Automatic checks are opt-in: Sparkle
asks on the second launch, and Settings can change automatic checks and
automatic installs at any time. Update requests carry no audio, transcripts or
vocabulary, and system profiling stays off. Dictation happens in other apps, so
`AppUpdater` implements Sparkle's gentle reminders: a scheduled update found
while BetterWispr is in the background shows an Update toast and an "Install
BetterWispr" menu bar item instead of Sparkle's alert behind other windows. With
automatic installs on, a downloaded update shows a Restart toast and the same
menu item, which installs and relaunches, because the app is rarely quit. Sparkle keeps these preferences in
its own user defaults, not in `SavedState`. `scripts/release.sh` signs both
architecture-specific DMGs with the private key in the login keychain and writes
the appcast. The Apple Silicon item comes first with Sparkle's `arm64` hardware
requirement; Intel Macs skip that item and receive the Intel download.

## Persistence and boundaries

`SavedState` contains a schema version, settings, vocabulary and transcripts.
`LocalStore` writes atomically to `workspace.json` in the app's Application
Support directory, restricts file permissions and rejects unsupported versions
or malformed JSON. Preserve existing data on decode/migration errors. Schema
changes need a deliberate migration or decoding defaults plus a check using an
older saved file.

Raw audio is temporary; persisted history is text and metadata. History being
disabled does not by itself imply previously saved history was erased. Keep
deletion an explicit action. Model files are managed separately from history.
Do not commit recordings, user transcripts, model binaries, signing material or
local development permission settings.

Keep the core/app boundary until a concrete independent consumer or build-time
problem justifies another library module. Runtime engine implementations and their
configuration are the extension points; a generic plugin system is unnecessary.
