import AppKit
import BetterWisprCore
import SwiftUI

struct Toast {
    let title: String
    let message: String
    let systemImage: String
    var isError = false
    var action: Action?

    struct Action {
        let title: String
        let perform: @MainActor () -> Void
    }
}

extension Toast {
    init(_ result: OutputResult) {
        switch result {
        case .copied: self.init(title: L10n.tr("Copied"), message: L10n.tr("Ready to paste anywhere."), systemImage: "doc.on.doc")
        case .copiedForManualPaste: self.init(title: L10n.tr("Copied"), message: L10n.tr("Paste into your app with ⌘V."), systemImage: "doc.on.clipboard")
        case .pasted(let app): self.init(title: L10n.tr("Pasted"), message: L10n.tr("Sent to %@.", String(app)), systemImage: "text.cursor")
        }
    }

    init(failure title: String, _ error: Error) {
        self.init(title: title, message: error.localizedDescription, systemImage: "exclamationmark.triangle.fill", isError: true)
    }

    init(pruned count: Int, by retention: HistoryRetention) {
        let limit = switch retention {
        case .forever: L10n.tr("from history")
        case .latest100: L10n.tr("beyond the latest 100")
        case .threeDays: L10n.tr("older than 3 days")
        case .twoWeeks: L10n.tr("older than 2 weeks")
        case .threeMonths: L10n.tr("older than 3 months")
        }
        self.init(title: L10n.tr("Deleted %ld dictations %@", count, limit),
                  message: L10n.tr("Your Keep history setting removes them from this Mac. Meetings and transcribed files stay."), systemImage: "trash")
    }
}

@MainActor
final class ToastWindow {
    static let shared = ToastWindow()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ toast: Toast) {
        dismiss(animated: false)

        let hostingView = ToastHostingView(rootView: ToastView(toast: toast) { [weak self] in self?.dismiss(animated: true) })
        let size = hostingView.fittingSize
        hostingView.sizingOptions = []
        hostingView.setFrameSize(size)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = toast.action == nil
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView

        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + slide))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(origin)
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "\(toast.title). \(toast.message)",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.action != nil ? 10 : toast.isError ? 4 : 2.5))
            guard !Task.isCancelled else { return }
            self?.dismiss(animated: true)
        }
    }

    private var slide: CGFloat { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 10 }

    private func dismiss(animated: Bool) {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(NSPoint(x: panel.frame.minX, y: panel.frame.minY + slide))
        } completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        }
    }
}

private final class ToastHostingView: NSHostingView<ToastView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(toast.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(toast.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action = toast.action {
                Button(action.title) {
                    dismiss()
                    action.perform()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .modifier(ToastSurface())
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct ToastSurface: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
        } else {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
    }
}
