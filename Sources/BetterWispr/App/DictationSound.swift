import AppKit
import BetterWisprCore
import Foundation

extension DictationSound {
    static let overrideDirectory = URL.applicationSupportDirectory
        .appendingPathComponent("BetterWispr/SoundOverrides", isDirectory: true)
    static let systemSoundNames = ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
        .map { ($0 as NSString).deletingPathExtension }
        .sorted()

    var title: String {
        switch self {
        case .started: L10n.tr("Start")
        case .finished: L10n.tr("Finish", table: "Sounds")
        case .cancelled: L10n.tr("Cancel")
        case .attention: L10n.tr("Needs attention")
        }
    }

    func sound(named name: String) -> NSSound? { sound(named: name, in: Self.overrideDirectory) }

    func sound(named name: String, in directory: URL) -> NSSound? {
        if let override = url(in: directory) { return NSSound(contentsOf: override, byReference: false) }
        return NSSound(named: name) ?? NSSound(named: defaultSoundName)
    }

    func url(in directory: URL) -> URL? {
        let file = directory.appendingPathComponent(rawValue).appendingPathExtension("wav")
        return FileManager.default.isReadableFile(atPath: file.path) ? file : nil
    }
}
