import AppKit
import BetterWisprCore
import Observation
import SwiftUI

private final class RecordingPanel: NSPanel {
    var acceptsLanguageNavigation = false
    override var canBecomeKey: Bool { acceptsLanguageNavigation }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
final class CapsuleHover {
    enum Target: Hashable { case surface, microphone, notetaker, meetingNotes, dictation, translationLanguages }

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
            set(isHovering: false, target: nil)
            return
        }
        // Keep the activation area stable while the small resting pill expands.
        let width = max(120, surface.width)
        let height = max(32, surface.height)
        let activation = CGRect(x: surface.midX - width / 2 - 6, y: surface.maxY - height - 8,
                                width: width + 12, height: height + 16)
        let inside = activation.contains(point) || regions[.translationLanguages]?.contains(point) == true
        let hit = [Target.microphone, .notetaker, .meetingNotes, .dictation].first { regions[$0]?.contains(point) == true }
        // Crossing the narrow gap between controls must not flash the tooltip off.
        set(isHovering: inside, target: hit ?? (inside && target.flatMap { regions[$0] } != nil ? target : nil))
    }

    /// Writes only changes, since every pointer move on screen lands here.
    private func set(isHovering: Bool, target: Target?) {
        if self.isHovering != isHovering { self.isHovering = isHovering }
        if self.target != target { self.target = target }
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
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); trackPointer() }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); trackPointer() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); trackPointer() }

    func trackPointer() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        hover.move(to: CGPoint(x: point.x, y: isFlipped ? point.y : bounds.maxY - point.y))
    }
}

extension AppModel {
    /// The call the capsule offers the notetaker for; a dictation or a running notetaker hides the offer.
    var meetingPrompt: DetectedMeeting? {
        isBusy || meetings.capturingID != nil ? nil : meetingDetector.meeting
    }

    var showsCapsuleAtTop: Bool { meetingPrompt != nil && settings.meetingPromptPosition == .top }

    var showsCapsule: Bool {
        if isBusy && settings.hideCapsuleWhileDictating { return false }
        return settings.showCapsule || phase != .idle || !meetings.runs.isEmpty || meetings.message != nil || meetingDetector.meeting != nil
    }
}

@MainActor
final class CapsuleController: NSObject, NSWindowDelegate {
    private let panel: RecordingPanel
    private let model: AppModel
    private let hover = CapsuleHover()
    private let content: CapsuleHostingView
    private weak var previousKeyWindow: NSWindow?
    private var waitingToShowAfterKeyboardRelease = false
    private var pointerMonitors: [Any] = []

    init(model: AppModel) {
        self.model = model
        content = CapsuleHostingView(model: model, hover: hover)
        panel = RecordingPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        NotificationCenter.default.addObserver(self, selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reposition),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        observeMeetings()
        observeHover()
        pointerMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                MainActor.assumeIsolated { self?.content.trackPointer() }
            },
            NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                MainActor.assumeIsolated { self?.content.trackPointer() }
                return event
            }
        ].compactMap { $0 }
    }

    func update() {
        guard !waitingToShowAfterKeyboardRelease else { return }
        let needsKeyboard = model.showsCapsule && model.phase == .recording && model.showsTranslationLanguages
        if needsKeyboard, !panel.acceptsLanguageNavigation {
            previousKeyWindow = NSApp.isActive ? NSApp.keyWindow : nil
            panel.acceptsLanguageNavigation = true
            panel.makeKey()
        } else if !needsKeyboard, panel.acceptsLanguageNavigation {
            releaseLanguageKeyboard()
            return
        }
        if model.showsCapsule { show() } else { panel.orderOut(nil) }
    }

    private func releaseLanguageKeyboard() {
        waitingToShowAfterKeyboardRelease = true
        let restoreKeyWindow = panel.isKeyWindow && NSApp.isActive
        // Let AppKit order out the still-key panel before changing its eligibility.
        panel.orderOut(nil)
        panel.acceptsLanguageNavigation = false
        if restoreKeyWindow, previousKeyWindow?.isVisible == true { previousKeyWindow?.makeKey() }
        previousKeyWindow = nil
        // Leave the panel out of the window list until AppKit has handed back keyboard focus.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.waitingToShowAfterKeyboardRelease else { return }
            self.waitingToShowAfterKeyboardRelease = false
            self.update()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !waitingToShowAfterKeyboardRelease, panel.acceptsLanguageNavigation else { return }
        model.showsTranslationLanguages = false
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

    /// Lets clicks outside the capsule's hover area reach the apps below the transparent panel.
    private func observeHover() {
        panel.ignoresMouseEvents = !hover.isHovering
        withObservationTracking {
            _ = hover.isHovering
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeHover() }
        }
    }

    func show() {
        reposition()
        content.trackPointer()
        panel.orderFrontRegardless()
    }

    @objc private func reposition() {
        let screens = NSScreen.screens
        let pointer = NSEvent.mouseLocation
        let meetingScreen = model.meetingPrompt.flatMap { meeting in
            Self.screenIndex(showing: MeetingPlatform.windowBounds(of: meeting.appID), in: screens.map(\.frame)).map { screens[$0] }
        }
        guard let screen = meetingScreen ?? screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        panel.setFrameOrigin(Self.origin(atTop: model.showsCapsuleAtTop, size: panel.frame.size, frame: screen.frame,
                                         visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top))
    }

    /// The panel origin centered at the bottom of the visible frame, or just below the menu bar and camera housing.
    static func origin(atTop: Bool, size: CGSize, frame: CGRect, visibleFrame: CGRect, safeTop: CGFloat) -> CGPoint {
        guard atTop else { return CGPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.minY + 12) }
        return CGPoint(x: frame.midX - size.width / 2, y: min(visibleFrame.maxY, frame.maxY - safeTop) - size.height - 4)
    }

    /// The screen, by index into `screens` (the first is the primary display), holding most of the frontmost sizable window in Quartz `windows`.
    static func screenIndex(showing windows: [CGRect], in screens: [CGRect]) -> Int? {
        guard let primary = screens.first,
              let window = windows.first(where: { $0.width >= 200 && $0.height >= 150 }) else { return nil }
        let flipped = CGRect(x: window.minX, y: primary.maxY - window.maxY, width: window.width, height: window.height)
        let overlaps = screens.map { $0.intersection(flipped) }.map { $0.isNull ? 0 : $0.width * $0.height }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 else { return nil }
        return best
    }

    func close() {
        waitingToShowAfterKeyboardRelease = false
        panel.delegate = nil
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors = []
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        panel.close()
    }
}
