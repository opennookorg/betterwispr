import CoreGraphics
import EventKit
import Foundation

/// Someone invited to a calendar event and how they answered.
public struct CalendarGuest: Equatable, Sendable {
    public enum Response: Equatable, Sendable { case accepted, declined, tentative, pending }

    public var name: String
    public var email: String?
    public var response: Response
    public var isOrganizer: Bool
    public var isYou: Bool

    public init(name: String, email: String? = nil, response: Response = .pending, isOrganizer: Bool = false, isYou: Bool = false) {
        self.name = name
        self.email = email
        self.response = response
        self.isOrganizer = isOrganizer
        self.isYou = isYou
    }
}

/// An event from the Mac's Calendar, reduced to what the Calendar page and a meeting note use.
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
    /// Everyone on the invite, including the user and the organizer, organizer first.
    public var guests: [CalendarGuest]
    public var location: String
    public var notes: String

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, isAttending: Bool = true, attendees: [String] = [],
                videoURL: URL? = nil, calendarTitle: String = "", calendarColor: SIMD3<Double>? = nil, guests: [CalendarGuest] = [],
                location: String = "", notes: String = "") {
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
        self.guests = guests
        self.location = location
        self.notes = notes
    }

    /// The service hosting the event's video link.
    public var videoPlatform: MeetingPlatform? {
        guard let host = videoURL?.host()?.lowercased() else { return nil }
        let platforms: [(String, MeetingPlatform)] = [("zoom.us", .zoom), ("meet.google.com", .googleMeet), ("teams.microsoft.com", .teams),
                                                      ("teams.live.com", .teams), ("webex.com", .webex)]
        return platforms.first { host == $0.0 || host.hasSuffix("." + $0.0) }?.1
    }

    static let earlyStart: TimeInterval = 5 * 60
    private static let videoHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com"]

    /// The timed event the user attends at `now`, counting from five minutes before it starts; a video call wins, then the latest start.
    public static func current(_ events: [CalendarEvent], at now: Date) -> CalendarEvent? {
        events
            .filter { $0.isAttending && !$0.isAllDay && $0.start.addingTimeInterval(-earlyStart) <= now && now < $0.end }
            .max { ($0.videoURL == nil ? 0 : 1, $0.start) < ($1.videoURL == nil ? 0 : 1, $1.start) }
    }

    /// Identifies one occurrence, since every occurrence of a repeating event shares `id`.
    public var occurrenceID: String { "\(id)@\(start.timeIntervalSinceReferenceDate)" }

    /// Whether any part of the event falls in `interval`; an event with no duration counts at its start.
    public func occurs(in interval: DateInterval) -> Bool {
        start < interval.end && (end > interval.start || start == interval.start)
    }

    /// The events the user attends, earliest first.
    public static func attended(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events.filter(\.isAttending).sorted { ($0.start, $0.title, $0.id) < ($1.start, $1.title, $1.id) }
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

/// Pure layout for the Day, Week and Month calendar views.
public enum CalendarLayout {
    /// The days a month grid shows: whole weeks from the one holding the 1st through the one holding the last day.
    public static func monthDays(containing date: Date, calendar: Calendar = .current) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let first = calendar.dateInterval(of: .weekOfYear, for: month.start)?.start,
              let last = calendar.dateInterval(of: .weekOfYear, for: month.end.addingTimeInterval(-1))?.end else { return [] }
        return Array(sequence(first: first) { calendar.date(byAdding: .day, value: 1, to: $0) }.prefix { $0 < last })
    }

    /// Side-by-side columns for overlapping events: each occurrence maps to its column and the column count of its overlap group.
    public static func columns(_ events: [CalendarEvent]) -> [String: (index: Int, count: Int)] {
        var result: [String: (index: Int, count: Int)] = [:]
        var group: [(id: String, column: Int)] = []
        var columnEnds: [Date] = []
        var groupEnd = Date.distantPast
        func close() {
            for item in group { result[item.id] = (item.column, columnEnds.count) }
            group = []
            columnEnds = []
        }
        for event in events.sorted(by: { ($0.start, $1.end) < ($1.start, $0.end) }) {
            if event.start >= groupEnd { close() }
            let end = max(event.end, event.start.addingTimeInterval(15 * 60))
            if let column = columnEnds.firstIndex(where: { $0 <= event.start }) {
                columnEnds[column] = end
                group.append((event.occurrenceID, column))
            } else {
                columnEnds.append(end)
                group.append((event.occurrenceID, columnEnds.count - 1))
            }
            groupEnd = max(groupEnd, end)
        }
        close()
        return result
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

    /// The attended events in `interval`, from the calendars the user did not exclude.
    public func events(excluding excluded: Set<String>, in interval: DateInterval) -> [CalendarEvent] {
        guard Self.isAuthorized else { return [] }
        let calendars = freshCalendars().filter { !excluded.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
        return CalendarEvent.attended(store.events(matching: predicate).map(CalendarEvent.init))
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
            calendarColor: event.calendar?.cgColor.flatMap(Self.sRGB),
            guests: Self.guests(of: event),
            location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            notes: event.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    private static func guests(of event: EKEvent) -> [CalendarGuest] {
        let organizer = event.organizer?.url
        let guests = (event.attendees ?? [])
            .filter { $0.participantType != .room && $0.participantType != .resource }
            .compactMap { attendee -> CalendarGuest? in
                guard let name = invitee(name: attendee.name, url: attendee.url) else { return nil }
                let email = attendee.url.scheme?.lowercased() == "mailto" ? URLComponents(url: attendee.url, resolvingAgainstBaseURL: false)?.path : nil
                let response: CalendarGuest.Response = switch attendee.participantStatus {
                case .accepted: .accepted
                case .declined: .declined
                case .tentative: .tentative
                default: .pending
                }
                return CalendarGuest(name: name, email: email == name ? nil : email, response: response,
                                     isOrganizer: attendee.url == organizer, isYou: attendee.isCurrentUser)
            }
        return guests.filter(\.isOrganizer) + guests.filter { !$0.isOrganizer }
    }

    private static func sRGB(_ color: CGColor) -> SIMD3<Double>? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let parts = color.converted(to: space, intent: .defaultIntent, options: nil)?.components, parts.count >= 3 else { return nil }
        return SIMD3(Double(parts[0]), Double(parts[1]), Double(parts[2]))
    }
}
