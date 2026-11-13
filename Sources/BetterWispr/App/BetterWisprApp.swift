import AppKit
import BetterWisprCore
import SwiftUI

struct BetterWisprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("BetterWispr", id: "dashboard") {
            ZStack {
                if delegate.model.needsOnboarding {
                    OnboardingView(model: delegate.model)
                        .windowChromeHidden()
                        .transition(.opacity)
                } else {
                    DashboardView(model: delegate.model)
                        .transition(.opacity)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                delegate.model.refreshPermissions()
            }
            .frame(minWidth: 760, minHeight: 520)
            .environment(\.appTheme, delegate.model.settings.theme)
            .animation(.easeInOut(duration: 0.4), value: delegate.model.needsOnboarding)
        }
        .defaultSize(width: 920, height: 680)
        .commands {
            SidebarCommands()
            CommandGroup(after: .appInfo) {
                Button(L10n.tr("Check for Updates…")) { delegate.model.updater.checkForUpdates() }
                    .disabled(!delegate.model.updater.canCheckForUpdates)
            }
            CommandGroup(after: .saveItem) {
                Button(L10n.tr("Export History…")) { delegate.model.exportHistory() }
                    .disabled(delegate.model.history.isEmpty)
            }
            CommandGroup(after: .newItem) {
                Button(delegate.model.phase == .recording ? L10n.tr("Finish dictation") : L10n.tr("Start dictation")) {
                    delegate.model.toggleRecording()
                }
                Button(L10n.tr("Cancel dictation")) { delegate.model.cancelRecording() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(!delegate.model.isBusy)
            }
            CommandGroup(after: .help) {
                WelcomeGuideButton(model: delegate.model)
            }
        }
        MenuBarExtra {
            MenuContents(model: delegate.model)
        } label: {
            Label {
                Text("BetterWispr")
            } icon: {
                if delegate.model.phase == .recording {
                    Image(systemName: "mic.fill")
                } else {
                    Image(nsImage: BrandGlyph.menuBarImage)
                }
            }
        }
    }
}

private struct WelcomeGuideButton: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L10n.tr("Show Welcome Guide")) {
            model.showOnboarding()
            openWindow(id: "dashboard")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .disabled(model.needsOnboarding)
    }
}

private struct MenuContents: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(status)
        Button { model.toggleRecording() } label: {
            Text(model.phase == .recording ? L10n.tr("Finish Dictation") : L10n.tr("Start Dictation"))
            Text(model.settings.shortcut.displayName)
        }
        .disabled(model.phase == .preparing || model.phase == .transcribing)
        if model.isBusy { Button(L10n.tr("Cancel")) { model.cancelRecording() } }
        Button(model.meetings.capturingID == nil ? L10n.tr("Start Meeting Notes") : L10n.tr("Stop Meeting")) {
            guard model.meetings.capturingID == nil else { return model.meetings.stop() }
            model.startNotetaker()
        }
        Divider()
        Picker(L10n.tr("Model"), selection: Binding(
            get: { model.selectedModel.id },
            set: { id in
                if let speechModel = model.models.first(where: { $0.id == id }) { model.selectModel(speechModel) }
            }
        )) {
            ForEach(model.models.filter(model.isModelInstalled)) { speechModel in
                Text(speechModel.localizedName).tag(speechModel.id)
            }
        }
        .disabled(model.isBusy)
        MicrophonePicker(model: model) { Text(L10n.tr("Microphone")) }
        Divider()
        Button(L10n.tr("Open Dashboard"), action: openDashboard)
        Button(L10n.tr("Settings…")) {
            model.selectedPage = .settings
            openDashboard()
        }
        .keyboardShortcut(",")
        if let version = model.updater.pendingVersion {
            Button(L10n.tr("Install BetterWispr %@…", String(version))) { model.updater.installUpdate() }
        } else {
            Button(L10n.tr("Check for Updates…")) { model.updater.checkForUpdates() }
                .disabled(!model.updater.canCheckForUpdates)
        }
        Divider()
        Button(L10n.tr("Quit BetterWispr")) { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }

    private var status: String {
        switch model.phase {
        case .recording: L10n.tr("Listening…")
        case .transcribing: L10n.tr("Transcribing…")
        case .preparing: L10n.tr("Preparing…")
        case .asking: L10n.tr("Waiting for your answer…")
        case .idle, .failed, .unpasted, .cancelled, .completed, .sending: L10n.tr("BetterWispr: Ready")
        }
    }

    private func openDashboard() {
        openWindow(id: "dashboard")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var capsule: CapsuleController?
    private var notetaker: NotetakerController?
    private var started = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        model.applyDockVisibility()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
        if model.settings.showInDock { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    func start() {
        guard !started else { return }
        started = true
        model.pruneHistoryAtLaunch()
        capsule = CapsuleController(model: model)
        model.onPresentationChange = { [weak self] in self?.capsule?.update() }
        notetaker = NotetakerController(model: model)
        model.onShowNotetaker = { [weak self] in self?.notetaker?.show($0) }
        model.registerShortcut()
        capsule?.update()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.keepDictationForQuit()
        model.discardRecording()
        guard let pending = model.mediaPauser.pending else { return .terminateNow }
        Task {
            await pending.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.discardRecording()
        model.meetings.endForQuit()
        model.transcriptions.endForQuit()
        capsule?.close()
        notetaker?.close()
        LlamaEngine.shared.shutdown()
    }
}

private extension View {
    @ViewBuilder func windowChromeHidden() -> some View {
        if #available(macOS 15, *) {
            toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}
