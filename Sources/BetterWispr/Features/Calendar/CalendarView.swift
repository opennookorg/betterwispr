import BetterWisprCore
import EventKit
import SwiftUI

struct CalendarView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.settings.useCalendar && model.calendarGranted {
                if model.calendarAccounts.isEmpty { noCalendars } else { agenda }
            } else if CalendarEvents.isDenied {
                denied
            } else {
                connect
            }
        }
        .background(.pageFill)
        .task(id: model.settings.excludedCalendarIDs) {
            while !Task.isCancelled {
                await model.refreshUpcomingEvents()
                try? await Task.sleep(for: .seconds(300))
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged).map({ _ in () }) {
                await model.refreshUpcomingEvents()
            }
        }
    }

    private var connect: some View {
        unavailable(L10n.tr("Connect your calendar"), systemImage: "calendar.badge.plus",
                    detail: L10n.tr("See your upcoming meetings, join calls and take notes with the event’s title and invitees. BetterWispr reads the calendars already on this Mac, such as iCloud, Google and Exchange, and never changes them.")) {
            Button(L10n.tr("Connect Calendar")) { model.useCalendar(true) }
                .buttonStyle(.borderedProminent)
        }
    }

    private var denied: some View {
        unavailable(L10n.tr("Calendar access is off"), systemImage: "calendar.badge.exclamationmark",
                    detail: L10n.tr("Allow BetterWispr under Privacy & Security, Calendars in System Settings, then come back here.")) {
            Button(L10n.tr("Open System Settings")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var noCalendars: some View {
        unavailable(L10n.tr("No calendars on this Mac"), systemImage: "calendar",
                    detail: L10n.tr("Calendar access is on, but the Calendar app has no accounts. Add iCloud, Google or Exchange under Internet Accounts in System Settings.")) {
            Button(L10n.tr("Open Internet Accounts")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func unavailable(_ title: String, systemImage: String, detail: String, @ViewBuilder action: () -> some View) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        } actions: {
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var agenda: some View {
        TimelineView(.everyMinute) { context in
            let days = CalendarDay.group(model.upcomingEvents.filter { context.date < $0.end }, now: context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    status
                    if days.isEmpty {
                        Card {
                            Text(L10n.tr("No meetings in the next 7 days."))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(days) { day in
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(day.title)
                            Card(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(day.events, id: \.id) { event in
                                        if event.id != day.events.first?.id { RowDivider() }
                                        EventRow(model: model, event: event, now: context.date)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var status: some View {
        let calendars = model.calendarAccounts.flatMap(\.calendars).filter { !model.settings.excludedCalendarIDs.contains($0.id) }
        let accounts = ListFormatter.localizedString(byJoining: model.calendarAccounts.map(\.title).filter { !$0.isEmpty })
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("Calendar connected")).font(.body.weight(.medium))
                Text(calendars.count == 1 ? L10n.tr("Reading 1 calendar from %@.", accounts) : L10n.tr("Reading %d calendars from %@.", calendars.count, accounts))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L10n.tr("Choose calendars")) { model.selectedPage = .settings }
        }
        .padding(.horizontal, 4)
    }
}

private struct CalendarDay: Identifiable {
    let start: Date
    let events: [CalendarEvent]
    let title: String
    var id: Date { start }

    static func group(_ events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> [CalendarDay] {
        Dictionary(grouping: events) { calendar.startOfDay(for: max($0.start, now)) }
            .map { start, events in CalendarDay(start: start, events: events, title: title(for: start, calendar: calendar)) }
            .sorted { $0.start < $1.start }
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return L10n.tr("Today") }
        if calendar.isDateInTomorrow(day) { return L10n.tr("Tomorrow") }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

private struct EventRow: View {
    @Bindable var model: AppModel
    let event: CalendarEvent
    let now: Date

    private var isHappening: Bool { event.start <= now && now < event.end }
    private var startsSoon: Bool { !event.isAllDay && event.start.timeIntervalSince(now) <= 15 * 60 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.calendarColor.map { Color(red: $0.x, green: $0.y, blue: $0.z) } ?? .accentColor)
                .frame(width: 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title.isEmpty ? L10n.tr("Untitled event") : event.title)
                    .font(.body.weight(.medium))
                Text(when)
                    .font(.callout)
                    .foregroundStyle(isHappening ? Color.accentColor : .secondary)
                if let invitees {
                    Text(invitees)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if let url = event.videoURL {
                    Button(L10n.tr("Join")) { NSWorkspace.shared.open(url) }
                        .help(url.host() ?? "")
                }
                if startsSoon {
                    Button(L10n.tr("Take notes")) { model.startNotetaker(for: event) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.meetings.capturingID != nil)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private var when: String {
        let range = event.isAllDay ? L10n.tr("All day") : L10n.tr("%@ to %@", event.start.formatted(date: .omitted, time: .shortened), event.end.formatted(date: .omitted, time: .shortened))
        let source = event.calendarTitle.isEmpty ? range : "\(range) · \(event.calendarTitle)"
        if isHappening && !event.isAllDay { return L10n.tr("Now, %@", source) }
        guard !event.isAllDay, event.start > now, event.start.timeIntervalSince(now) < 60 * 60 else { return source }
        return L10n.tr("In %d min, %@", max(1, Int(event.start.timeIntervalSince(now) / 60)), source)
    }

    private var invitees: String? {
        guard !event.attendees.isEmpty else { return nil }
        let shown = Array(event.attendees.prefix(3))
        let names = ListFormatter.localizedString(byJoining: shown)
        let more = event.attendees.count - shown.count
        return more == 0 ? L10n.tr("With %@", names) : L10n.tr("With %@ and %d more", names, more)
    }
}
