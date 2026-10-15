import AppKit
import BetterWisprCore
import Charts
import SwiftUI

private extension InsightsPeriod {
    var title: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .allTime: "All time"
        }
    }

    var comparison: String {
        switch self {
        case .week: "prior 7 days"
        case .month: "prior 30 days"
        case .allTime: ""
        }
    }

    var shareOpening: String {
        switch self {
        case .week: "In the last 7 days I dictated"
        case .month: "In the last 30 days I dictated"
        case .allTime: "I’ve dictated"
        }
    }
}

struct InsightsView: View {
    let history: [Transcript]
    let savesHistory: Bool
    @AppStorage("insightsPeriod") private var period = InsightsPeriod.week
    @State private var isWide = true

    var body: some View {
        if history.isEmpty {
            ScrollView {}
                .overlay {
                    ContentUnavailableView(
                        "No Insights Yet",
                        systemImage: "chart.bar",
                        description: Text(savesHistory
                            ? "Dictate a few times and your pace, time saved and top apps appear here."
                            : "Insights are built from saved dictations. Turn on Save history in Settings to see them.")
                    )
                }
        } else {
            content(UsageInsights(history, period: period))
        }
    }

    private func content(_ insights: UsageInsights) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(insights)
                if !savesHistory {
                    Label("History is off, so new dictations are not counted.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                MetricTiles(insights: insights)
                ActivityCard(insights: insights)
                row {
                    TopAppsCard(insights: insights)
                    TimeOfDayCard(insights: insights)
                }
                row {
                    CleanupCard(insights: insights)
                    StreakCard(insights: insights)
                }
            }
            .onGeometryChange(for: Bool.self) { $0.size.width >= 640 } action: { isWide = $0 }
            .padding(24)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(.ui, value: period)
        }
        .toolbar {
            ToolbarItem {
                ShareLink(item: shareText(insights)) {
                    Label("Share Insights", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func header(_ insights: UsageInsights) -> some View {
        HStack {
            Text((insights.start..<Date.now).formatted(.interval.month(.abbreviated).day().year()))
                .font(.title3.weight(.semibold))
                .contentTransition(.opacity)
            Spacer(minLength: 12)
            Picker("Period", selection: $period) {
                ForEach(InsightsPeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func row(@ViewBuilder _ cards: () -> some View) -> some View {
        let layout = isWide ? AnyLayout(HStackLayout(alignment: .top, spacing: 16)) : AnyLayout(VStackLayout(spacing: 16))
        return layout(cards).fixedSize(horizontal: false, vertical: isWide)
    }

    private func shareText(_ insights: UsageInsights) -> String {
        let totals = insights.current
        return "\(insights.period.shareOpening) \(totals.words.formatted()) words with BetterWispr at \(totals.wordsPerMinute) words per minute, about \(formattedTime(totals.timeSaved)) faster than typing."
    }
}

private func formattedTime(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
}

private struct CardTitle<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct BigFigure: View {
    let value: String
    let caption: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.4)
                .contentTransition(.numericText())
            Text(caption).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

private struct MetricTiles: View {
    let insights: UsageInsights

    var body: some View {
        let now = insights.current
        let before = insights.previous
        let comparison = insights.period.comparison
        let typing = UsageInsights.typingWordsPerMinute
        let ratio = Double(now.wordsPerMinute) / Double(typing)
        let tiles = [
            MetricTile(
                label: "Words dictated", value: now.words.formatted(),
                current: Double(now.words), previous: before.map { Double($0.words) }, comparison: comparison,
                note: Text("^[\(now.dictations) dictation](inflect: true)")
            ),
            MetricTile(
                label: "Time saved", value: formattedTime(now.timeSaved),
                current: now.timeSaved, previous: before?.timeSaved, comparison: comparison,
                note: Text("vs typing at \(typing) wpm"),
                help: "Estimate: the time these words take to type at \(typing) wpm, the mean of 168,000 typists in Dhakal et al., CHI 2018, minus the time you spent speaking."
            ),
            MetricTile(
                label: "Speaking pace", value: now.wordsPerMinute.formatted(), unit: "wpm",
                current: 0, previous: nil, comparison: comparison,
                note: ratio >= 1.1
                    ? Text("\(ratio.formatted(.number.precision(.fractionLength(1))))× typing speed")
                    : Text("Pauses count toward pace"),
                help: "Words divided by recording time, pauses included."
            ),
            MetricTile(
                label: "Dictations", value: now.dictations.formatted(),
                current: Double(now.dictations), previous: before.map { Double($0.dictations) }, comparison: comparison,
                note: Text("~\(now.dictations > 0 ? now.words / now.dictations : 0) words each")
            ),
        ]
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { ForEach(tiles, id: \.label) { $0.frame(minWidth: 150) } }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { tiles[0]; tiles[1] }
                GridRow { tiles[2]; tiles[3] }
            }
        }
    }
}

private struct MetricTile: View {
    let label: String
    let value: String
    var unit: String?
    let current: Double
    let previous: Double?
    let comparison: String
    let note: Text
    var help: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.4)
                        .contentTransition(.numericText())
                    if let unit { Text(unit).foregroundStyle(.secondary) }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                change
                    .font(.callout)
                    .lineLimit(1)
            }
        }
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var change: some View {
        if let previous, previous > 0 {
            let delta = (current - previous) / previous
            if abs(delta) < 0.005 {
                Text("Same as \(comparison)").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 3) {
                    Image(systemName: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.bold))
                    Text("\(abs(delta).formatted(.percent.precision(.fractionLength(0)))) vs \(comparison)")
                }
                .foregroundStyle(delta > 0 ? Color.green : .secondary)
            }
        } else if previous != nil, current > 0 {
            Text("None in \(comparison)").foregroundStyle(.secondary)
        } else {
            note.foregroundStyle(.secondary)
        }
    }
}

private struct ActivityCard: View {
    let insights: UsageInsights
    @State private var selection: Date?

    var body: some View {
        let buckets = insights.activity
        let average = Double(insights.current.words) / Double(max(buckets.count, 1))
        let busiest = buckets.max { $0.words < $1.words }
        let selected = selection.flatMap { date in buckets.last { $0.start <= date } }
        let step = buckets.count <= 12 ? 1 : Int((Double(buckets.count) / 6).rounded(.up))
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                CardTitle(title: "Words per \(unitName)") {
                    if let selected {
                        Text("\(label(selected.start)): \(selected.words.formatted()) words").foregroundStyle(.primary)
                    } else if let busiest, busiest.words > 0 {
                        Text("Busiest \(unitName): \(label(busiest.start)), \(busiest.words.formatted()) words")
                    }
                }
                Chart {
                    ForEach(buckets, id: \.start) { bucket in
                        BarMark(
                            x: .value("Date", bucket.start, unit: insights.granularity),
                            y: .value("Words", bucket.words)
                        )
                        .foregroundStyle(Color.accentColor.opacity(selected == nil || selected == bucket ? 1 : 0.35))
                        .cornerRadius(3)
                        .accessibilityLabel(label(bucket.start))
                        .accessibilityValue("\(bucket.words) words")
                    }
                    if average > 0 {
                        RuleMark(y: .value("Average", average))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top, alignment: .leading, spacing: 2) {
                                Text("avg \(Int(average.rounded()).formatted())")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .chartXSelection(value: $selection)
                .chartXAxis {
                    AxisMarks(values: .stride(by: insights.granularity, count: step)) { _ in
                        AxisValueLabel(format: axisFormat, centered: step == 1)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 180)
                .overlay {
                    if insights.current.dictations == 0 {
                        Text("No dictations in this period").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var unitName: String {
        switch insights.granularity {
        case .weekOfYear: "week"
        case .month: "month"
        default: "day"
        }
    }

    private var axisFormat: Date.FormatStyle {
        switch insights.granularity {
        case .month: .dateTime.month(.abbreviated)
        case .day where insights.activity.count <= 7: .dateTime.weekday(.abbreviated)
        default: .dateTime.month(.abbreviated).day()
        }
    }

    private func label(_ date: Date) -> String {
        switch insights.granularity {
        case .weekOfYear: "Week of \(date.formatted(.dateTime.month(.abbreviated).day()))"
        case .month: date.formatted(.dateTime.month(.wide).year())
        default: date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
    }
}

private struct TopAppsCard: View {
    let insights: UsageInsights

    var body: some View {
        let total = Double(max(insights.apps.reduce(0) { $0 + $1.words }, 1))
        let others = insights.apps.dropFirst(4)
        let otherWords = others.reduce(0) { $0 + $1.words }
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: "Top apps") {
                    if !insights.apps.isEmpty { Text("^[\(insights.apps.count) app](inflect: true)") }
                }
                if insights.apps.isEmpty {
                    Text(insights.current.dictations == 0
                        ? "No dictations in this period."
                        : "Dictations record the app they went to, so this fills in as you dictate.")
                        .foregroundStyle(.secondary)
                }
                ForEach(insights.apps.prefix(4), id: \.bundleID) { app in
                    AppRow(bundleID: app.bundleID, words: app.words, share: Double(app.words) / total)
                }
                if !others.isEmpty {
                    AppRow(bundleID: nil, words: otherWords, share: Double(otherWords) / total,
                           fallbackName: others.count == 1 ? "1 other app" : "\(others.count) other apps")
                }
                if insights.dictationsWithoutApp > 0, !insights.apps.isEmpty {
                    Text("Not counted: ^[\(insights.dictationsWithoutApp) dictation](inflect: true) with no app recorded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AppRow: View {
    let bundleID: String?
    let words: Int
    let share: Double
    var fallbackName: String?
    @State private var app: (name: String, icon: NSImage)?

    private var name: String { app?.name ?? fallbackName ?? bundleID ?? "" }
    private var percent: String { share.formatted(.percent.precision(.fractionLength(0))) }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let app {
                    Image(nsImage: app.icon).resizable()
                } else {
                    Image(systemName: bundleID == nil ? "square.grid.2x2" : "app.dashed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 5, style: .continuous))
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("\(words.formatted()) words").foregroundStyle(.secondary)
                    Text(percent)
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .font(.callout)
                .monospacedDigit()
                Capsule()
                    .fill(Color.accentColor.opacity(0.15))
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule().fill(Color.accentColor).frame(width: max(4, proxy.size.width * share))
                        }
                    }
                    .frame(height: 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(words) words, \(percent)")
        .task(id: bundleID) {
            guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            app = (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                   NSWorkspace.shared.icon(forFile: url.path))
        }
    }
}

private enum DayPart: CaseIterable {
    case morning, afternoon, evening, night

    var hours: [Int] {
        switch self {
        case .morning: Array(5..<12)
        case .afternoon: Array(12..<17)
        case .evening: Array(17..<22)
        case .night: Array(22..<24) + Array(0..<5)
        }
    }

    var headline: String {
        switch self {
        case .morning: "Mostly mornings"
        case .afternoon: "Mostly afternoons"
        case .evening: "Mostly evenings"
        case .night: "Mostly late at night"
        }
    }

    func words(_ byHour: [Int]) -> Int { hours.reduce(0) { $0 + byHour[$1] } }
}

private struct TimeOfDayCard: View {
    let insights: UsageInsights
    private let calendar = Calendar.current

    var body: some View {
        let hours = insights.wordsByHour
        let total = hours.reduce(0, +)
        let peak = hours.indices.max { hours[$0] < hours[$1] } ?? 0
        let part = DayPart.allCases.max { $0.words(hours) < $1.words(hours) } ?? .morning
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: "When you dictate") {
                    if total > 0 { Text("Peak around \(hour(peak).formatted(.dateTime.hour()))") }
                }
                if total > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(part.headline).font(.title3.weight(.semibold))
                        Text("\((Double(part.words(hours)) / Double(total)).formatted(.percent.precision(.fractionLength(0)))) of your words")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No dictations in this period.").foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(0..<24, id: \.self) { index in
                        BarMark(x: .value("Hour", hour(index), unit: .hour), y: .value("Words", hours[index]))
                            .foregroundStyle(Color.accentColor.opacity(index == peak && total > 0 ? 1 : 0.55))
                            .cornerRadius(2)
                            .accessibilityLabel(hour(index).formatted(.dateTime.hour()))
                            .accessibilityValue("\(hours[index]) words")
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 96)
            }
        }
    }

    private func hour(_ index: Int) -> Date {
        let day = calendar.startOfDay(for: .now)
        return calendar.date(bySettingHour: index, minute: 0, second: 0, of: day) ?? day
    }
}

private struct CleanupCard: View {
    let insights: UsageInsights

    var body: some View {
        let share = Double(insights.wordsCleaned) / Double(max(insights.spokenWords, 1))
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: "Cleanup") { EmptyView() }
                VStack(alignment: .leading, spacing: 2) {
                    BigFigure(value: insights.wordsCleaned.formatted(), caption: insights.wordsCleaned == 1 ? "word removed" : "words removed")
                    Text(insights.wordsCleaned == 0
                        ? "Nothing needed cleaning in this period."
                        : "\(share.formatted(.percent.precision(.fractionLength(0)))) of the \(insights.spokenWords.formatted()) words you said")
                        .foregroundStyle(.secondary)
                }
                .help("Words in the original transcription that cleanup, rewriting or Vocabulary removed or replaced.")
                if !insights.mostRemoved.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Removed most often")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ViewThatFits(in: .horizontal) {
                            chips(5)
                            chips(3)
                            chips(1)
                        }
                    }
                }
                Divider()
                HStack {
                    Label("Vocabulary fixes", systemImage: "character.book.closed")
                    Spacer()
                    Text(insights.vocabularyFixes.formatted()).monospacedDigit()
                }
                .help("Words respelled from your Vocabulary, counted from version 0.1.1.")
            }
        }
    }

    private func chips(_ count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(insights.mostRemoved.prefix(count), id: \.word) { removed in
                HStack(spacing: 4) {
                    Text(removed.word)
                    Text("×\(removed.count.formatted())").foregroundStyle(.secondary)
                }
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: .capsule)
                .fixedSize()
            }
        }
    }
}

private struct StreakCard: View {
    let insights: UsageInsights
    private let calendar = Calendar.current

    var body: some View {
        let today = calendar.startOfDay(for: .now)
        let week = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let streak = insights.currentStreak
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: "Streak") {
                    Text("Longest: ^[\(insights.longestStreak) day](inflect: true)")
                }
                VStack(alignment: .leading, spacing: 2) {
                    BigFigure(value: streak.formatted(), caption: streak == 1 ? "day in a row" : "days in a row")
                    if !insights.activeDates.contains(today) {
                        Text(streak > 0 ? "Dictate today to keep it going." : "Dictate today to start a streak.")
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(week, id: \.self) { day in
                        let active = insights.activeDates.contains(day)
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(active ? Color.accentColor : Color.primary.opacity(0.07))
                                .overlay {
                                    if active {
                                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                                    }
                                }
                                .overlay {
                                    if day == today {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.5), lineWidth: 1.5)
                                    }
                                }
                                .frame(height: 26)
                            Text(day, format: .dateTime.weekday(.narrow))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(day.formatted(.dateTime.weekday(.wide))), \(active ? "dictated" : "no dictation")")
                    }
                }
                Text(activeNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activeNote: String {
        let days = insights.activeDays == 1 ? "1 day" : "\(insights.activeDays) days"
        if let length = insights.period.days { return "Active on \(insights.activeDays) of the last \(length) days" }
        return "Active on \(days) since \(insights.start.formatted(.dateTime.month(.abbreviated).day()))"
    }
}
