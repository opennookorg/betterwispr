import BetterWisprCore
import Darwin
import Foundation

/// Owns a temporary rule on one internal keyboard service. The journal survives a forced quit.
@MainActor
final class MicrophoneKeyRemap {
    struct Rule: Codable, Equatable, Sendable {
        let source: UInt64
        let destination: UInt64
    }

    nonisolated static let microphoneToF5 = Rule(source: 0xC000000CF, destination: 0x70000003E)

    private struct Journal: Codable {
        let boot: String
        let serviceID: UInt64
        let previous: [Rule]
        // Old journals predate this field and may already have applied their rule.
        var preparedOnly: Bool?
        var keyboardRestored: Bool?
        var applied: [Rule] { previous + [MicrophoneKeyRemap.microphoneToF5] }
    }

    private struct Keyboard {
        let id: UInt64
        let matching: String
    }

    private let directory: URL
    private let runCommand: @MainActor ([String]) throws -> String
    private let bootSession: @MainActor () throws -> String
    private let writeCommand: @MainActor ([String], Int32) throws -> Void
    private var lock: Int32 = -1
    private var journalURL: URL { directory.appendingPathComponent("microphone-key-remap.json") }

    init(directory: URL,
         runCommand: @escaping @MainActor ([String]) throws -> String = MicrophoneKeyRemap.hidutil,
         bootSession: @escaping @MainActor () throws -> String = MicrophoneKeyRemap.bootID,
         writeCommand: @escaping @MainActor ([String], Int32) throws -> Void = MicrophoneKeyRemap.writeWithLock) {
        self.directory = directory
        self.runCommand = runCommand
        self.bootSession = bootSession
        self.writeCommand = writeCommand
    }

    isolated deinit { unlock() }

    static func addingRule(to rules: [Rule]) throws -> [Rule] {
        let rule = microphoneToF5
        guard !rules.contains(where: {
            $0.source == rule.source || $0.source == rule.destination || $0.destination == rule.destination
        }) else { throw RemapError.conflict }
        return rules + [rule]
    }

    func enable() throws {
        try acquireLock()
        var journalCreated = false
        var started = false
        do {
            guard !FileManager.default.fileExists(atPath: journalURL.path) else { throw RemapError.conflict }
            let services = try keyboards()
            guard services.count == 1, let service = services.first else { throw RemapError.keyboard }
            let previous = try rules(on: service)
            let expected = try Self.addingRule(to: previous)
            var journal = Journal(boot: try bootSession(), serviceID: service.id, previous: previous, preparedOnly: true)
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            journalCreated = true
            guard try rules(on: service) == previous else { throw RemapError.conflict }
            journal.preparedOnly = false
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            started = true
            try write(expected, to: service)
            let current = try rules(on: service)
            guard current == expected else { throw RemapError.write }
        } catch {
            // Read back before restoring, including when the setter reported failure.
            if started {
                // restore() releases our lock only after the journal is cleared.
                _ = try? restore()
            } else {
                if journalCreated { try? FileManager.default.removeItem(at: journalURL) }
                unlock()
            }
            throw error
        }
    }

    var needsRecovery: Bool { FileManager.default.fileExists(atPath: journalURL.path) }

    @discardableResult
    func restore(beforeRemovingJournal: () throws -> Void = {}) throws -> Bool {
        guard needsRecovery else { unlock(); return false }
        let alreadyOwned = lock >= 0
        try acquireLock()
        var restored = false
        // An active owner must keep its lock if restoration fails. A recovery
        // attempt that borrowed the lock releases it so another attempt can retry.
        defer { if restored || !alreadyOwned { unlock() } }
        guard needsRecovery else { restored = true; return false }
        var journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        if journal.keyboardRestored != true, journal.preparedOnly != true, journal.boot == (try bootSession()) {
            // hidutil can omit services when access is unavailable, even with exit status zero.
            guard let service = try keyboards().first(where: { $0.id == journal.serviceID }) else {
                throw RemapError.write
            }
            let current = try rules(on: service)
            if current.contains(Self.microphoneToF5) {
                guard current == journal.applied else { throw RemapError.conflict }
                try write(journal.previous, to: service)
                guard try rules(on: service) == journal.previous else {
                    throw RemapError.write
                }
            }
        }
        if journal.keyboardRestored != true {
            // A retry after a save failure must leave subsequent keyboard mappings alone.
            journal.keyboardRestored = true
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        }
        try beforeRemovingJournal()
        try FileManager.default.removeItem(at: journalURL)
        restored = true
        return true
    }

    private static let keyboardMatch = #"{"PrimaryUsagePage":1,"PrimaryUsage":6}"#

    private func keyboards() throws -> [Keyboard] {
        let output = try runCommand(["list", "--matching", Self.keyboardMatch])
        let services = output.components(separatedBy: "Devices:")[0]
        guard services.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Services:") else {
            throw RemapError.write
        }
        return services.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 10, columns.last == "1", columns[4] == "6",
                  columns[2].hasPrefix("0x"), let location = UInt64(columns[2].dropFirst(2), radix: 16),
                  columns[5].hasPrefix("0x"), let id = UInt64(columns[5].dropFirst(2), radix: 16)
            else { return nil }
            return Keyboard(id: id, matching: "{\"LocationID\":\(location),\"PrimaryUsagePage\":1,\"PrimaryUsage\":6}")
        }
    }

    private func rules(on service: Keyboard) throws -> [Rule] {
        let output = try runCommand(["property", "--matching", service.matching, "--get", "UserKeyMapping"])
        let lines = output.split(separator: "\n", maxSplits: 1)
        guard lines.count == 2 else { throw RemapError.keyboard }
        let row = lines[1].split(maxSplits: 2, whereSeparator: \.isWhitespace)
        guard row.count == 3, UInt64(row[0], radix: 16) == service.id, row[1] == "UserKeyMapping" else {
            throw RemapError.keyboard
        }
        let value = row[2].trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "(null)" { return [] }
        guard let entries = try PropertyListSerialization.propertyList(from: Data(value.utf8), format: nil) as? [[String: String]] else {
            throw RemapError.conflict
        }
        return try entries.map {
            guard $0.count == 2, let source = $0["HIDKeyboardModifierMappingSrc"].flatMap(UInt64.init),
                  let destination = $0["HIDKeyboardModifierMappingDst"].flatMap(UInt64.init) else {
                throw RemapError.conflict
            }
            return Rule(source: source, destination: destination)
        }
    }

    private func write(_ rules: [Rule], to service: Keyboard) throws {
        let entries = rules.map {
            ["HIDKeyboardModifierMappingSrc": $0.source, "HIDKeyboardModifierMappingDst": $0.destination]
        }
        let data = try JSONEncoder().encode(["UserKeyMapping": entries])
        try writeCommand(["property", "--matching", service.matching, "--set", String(decoding: data, as: UTF8.self)], lock)
    }

    private static func writeWithLock(_ arguments: [String], lock: Int32) throws {
        try runLockedWriter("/usr/bin/hidutil", arguments: arguments, lock: lock)
    }

    /// The writer inherits a duplicate of the locked file description as its unused stdin.
    /// If the app is killed, recovery still cannot acquire the lock until the writer exits.
    static func runLockedWriter(_ executable: String, arguments: [String], lock: Int32) throws {
        guard lock > STDERR_FILENO else { throw RemapError.write }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw RemapError.write }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, lock, STDIN_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else {
            throw RemapError.write
        }
        var argv = ([executable] + arguments).map { strdup($0) }
        defer { for arg in argv { free(arg) } }
        guard argv.allSatisfy({ $0 != nil }) else { throw RemapError.write }
        argv.append(nil)
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, &actions, nil, &argv, environ) == 0 else {
            throw RemapError.write
        }
        let deadline = ContinuousClock.now + .seconds(2)
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                guard status == 0 else { throw RemapError.write }
                return
            }
            if result < 0, errno != EINTR { throw RemapError.write }
            if ContinuousClock.now >= deadline {
                // This PID belongs to our still-unreaped child.
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                throw RemapError.write
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func hidutil(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2), execute: deadline)
        defer { deadline.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RemapError.write }
        return String(decoding: data, as: UTF8.self)
    }

    private static func bootID() throws -> String {
        var bytes = [CChar](repeating: 0, count: 64)
        var count = bytes.count
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0,
              let end = bytes.firstIndex(of: 0), end > 0 else { throw RemapError.keyboard }
        return String(decoding: bytes[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func acquireLock() throws {
        guard lock == -1 else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("microphone-key-remap.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RemapError.write }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw RemapError.inUse }
        lock = fd
    }

    private func unlock() {
        guard lock >= 0 else { return }
        close(lock)
        lock = -1
    }

    enum RemapError: LocalizedError {
        case keyboard, conflict, write, inUse

        var errorDescription: String? {
            switch self {
            case .keyboard: L10n.tr("BetterWispr couldn’t identify a single supported internal keyboard.")
            case .conflict: L10n.tr("Another keyboard mapping is active. BetterWispr left the keyboard settings alone.")
            case .write: L10n.tr("macOS couldn’t verify the microphone key change. Check Input Monitoring in System Settings.")
            case .inUse: L10n.tr("Another BetterWispr process is using the microphone key.")
            }
        }
    }
}
