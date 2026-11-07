import AppKit
import BetterWisprCore
import OSLog

enum MediaApp: String, CaseIterable, Sendable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    var suite: String {
        switch self {
        case .music: "hook"
        case .spotify: "spfy"
        }
    }
}

enum PlayerState: Sendable {
    case playing, paused, stopped, unavailable
}

protocol MediaPlayers: Sendable {
    func state(of app: MediaApp) async -> PlayerState
    func pause(_ app: MediaApp) async
    func play(_ app: MediaApp) async
}

/// Silences apps that can't be paused, such as browsers, without changing whether they play.
protocol OtherAppsAudio: Sendable {
    func mute(onFailure: @escaping @MainActor @Sendable (any Error) -> Void) async
    func unmute() async
}

@available(macOS 14.2, *)
extension SystemAudioMute: OtherAppsAudio {}

@MainActor
final class MediaPauser {
    private let players: any MediaPlayers
    private let otherApps: (any OtherAppsAudio)?
    private let callInProgress: @MainActor () -> Bool
    private var paused: [MediaApp] = []
    private var muted = false
    private(set) var pending: Task<Void, Never>?
    var onMuteFailure: (@MainActor (any Error) -> Void)?

    init(players: any MediaPlayers = AppleEventMediaPlayers(), otherApps: (any OtherAppsAudio)? = MediaPauser.systemMute(),
         callInProgress: @escaping @MainActor () -> Bool = { MeetingPlatform.mayBeInCall(recording: MicrophoneActivity.recordingBundleIDs()) }) {
        self.players = players
        self.otherApps = otherApps
        self.callInProgress = callInProgress
    }

    static func systemMute() -> (any OtherAppsAudio)? {
        guard #available(macOS 14.2, *) else { return nil }
        return SystemAudioMute()
    }

    func pause() {
        let previous = pending
        pending = Task {
            await previous?.value
            for app in MediaApp.allCases where await players.state(of: app) == .playing {
                await players.pause(app)
                paused.append(app)
            }
        }
    }

    func resume() {
        guard let previous = pending else { return }
        pending = Task {
            await previous.value
            let apps = paused
            paused = []
            for app in apps where await players.state(of: app) == .paused {
                await players.play(app)
            }
        }
    }

    /// Mutes other apps unless a call may be running; a failure is reported and leaves them audible.
    func muteOtherApps() {
        guard otherApps != nil, !callInProgress() else { return }
        let previous = pending
        pending = Task {
            await previous?.value
            muted = true
            await otherApps?.mute { error in
                Logger(subsystem: "org.betterwispr.app", category: "MediaPauser").error("Couldn’t mute other apps: \(error.localizedDescription, privacy: .public)")
                self.muted = false
                self.onMuteFailure?(error)
            }
        }
    }

    func unmuteOtherApps() {
        guard let previous = pending else { return }
        pending = Task {
            await previous.value
            guard muted else { return }
            muted = false
            await otherApps?.unmute()
        }
    }
}

struct AppleEventMediaPlayers: MediaPlayers {
    @concurrent
    func state(of app: MediaApp) async -> PlayerState {
        guard let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: Self.code("obj ")) else { return .unavailable }
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: Self.code("prop")), forKeyword: Self.code("want"))
        specifier.setDescriptor(.null(), forKeyword: Self.code("from"))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: Self.code("prop")), forKeyword: Self.code("form"))
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: Self.code("pPlS")), forKeyword: Self.code("seld"))
        let reply = Self.send("core", "getd", to: app, directObject: specifier)
        switch reply?.paramDescriptor(forKeyword: Self.code("----"))?.enumCodeValue {
        case Self.code("kPSP"): return .playing
        case Self.code("kPSp"): return .paused
        case Self.code("kPSS"): return .stopped
        default: return .unavailable
        }
    }

    @concurrent
    func pause(_ app: MediaApp) async {
        Self.send(app.suite, "Paus", to: app)
    }

    @concurrent
    func play(_ app: MediaApp) async {
        Self.send(app.suite, "Play", to: app)
    }

    @concurrent
    static func requestPermission() async {
        for app in MediaApp.allCases {
            guard let target = AppleEventTarget.descriptor(for: app.rawValue) else { continue }
            AppleEventTarget.allowed(target, askingUser: true)
        }
    }

    @discardableResult
    private static func send(_ eventClass: String, _ eventID: String, to app: MediaApp,
                             directObject: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor? {
        guard let target = AppleEventTarget.descriptor(for: app.rawValue), AppleEventTarget.allowed(target, askingUser: false) else { return nil }
        let event = NSAppleEventDescriptor(eventClass: code(eventClass), eventID: code(eventID), targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let directObject { event.setParam(directObject, forKeyword: code("----")) }
        return try? event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 1)
    }

    private static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
