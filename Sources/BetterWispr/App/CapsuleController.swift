import AppKit
import Observation
import SwiftUI

private final class RecordingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
final class CapsuleHover {
    enum Target: Hashable { case surface, microphone, notetaker, meetingNotes, dictation }

    private(set) var isHovering = false
    private(set) var target: Target?
    @ObservationIgnored private var regions: [Target: CGRect] = [:]
    @ObservationIgnored private var location: CGPoint?

    func update(regions: [Target: CGRect]) {
        self.regions = regions
        move(to: location)
    }

    func move(to point: CGPoint?) {
        location = point
        guard let point, let surface = regions[.surface] else {
            isHovering = false
            target = nil
            return
        }
        // Keep the activation area stable while the small resting pill expands.
        let width = max(120, surface.width)
        let height = max(32, surface.height)
        let activation = CGRect(x: surface.midX - width / 2 - 6, y: surface.maxY - height - 8,
                                width: width + 12, height: height + 16)
        isHovering = activation.contains(point)
        let hit = [Target.microphone, .notetaker, .meetingNotes, .dictation].first { regions[$0]?.contains(point) == true }
        // Crossing the narrow gap between controls must not flash the tooltip off.
        target = hit ?? (isHovering && target.flatMap { regions[$0] } != nil ? target : nil)
    }
}

struct CapsuleRegions: PreferenceKey {
    static let defaultValue: [CapsuleHover.Target: CGRect] = [:]
    static func reduce(value: inout [CapsuleHover.Target: CGRect], nextValue: () -> [CapsuleHover.Target: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func capsuleRegion(_ target: CapsuleHover.Target) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: CapsuleRegions.self, value: [target: geometry.frame(in: .named("capsule"))])
            }
        }
    }
}

private final class CapsuleHostingView: NSHostingView<CapsuleView> {
    let hover: CapsuleHover

    init(model: AppModel, hover: CapsuleHover) {
        self.hover = hover
        super.init(rootView: CapsuleView(model: model, hover: hover))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @MainActor @preconcurrency required init(rootView: CapsuleView) { fatalError("init(rootView:) is unavailable") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); track(event) }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); track(event) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hover.move(to: nil) }

    private func track(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hover.move(to: CGPoint(x: point.x, y: isFlipped ? point.y : bounds.maxY - point.y))
    }
}

extension AppModel {
    var showsCapsule: Bool {
        if isBusy && settings.hideCapsuleWhileDictating && recordingSecondsLeft == nil { return false }
        return settings.showCapsule || phase != .idle || !meetings.runs.isEmpty || meetings.message != nil || meetingDetector.meeting != nil
    }
}

@MainActor
final class CapsuleController {
    private let panel: NSPanel
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        panel = RecordingPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = CapsuleHostingView(model: model, hover: CapsuleHover())
        NotificationCenter.default.addObserver(self, selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reposition),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        observeMeetings()
    }

    func update() {
        if model.showsCapsule { show() } else { panel.orderOut(nil) }
    }

    private func observeMeetings() {
        withObservationTracking {
            _ = model.meetings.runs
            _ = model.meetings.message
            _ = model.meetingDetector.meeting
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.update()
                self?.observeMeetings()
            }
        }
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
    }

    @objc private func reposition() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - 220, y: frame.minY + 12))
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        panel.close()
    }
}
