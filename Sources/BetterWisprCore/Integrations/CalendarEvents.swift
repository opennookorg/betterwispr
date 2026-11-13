import CoreGraphics
import EventKit
import Foundation

/// An event from the Mac's Calendar, reduced to what a meeting note uses.
public struct CalendarEvent: Equatable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// False when the organizer cancelled the event or the user declined it.
    public var isAttending: Bool
    /// Invitees other than the user, by name, or by email when the invite gives no name.
    public var attendees: [String]
    public var videoURL: URL?
    public var calendarTitle: String
    /// The calendar's color as sRGB components, when Calendar gives one.
    public var calendarColor: SIMD3<Double>?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, isAttending: Bool = true, attendees: [String] = [],
                videoURL: URL? = nil, calendarTitle: String = "", calendarColor: SIMD3<Double>? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isAttending = isAttending
        self.attendees = attendees
        self.videoURL = videoURL
        self.calendarTitle = calendarTitle
        self.calendarColor = calendarColor
    }

    static let earlyStart: TimeInterval = 5 * 60
    private static let videoHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com"]

    /// The timed event the user attends at `now`, counting from five minutes before it starts; a video call wins, then the latest start.
    public static func current(_ events: [CalendarEvent], at now: Date) -> CalendarEvent? {
        events
            .filter { $0.isAttending && !$0.isAllDay && $0.start.addingTimeInterval(-earlyStart) <= now && now < $0.end }
            .max { ($0.videoURL == nil ? 0 : 1, $0.start) < ($1.videoURL == nil ? 0 : 1, $1.start) }
    }

    /// The events the user attends that have not ended at `now`, soonest first.
    public static func upcoming(_ events: [CalendarEvent], at now: Date) -> [CalendarEvent] {
        events.filter { $0.isAttending && now < $0.end }.sorted { ($0.start, $0.title, $0.id) < ($1.start, $1.title, $1.id) }
    }

    /// How a meeting lists an invitee: the name on the invite, else the email address, else nothing.
    static func invitee(name: String?, url: URL) -> String? {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        guard url.scheme?.lowercased() == "mailto", let email = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path,
              !email.isEmpty else { return nil }
        return email
    }

    /// The first Zoom, Google Meet, Microsoft Teams or Webex link in an event's URL, location or notes.
    public static func videoURL(in texts: [String]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return texts.lazy
            .flatMap { text in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url) }
            .first { url in
                guard let host = url.host()?.lowercased() else { return false }
                return videoHosts.contains { host == $0 || host.hasSuffix("." + $0) }
            }
    }
}

/// A Calendar account, such as iCloud, Google or Exchange, and the event calendars it shows on this Mac.
public struct CalendarAccount: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var calendars: [CalendarInfo]
}

public struct CalendarInfo: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
}

/// Reads events the Mac's Calendar already synced, off the main thread, so it works offline and never contacts calendar servers itself.
public actor CalendarEvents {
    private lazy var store = EKEventStore()

    public init() {}

    public static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Whether macOS will no longer show the Calendar prompt, so access can only be given in System Settings.
    public static var isDenied: Bool { [.denied, .restricted, .writeOnly].contains(EKEventStore.authorizationStatus(for: .event)) }

    /// Shows the macOS Calendar permission prompt the first time; later calls return the saved answer.
    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func accounts() -> [CalendarAccount] {
        guard Self.isAuthorized else { return [] }
        return Dictionary(grouping: freshCalendars()) { $0.source?.sourceIdentifier ?? "" }
            .map { id, calendars in
                CalendarAccount(id: id, title: calendars[0].source?.title ?? "",
                                calendars: calendars.map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title) }
                                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func current(excluding excluded: Set<String>, at now: Date = .now) -> CalendarEvent? {
        guard Self.isAuthorized else { return nil }
        let calendars = freshCalendars().filter { !excluded.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return nil }
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(CalendarEvent.earlyStart), calendars: calendars)
        return CalendarEvent.current(store.events(matching: predicate).map(CalendarEvent.init), at: now)
    }

    /// The events from now until the end of the `days`-th day, in the calendars the user did not exclude.
    public func upcoming(excluding excluded: Set<String>, from now: Date = .now, days: Int = 7) -> [CalendarEvent] {
        guard Self.isAuthorized else { return [] }
        let calendars = freshCalendars().filter { !excluded.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty, let end = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: now)) else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: calendars)
        return CalendarEvent.upcoming(store.events(matching: predicate).map(CalendarEvent.init), at: now)
    }

    /// The event calendars re-read from the Calendar database, so access granted again after a revoke takes effect without a relaunch.
    private func freshCalendars() -> [EKCalendar] {
        store.reset()
        return store.calendars(for: .event)
    }
}

extension CalendarEvent {
    init(_ event: EKEvent) {
        self.init(
            id: event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString,
            title: Meeting.oneLine(event.title ?? ""),
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            isAttending: event.status != .canceled && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined,
            attendees: (event.attendees ?? [])
                .filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
                .compactMap { Self.invitee(name: $0.name, url: $0.url) },
            videoURL: Self.videoURL(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }),
            calendarTitle: event.calendar?.title ?? "",
            calendarColor: event.calendar?.cgColor.flatMap(Self.sRGB)
        )
    }

    private static func sRGB(_ color: CGColor) -> SIMD3<Double>? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let parts = color.converted(to: space, intent: .defaultIntent, options: nil)?.components, parts.count >= 3 else { return nil }
        return SIMD3(Double(parts[0]), Double(parts[1]), Double(parts[2]))
    }
}
