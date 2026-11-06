import Foundation
import Testing
@testable import BetterWisprCore
@testable import BetterWispr

actor FakeMediaPlayers: MediaPlayers, OtherAppsAudio {
    private(set) var states: [MediaApp: PlayerState]
    private(set) var log: [String] = []
    private let muteError: (any Error)?

    init(_ states: [MediaApp: PlayerState], muteError: (any Error)? = nil) {
        self.states = states
        self.muteError = muteError
    }

    func set(_ app: MediaApp, to state: PlayerState) {
        states[app] = state
    }

    func state(of app: MediaApp) -> PlayerState {
        states[app] ?? .unavailable
    }

    func pause(_ app: MediaApp) {
        log.append("pause \(app)")
        states[app] = .paused
    }

    func play(_ app: MediaApp) {
        log.append("play \(app)")
        states[app] = .playing
    }

    func mute() throws {
        if let muteError { throw muteError }
        log.append("mute")
    }

    func unmute() {
        log.append("unmute")
    }
}

@Test @MainActor func resumePlaysOnlyTheAppsThePauseStopped() async {
    let players = FakeMediaPlayers([.music: .playing, .spotify: .paused])
    let pauser = MediaPauser(players: players, otherApps: nil)
    pauser.pause()
    await pauser.pending?.value
    #expect(await players.log == ["pause music"])
    pauser.resume()
    await pauser.pending?.value
    #expect(await players.log == ["pause music", "play music"])
    #expect(await players.states == [.music: .playing, .spotify: .paused])
}

@Test(arguments: [PlayerState.stopped, .playing])
@MainActor func resumeLeavesAnAppTheUserChangedDuringDictation(userState: PlayerState) async {
    let players = FakeMediaPlayers([.music: .playing])
    let pauser = MediaPauser(players: players, otherApps: nil)
    pauser.pause()
    await pauser.pending?.value
    await players.set(.music, to: userState)
    pauser.resume()
    await pauser.pending?.value
    #expect(await players.log == ["pause music"])
    #expect(await players.states[.music] == userState)
}

@Test @MainActor func quickRestartRunsPauseResumeAndPauseInOrder() async {
    let players = FakeMediaPlayers([.music: .playing])
    let pauser = MediaPauser(players: players, otherApps: nil)
    pauser.pause()
    pauser.resume()
    pauser.pause()
    await pauser.pending?.value
    #expect(await players.log == ["pause music", "play music", "pause music"])
    #expect(await players.states[.music] == .paused)
}

@Test @MainActor func unusedPauserStaysIdleAndUnreachableAppsAreNeverCommanded() async {
    let players = FakeMediaPlayers([.spotify: .playing])
    let pauser = MediaPauser(players: players, otherApps: nil)
    pauser.resume()
    #expect(pauser.pending == nil)
    #expect(await players.log.isEmpty)
    pauser.pause()
    pauser.resume()
    await pauser.pending?.value
    #expect(await players.log == ["pause spotify", "play spotify"])
}

@MainActor
private func dictationModel(_ players: FakeMediaPlayers, in folder: URL, callInProgress: @escaping @MainActor () -> Bool = { false }) -> AppModel {
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false,
                         mediaPauser: MediaPauser(players: players, otherApps: players, callInProgress: callInProgress))
    model.settings.soundEffects = false
    return model
}

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private struct MuteFailure: Error {}

@Test(arguments: [true, false])
@MainActor func thePauseSettingPausesMediaWhileTheMicrophoneIsHeldAndNeverMutes(enabled: Bool) async {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let players = FakeMediaPlayers([.music: .playing])
    let model = dictationModel(players, in: folder)
    model.settings.pauseMediaWhileDictating = enabled
    model.phase = .preparing
    model.phase = .recording
    await model.mediaPauser.pending?.value
    #expect(await players.log == (enabled ? ["pause music"] : []))
    model.phase = .transcribing
    await model.mediaPauser.pending?.value
    #expect(await players.log == (enabled ? ["pause music", "play music"] : []))
    #expect((model.mediaPauser.pending == nil) == !enabled)
}

@Test @MainActor func failingCancellingAndDiscardingADictationEachResumePausedMedia() async {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let players = FakeMediaPlayers([.music: .playing])
    let model = dictationModel(players, in: folder)
    model.settings.pauseMediaWhileDictating = true
    model.phase = .preparing
    model.phase = .failed(.noSpeech)
    model.phase = .preparing
    model.cancelRecording()
    model.phase = .recording
    model.cancelRecording()
    model.phase = .recording
    model.discardRecording()
    await model.mediaPauser.pending?.value
    #expect(model.phase == .idle)
    #expect(await players.log == Array(repeating: ["pause music", "play music"], count: 4).flatMap { $0 })
    #expect(await players.states[.music] == .playing)
}

@Test @MainActor func theMuteSettingWorksAloneAndLeavesPlayersPlaying() async {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let players = FakeMediaPlayers([.music: .playing])
    let model = dictationModel(players, in: folder)
    model.settings.muteOtherAppsWhileDictating = true
    model.phase = .preparing
    model.phase = .recording
    model.phase = .transcribing
    await model.mediaPauser.pending?.value
    #expect(await players.log == ["mute", "unmute"])
    #expect(await players.states[.music] == .playing)
}

@Test @MainActor func otherAppsStayAudibleUntilTheRecorderIsCapturingAndComeBackBeforeMusic() async {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let players = FakeMediaPlayers([.music: .playing])
    let model = dictationModel(players, in: folder)
    model.settings.pauseMediaWhileDictating = true
    model.settings.muteOtherAppsWhileDictating = true
    model.phase = .preparing
    await model.mediaPauser.pending?.value
    #expect(await players.log == ["pause music"])
    model.phase = .recording
    await model.mediaPauser.pending?.value
    #expect(await players.log == ["pause music", "mute"])
    model.phase = .transcribing
    await model.mediaPauser.pending?.value
    #expect(await players.log == ["pause music", "mute", "unmute", "play music"])
}

@Test @MainActor func aDictationThatEndsWhileStillPreparingNeverMutes() async {
    let exits: [@MainActor (AppModel) -> Void] = [
        { $0.phase = .failed(.noSpeech) },
        { $0.cancelRecording() },
        { $0.discardRecording() },
    ]
    for exit in exits {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let players = FakeMediaPlayers([:])
        let model = dictationModel(players, in: folder)
        model.settings.muteOtherAppsWhileDictating = true
        model.phase = .preparing
        exit(model)
        await model.mediaPauser.pending?.value
        #expect(await players.log.isEmpty)
    }
}

@Test @MainActor func everyWayOutOfARecordingUnmutesOtherApps() async {
    let exits: [@MainActor (AppModel) -> Void] = [
        { $0.phase = .transcribing },
        { $0.phase = .failed(.noSpeech) },
        { $0.cancelRecording() },
        { $0.discardRecording() },
        { $0.keepDictationForQuit(); $0.discardRecording() },
    ]
    for exit in exits {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let players = FakeMediaPlayers([:])
        let model = dictationModel(players, in: folder)
        model.settings.muteOtherAppsWhileDictating = true
        model.phase = .recording
        exit(model)
        await model.mediaPauser.pending?.value
        #expect(await players.log == ["mute", "unmute"])
    }
}

@Test(arguments: [MeetingPhase.starting, .recording])
@MainActor func dictatingDuringMeetingNotesPausesPlayersButLeavesOtherAppsAudible(meetingPhase: MeetingPhase) async {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let players = FakeMediaPlayers([.music: .playing])
    let model = dictationModel(players, in: folder)
    model.settings.pauseMediaWhileDictating = true
    model.settings.muteOtherAppsWhileDictating = true
    let meeting = UUID()
    model.meetings.runs[meeting] = MeetingRun(meetingID: meeting, phase: meetingPhase)
    model.phase = .preparing
    model.phase = .recording
    await model.mediaPauser.pending?.value
    #expect(await players.log == ["pause music"])
    model.phase = .transcribing
    await model.mediaPauser.pending?.value
    #expect(await players.log == ["pause music", "play music"])
}

@Test @MainActor func dictatingDuringACallLeavesOtherAppsAudibleAndNeverUnmutes() async {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let players = FakeMediaPlayers([.music: .playing])
    let model = dictationModel(players, in: folder, callInProgress: { true })
    model.settings.pauseMediaWhileDictating = true
    model.settings.muteOtherAppsWhileDictating = true
    model.phase = .preparing
    model.phase = .recording
    model.phase = .transcribing
    await model.mediaPauser.pending?.value
    #expect(await players.log == ["pause music", "play music"])
}

@Test(arguments: [
    (["us.zoom.xos"], true),
    (["com.apple.avconferenced"], true),
    (["com.google.Chrome.helper"], true),
    (["com.apple.WebKit.GPU"], true),
    (["org.betterwispr.app", "com.tinyspeck.slackmacgap"], true),
    (["org.betterwispr.app", "com.apple.dt.Xcode"], false),
    ([], false),
])
func aCallIsAssumedWhenAKnownCallAppOrABrowserUsesTheMicrophone(recording: [String], expected: Bool) {
    #expect(MeetingPlatform.mayBeInCall(recording: recording) == expected)
}

@Test @MainActor func turningTheSettingOffMidDictationStillUnmutesOtherApps() async {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let players = FakeMediaPlayers([:])
    let model = dictationModel(players, in: folder)
    model.settings.muteOtherAppsWhileDictating = true
    model.phase = .recording
    model.settings.muteOtherAppsWhileDictating = false
    model.phase = .transcribing
    await model.mediaPauser.pending?.value
    #expect(await players.log == ["mute", "unmute"])
}

@Test @MainActor func aFailedMuteIsReportedKeepsTheDictationGoingAndNeverUnmutes() async {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let players = FakeMediaPlayers([.music: .playing], muteError: MuteFailure())
    let model = dictationModel(players, in: folder)
    model.settings.pauseMediaWhileDictating = true
    model.settings.muteOtherAppsWhileDictating = true
    var failures: [any Error] = []
    model.mediaPauser.onMuteFailure = { failures.append($0) }
    model.phase = .preparing
    model.phase = .recording
    await model.mediaPauser.pending?.value
    #expect(failures.count == 1)
    #expect(failures.first is MuteFailure)
    #expect(model.phase == .recording)
    #expect(await players.log == ["pause music"])
    model.phase = .transcribing
    await model.mediaPauser.pending?.value
    #expect(await players.log == ["pause music", "play music"])
}

@Test @MainActor func unmutingTwiceOrWithoutAMuteDoesNothing() async {
    let players = FakeMediaPlayers([:])
    let pauser = MediaPauser(players: players, otherApps: players, callInProgress: { false })
    pauser.unmuteOtherApps()
    #expect(pauser.pending == nil)
    pauser.muteOtherApps()
    pauser.unmuteOtherApps()
    pauser.unmuteOtherApps()
    await pauser.pending?.value
    #expect(await players.log == ["mute", "unmute"])
}

@available(macOS 14.2, *)
@MainActor
private final class FakeTap: MutingTap {
    var failure: (any Error)?
    private(set) var events: [String] = []

    func begin() throws {
        events.append("begin")
        if let failure { throw failure }
    }

    func stop() {
        events.append("stop")
    }
}

@available(macOS 14.2, *)
@Test @MainActor func aFailedTapIsStoppedRethrownAndRetriedNextTime() async throws {
    let failing = FakeTap()
    failing.failure = MuteFailure()
    let working = FakeTap()
    var taps = [failing, working]
    let mute = SystemAudioMute(makeTap: { taps.removeFirst() })
    await #expect(throws: MuteFailure.self) { try await mute.mute() }
    #expect(failing.events == ["begin", "stop"])
    try await mute.mute()
    #expect(working.events == ["begin"])
    mute.unmute()
    #expect(working.events == ["begin", "stop"])
}

@available(macOS 14.2, *)
@Test @MainActor func mutingTwiceUsesOneTapAndUnmutingWithoutOneDoesNothing() async throws {
    let tap = FakeTap()
    var made = 0
    let mute = SystemAudioMute(makeTap: { made += 1; return tap })
    mute.unmute()
    #expect(made == 0)
    try await mute.mute()
    try await mute.mute()
    #expect(made == 1)
    mute.unmute()
    mute.unmute()
    #expect(tap.events == ["begin", "stop"])
}

@Test func mutingCodeCannotChangeAMuteTheUserSetOnTheOutputDevice() throws {
    let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources")
    let files = ["BetterWispr/App/MediaPauser.swift", "BetterWisprCore/Audio/SystemAudioMute.swift", "BetterWisprCore/Audio/SystemAudioTap.swift"]
    let deviceControls = ["kAudioDevicePropertyMute", "kAudioDevicePropertyVolumeScalar", "VirtualMainVolume", "VirtualMasterVolume", "AudioObjectSetPropertyData", "set volume"]
    for file in files {
        let source = try String(contentsOf: sources.appending(path: file), encoding: .utf8)
        for control in deviceControls { #expect(!source.contains(control), "\(file) uses \(control)") }
    }
}
