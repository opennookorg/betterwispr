import Foundation
import Observation
import os
import Sparkle
import BetterWisprCore

@MainActor @Observable
final class AppUpdater: NSObject {
    private(set) var canCheckForUpdates = false
    private(set) var pendingVersion: String?

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) { controller.updater.automaticallyChecksForUpdates = newValue }
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            access(keyPath: \.automaticallyDownloadsUpdates)
            return controller.updater.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyDownloadsUpdates) { controller.updater.automaticallyDownloadsUpdates = newValue }
        }
    }

    @ObservationIgnored private lazy var controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var relaunch: (() -> Void)?

    override init() {
        super.init()
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    func installUpdate() {
        guard let relaunch else { return checkForUpdates() }
        relaunch()
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        Logger(subsystem: "org.betterwispr.app", category: "Updates").notice("Update ready to install on quit: version=\(item.versionString, privacy: .public)")
        relaunch = immediateInstallHandler
        pendingVersion = item.displayVersionString
        ToastWindow.shared.show(Toast(title: L10n.tr("Update ready"), message: L10n.tr("Restart BetterWispr to finish updating to %@.", String(item.displayVersionString)),
                                      systemImage: "arrow.down.circle", action: Toast.Action(title: L10n.tr("Restart"), perform: installUpdate)))
        return true
    }
}

extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        pendingVersion = update.displayVersionString
        ToastWindow.shared.show(Toast(title: L10n.tr("Update available"), message: L10n.tr("BetterWispr %@ is ready to install.", String(update.displayVersionString)),
                                      systemImage: "arrow.down.circle", action: Toast.Action(title: L10n.tr("Update"), perform: installUpdate)))
    }

    func standardUserDriverWillFinishUpdateSession() {
        guard relaunch == nil else { return }
        pendingVersion = nil
    }
}
