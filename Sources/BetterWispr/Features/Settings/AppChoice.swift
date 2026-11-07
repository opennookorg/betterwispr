import AppKit
import SwiftUI

/// An installed app the user can pick in settings, named and iconed from its bundle so a renamed app never shows a stale label.
struct AppChoice: Identifiable {
    let id: String
    let name: String
    let icon: NSImage

    init?(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        id = bundleID
        name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
    }

    var label: some View {
        Label { Text(name) } icon: { Image(nsImage: icon) }
    }

    /// Apps that are open or that the user dictated into recently, without BetterWispr itself.
    static func offered(recent: [String]) -> [AppChoice] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier)
        let ids = Set(running + recent).subtracting([Bundle.main.bundleIdentifier].compactMap { $0 })
        return ids.compactMap(AppChoice.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
