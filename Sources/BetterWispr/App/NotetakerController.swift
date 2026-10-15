import AppKit
import SwiftUI

/// The meeting card docked to the right edge of the screen, floating beside the call while notes are taken.
@MainActor
final class NotetakerController {
    private static let width: CGFloat = 440
    private let model: AppModel
    private let panel: NSPanel
    private var meetingID: UUID?

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 720),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.title = "Notetaker"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .textBackgroundColor
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 380, height: 460)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let expand = NSButton(image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Open in BetterWispr")!,
                              target: self, action: #selector(openInDashboard))
        expand.isBordered = false
        expand.contentTintColor = .secondaryLabelColor
        expand.toolTip = "Open in BetterWispr"
        expand.frame = NSRect(x: 0, y: 0, width: 40, height: 28)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = expand
        accessory.layoutAttribute = .trailing
        panel.addTitlebarAccessoryViewController(accessory)
    }

    func show(_ id: UUID) {
        if meetingID != id || panel.contentView == nil {
            meetingID = id
            panel.contentView = NSHostingView(rootView: NotetakerCard(model: model, id: id) { [weak self] in self?.panel.close() })
        }
        if !panel.isVisible { dock() }
        panel.orderFrontRegardless()
    }

    func close() { panel.close() }

    private func dock() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        panel.setFrame(NSRect(x: frame.maxX - Self.width, y: frame.minY, width: Self.width, height: frame.height), display: true)
    }

    @objc private func openInDashboard() {
        guard let meetingID else { return }
        model.meetings.selectedID = meetingID
        model.selectedPage = .meetings
        model.onShowDashboard?()
        panel.close()
    }
}

private struct NotetakerCard: View {
    let model: AppModel
    let id: UUID
    let close: () -> Void

    var body: some View {
        MeetingDetailView(model: model, id: id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ThemedPage())
            .environment(\.appTheme, model.settings.theme)
            .onChange(of: model.meetings.meeting(id) == nil) { _, removed in if removed { close() } }
    }
}
