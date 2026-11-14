import BetterWisprCore
import EventKit
import SwiftUI

private enum CalendarScope: CaseIterable {
    case day, week, month

    var title: String {
        switch self {
        case .day: L10n.tr("Day")
        case .week: L10n.tr("Week")
        case .month: L10n.tr("Month")
        }
    }

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }
}

private struct CalendarRefresh: Equatable {
    let interval: DateInterval
    let excluded: Set<String>
    let connected: Bool
}

struct CalendarView: View {
    @Bindable var model: AppModel
    @State private var scope = CalendarScope.week
    @State private var date = Date.now

    private var calendar: Calendar { .current }
    private var isConnected: Bool { model.settings.useCalendar && model.calendarGranted }

    var body: some View {
        Group {
            if isConnected {
                if model.calendarAccounts.isEmpty { noCalendars } else { browser }
            } else if CalendarEvents.isDenied {
                denied
            } else {
                connect
            }
        }
        .background(.pageFill)
        .task(id: CalendarRefresh(interval: interval, excluded: model.settings.excludedCalendarIDs, connected: isConnected)) {
            while !Task.isCancelled {
                await model.refreshCalendarEvents(in: interval)
                try? await Task.sleep(for: .seconds(300))
            }
        }
        .task(id: interval) {
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged).map({ _ in () }) {
                await model.refreshCalendarEvents(in: interval)
            }
        }
    }

    private var monthDays: [Date] { CalendarLayout.monthDays(containing: date, calendar: calendar) }

    private var interval: DateInterval {
        if scope == .month, let first = monthDays.first, let last = monthDays.last, let end = calendar.date(byAdding: .day, value: 1, to: last) {
            return DateInterval(start: first, end: end)
        }
        return calendar.dateInterval(of: scope.component, for: date) ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    }

    private var title: String {
        switch scope {
        case .day: date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        case .week, .month: date.formatted(.dateTime.month(.wide).year())
        }
    }

    private var browser: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 0) {
                header
                Divider()
                switch scope {
                case .month:
                    MonthGrid(model: model, days: monthDays, month: date, now: context.date, events: model.shownCalendarEvents, open: open)
                case .week:
                    TimeGrid(model: model, days: days(in: interval), now: context.date, events: model.shownCalendarEvents, open: open)
                case .day:
                    TimeGrid(model: model, days: [calendar.startOfDay(for: date)], now: context.date, events: model.shownCalendarEvents, open: open)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Text(status)
                        .foregroundStyle(.secondary)
                    Button(L10n.tr("Choose calendars")) { model.selectedPage = .settings }
                        .buttonStyle(.link)
                    Button(L10n.tr("Add Account…"), action: model.addCalendarAccount)
                        .buttonStyle(.link)
                }
                .font(.callout)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            Picker(L10n.tr("Calendar"), selection: $scope) {
                ForEach(CalendarScope.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            ControlGroup {
                Button { step(-1) } label: { Label(L10n.tr("Previous"), systemImage: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button(L10n.tr("Today")) { date = .now }
                    .keyboardShortcut("t", modifiers: .command)
                Button { step(1) } label: { Label(L10n.tr("Next"), systemImage: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
            }
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var status: String {
        let calendars = model.calendarAccounts.flatMap(\.calendars).filter { !model.settings.excludedCalendarIDs.contains($0.id) }
        let accounts = ListFormatter.localizedString(byJoining: model.calendarAccounts.map(\.title).filter { !$0.isEmpty })
        return calendars.count == 1 ? L10n.tr("Reading 1 calendar from %@.", accounts) : L10n.tr("Reading %d calendars from %@.", calendars.count, accounts)
    }

    private func step(_ direction: Int) {
        date = calendar.date(byAdding: scope.component, value: direction, to: date) ?? date
    }

    private func open(_ day: Date) {
        date = day
        scope = .day
    }

    private func days(in interval: DateInterval) -> [Date] {
        Array(sequence(first: interval.start) { calendar.date(byAdding: .day, value: 1, to: $0) }.prefix { $0 < interval.end })
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
                    detail: L10n.tr("Calendar access is on, but this Mac has no calendar accounts yet. Sign in to Google, Outlook, Exchange, Yahoo or iCloud in Internet Accounts, and the calendars appear here once they sync. For Outlook, choose Microsoft Exchange.")) {
            Button(L10n.tr("Add Account…"), action: model.addCalendarAccount)
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
}

private extension CalendarEvent {
    var displayTitle: String { title.isEmpty ? L10n.tr("Untitled event") : title }
    var color: Color { calendarColor.map { Color(red: $0.x, green: $0.y, blue: $0.z) } ?? .accentColor }
}

private func wholeDay(_ day: Date, calendar: Calendar) -> DateInterval {
    DateInterval(start: day, end: calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400))
}

private struct DayNumber: View {
    let day: Date
    let isToday: Bool
    var dimmed = false

    var body: some View {
        Text(day.formatted(.dateTime.day()))
            .font(.callout.weight(isToday ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(isToday ? AnyShapeStyle(.white) : dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .frame(minWidth: 22, minHeight: 22)
            .background { if isToday { Circle().fill(.red) } }
    }
}

private struct MonthGrid: View {
    @Bindable var model: AppModel
    let days: [Date]
    let month: Date
    let now: Date
    let events: [CalendarEvent]
    let open: (Date) -> Void

    private let shownPerDay = 3

    var body: some View {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        let weekdays = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { weekday in
                    Text(weekday)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
            }
            Divider()
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        if day != week.first { Divider() }
                        cell(day, calendar: calendar)
                    }
                }
                .frame(maxHeight: .infinity)
                Divider()
            }
        }
    }

    private func cell(_ day: Date, calendar: Calendar) -> some View {
        let dayEvents = events.filter { $0.occurs(in: wholeDay(day, calendar: calendar)) }
        let shown = dayEvents.count > shownPerDay ? Array(dayEvents.prefix(shownPerDay - 1)) : dayEvents
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer(minLength: 0)
                DayNumber(day: day, isToday: calendar.isDate(day, inSameDayAs: now), dimmed: !calendar.isDate(day, equalTo: month, toGranularity: .month))
            }
            ForEach(shown, id: \.occurrenceID) { event in
                EventButton(model: model, event: event, now: now) {
                    HStack(spacing: 4) {
                        if event.isAllDay {
                            Text(event.displayTitle)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(event.color.opacity(0.25), in: .rect(cornerRadius: 3))
                        } else {
                            Circle().fill(event.color).frame(width: 6, height: 6)
                            Text(event.displayTitle).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(event.start.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .opacity(event.end <= now ? 0.55 : 1)
                }
            }
            if dayEvents.count > shown.count {
                Text(L10n.tr("%d more", dayEvents.count - shown.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .contentShape(.rect)
        .onTapGesture { open(day) }
    }
}

private struct TimeGrid: View {
    @Bindable var model: AppModel
    let days: [Date]
    let now: Date
    let events: [CalendarEvent]
    let open: (Date) -> Void

    private let hourHeight: CGFloat = 48
    private let gutter: CGFloat = 56

    var body: some View {
        let calendar = Calendar.current
        let allDay = days.map { day in events.filter { $0.isAllDay && $0.occurs(in: wholeDay(day, calendar: calendar)) } }
        VStack(spacing: 0) {
            if days.count > 1 {
                HStack(spacing: 0) {
                    Color.clear.frame(width: gutter, height: 1)
                    ForEach(days, id: \.self) { day in
                        Button { open(day) } label: {
                            HStack(spacing: 4) {
                                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                                    .foregroundStyle(.secondary)
                                DayNumber(day: day, isToday: calendar.isDate(day, inSameDayAs: now))
                            }
                            .font(.callout)
                            .frame(maxWidth: .infinity)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
            if allDay.contains(where: { !$0.isEmpty }) {
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    Text(L10n.tr("All day"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: gutter - 6, alignment: .trailing)
                        .padding(.trailing, 6)
                    ForEach(Array(zip(days, allDay)), id: \.0) { _, dayEvents in
                        VStack(spacing: 2) {
                            ForEach(dayEvents, id: \.occurrenceID) { event in
                                EventButton(model: model, event: event, now: now) {
                                    Text(event.displayTitle)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(event.color.opacity(0.25), in: .rect(cornerRadius: 4))
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(hour == 0 ? "" : hourLabel(hour, calendar: calendar))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: gutter - 8, height: hourHeight, alignment: .topTrailing)
                                    .padding(.trailing, 8)
                                    .offset(y: -7)
                                    .id(hour)
                            }
                        }
                        ForEach(days, id: \.self) { day in
                            DayColumn(model: model, day: day, now: now, hourHeight: hourHeight,
                                      events: events.filter { !$0.isAllDay && $0.occurs(in: wholeDay(day, calendar: calendar)) })
                        }
                    }
                    .background(alignment: .top) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { _ in
                                VStack(spacing: 0) {
                                    Divider()
                                    Spacer(minLength: 0)
                                }
                                .frame(height: hourHeight)
                            }
                        }
                        .padding(.leading, gutter)
                    }
                    .padding(.top, 8)
                }
                .onAppear { proxy.scrollTo(min(max(calendar.component(.hour, from: now) - 1, 0), 15), anchor: .top) }
            }
        }
    }

    private func hourLabel(_ hour: Int, calendar: Calendar) -> String {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)?.formatted(.dateTime.hour()) ?? ""
    }
}

private struct DayColumn: View {
    @Bindable var model: AppModel
    let day: Date
    let now: Date
    let hourHeight: CGFloat
    let events: [CalendarEvent]

    var body: some View {
        let calendar = Calendar.current
        let columns = CalendarLayout.columns(events)
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(events, id: \.occurrenceID) { event in
                    let top = offset(of: max(event.start, day), calendar: calendar)
                    let height = max(offset(of: event.end, calendar: calendar) - top, 22)
                    let column = columns[event.occurrenceID] ?? (index: 0, count: 1)
                    let width = proxy.size.width / CGFloat(column.count)
                    EventButton(model: model, event: event, now: now) {
                        block(event, height: height)
                    }
                    .frame(width: max(width - 3, 1), height: height - 2)
                    .offset(x: CGFloat(column.index) * width + 1, y: top + 1)
                }
                if calendar.isDate(now, inSameDayAs: day) {
                    HStack(spacing: 0) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Rectangle().fill(.red).frame(height: 1)
                    }
                    .offset(x: -3, y: offset(of: now, calendar: calendar) - 3.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(height: hourHeight * 24)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) { Divider() }
    }

    private func offset(of date: Date, calendar: Calendar) -> CGFloat {
        guard calendar.isDate(date, inSameDayAs: day) else { return date < day ? 0 : hourHeight * 24 }
        let time = calendar.dateComponents([.hour, .minute], from: date)
        return (CGFloat(time.hour ?? 0) + CGFloat(time.minute ?? 0) / 60) * hourHeight
    }

    private func block(_ event: CalendarEvent, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.displayTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(height > 40 ? 2 : 1)
            if height > 34 {
                Text(event.start.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(event.color.opacity(0.2), in: .rect(cornerRadius: 4))
        .overlay(alignment: .leading) { event.color.frame(width: 3) }
        .clipShape(.rect(cornerRadius: 4))
        .opacity(event.end <= now ? 0.55 : 1)
    }
}

private struct EventButton<Content: View>: View {
    @Bindable var model: AppModel
    let event: CalendarEvent
    let now: Date
    @ViewBuilder let content: Content
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { content.contentShape(.rect) }
            .buttonStyle(.plain)
            .help(event.displayTitle)
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                EventDetail(model: model, event: event, now: now)
            }
    }
}

private struct EventDetail: View {
    @Bindable var model: AppModel
    let event: CalendarEvent
    let now: Date

    private static let shownGuests = 25

    private var canTakeNotes: Bool { !event.isAllDay && now < event.end && event.start.timeIntervalSince(now) <= 15 * 60 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let url = event.videoURL { video(url) }
                    if showsLocation {
                        section("mappin.and.ellipse") { LinkedText(event.location) }
                    }
                    if !event.guests.isEmpty { guests }
                    if !event.notes.isEmpty {
                        section("text.alignleft") { LinkedText(event.notes) }
                    }
                    if !event.calendarTitle.isEmpty {
                        section("calendar") {
                            Text(event.calendarTitle)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            if canTakeNotes {
                Divider()
                HStack {
                    Spacer()
                    Button(L10n.tr("Take notes")) { model.startNotetaker(for: event) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.meetings.capturingID != nil)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 400)
        .frame(maxHeight: 600)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(event.color)
                .frame(width: 12, height: 12)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.displayTitle)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(when)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func video(_ url: URL) -> some View {
        section("video") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button(event.videoPlatform.map { L10n.tr("Join with %@", String($0.name)) } ?? L10n.tr("Join")) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Spacer()
                    copyButton(url.absoluteString, help: L10n.tr("Copy link"))
                }
                Text(displayed(url))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var guests: some View {
        section("person.2") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.guests.count == 1 ? L10n.tr("1 guest") : L10n.tr("%d guests", event.guests.count))
                        if let replies { Text(replies).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    let emails = event.guests.compactMap(\.email)
                    if !emails.isEmpty { copyButton(emails.joined(separator: ", "), help: L10n.tr("Copy guest emails")) }
                }
                ForEach(Array(event.guests.prefix(Self.shownGuests).enumerated()), id: \.offset) { _, guest in
                    GuestRow(guest: guest)
                }
                if event.guests.count > Self.shownGuests {
                    Text(L10n.tr("%d more", event.guests.count - Self.shownGuests))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func section(_ symbol: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copyButton(_ text: String, help: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    private var showsLocation: Bool {
        !event.location.isEmpty && event.location != event.videoURL?.absoluteString
    }

    private var replies: String? {
        let counts = Dictionary(grouping: event.guests, by: \.response).mapValues(\.count)
        let parts: [String] = [
            counts[.accepted].map { L10n.tr("%d yes", $0) },
            counts[.declined].map { L10n.tr("%d no", $0) },
            counts[.tentative].map { L10n.tr("%d maybe", $0) },
            counts[.pending].map { L10n.tr("%d awaiting", $0) },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func displayed(_ url: URL) -> String {
        let text = (url.host() ?? "") + url.path()
        return text.isEmpty ? url.absoluteString : text
    }

    private var when: String {
        let end = max(event.end, event.start)
        if event.isAllDay { return (event.start..<max(end.addingTimeInterval(-1), event.start)).formatted(date: .complete, time: .omitted) }
        return (event.start..<end).formatted(date: .complete, time: .shortened)
    }
}

private struct GuestRow: View {
    let guest: CalendarGuest

    var body: some View {
        HStack(spacing: 10) {
            Text(initials)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.08), in: .circle)
                .overlay(alignment: .bottomTrailing) { badge }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(guest.isYou ? L10n.tr("%@ (you)", guest.name) : guest.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(response ?? "")
    }

    @ViewBuilder private var badge: some View {
        if let symbol {
            Image(systemName: symbol.name)
                .font(.system(size: 11))
                .foregroundStyle(.white, symbol.color)
                .background(Circle().fill(.background).padding(-1.5))
                .offset(x: 3, y: 3)
        }
    }

    private var symbol: (name: String, color: Color)? {
        switch guest.response {
        case .accepted: ("checkmark.circle.fill", .green)
        case .declined: ("xmark.circle.fill", .red)
        case .tentative: ("questionmark.circle.fill", .orange)
        case .pending: nil
        }
    }

    private var response: String? {
        switch guest.response {
        case .accepted: L10n.tr("Going")
        case .declined: L10n.tr("Not going")
        case .tentative: L10n.tr("Maybe")
        case .pending: L10n.tr("Awaiting reply")
        }
    }

    private var caption: String? {
        let parts = [guest.isOrganizer ? L10n.tr("Organizer") : nil, guest.email].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var initials: String {
        let words = guest.name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(guest.name.contains("@") ? 1 : 2)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

private struct LinkedText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(linked)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var linked: AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}
