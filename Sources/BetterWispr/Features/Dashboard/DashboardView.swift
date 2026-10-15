import BetterWisprCore
import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case overview, insights, meetings, transcribe, history, models, vocabulary, style, settings, about

    static let sections: [(title: String?, pages: [AppPage])] = [
        (nil, [.overview, .insights, .meetings, .transcribe, .history]),
        ("Personalize", [.models, .vocabulary, .style]),
        ("App", [.settings, .about]),
    ]

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Home"
        case .meetings: "Notetaker"
        default: rawValue.capitalized
        }
    }
    var symbol: String {
        switch self {
        case .overview: "house"
        case .insights: "chart.bar"
        case .meetings: "note.text"
        case .transcribe: "waveform"
        case .history: "clock"
        case .models: "cpu"
        case .vocabulary: "character.book.closed"
        case .style: "textformat"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

struct DashboardView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<AppPage?>(
                get: { model.selectedPage },
                set: { if let page = $0 { model.selectedPage = page } }
            )) {
                ForEach(AppPage.sections, id: \.pages) { section in
                    Section {
                        ForEach(section.pages) { page in
                            Label(page.title, systemImage: page.symbol).tag(page)
                        }
                    } header: {
                        if let title = section.title { Text(title) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 6) {
                    Text("Version \(AboutView.version)")
                        .textSelection(.enabled)
                    Text("·").accessibilityHidden(true)
                    Link("What’s new", destination: AboutView.changelog)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            ZStack {
                page
                    .id(model.selectedPage)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 8)),
                        removal: .opacity
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.ui, value: model.selectedPage)
            .modifier(ThemedPage())
            .navigationTitle(model.selectedPage.title)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !model.statusMessage.isEmpty { statusBar }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 520)
        .onExitCommand {
            if model.isBusy { model.cancelRecording() }
        }
        .onAppear {
            model.onShowDashboard = { [openWindow] in
                openWindow(id: "dashboard")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch model.selectedPage {
        case .overview: HomeView(model: model)
        case .insights: InsightsView(history: model.history, savesHistory: model.settings.saveHistory)
        case .meetings: MeetingsView(model: model)
        case .transcribe: TranscribeView(model: model)
        case .history: HistoryView(model: model)
        case .models: ModelsView(model: model)
        case .vocabulary: VocabularyView(model: model)
        case .style: StyleView(model: model)
        case .settings: SettingsView(model: model)
        case .about: AboutView(updater: model.updater, shortcut: model.settings.shortcut)
        }
    }

    private var statusBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: model.failure != nil ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(model.failure != nil ? Color.red : Color.secondary)
            Text(model.statusMessage)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
