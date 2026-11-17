import AppKit
import BetterWisprCore
import OSLog

/// Listens for side mouse buttons anywhere, passing them through so they still click the app.
@MainActor
final class MouseButtonMonitor {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var pressedButtons: Set<Int> = []
    var onPress: ((Int) -> Void)?
    var onRelease: ((Int) -> Void)?

    var isRunning: Bool { localMonitor != nil }

    func start() {
        guard localMonitor == nil else { return }
        pressedButtons = []
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        guard localMonitor != nil, globalMonitor != nil else {
            Logger(subsystem: "org.betterwispr.app", category: "MouseButtonMonitor").error("Couldn't listen for side mouse buttons.")
            stop()
            return
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        pressedButtons = []
    }

    private func handle(_ event: NSEvent) {
        guard DictationTrigger.recordableMouseButtons.contains(event.buttonNumber) else { return }
        switch event.type {
        case .otherMouseDown:
            guard pressedButtons.insert(event.buttonNumber).inserted else { return }
            onPress?(event.buttonNumber)
        case .otherMouseUp:
            guard pressedButtons.remove(event.buttonNumber) != nil else { return }
            onRelease?(event.buttonNumber)
        default: break
        }
    }
}
