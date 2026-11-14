import Foundation
import Testing
@testable import BetterWisprCore
@testable import BetterWispr

private func voice(at angle: Double, length: Float = 1) -> [Float] {
    [Float(cos(angle)) * length, Float(sin(angle)) * length]
}

private func known(_ name: String, _ embedding: [Float], meeting: UUID = UUID(), participant: Int = 1) -> KnownVoice {
    KnownVoice(name: name, meetingID: meeting, participant: participant, embedding: embedding)
}

private func call(_ speakers: [Int]) -> Meeting {
    var meeting = Meeting(modelName: "Parakeet", language: "en")
    for (index, speaker) in speakers.enumerated() {
        meeting.insert(MeetingSegment(speaker: .them, start: TimeInterval(index), duration: 1, text: "Point \(index)", rawText: "point \(index)", participant: speaker))
    }
    return meeting
}

private func temporaryStore() -> VoiceStore {
    VoiceStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Voices.json"))
}

@MainActor
private func rememberingModel(_ saved: [Meeting], in root: URL) throws -> (model: MeetingModel, voices: VoiceStore) {
    let meetings = MeetingStore(directory: root.appendingPathComponent("Meetings"))
    for meeting in saved { try meetings.save(meeting) }
    let model = MeetingModel(store: meetings)
    model.remembersVoices = true
    return (model, VoiceStore(url: root.appendingPathComponent("Voices.json")))
}

@Test func rememberedVoicesNameOnlyVoicesWithinSpeakerKitsClusteringDistance() {
    let remembered = [known("Ana", voice(at: 0)), known("Bo", voice(at: .pi / 2))]

    let names = SpeakerDetection.recognise([
        1: voice(at: .pi / 2 - 0.1, length: 0.2),
        2: voice(at: .pi),
        3: [1, 0, 0],
        4: [0, 0],
    ], among: remembered).mapValues(\.name)

    #expect(names == [1: "Bo"])
    #expect(SpeakerDetection.recognise([1: voice(at: 0.60, length: 7)], among: remembered).mapValues(\.name) == [1: "Ana"])
    #expect(SpeakerDetection.recognise([1: voice(at: 0.62)], among: remembered).isEmpty)
    #expect(SpeakerDetection.recognise([1: voice(at: 0)], among: []).isEmpty)
}

@Test func eachRememberedNameGoesToTheNearestVoiceOnly() {
    let remembered = [known("Ana", voice(at: 0)), known(" ana", voice(at: 0.4)), known("Bo", voice(at: 0.55))]

    let names = SpeakerDetection.recognise([1: voice(at: 0.43), 2: voice(at: 0.01), 3: voice(at: 0.2)], among: remembered).mapValues(\.name)

    #expect(names == [2: "Ana", 1: "Bo"])
}

@Test func aRememberedVoiceIsOnlySuggestedAndAcceptingItStoresNothingNew() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    let ana = known("Ana", voice(at: 0))
    try store.replaceVoices(from: ana.meetingID, with: [ana])
    var meeting = call([1, 2])
    let heard = HeardVoices([1: voice(at: 0.01), 2: voice(at: .pi)], among: try store.load())

    #expect(heard.suggestion(for: 1, in: meeting) == "Ana")
    #expect(heard.suggestion(for: 2, in: meeting) == nil)

    meeting.participantNames = [1: "ana ", 2: " Bo "]
    try heard.remember(in: meeting, to: store)
    #expect(heard.suggestion(for: 1, in: meeting) == nil)
    #expect(try store.load() == [ana, known("Bo", voice(at: .pi), meeting: meeting.id, participant: 2)])
}

@MainActor
@Test func detectionSuggestsARememberedNameWithoutNamingTheSpeaker() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = call([1, 2])
    let (model, voices) = try rememberingModel([meeting], in: root)
    let ana = known("Ana", voice(at: 0))
    try voices.replaceVoices(from: ana.meetingID, with: [ana])

    model.applySpeakers((segments: meeting.segments, voices: [1: voice(at: 0.01), 2: voice(at: .pi)]), to: meeting.id)

    let shown = try #require(model.meeting(meeting.id))
    #expect(model.suggestedName(for: 1, in: shown) == "Ana")
    #expect(shown.participantNames == nil)
    #expect(MeetingStore(directory: root.appendingPathComponent("Meetings")).load().meetings.map(\.participantNames) == [nil])
    #expect(try voices.load() == [ana])
}

@MainActor
@Test func mergingThenRenamingRemembersOnlyTheVoiceThatKeptItsLines() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = call([1, 2, 3])
    let (model, voices) = try rememberingModel([meeting], in: root)
    model.applySpeakers((segments: meeting.segments, voices: [1: voice(at: 0), 2: voice(at: 1), 3: voice(at: 2)]), to: meeting.id)

    model.merge(2, into: 3, in: meeting.id)
    model.edit(meeting.id) { $0.assign(segment: $0.segments[0].id, toParticipant: $0.nextParticipant) }
    #expect(model.meeting(meeting.id)?.participants == [2, 3])
    model.edit(meeting.id) { $0.participantNames = [1: "Di", 2: "Cy", 3: "Bo"] }
    model.saveNow(meeting.id)

    #expect(try voices.load() == [known("Bo", voice(at: 2), meeting: meeting.id, participant: 3)])
}

@MainActor
@Test func typingANameAndErasingItKeepsTheRememberedVoice() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = call([1, 2])
    let (model, voices) = try rememberingModel([meeting], in: root)
    let ana = known("Ana", voice(at: 0))
    try voices.replaceVoices(from: ana.meetingID, with: [ana])
    model.applySpeakers((segments: meeting.segments, voices: [1: voice(at: 0.01), 2: voice(at: .pi)]), to: meeting.id)

    for typed in ["B", ""] {
        model.edit(meeting.id) { $0.participantNames = [1: typed] }
        model.saveNow(meeting.id)
    }
    model.commitName(of: 1, in: meeting.id)

    #expect(try voices.load() == [ana])
    #expect(model.suggestedName(for: 1, in: try #require(model.meeting(meeting.id))) == "Ana")
}

@MainActor
@Test func committingAnotherNameForgetsTheSuggestedVoiceEvenWhenItsMeetingSavesAgain() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = call([1])
    let second = call([1])
    let (model, voices) = try rememberingModel([first, second], in: root)
    model.applySpeakers((segments: first.segments, voices: [1: voice(at: 0)]), to: first.id)
    model.edit(first.id) { $0.participantNames = [1: "Ana"] }
    model.saveNow(first.id)
    model.applySpeakers((segments: second.segments, voices: [1: voice(at: 0.01)]), to: second.id)
    #expect(model.suggestedName(for: 1, in: second) == "Ana")

    model.edit(second.id) { $0.participantNames = [1: "Cy"] }
    model.saveNow(second.id)
    let ana = known("Ana", voice(at: 0), meeting: first.id)
    let cy = known("Cy", voice(at: 0.01), meeting: second.id)
    #expect(try voices.load() == [ana, cy])

    model.commitName(of: 1, in: second.id)
    #expect(try voices.load() == [cy])
    #expect(model.suggestedName(for: 1, in: second) == nil)

    model.saveNow(first.id)
    model.saveNow(second.id)
    #expect(try voices.load() == [cy])
}

@Test func namingASuggestedSpeakerSomeoneElseForgetsTheVoiceThatSuggestedIt() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    let ana = known("Ana", voice(at: 0))
    let bo = known("Bo", voice(at: .pi / 2))
    try store.replaceVoices(from: ana.meetingID, with: [ana])
    try store.replaceVoices(from: bo.meetingID, with: [bo])
    var meeting = call([1])
    var heard = HeardVoices([1: voice(at: 0.01)], among: try store.load())
    #expect(heard.suggestion(for: 1, in: meeting) == "Ana")

    meeting.participantNames = [1: "Cy"]
    try heard.remember(in: meeting, to: store)
    let cy = known("Cy", voice(at: 0.01), meeting: meeting.id, participant: 1)
    #expect(try store.load() == [ana, bo, cy])
    #expect(try heard.reject(1, in: meeting, from: store) == ana)
    #expect(try store.load() == [bo, cy])
    #expect(try heard.reject(1, in: meeting, from: store) == nil)

    meeting.participantNames = nil
    #expect(heard.suggestion(for: 1, in: meeting) == nil)
    try heard.remember(in: meeting, to: store)
    #expect(try store.load() == [bo])
}

@MainActor
@Test func deletingAMeetingDeletesTheVoicesNamedInIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let meetings = MeetingStore(directory: root.appendingPathComponent("Meetings"))
    let voices = VoiceStore(url: root.appendingPathComponent("Voices.json"))
    let meeting = call([1])
    try meetings.save(meeting)
    let kept = known("Bo", voice(at: 1))
    try voices.replaceVoices(from: meeting.id, with: [known("Ana", voice(at: 0), meeting: meeting.id)])
    try voices.replaceVoices(from: kept.meetingID, with: [kept])
    let model = MeetingModel(store: meetings)

    model.delete(meeting.id)

    #expect(model.meetings.isEmpty)
    #expect(model.voicesMessage == nil)
    #expect(try voices.load() == [kept])
}

@MainActor
@Test(arguments: [false, true])
func forgettingAVoiceRemovesOtherMeetingsSuggestionsAndPreventsSavingItAgain(deleteSource: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = call([1])
    let second = call([1])
    let pending = call([1, 2])
    let accepted = call([1])
    let (model, voices) = try rememberingModel([first, second, pending, accepted], in: root)
    model.applySpeakers((segments: first.segments, voices: [1: voice(at: 0)]), to: first.id)
    model.edit(first.id) { $0.participantNames = [1: "Ana"] }
    model.saveNow(first.id)
    let bo = known("Bo", voice(at: .pi))
    try voices.replaceVoices(from: bo.meetingID, with: [bo])
    for meeting in [second, pending, accepted] {
        let embeddings = meeting.id == pending.id ? [1: voice(at: 0.01), 2: voice(at: .pi)] : [1: voice(at: 0.01)]
        model.applySpeakers((segments: meeting.segments, voices: embeddings), to: meeting.id)
    }
    model.edit(accepted.id) { $0.participantNames = [1: "Ana"] }
    model.saveNow(accepted.id)
    #expect(model.suggestedName(for: 1, in: pending) == "Ana")

    if deleteSource {
        model.delete(first.id)
    } else {
        model.edit(second.id) { $0.participantNames = [1: "Cy"] }
        model.commitName(of: 1, in: second.id)
    }

    #expect(model.suggestedName(for: 1, in: pending) == nil)
    #expect(model.suggestedName(for: 2, in: pending) == "Bo")
    model.edit(pending.id) { $0.participantNames = [1: "Di", 2: "Eve"] }
    model.saveNow(pending.id)
    model.saveNow(accepted.id)
    let saved = try voices.load()
    #expect(!saved.contains { $0.name == "Ana" || $0.name == "Di" })
    #expect(saved.filter { $0.meetingID == pending.id } == [known("Eve", voice(at: .pi), meeting: pending.id, participant: 2)])
    #expect(saved.contains(bo))
    #expect(model.meeting(accepted.id)?.participantNames == [1: "Ana"])
}

@Test func voiceStoreReplacesOneMeetingsVoicesAndNeverWritesOverAnUnreadableFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let store = VoiceStore(url: directory.appendingPathComponent("Voices.json"))
    let first = UUID()
    let second = UUID()
    #expect(try store.load().isEmpty)

    try store.replaceVoices(from: first, with: [known("Ana", [1, 0], meeting: first)])
    try store.replaceVoices(from: second, with: [known("Bo", [0, 1], meeting: second)])
    try store.replaceVoices(from: first, with: [known("Cy", [1, 1], meeting: first, participant: 2)])
    #expect(try store.load() == [known("Bo", [0, 1], meeting: second), known("Cy", [1, 1], meeting: first, participant: 2)])
    #expect(try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)

    let unreadable = Data("not voices".utf8)
    try unreadable.write(to: store.url)
    #expect(throws: (any Error).self) { try store.replaceVoices(from: first, with: []) }
    #expect(try Data(contentsOf: store.url) == unreadable)

    try Data(#"{"version":2,"voices":[]}"#.utf8).write(to: store.url)
    #expect(throws: StoreError.self) { try store.load() }

    try store.forget()
    #expect(!FileManager.default.fileExists(atPath: store.url.path))
    try store.forget()
    #expect(try store.load().isEmpty)
}

@Test func myVoiceIsStoredBesideRememberedVoicesAndForgottenWithThem() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    let meeting = UUID()
    #expect(try store.myVoice() == nil)

    try store.setMyVoice([0.5, 0.25])
    try store.replaceVoices(from: meeting, with: [known("Ana", [1, 0], meeting: meeting)])
    #expect(try store.myVoice() == [0.5, 0.25])
    #expect(try store.load() == [known("Ana", [1, 0], meeting: meeting)])
    #expect(try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int == 0o600)

    try store.setMyVoice(nil)
    #expect(try store.myVoice() == nil)
    #expect(try store.load() == [known("Ana", [1, 0], meeting: meeting)])

    try Data(#"{"version":1,"voices":[]}"#.utf8).write(to: store.url)
    #expect(try store.myVoice() == nil)

    try store.setMyVoice([1, 0])
    try store.forget()
    #expect(try store.myVoice() == nil)

    let unreadable = Data("not voices".utf8)
    try unreadable.write(to: store.url)
    #expect(throws: (any Error).self) { try store.setMyVoice([1, 0]) }
    #expect(try Data(contentsOf: store.url) == unreadable)
}
