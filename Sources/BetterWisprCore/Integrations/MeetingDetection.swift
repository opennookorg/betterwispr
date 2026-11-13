import AppKit
import ApplicationServices

/// A call app or web meeting service BetterWispr recognizes while it records from the microphone.
public enum MeetingPlatform: String, CaseIterable, Sendable {
    case zoom, googleMeet, teams, slack, webex, faceTime, discord, whatsApp, signal, telegram, whereby, jitsi

    public var name: String {
        switch self {
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .slack: "Slack huddle"
        case .webex: "Webex"
        case .faceTime: "FaceTime"
        case .discord: "Discord"
        case .whatsApp: "WhatsApp"
        case .signal: "Signal"
        case .telegram: "Telegram"
        case .whereby: "Whereby"
        case .jitsi: "Jitsi Meet"
        }
    }

    private static let apps: [String: MeetingPlatform] = [
        "us.zoom.xos": .zoom,
        "com.microsoft.teams2": .teams, "com.microsoft.teams": .teams,
        "com.tinyspeck.slackmacgap": .slack,
        "Cisco-Systems.Spark": .webex, "com.webex.meetingmanager": .webex,
        "com.apple.FaceTime": .faceTime, "com.apple.avconferenced": .faceTime,
        "com.hnc.Discord": .discord,
        "net.whatsapp.WhatsApp": .whatsApp, "desktop.WhatsApp": .whatsApp,
        "org.whispersystems.signal-desktop": .signal,
        "ru.keepcoder.Telegram": .telegram, "org.telegram.desktop": .telegram,
    ]

    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "org.mozilla.firefox", "com.apple.Safari", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    private static let pages: [(fragment: String, platform: MeetingPlatform)] = [
        ("Google Meet", .googleMeet), ("Microsoft Teams", .teams), ("Zoom", .zoom), ("Huddle", .slack),
        ("Slack", .slack), ("Webex", .webex), ("Whereby", .whereby), ("Jitsi Meet", .jitsi), ("Discord", .discord),
    ]

    public static func isBrowser(_ appID: String) -> Bool { browsers.contains(appID) }

    /// The known app or browser a recording process belongs to; helpers map to their app and Safari records through WebKit's GPU process.
    public static func app(recording bundleID: String) -> String? {
        if bundleID == "com.apple.WebKit.GPU" { return "com.apple.Safari" }
        return (Array(apps.keys) + browsers)
            .filter { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
            .max { $0.count < $1.count }
    }

    /// Whether a process using the microphone is a known call app or a browser; browsers count without a title check, because titles need Accessibility and a wrong guess would silence a call.
    public static func mayBeInCall(recording bundleIDs: [String]) -> Bool {
        bundleIDs.contains { app(recording: $0) != nil }
    }

    /// The meeting service a browser window shows, judged from a title such as "Meet - Daily Scrum - Google Chrome".
    static func page(titled title: String) -> MeetingPlatform? {
        if title.hasPrefix("Meet - ") || title.hasPrefix("Meet – ") { return .googleMeet }
        return pages.first { title.contains($0.fragment) }?.platform
    }

    /// Calls among the recording apps; a browser counts only when one of its windows shows a meeting service.
    public static func meetings(in appIDs: Set<String>, windowTitles: (String) -> [String]) -> [DetectedMeeting] {
        appIDs.sorted().compactMap { appID in
            let platform = apps[appID] ?? (isBrowser(appID) ? windowTitles(appID).lazy.compactMap(page(titled:)).first : nil)
            return platform.map { DetectedMeeting(platform: $0, appID: appID) }
        }
    }

    /// Titles of an app's windows through Accessibility, with a short timeout so a busy browser can't stall the caller.
    public static func windowTitles(of appID: String) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: appID).flatMap { app -> [String] in
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            var windows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
                  let windows = windows as? [AXUIElement] else { return [] }
            return windows.compactMap { window in
                AXUIElementSetMessagingTimeout(window, 0.25)
                var title: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else { return nil }
                return title as? String
            }
        }
    }
}

/// A call recording from the microphone, keyed by the app running it so an answered prompt stays answered for that call.
public struct DetectedMeeting: Equatable, Sendable {
    public let platform: MeetingPlatform
    public let appID: String

    public init(platform: MeetingPlatform, appID: String) {
        self.platform = platform
        self.appID = appID
    }
}
