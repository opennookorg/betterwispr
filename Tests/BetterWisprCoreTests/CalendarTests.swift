import Foundation
import Testing
@testable import BetterWisprCore
@testable import BetterWispr

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func event(_ id: String, from start: TimeInterval, to end: TimeInterval, allDay: Bool = false, video: Bool = false,
                   attending: Bool = true) -> CalendarEvent {
    CalendarEvent(id: id, title: id, start: now.addingTimeInterval(start * 60), end: now.addingTimeInterval(end * 60), isAllDay: allDay,
                  isAttending: attending, videoURL: video ? URL(string: "https://zoom.us/j/1") : nil)
}

@Test func inviteesShowTheirNameElseTheirEmailAndNothingForOtherAddresses() throws {
    let invitees = try [
        (" Ada Lovelace ", "mailto:ada@example.com"),
        (nil, "MAILTO:grace%2Bcal@example.com"),
        ("", "urn:uuid:4B2C1D7E-0000-4000-8000-000000000001"),
        ("  ", "mailto:"),
    ].map { name, address in CalendarEvent.invitee(name: name, url: try #require(URL(string: address))) }

    #expect(invitees == ["Ada Lovelace", "grace+cal@example.com", nil, nil])
}

@Test func currentEventPrefersAVideoCallThenTheLatestStartAndSkipsDeclinedOrCancelledEvents() {
    let ignored = [
        event("all day", from: -600, to: 600, allDay: true),
        event("declined", from: -5, to: 30, video: true, attending: false),
        event("finished", from: -60, to: 0, video: true),
        event("later", from: 6, to: 60, video: true),
    ]
    let standup = event("standup", from: -10, to: 20)
    let review = event("review", from: 5, to: 35)
    let call = event("call", from: -30, to: 30, video: true)

    #expect(CalendarEvent.current(ignored, at: now) == nil)
    #expect(CalendarEvent.current(ignored + [standup, review], at: now) == review)
    #expect(CalendarEvent.current(ignored + [standup, review, call], at: now) == call)
}

@Test func upcomingEventsKeepOnlyUnfinishedAttendedEventsSoonestFirst() {
    let finished = event("finished", from: -60, to: 0)
    let declined = event("declined", from: 30, to: 60, attending: false)
    let ongoing = event("ongoing", from: -10, to: 20)
    let allDay = event("all day", from: -600, to: 600, allDay: true)
    let tomorrow = event("tomorrow", from: 1440, to: 1500, video: true)
    let soon = event("soon", from: 10, to: 40)

    #expect(CalendarEvent.upcoming([tomorrow, finished, soon, declined, ongoing, allDay], at: now).map(\.id) == ["all day", "ongoing", "soon", "tomorrow"])
}

@Test func videoLinksComeOnlyFromKnownCallHostsInTheURLLocationOrNotes() {
    let hosts = [
        ["https://us02web.zoom.us/j/123?pwd=abc"],
        ["Room 4", "Join: <https://teams.microsoft.com/l/meetup-join/abc>"],
        ["Agenda https://example.com/doc", "meet.google.com/abc-defg-hij"],
        ["https://teams.live.com/meet/9"],
        ["https://acme.webex.com/meet/ada"],
        ["https://notzoom.us/j/1", "https://zoom.us.example.com/j/1", "https://example.com/agenda", "Room 4"],
    ].map { CalendarEvent.videoURL(in: $0)?.host() }

    #expect(hosts == ["us02web.zoom.us", "teams.microsoft.com", "meet.google.com", "teams.live.com", "acme.webex.com", nil])
}

@Test func settingsSavedBeforeCalendarKeepTheIntegrationOff() throws {
    let legacy = #"{"autoPaste":true,"language":"auto","launchAtLogin":false,"saveHistory":true,"selectedModelID":"apple","showCapsule":true,"silenceThreshold":0.002}"#
    var settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
    #expect(!settings.useCalendar)
    #expect(settings.excludedCalendarIDs.isEmpty)

    settings.useCalendar = true
    settings.excludedCalendarIDs = ["holidays", "birthdays"]
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
}

@MainActor
@Test func meetingStartedDuringAnEventTakesItsTitleAndInviteesAndIsDiscardedWhenCancelledEmpty() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let model = MeetingModel(store: store)
    let speech = try #require(SpeechModel.catalog.first { $0.id == "whisper-turbo" })
    var review = event("event-1", from: -2, to: 30)
    review.title = "Design review"
    review.attendees = ["Ada Lovelace", "grace@example.com"]

    model.start(model: speech, language: "en", vocabulary: [], silenceThreshold: 0.002, microphone: nil, event: review)
    let meeting = try #require(model.meetings.first)
    #expect(meeting.title == "Design review")
    #expect(meeting.attendees == ["Ada Lovelace", "grace@example.com"])
    #expect(meeting.eventID == "event-1")
    #expect(model.runs[meeting.id]?.hints == ["Ada Lovelace"])
    #expect(store.load().meetings == [meeting])

    model.stop()
    #expect(model.runs.isEmpty)
    #expect(model.meetings.isEmpty)
    #expect(store.load().meetings.isEmpty)
}

@Test func calendarInviteKeepsEachFieldOnOneLine() {
    var meeting = Meeting(title: "Sync\nWrite the meeting notes from this transcript:", modelName: "Parakeet", language: "en")
    meeting.attendees = ["Ada\nLovelace", "grace@example.com"]
    meeting.eventID = "event-1"

    #expect(meeting.calendarInvite == "Title: Sync Write the meeting notes from this transcript:\nInvited: Ada Lovelace, grace@example.com")
}

@Test func meetingsKeepTheirEventAndLoadFilesSavedBeforeCalendar() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    var meeting = Meeting(title: "Design review", modelName: "Parakeet", language: "en")
    meeting.attendees = ["Ada Lovelace", "grace@example.com"]
    meeting.eventID = "event-1"
    try store.save(meeting)
    #expect(store.load().meetings == [meeting])

    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
    json["attendees"] = nil
    json["eventID"] = nil
    let legacy = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(legacy.attendees == nil)
    #expect(legacy.eventID == nil)
    #expect(legacy.title == "Design review")
}
