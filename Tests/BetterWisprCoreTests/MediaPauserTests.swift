import Foundation
import Testing
@testable import BetterWisprCore
@testable import BetterWispr

actor FakeMediaPlayers: MediaPlayers, OtherAppsAudio {
    private(set) var states: [MediaApp: PlayerState]
    private(set) var log: [String] = []

    init(_ states: [MediaApp: PlayerState]) {
        self.states = states
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

    func mute() {
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

@Test(arguments: [true, false])
@MainActor func dictationPausesMediaOnlyWhileTheMicrophoneIsHeld(enabled: Bool) async {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let players = FakeMediaPlayers([.music: .playing])
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false, mediaPauser: MediaPauser(players: players, otherApps: players))
    model.settings.pauseMediaWhileDictating = enabled
    model.phase = .preparing
    model.phase = .recording
    await model.mediaPauser.pending?.value
    #expect(await players.log == (enabled ? ["mute", "pause music"] : []))
    model.phase = .transcribing
    await model.mediaPauser.pending?.value
    #expect(await players.log == (enabled ? ["mute", "pause music", "unmute", "play music"] : []))
    #expect((model.mediaPauser.pending == nil) == !enabled)
}

@Test @MainActor func failingCancellingAndDiscardingADictationEachResumePausedMedia() async {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let players = FakeMediaPlayers([.music: .playing])
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false, mediaPauser: MediaPauser(players: players, otherApps: players))
    model.settings.pauseMediaWhileDictating = true
    model.settings.soundEffects = false
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
    #expect(await players.log == Array(repeating: ["mute", "pause music", "unmute", "play music"], count: 4).flatMap { $0 })
    #expect(await players.states[.music] == .playing)
}

@Test(arguments: [PlayerState.playing, .paused])
@MainActor func otherAppsAreMutedForTheWholeDictationWhateverThePlayersDo(musicState: PlayerState) async {
    let players = FakeMediaPlayers([.music: musicState])
    let pauser = MediaPauser(players: players, otherApps: players)
    pauser.pause()
    pauser.resume()
    pauser.pause()
    pauser.resume()
    await pauser.pending?.value
    let once = musicState == .playing ? ["mute", "pause music", "unmute", "play music"] : ["mute", "unmute"]
    #expect(await players.log == once + once)
}

@Test(arguments: [MeetingPhase.starting, .recording])
@MainActor func dictatingDuringMeetingNotesPausesPlayersButLeavesOtherAppsAudible(meetingPhase: MeetingPhase) async {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let players = FakeMediaPlayers([.music: .playing])
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false, mediaPauser: MediaPauser(players: players, otherApps: players))
    model.settings.pauseMediaWhileDictating = true
    let meeting = UUID()
    model.meetings.runs[meeting] = MeetingRun(meetingID: meeting, phase: meetingPhase)
    model.phase = .preparing
    await model.mediaPauser.pending?.value
    #expect(await players.log == ["pause music"])
    model.phase = .transcribing
    await model.mediaPauser.pending?.value
    #expect(await players.log == ["pause music", "play music"])
}

@Test @MainActor func turningTheSettingOffMidDictationStillUnmutesOtherApps() async {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let players = FakeMediaPlayers([:])
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false, mediaPauser: MediaPauser(players: players, otherApps: players))
    model.settings.pauseMediaWhileDictating = true
    model.phase = .preparing
    model.settings.pauseMediaWhileDictating = false
    model.phase = .transcribing
    await model.mediaPauser.pending?.value
    #expect(await players.log == ["mute", "unmute"])
}

@Test @MainActor func pausingWithoutMutingLeavesOtherAppsAudible() async {
    let players = FakeMediaPlayers([.music: .playing])
    let pauser = MediaPauser(players: players, otherApps: players)
    pauser.pause(mutingOtherApps: false)
    pauser.resume()
    await pauser.pending?.value
    #expect(await players.log == ["pause music", "play music"])
}
