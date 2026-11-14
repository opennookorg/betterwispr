import Darwin
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
    private let setWorkspacePermissions: @Sendable (URL) throws -> Void
    public var stateURL: URL { directory.appendingPathComponent("workspace.json") }

    public init(directory: URL? = nil) {
        self.init(directory: directory ?? URL.applicationSupportDirectory.appendingPathComponent("BetterWispr", isDirectory: true)) { url in
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    init(directory: URL, setWorkspacePermissions: @escaping @Sendable (URL) throws -> Void) {
        self.directory = directory
        self.setWorkspacePermissions = setWorkspacePermissions
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
        let staging = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent(stateURL.lastPathComponent)
        try encoder.encode(state).write(to: temporary)
        try setWorkspacePermissions(temporary)
        // The replacement is the last fallible operation affecting the workspace.
        guard rename(temporary.path, stateURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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
