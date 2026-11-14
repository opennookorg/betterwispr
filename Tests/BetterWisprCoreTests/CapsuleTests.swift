import AppKit
import Foundation
import Testing
@testable import BetterWisprCore
@testable import BetterWispr

@Test(arguments: DictationSound.allCases) @MainActor func everyCuePlaysItsPickedSystemSoundOrFallsBackToItsDefault(cue: DictationSound) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(cue.url(in: directory) == nil)
    #expect(DictationSound.systemSoundNames.contains(cue.defaultSoundName))
    #expect(try #require(cue.sound(named: AppSettings().soundName(for: cue), in: directory)).name == cue.defaultSoundName)
    #expect(try #require(cue.sound(named: "Glass", in: directory)).name == "Glass")
    #expect(try #require(cue.sound(named: "No Such Sound", in: directory)).name == cue.defaultSoundName)
}

@Test @MainActor func overrideFileWinsOverThePickedSoundAndABrokenOverrideStaysSilent() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #expect(DictationSound.finished.url(in: directory) == nil)
    let custom = directory.appendingPathComponent("finished.wav")
    try Data(contentsOf: URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")).write(to: custom)
    #expect(DictationSound.finished.url(in: directory) == custom)
    let override = try #require(DictationSound.finished.sound(named: "Ping", in: directory))
    #expect(override.name == nil)
    #expect(DictationSound.attention.sound(named: "Ping", in: directory)?.name == "Ping")
    try Data().write(to: custom)
    #expect(DictationSound.finished.sound(named: "Ping", in: directory) == nil)
}

@Test @MainActor func hiddenCapsuleStaysAwayWhileDictatingButReturnsForCards() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    defer {
        model.phase = .idle
        try? FileManager.default.removeItem(at: folder)
    }
    model.settings.showCapsule = false
    model.phase = .recording
    var presentations = 0
    model.onPresentationChange = { presentations += 1 }
    model.advanceRecording(to: 30)
    #expect(model.showsCapsule && presentations == 0)
    model.advanceRecording(to: 0)
    model.settings.hideCapsuleWhileDictating = true
    #expect(!model.showsCapsule)

    model.advanceRecording(to: 3 * 3600)
    #expect(model.phase == .recording && !model.showsCapsule && presentations == 0)

    model.phase = .transcribing
    #expect(!model.showsCapsule)
    model.phase = .cancelled
    #expect(model.showsCapsule)
    model.phase = .failed(DictationFailure(title: "Couldn’t start dictation.", message: "Microphone access is off."))
    #expect(model.showsCapsule)
    model.phase = .idle
    #expect(!model.showsCapsule)
}

@Test @MainActor func capsuleHoverTracksEachControlAcrossExpansionAndExit() {
    let hover = CapsuleHover()
    hover.update(regions: [.surface: CGRect(x: 202, y: 218, width: 36, height: 6)])
    hover.move(to: CGPoint(x: 190, y: 210))
    #expect(hover.isHovering)

    let controls: [CapsuleHover.Target: CGRect] = [
        .surface: CGRect(x: 172, y: 196, width: 96, height: 28),
        .microphone: CGRect(x: 172, y: 196, width: 42, height: 28),
        .notetaker: CGRect(x: 218, y: 196, width: 28, height: 28),
        .meetingNotes: CGRect(x: 246, y: 196, width: 22, height: 28)
    ]
    hover.update(regions: controls)
    #expect(hover.target == .microphone)
    hover.move(to: CGPoint(x: 216, y: 210))
    #expect(hover.target == .microphone) // The gap should not flicker.
    hover.move(to: CGPoint(x: 230, y: 210))
    #expect(hover.target == .notetaker)
    hover.move(to: CGPoint(x: 257, y: 210))
    #expect(hover.target == .meetingNotes)

    hover.move(to: CGPoint(x: 10, y: 210))
    #expect(!hover.isHovering && hover.target == nil)
    hover.move(to: CGPoint(x: 230, y: 210))
    hover.move(to: nil)
    #expect(!hover.isHovering && hover.target == nil)

    hover.move(to: CGPoint(x: 220, y: 210))
    hover.update(regions: [
        .surface: CGRect(x: 183, y: 192, width: 74, height: 32),
        .dictation: CGRect(x: 183, y: 192, width: 74, height: 32)
    ])
    #expect(hover.target == .dictation)
    hover.update(regions: [
        .surface: CGRect(x: 183, y: 192, width: 74, height: 32),
        .notetaker: CGRect(x: 183, y: 192, width: 74, height: 32)
    ])
    #expect(hover.target == .notetaker) // The recording pill replaces all idle controls.
    hover.update(regions: [.surface: CGRect(x: 40, y: 104, width: 360, height: 120)])
    #expect(hover.isHovering && hover.target == nil) // No stale tooltip over an error.
}

@Test @MainActor func noSpeechCardCanBeTurnedOff() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    model.settings.soundEffects = false

    model.phase = .transcribing
    model.noSpeechHeard()
    #expect(model.phase == .failed(.noSpeech))

    model.settings.showNoSpeechNotice = false
    model.phase = .transcribing
    model.noSpeechHeard()
    #expect(model.phase == .idle && model.statusMessage.isEmpty)
}

@Test @MainActor func noSpeechCardStaysWhenAnEarlierDictationWasLeftUnsent() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    model.settings.soundEffects = false
    model.settings.showNoSpeechNotice = false
    defer { model.discardRecording() }

    model.pressSendKey(in: .current, after: .seconds(1), using: FocusedAppIntegration(keepsCopy: false),
                       otherwise: {}, resolving: { _, _ in nil })
    model.toggleRecording()
    #expect(model.phase == .preparing)

    model.noSpeechHeard()
    #expect(model.failure?.title == DictationFailure.noSpeech.title)
    #expect(model.failure?.message.hasSuffix("Your earlier dictation was pasted but not sent.") == true)
}

@Test @MainActor func recordingFailureStillShowsWithTheNoSpeechCardOff() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    model.settings.soundEffects = false
    model.settings.showNoSpeechNotice = false

    model.phase = .recording
    model.toggleRecording()
    let deadline = ContinuousClock.now + .seconds(2)
    while model.phase == .transcribing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.failure?.title == "Couldn’t finish recording.")
    #expect(model.statusMessage == AudioRecordingError.notRecording.localizedDescription)
}

@Test @MainActor func quickTapBecomesHandsFreeAndCancelledReleaseCannotFinishANewSession() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    model.settings.soundEffects = false
    defer { model.discardRecording() }

    model.shortcutPressed()
    #expect(model.phase == .preparing && model.isHeldSession)
    model.shortcutReleased()
    #expect(model.phase == .preparing && !model.isHeldSession)
    model.shortcutReleased()
    #expect(model.phase == .preparing)
    model.cancelRecording()
    #expect(model.phase == .cancelled && !model.canUndoCancellation)
    #expect(model.cardDeadline != nil)

    model.shortcutPressed()
    model.cancelRecording()
    model.toggleRecording()
    model.shortcutReleased()
    #expect(model.phase == .preparing && !model.isHeldSession)
    #expect(model.cardDeadline == nil)
}

@Test @MainActor func cancellationUndoOwnsAudioUntilDismissalAndNeverDeliversStaleWork() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    model.settings.soundEffects = false
    model.settings.autoPaste = false
    model.settings.copyToClipboard = false
    defer { model.discardRecording() }
    let url = folder.appendingPathComponent("cancelled.caf")
    try Data("synthetic audio ownership check".utf8).write(to: url)
    var recording: DictationRecording? = DictationRecording(
        audio: RecordedAudio(url: url, duration: 1, hasSpeech: true), model: model.selectedModel,
        settings: model.settings, vocabulary: [], target: nil)
    weak let retained = recording
    model.transcribe(try #require(recording))
    recording = nil
    model.cancelRecording()
    #expect(model.canUndoCancellation)
    #expect(FileManager.default.fileExists(atPath: url.path))
    model.settings.language = "hi"
    #expect(retained?.settings.language == "auto")

    model.undoCancellation()
    #expect(model.phase == .transcribing && !model.canUndoCancellation)
    #expect(model.cardDeadline == nil)
    model.undoCancellation()
    model.cancelRecording()
    #expect(model.canUndoCancellation)
    model.dismissCard()
    model.undoCancellation()
    #expect(model.phase == .idle && !model.canUndoCancellation)
    try await Task.sleep(for: .milliseconds(100))
    #expect(retained == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(model.history.isEmpty && model.partialTranscript.isEmpty)

    model.toggleRecording()
    model.cancelRecording()
    model.phase = .recording
    try await Task.sleep(for: .seconds(AppModel.cancellationSeconds + 0.1))
    #expect(model.phase == .recording)
    model.discardRecording()

    try Data("synthetic expired undo check".utf8).write(to: url)
    model.transcribe(DictationRecording(
        audio: RecordedAudio(url: url, duration: 1, hasSpeech: true), model: model.selectedModel,
        settings: model.settings, vocabulary: [], target: nil))
    model.cancelRecording()
    #expect(model.canUndoCancellation)
    try await Task.sleep(for: .seconds(AppModel.cancellationSeconds + 0.1))
    #expect(model.phase == .idle && !model.canUndoCancellation)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    model.undoCancellation()
    #expect(model.phase == .idle)
}

@Test @MainActor func cancelShortcutArmsOnceWhenADictationTurnsBusyAndDisarmsOnceWhenItStops() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    model.settings.soundEffects = false
    model.settings.autoPaste = false
    model.settings.copyToClipboard = false
    defer { model.discardRecording() }
    var armed: [Bool] = []
    model.onBusyChange = { armed.append($0) }

    model.toggleRecording()
    #expect(model.phase == .preparing && armed == [true])
    model.phase = .recording
    model.phase = .transcribing
    model.cancelRecording()
    let url = folder.appendingPathComponent("cancelled.caf")
    try Data("synthetic busy edge check".utf8).write(to: url)
    model.transcribe(DictationRecording(
        audio: RecordedAudio(url: url, duration: 1, hasSpeech: true), model: model.selectedModel,
        settings: model.settings, vocabulary: [], target: nil))
    model.cancelRecording()
    model.undoCancellation()
    model.discardRecording()
    model.dismissCard()
    #expect(armed == [true, false, true, false, true, false])
}

@Test @MainActor func darkIsTheDefaultThemeAndEachThemeSetsTheAppAppearance() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        NSApplication.shared.appearance = nil
        try? FileManager.default.removeItem(at: folder)
    }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    #expect(model.settings.theme == .dark)
    model.settings.theme = .light
    model.saveSettings()
    #expect(NSApplication.shared.appearance?.name == .aqua)
    #expect(try LocalStore(directory: folder).load().settings.theme == .light)
    model.settings.theme = .dark
    model.saveSettings()
    #expect(NSApplication.shared.appearance?.name == .darkAqua)
    model.settings.theme = .cream
    model.saveSettings()
    #expect(NSApplication.shared.appearance?.name == .aqua)
    #expect(try LocalStore(directory: folder).load().settings.theme == .cream)
    model.settings.theme = .system
    model.saveSettings()
    #expect(NSApplication.shared.appearance == nil)
    #expect(try LocalStore(directory: folder).load().settings.theme == .system)
}

@Test @MainActor func idleUnloadReleasesTheModelOnlyWhenChosenAndNeverDuringADictation() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    model.settings.soundEffects = false
    let apple = try #require(SpeechModel.catalog.first { $0.engine == .apple })
    model.selectModel(apple, prepared: AppleSpeechProvider())

    model.scheduleIdleUnload(after: .milliseconds(20))
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.isSpeechModelLoaded)

    model.settings.unloadModelWhenIdle = .fiveMinutes
    model.scheduleIdleUnload(after: .milliseconds(50))
    model.phase = .recording
    model.scheduleIdleUnload(after: .milliseconds(20))
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.isSpeechModelLoaded)

    model.phase = .idle
    model.scheduleIdleUnload(after: .milliseconds(20))
    try await Task.sleep(for: .milliseconds(150))
    #expect(!model.isSpeechModelLoaded)

    model.scheduleIdleUnload(after: .milliseconds(20))
    model.selectModel(apple, prepared: AppleSpeechProvider())
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.isSpeechModelLoaded)
}

@Test @MainActor func meetingPromptAppearsOncePerCallAndNeverAlongsideTheNotetaker() {
    let model = AppModel(store: LocalStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                         startsServices: false)
    let detector = model.meetingDetector
    let zoom = DetectedMeeting(platform: .zoom, appID: "us.zoom.xos")
    let meet = DetectedMeeting(platform: .googleMeet, appID: "com.google.Chrome")

    detector.update([zoom], recording: [zoom.appID])
    #expect(detector.meeting == zoom)
    detector.dismiss()
    detector.update([zoom], recording: [zoom.appID])
    #expect(detector.meeting == nil)
    detector.update([], recording: [])
    detector.update([zoom], recording: [zoom.appID])
    #expect(detector.meeting == zoom)

    detector.update([meet], recording: [meet.appID])
    #expect(detector.meeting == meet)
    let earlier = UUID()
    model.meetings.runs[earlier] = MeetingRun(meetingID: earlier, phase: .recording)
    detector.update([meet], recording: [meet.appID])
    #expect(detector.meeting == nil)
    model.meetings.runs = [:]
    detector.update([meet], recording: [meet.appID])
    #expect(detector.meeting == nil)

    model.meetings.runs[earlier] = MeetingRun(meetingID: earlier, phase: .finishing)
    detector.update([zoom], recording: [zoom.appID])
    #expect(detector.meeting == zoom)
}

@Test @MainActor func escapeStaysArmedWhileASendCountsDownAndHoldingBackEndsIt() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    var armed: [Bool] = []
    model.onBusyChange = { armed.append($0) }

    model.phase = .transcribing
    model.phase = .sending
    #expect(armed == [true])
    model.holdBackReturn()
    #expect(model.phase == .idle && armed == [true, false])
    model.holdBackReturn()
    #expect(model.phase == .idle && armed == [true, false])
}

@Test(arguments: [Duration.milliseconds(120), .milliseconds(250)]) @MainActor
func pendingSendStaysCancellableThroughTheFinalPromptCheck(delay: Duration) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    model.settings.soundEffects = false
    model.settings.sendToClaude = true
    var checkStarted = false
    var releaseCheck: CheckedContinuation<Bool, Never>?
    var notSent = 0
    model.pressSendKey(in: .current, after: delay, using: FocusedAppIntegration(keepsCopy: false),
                       otherwise: { notSent += 1 }, resolving: { _, _ in
        checkStarted = true
        return await withCheckedContinuation { releaseCheck = $0 } ? .return : nil
    })
    #expect(model.phase == .sending && model.phase.armsCancelShortcut)
    let deadline = ContinuousClock.now + .seconds(2)
    while !checkStarted, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(checkStarted)
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.phase == .sending && model.phase.armsCancelShortcut)
    model.holdBackReturn()
    #expect(model.phase == .idle && notSent == 1)
    releaseCheck?.resume(returning: true)
    try await Task.sleep(for: .milliseconds(30))
    #expect(model.phase == .idle && notSent == 1)
}

@Test @MainActor func disablingSendCancelsAnInFlightPromptCheck() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    model.settings.soundEffects = false
    model.settings.sendToClaude = true
    var releaseCheck: CheckedContinuation<Bool, Never>?
    var notSent = 0
    model.pressSendKey(in: .current, after: .zero, using: FocusedAppIntegration(keepsCopy: false),
                       otherwise: { notSent += 1 }, resolving: { _, _ in
        await withCheckedContinuation { releaseCheck = $0 } ? .return : nil
    })
    let deadline = ContinuousClock.now + .seconds(2)
    while releaseCheck == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(releaseCheck != nil)
    model.settings.sendToClaude = false
    model.saveSettings()
    #expect(model.phase == .idle && notSent == 1)
    releaseCheck?.resume(returning: true)
    try await Task.sleep(for: .milliseconds(30))
    #expect(model.phase == .idle && notSent == 1)
}

@Test @MainActor func selectedTextCleanupHoldsBackAPendingSendBeforeStarting() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    model.settings.sendToClaude = true
    var notSent = 0
    model.pressSendKey(in: .current, after: .seconds(1), using: FocusedAppIntegration(keepsCopy: false),
                       otherwise: { notSent += 1 }, resolving: { _, _ in nil })
    model.cleanUpSelectedText()
    #expect(model.phase == .idle && notSent == 1)
    // Keep the cleanup task from reading the user's actual selection in this test.
    model.phase = .preparing
}

@Test @MainActor func discardingADictationCancelsItsPendingSendBeforeItResolves() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    model.settings.soundEffects = false
    model.settings.sendToClaude = true
    var resolved = false
    var notSent = 0
    model.pressSendKey(in: .current, after: .milliseconds(50), using: FocusedAppIntegration(keepsCopy: false),
                       otherwise: { notSent += 1 }, resolving: { _, _ in
        resolved = true
        return .return
    })
    model.discardRecording()
    try await Task.sleep(for: .milliseconds(150))
    #expect(!resolved && notSent == 0)
}

@Test @MainActor func expiredMeetingPromptRecordsNothingAndStaysDismissedForThatCall() async throws {
    let model = AppModel(store: LocalStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                         startsServices: false)
    let detector = model.meetingDetector
    let zoom = DetectedMeeting(platform: .zoom, appID: "us.zoom.xos")
    #expect(detector.timeout == 30)

    detector.timeout = 0.05
    detector.update([zoom], recording: [zoom.appID])
    let deadline = try #require(detector.deadline)
    #expect(deadline.timeIntervalSinceNow <= 0.05)
    try await waitUntil { detector.meeting == nil }
    #expect(detector.meeting == nil && detector.deadline == nil)
    #expect(model.meetings.capturingID == nil && model.meetings.runs.isEmpty)
    detector.update([zoom], recording: [zoom.appID])
    #expect(detector.meeting == nil)

    detector.update([], recording: [])
    detector.timeout = MeetingPromptTimeout.never.seconds
    detector.update([zoom], recording: [zoom.appID])
    try await Task.sleep(for: .milliseconds(150))
    #expect(detector.meeting == zoom && detector.deadline == nil)

    detector.timeout = 0.05
    #expect(detector.deadline != nil)
    try await waitUntil { detector.meeting == nil }
    #expect(detector.meeting == nil)
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let limit = clock.now + .seconds(5)
    while !condition(), clock.now < limit { try await Task.sleep(for: .milliseconds(20)) }
}

@Test @MainActor func savingSettingsAppliesTheMeetingPromptTimeout() {
    let model = AppModel(store: LocalStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                         startsServices: false)
    model.settings.meetingPromptTimeout = .sixtySeconds
    model.saveSettings()
    #expect(model.meetingDetector.timeout == 60)
    model.settings.meetingPromptTimeout = .never
    model.saveSettings()
    #expect(model.meetingDetector.timeout == nil)
}

@Test func olderAndUnknownMeetingPromptSettingsDecodeToTodaysBehavior() throws {
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
    json["meetingPromptPosition"] = nil
    json["meetingPromptTimeout"] = nil
    var settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(settings.meetingPromptPosition == .bottom && settings.meetingPromptTimeout == .thirtySeconds)

    json["meetingPromptPosition"] = "left"
    json["meetingPromptTimeout"] = 90
    settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(settings.meetingPromptPosition == .bottom && settings.meetingPromptTimeout == .thirtySeconds)

    json["meetingPromptPosition"] = "top"
    json["meetingPromptTimeout"] = 0
    settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(settings.meetingPromptPosition == .top && settings.meetingPromptTimeout == .never)
}

@Test @MainActor func meetingPromptSitsBelowTheMenuBarAndNotchOrAtTheBottom() {
    let size = CGSize(width: 440, height: 240)
    let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 70, width: 1512, height: 875)
    #expect(CapsuleController.origin(atTop: false, size: size, frame: frame, visibleFrame: visible, safeTop: 32) == CGPoint(x: 536, y: 82))
    #expect(CapsuleController.origin(atTop: true, size: size, frame: frame, visibleFrame: visible, safeTop: 32) == CGPoint(x: 536, y: 701))

    let fullScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    #expect(CapsuleController.origin(atTop: true, size: size, frame: frame, visibleFrame: fullScreen, safeTop: 32) == CGPoint(x: 536, y: 706))
    #expect(CapsuleController.origin(atTop: true, size: size, frame: frame, visibleFrame: fullScreen, safeTop: 0) == CGPoint(x: 536, y: 738))

    let side = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
    #expect(CapsuleController.origin(atTop: true, size: size, frame: side, visibleFrame: side.insetBy(dx: 0, dy: 12), safeTop: 0)
            == CGPoint(x: 2252, y: 624))
}

@Test @MainActor func capsuleRestsAtItsChosenBottomPositionButMeetingPromptsAtTheTopStayCentered() {
    let size = CGSize(width: 440, height: 240)
    let frame = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    let visible = CGRect(x: 1512, y: 70, width: 1920, height: 985)
    func origin(_ position: CapsulePosition, atTop: Bool = false) -> CGPoint {
        CapsuleController.origin(atTop: atTop, position: position, size: size, frame: frame, visibleFrame: visible, safeTop: 0)
    }
    #expect(origin(.bottomCenter) == CGPoint(x: 2252, y: 82))
    #expect(origin(.bottomLeft) == CGPoint(x: 1528, y: 82))
    #expect(origin(.bottomRight) == CGPoint(x: 2976, y: 82))
    #expect(CapsulePosition.allCases.map { origin($0, atTop: true) } == Array(repeating: CGPoint(x: 2252, y: 811), count: 3))
}

@Test @MainActor func meetingPromptFollowsTheScreenHoldingTheCallWindow() {
    let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: -200, width: 1920, height: 1080)]
    #expect(CapsuleController.screenIndex(showing: [CGRect(x: 1600, y: 300, width: 1200, height: 800)], in: screens) == 1)
    #expect(CapsuleController.screenIndex(showing: [CGRect(x: 100, y: 100, width: 900, height: 600)], in: screens) == 0)
    #expect(CapsuleController.screenIndex(showing: [CGRect(x: 1600, y: 300, width: 80, height: 40),
                                                    CGRect(x: 100, y: 100, width: 900, height: 600)], in: screens) == 0)
    #expect(CapsuleController.screenIndex(showing: [CGRect(x: 1300, y: 100, width: 400, height: 300)], in: screens) == 0)
    #expect(CapsuleController.screenIndex(showing: [CGRect(x: 9000, y: 9000, width: 900, height: 600)], in: screens) == nil)
    #expect(CapsuleController.screenIndex(showing: [], in: screens) == nil)
}
