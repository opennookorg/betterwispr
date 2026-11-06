import AppKit
import Foundation
import SwiftUI
import Testing
@testable import BetterWisprCore
@testable import BetterWispr

@Test @MainActor func historyMountsOnlyVisibleRowsHoweverLongTheHistoryIs() {
    #expect(mountedViews(onHistoryWith: 400) <= mountedViews(onHistoryWith: 20) + 50)
}

@MainActor private func mountedViews(onHistoryWith count: Int) -> Int {
    let model = AppModel(store: LocalStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                         startsServices: false)
    model.history = (0..<count).map { index in
        Transcript(createdAt: Date(timeIntervalSinceNow: -Double(index) * 600), text: "Dictation \(index) about the release plan.",
                   rawText: "Dictation \(index) about the release plan, um.", duration: 12, modelName: "Parakeet", language: "auto")
    }
    model.selectedPage = .history
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: DashboardView(model: model))
    defer { window.close() }
    for _ in 0..<20 {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        window.contentView?.layoutSubtreeIfNeeded()
    }
    return descendants(of: window.contentView)
}

@MainActor private func descendants(of view: NSView?) -> Int {
    guard let view else { return 0 }
    return view.subviews.reduce(view.subviews.count) { $0 + descendants(of: $1) }
}
