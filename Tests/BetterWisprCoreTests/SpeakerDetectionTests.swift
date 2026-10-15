import Foundation
import SpeakerKit
import Testing
@testable import BetterWisprCore

private func turn(_ voice: Int, _ start: Float, _ end: Float) -> SpeakerSegment {
    SpeakerSegment(speaker: .speakerId(voice), startTime: start, endTime: end, frameRate: 1)
}

@Test func speakerDetectionSplitsSegmentsAtVoiceChangesAndFoldsShortInterjections() {
    let ids = (0..<8).map { _ in UUID() }
    let turns = [
        turn(1, 50, 53), turn(2, 55, 60), turn(3, 0, 5), turn(1, 5, 12), turn(3, 12, 20), turn(9, 40, 40.5), turn(8, 40.5, 42),
        turn(1, 70, 75), turn(2, 75, 75.4), turn(1, 75.4, 80), turn(1, 90, 96), turn(2, 95, 100),
        SpeakerSegment(speaker: .noMatch, startTime: 20, endTime: 25, frameRate: 1),
    ]
    let placements = [
        SpeakerRecording.Placement(segment: ids[0], start: 0, end: 4),
        SpeakerRecording.Placement(segment: ids[1], start: 4.5, end: 10),
        SpeakerRecording.Placement(segment: ids[2], start: 10, end: 20),
        SpeakerRecording.Placement(segment: ids[3], start: 20, end: 25),
        SpeakerRecording.Placement(segment: ids[4], start: 40, end: 42),
        SpeakerRecording.Placement(segment: ids[5], start: 50, end: 60),
        SpeakerRecording.Placement(segment: ids[6], start: 70, end: 80),
        SpeakerRecording.Placement(segment: ids[7], start: 90, end: 100),
    ]

    let voices = SpeakerDetection.voiceTurns(turns: turns, placements: placements, shortest: 1)

    #expect(voices[ids[0]] == [VoiceTurn(voice: "3", start: 0, end: 4)])
    #expect(voices[ids[1]] == [VoiceTurn(voice: "1", start: 0, end: 5.5)])
    #expect(voices[ids[2]] == [VoiceTurn(voice: "1", start: 0, end: 2), VoiceTurn(voice: "3", start: 2, end: 10)])
    #expect(voices[ids[3]] == nil)
    #expect(voices[ids[4]] == [VoiceTurn(voice: "8", start: 0, end: 2)])
    #expect(voices[ids[5]] == [VoiceTurn(voice: "1", start: 0, end: 4), VoiceTurn(voice: "2", start: 4, end: 10)])
    #expect(voices[ids[6]] == [VoiceTurn(voice: "1", start: 0, end: 10)])
    #expect(voices[ids[7]] == [VoiceTurn(voice: "1", start: 0, end: 6), VoiceTurn(voice: "2", start: 6, end: 10)])
    #expect(SpeakerDetection.voiceTurns(turns: [], placements: placements).isEmpty)
}

@MainActor
@Test func speakerLabelsTranscribeMixedSegmentsAgainInPiecesAndKeepTextWhenAPieceFails() async throws {
    let me = MeetingSegment(speaker: .me, start: 0, duration: 3, text: "Shall we start?", rawText: "shall we start")
    let solo = MeetingSegment(speaker: .them, start: 3, duration: 4, text: "Sure.", rawText: "sure")
    let mixed = MeetingSegment(speaker: .them, start: 7, duration: 10, text: "I can take it. No, let me.", rawText: "i can take it no let me")
    let failing = MeetingSegment(speaker: .them, start: 17, duration: 6, text: "Fine by me, thanks.", rawText: "fine by me thanks")
    let unheard = MeetingSegment(speaker: .them, start: 23, duration: 2, text: "Hmm.", rawText: "hmm")
    let turns = [
        solo.id: [VoiceTurn(voice: "B", start: 0, end: 4)],
        mixed.id: [VoiceTurn(voice: "A", start: 0, end: 6), VoiceTurn(voice: "B", start: 6, end: 10)],
        failing.id: [VoiceTurn(voice: "C", start: 0, end: 2), VoiceTurn(voice: "A", start: 2, end: 6)],
    ]
    var written: [URL] = []

    let labelled = try await SpeakerDetection.label([me, solo, mixed, failing, unheard], turns: turns, audio: { _, _ in
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: url)
        written.append(url)
        return url
    }) { _, start, duration in
        if start >= 17 { throw CocoaError(.fileReadCorruptFile) }
        return MeetingSegment(speaker: .them, start: start, duration: duration, text: start == 7 ? "I can take it." : "No, let me.", rawText: "")
    }.segments

    #expect(labelled.map(\.text) == ["Shall we start?", "Sure.", "I can take it.", "No, let me.", "Fine by me, thanks.", "Hmm."])
    #expect(labelled.map(\.start) == [0, 3, 7, 13, 17, 23])
    #expect(labelled.map(\.participant) == [nil, 1, 2, 1, 2, nil])
    #expect(written.count == 3)
    #expect(written.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
}

@MainActor
@Test func roomVoicesGetNumbersWhileTheMostHeardMicrophoneVoiceStaysMe() async throws {
    let mine = MeetingSegment(speaker: .me, start: 0, duration: 6, text: "Morning, let us look at the launch plan.", rawText: "")
    let remote = MeetingSegment(speaker: .them, start: 6, duration: 4, text: "Sounds good.", rawText: "")
    let room = MeetingSegment(speaker: .me, start: 10, duration: 3, text: "I can take the slides.", rawText: "")
    let mixed = MeetingSegment(speaker: .me, start: 13, duration: 8, text: "Great, thanks. Then I will draft the email.", rawText: "")
    let echo = MeetingSegment(speaker: .me, start: 21, duration: 20, text: "We should move the launch to next Friday.", rawText: "")
    let echoed = MeetingSegment(speaker: .them, start: 21, duration: 20, text: "We should move the launch to next Friday.", rawText: "")
    let myVoiceOnTheCall = MeetingSegment(speaker: .them, start: 45, duration: 2, text: "Can you hear me?", rawText: "")
    let turns = [
        mine.id: [VoiceTurn(voice: "A", start: 0, end: 6)],
        remote.id: [VoiceTurn(voice: "C", start: 0, end: 4)],
        room.id: [VoiceTurn(voice: "B", start: 0, end: 3)],
        mixed.id: [VoiceTurn(voice: "A", start: 0, end: 4), VoiceTurn(voice: "B", start: 4, end: 8)],
        echo.id: [VoiceTurn(voice: "E", start: 0, end: 20)],
        echoed.id: [VoiceTurn(voice: "D", start: 0, end: 20)],
        myVoiceOnTheCall.id: [VoiceTurn(voice: "A", start: 0, end: 2)],
    ]

    let embeddings: [String: [Float]] = ["A": [1, 0, 0], "B": [0, 1, 0], "C": [0, 0, 1], "D": [1, 1, 0], "E": [0, 1, 1]]

    let (labelled, voices) = try await SpeakerDetection.label([mine, remote, room, mixed, echo, echoed, myVoiceOnTheCall], turns: turns, embeddings: embeddings, audio: { _, _ in
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: url)
        return url
    }) { _, start, duration in
        MeetingSegment(speaker: .them, start: start, duration: duration, text: start == 13 ? "Great, thanks." : "Then I will draft the email.", rawText: "")
    }

    #expect(labelled.map(\.speaker) == [.me, .them, .me, .me, .me, .me, .them, .them])
    #expect(labelled.map(\.participant) == [nil, 1, 2, nil, 2, nil, 3, 4])
    #expect(labelled.map { $0.label() } == ["Me", "Speaker 1", "Speaker 2", "Me", "Speaker 2", "Me", "Speaker 3", "Speaker 4"])
    #expect(voices == [1: [0, 0, 1], 2: [0, 1, 0], 3: [1, 1, 0], 4: [1, 0, 0]])
}

@Test func speakerLabelsUseGivenNamesAndFallBackToNumbers() {
    let me = MeetingSegment(speaker: .me, start: 0, duration: 2, text: "Can we ship Friday?", rawText: "")
    let them = MeetingSegment(speaker: .them, start: 2, duration: 2, text: "Probably.", rawText: "")
    let ana = MeetingSegment(speaker: .them, start: 4, duration: 2, text: "Only if QA signs off.", rawText: "", participant: 2)
    let bo = MeetingSegment(speaker: .them, start: 6, duration: 2, text: "Agreed.", rawText: "", participant: 1)
    let cy = MeetingSegment(speaker: .me, start: 8, duration: 2, text: "I can test it tonight.", rawText: "", participant: 3)

    #expect(me.label(names: [1: "Ana"]) == "Me")
    #expect(them.label(names: [1: "Ana"]) == "Them")
    #expect(ana.label() == "Speaker 2")
    #expect(ana.label(names: [2: "  Ana "]) == "Ana")
    #expect(ana.label(names: [2: " "]) == "Speaker 2")
    #expect(cy.label() == "Speaker 3")

    var meeting = Meeting(modelName: "Parakeet", language: "en")
    for segment in [cy, bo, ana, them, me] { meeting.insert(segment) }
    meeting.participantNames = [2: "Ana", 3: "Cy"]
    #expect(meeting.participants == [1, 2, 3])
    #expect(meeting.transcript.components(separatedBy: "\n").map { $0.components(separatedBy: "] ").last ?? "" } == [
        "Me: Can we ship Friday?", "Them: Probably.", "Ana: Only if QA signs off.", "Speaker 1: Agreed.", "Cy: I can test it tonight.",
    ])
    #expect(TranscriptChunker.chunks(meeting.segments, names: meeting.participantNames, budget: 500) == [
        "Me: Can we ship Friday?\nThem: Probably.\nAna: Only if QA signs off.\nSpeaker 1: Agreed.\nCy: I can test it tonight.",
    ])
}

@Test func meetingsKeepSpeakerNamesAndLoadFilesSavedBeforeSpeakers() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    var meeting = Meeting(modelName: "Parakeet", language: "en")
    meeting.insert(MeetingSegment(speaker: .them, start: 0, duration: 2, text: "Hello", rawText: "hello", participant: 2))
    meeting.participantNames = [2: "Ana"]
    try store.save(meeting)
    #expect(store.load().meetings == [meeting])

    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
    json["participantNames"] = nil
    json["segments"] = (json["segments"] as? [[String: Any]])?.map { $0.filter { $0.key != "participant" } }
    let legacy = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(legacy.participantNames == nil)
    #expect(legacy.segments.map(\.participant) == [nil])
    #expect(legacy.segments.map(\.text) == ["Hello"])
}

@Test func speakerDetectionIsInstalledOnlyWithTheMarkerAndEveryPinnedModel() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func add(_ model: String) throws {
        try FileManager.default.createDirectory(at: directory.appending(path: model), withIntermediateDirectories: true)
    }
    let marker = directory.appending(path: ".betterwispr-installed")

    try Data().write(to: marker)
    #expect(!SpeakerDetection.isInstalled(at: directory))
    try add("speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc")
    try add("speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc")
    try add("speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc")
    try add("speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc")
    #expect(!SpeakerDetection.isInstalled(at: directory))
    try add("speaker_segmenter/pyannote-v3/W32A32/SpeakerSegmenter.mlmodelc")
    #expect(SpeakerDetection.isInstalled(at: directory))
    try FileManager.default.removeItem(at: marker)
    #expect(!SpeakerDetection.isInstalled(at: directory))
}

@Test func speakerDetectionStopsWaitingForWorkThatIgnoresCancellation() async throws {
    #expect(try await SpeakerDetection.abandoningOnCancel { 42 } == 42)
    await #expect(throws: CocoaError.self) {
        try await SpeakerDetection.abandoningOnCancel { () async throws -> Int in throw CocoaError(.fileReadCorruptFile) }
    }

    let clock = ContinuousClock()
    let started = clock.now
    let waiting = Task {
        try await SpeakerDetection.abandoningOnCancel {
            await Task.detached { try? await Task.sleep(for: .seconds(30)) }.value
            return 1
        }
    }
    try await Task.sleep(for: .milliseconds(100))
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }
    #expect(clock.now - started < .seconds(5))
}
