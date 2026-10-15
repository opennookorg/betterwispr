import Foundation
import Testing
@testable import BetterWisprCore

private func call(_ voices: [Int?], names: [Int: String]? = nil) -> Meeting {
    var meeting = Meeting(modelName: "Parakeet", language: "en")
    meeting.insert(MeetingSegment(speaker: .me, start: 0, duration: 1, text: "Morning everyone", rawText: "morning everyone"))
    for (index, voice) in voices.enumerated() {
        let start = TimeInterval(index + 1) * 10
        meeting.insert(MeetingSegment(speaker: .them, start: start, duration: 1, text: "Point \(index)", rawText: "point \(index)", participant: voice))
    }
    meeting.participantNames = names
    return meeting
}

private func labels(_ meeting: Meeting) -> [String] {
    meeting.segments.map { $0.label(names: meeting.participantNames) }
}

@Test func reassigningMovesOneLineOnEitherSide() {
    var meeting = call([1, 2, 1], names: [2: "Ana"])
    meeting.assign(segment: meeting.segments[3].id, toParticipant: 2)
    #expect(labels(meeting) == ["Me", "Speaker 1", "Ana", "Ana"])

    meeting.assign(segment: meeting.segments[1].id, toParticipant: nil)
    #expect(labels(meeting) == ["Me", "Them", "Ana", "Ana"])
    #expect(meeting.participants == [2])

    meeting.assign(segment: meeting.segments[0].id, toParticipant: meeting.nextParticipant)
    #expect(labels(meeting) == ["Speaker 1", "Them", "Ana", "Ana"])
    #expect(meeting.segments[0].speaker == .me)

    meeting.assign(segment: meeting.segments[0].id, toParticipant: nil)
    #expect(labels(meeting) == ["Me", "Them", "Ana", "Ana"])

    let before = meeting
    meeting.assign(segment: UUID(), toParticipant: 1)
    #expect(meeting == before)
}

@Test func roomVoicesMergeAndNameLikeCallVoices() {
    var meeting = call([1, 2], names: [1: "Bo"])
    meeting.insert(MeetingSegment(speaker: .me, start: 5, duration: 1, text: "Same here", rawText: "same here", participant: 3))
    #expect(labels(meeting) == ["Me", "Speaker 3", "Bo", "Speaker 2"])
    #expect(meeting.participants == [1, 2, 3])
    #expect(meeting.nextParticipant == 4)

    meeting.mergeParticipant(3, into: 1)
    #expect(labels(meeting) == ["Me", "Bo", "Bo", "Speaker 2"])
    #expect(meeting.segments.map(\.speaker) == [.me, .me, .them, .them])
    #expect(meeting.transcript.contains("[00:05] Bo: Same here"))
}

@Test func speakersCanBeSetWhenDetectionNeverRan() {
    var meeting = call([nil, nil, nil])
    #expect(meeting.participants.isEmpty)
    #expect(meeting.nextParticipant == 1)

    meeting.assign(segment: meeting.segments[1].id, toParticipant: meeting.nextParticipant)
    meeting.assign(segment: meeting.segments[2].id, toParticipant: meeting.nextParticipant)
    #expect(labels(meeting) == ["Me", "Speaker 1", "Speaker 2", "Them"])
    #expect(meeting.transcript.contains("[00:20] Speaker 2: Point 1"))
}

@Test func newSpeakerTakesTheLowestNumberNoLineOrNameUses() {
    #expect(call([]).nextParticipant == 1)
    #expect(call([1, 3, 1]).nextParticipant == 2)
    #expect(call([1, 3], names: [2: "Ana"]).nextParticipant == 4)
    #expect(call([1, 3], names: [2: " "]).nextParticipant == 2)
}

@Test func mergingRelabelsEveryLineAndCarriesTheNameAcross() {
    var meeting = call([1, 3, 2, 3], names: [3: "Ana"])
    meeting.mergeParticipant(3, into: 1)
    #expect(labels(meeting) == ["Me", "Ana", "Ana", "Speaker 2", "Ana"])
    #expect(meeting.participants == [1, 2])
    #expect(meeting.participantNames == [1: "Ana"])
    #expect(meeting.transcript.contains("[00:40] Ana: Point 3"))
    #expect(meeting.nextParticipant == 3)
}

@Test func mergingKeepsTheTargetsOwnName() {
    var named = call([1, 2], names: [1: "Bo", 2: "Cy"])
    named.mergeParticipant(2, into: 1)
    #expect(named.participantNames == [1: "Bo"])
    #expect(labels(named) == ["Me", "Bo", "Bo"])

    var blank = call([1, 2], names: [1: "  ", 2: "Cy"])
    blank.mergeParticipant(2, into: 1)
    #expect(blank.participantNames == [1: "Cy"])

    var unnamed = call([1, 2])
    unnamed.mergeParticipant(2, into: 1)
    #expect(unnamed.participantNames == nil)
    #expect(unnamed.participants == [1])
}

@Test func mergingASpeakerIntoItselfChangesNothing() {
    var meeting = call([1, 2], names: [1: "Bo"])
    let before = meeting
    meeting.mergeParticipant(1, into: 1)
    #expect(meeting == before)
}

@Test func correctingSpeakersMarksTheSummaryOutOfDate() {
    var meeting = call([1, 2, 1])
    var summary = MeetingSummary(overview: "Planning")
    summary.sourceFingerprint = meeting.summarySourceFingerprint
    meeting.summary = summary
    #expect(!meeting.summaryNeedsUpdate)

    var reassigned = meeting
    reassigned.assign(segment: reassigned.segments[1].id, toParticipant: 2)
    #expect(reassigned.summaryNeedsUpdate)

    var merged = meeting
    merged.mergeParticipant(2, into: 1)
    #expect(merged.summaryNeedsUpdate)
}

@Test func inviteesAlreadyGivenToASpeakerLeaveTheNameMenu() {
    var meeting = call([1, 2, 3], names: [1: " ana", 2: ""])
    meeting.attendees = ["Ana", "Ben", "ben ", "Cy"]
    #expect(meeting.unusedAttendees == ["Ben", "Cy"])

    meeting.participantNames?[3] = "Cy"
    #expect(meeting.unusedAttendees == ["Ben"])

    meeting.participantNames = nil
    meeting.attendees = ["  ", "Ben"]
    #expect(meeting.unusedAttendees == ["Ben"])

    meeting.attendees = nil
    #expect(meeting.unusedAttendees.isEmpty)
}

@Test func settingsSavedBeforeTheSpeakerDetectionOfferStillLoad() throws {
    let legacy = #"{"autoPaste":true,"language":"auto","launchAtLogin":false,"saveHistory":true,"selectedModelID":"apple","showCapsule":true,"silenceThreshold":0.002}"#
    var settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
    #expect(!settings.dismissedSpeakerDetectionOffer)
    #expect(!settings.separateRoomVoices)
    #expect(!settings.rememberVoices)

    settings.dismissedSpeakerDetectionOffer = true
    let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(saved.dismissedSpeakerDetectionOffer)
}
