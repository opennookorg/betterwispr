import BetterWisprCore
import Foundation
import Observation

/// Offers the notetaker once per call when a known call app or web meeting starts recording from the microphone.
@MainActor @Observable
final class MeetingDetector {
    static let browserPollSeconds = 3.0

    private(set) var meeting: DetectedMeeting?
    /// When the shown prompt closes by itself, or nil while it waits for an answer.
    private(set) var deadline: Date?
    @ObservationIgnored var timeout: TimeInterval? = MeetingPromptTimeout.thirtySeconds.seconds {
        didSet { if timeout != oldValue { scheduleExpiry() } }
    }
    @ObservationIgnored var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                observer = MicrophoneActivityObserver { [weak self] in self?.refresh() }
                refresh()
            } else {
                observer?.cancel()
                observer = nil
                polling?.cancel()
                update([], recording: [])
            }
        }
    }
    @ObservationIgnored private let meetings: MeetingModel
    @ObservationIgnored private var answered: Set<String> = []
    @ObservationIgnored private var observer: MicrophoneActivityObserver?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    init(meetings: MeetingModel) {
        self.meetings = meetings
    }

    /// Hides the prompt until that app stops recording.
    func dismiss() {
        guard let meeting else { return }
        answered.insert(meeting.appID)
        expiry?.cancel()
        deadline = nil
        self.meeting = nil
    }

    /// Browser calls are recognized by window title, so a browser that records without one is checked again while the user switches tabs.
    func refresh() {
        polling?.cancel()
        guard isEnabled else { return }
        let recording = Set(MicrophoneActivity.recordingBundleIDs().compactMap(MeetingPlatform.app(recording:)))
        update(MeetingPlatform.meetings(in: recording.subtracting(answered), windowTitles: MeetingPlatform.windowTitles(of:)),
               recording: recording)
        guard recording.contains(where: { MeetingPlatform.isBrowser($0) && !answered.contains($0) && meeting?.appID != $0 }) else { return }
        polling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.browserPollSeconds))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Forgets calls that ended, treats calls running alongside the notetaker as answered, and offers the first new one.
    func update(_ calls: [DetectedMeeting], recording: Set<String>) {
        answered.formIntersection(recording)
        if meetings.capturingID != nil { answered.formUnion(calls.map(\.appID)) }
        let next = calls.first { !answered.contains($0.appID) }
        guard next != meeting else { return }
        meeting = next
        scheduleExpiry()
    }

    /// Restarts the countdown for the shown prompt; expiry answers it the way Not now does.
    private func scheduleExpiry() {
        expiry?.cancel()
        deadline = nil
        guard let shown = meeting, let timeout else { return }
        deadline = .now.addingTimeInterval(timeout)
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, self?.meeting == shown else { return }
            self?.dismiss()
        }
    }
}
