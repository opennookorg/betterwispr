import AppKit
import BetterWisprCore

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
    func mute() async
    func unmute() async
}

@available(macOS 14.2, *)
extension SystemAudioMute: OtherAppsAudio {}

@MainActor
final class MediaPauser {
    private let players: any MediaPlayers
    private let otherApps: (any OtherAppsAudio)?
    private var paused: [MediaApp] = []
    private var muted = false
    private(set) var pending: Task<Void, Never>?

    init(players: any MediaPlayers = AppleEventMediaPlayers(), otherApps: (any OtherAppsAudio)? = MediaPauser.systemMute()) {
        self.players = players
        self.otherApps = otherApps
    }

    static func systemMute() -> (any OtherAppsAudio)? {
        guard #available(macOS 14.2, *) else { return nil }
        return SystemAudioMute()
    }

    func pause(mutingOtherApps: Bool = true) {
        let previous = pending
        pending = Task {
            await previous?.value
            if mutingOtherApps, let otherApps {
                await otherApps.mute()
                muted = true
            }
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
            if muted {
                muted = false
                await otherApps?.unmute()
            }
            let apps = paused
            paused = []
            for app in apps where await players.state(of: app) == .paused {
                await players.play(app)
            }
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
