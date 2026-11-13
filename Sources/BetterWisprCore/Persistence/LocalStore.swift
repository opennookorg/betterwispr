import Foundation

public struct SavedState: Codable, Equatable, Sendable {
    public var version = 1
    public var settings = AppSettings()
    public var history: [Transcript] = []
    public var vocabulary: [VocabularyEntry] = []
    public init() {}
}

public struct LocalStore: Sendable {
    public let directory: URL
    public var stateURL: URL { directory.appendingPathComponent("workspace.json") }

    public init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("BetterWispr", isDirectory: true)
    }

    public func load() throws -> SavedState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return SavedState() }
        let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateURL))
        guard state.version == 1 else { throw StoreError.unsupportedVersion(state.version) }
        return state
    }

    public func save(_ state: SavedState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
}

public enum StoreError: LocalizedError {
    case unsupportedVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): L10n.tr("This workspace uses version %@. Update BetterWispr before opening it.", String(version))
        }
    }
}
