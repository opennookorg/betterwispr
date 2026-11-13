import CryptoKit
import Darwin
import Foundation

public enum YTDLPError: LocalizedError, Equatable {
    case invalidLink
    case notInstalled
    case releaseUnavailable(Int)
    case unverified
    case download(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLink: L10n.tr("Paste a full web link that starts with https://.")
        case .notInstalled: L10n.tr("Install yt-dlp to transcribe links.")
        case .releaseUnavailable(let status): L10n.tr("GitHub didn’t return yt-dlp (HTTP %@). Try again later.", String(status))
        case .unverified: L10n.tr("The downloaded yt-dlp didn’t match its published checksum, so it wasn’t installed.")
        case .download(let reason): L10n.tr("Couldn’t download this link. %@", String(reason))
        }
    }
}

/// A web link checked before it reaches yt-dlp.
public struct MediaLink: Equatable, Sendable {
    public let url: URL

    public init(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text), ["http", "https"].contains(components.scheme?.lowercased()),
              components.host?.isEmpty == false, let url = components.url else {
            throw YTDLPError.invalidLink
        }
        self.url = url
    }
}

/// Finds, installs and runs yt-dlp to fetch the audio of a web video into a private temporary folder.
public enum YTDLP {
    static let release = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/")!
    static let asset = "yt-dlp_macos"
    static let progressMark = "betterwispr-progress"

    /// BetterWispr's own copy, installed only by an explicit action.
    public static var installed: URL { URL.applicationSupportDirectory.appending(path: "BetterWispr/Tools/yt-dlp") }

    public static var executable: URL? {
        FileManager.default.isExecutableFile(atPath: installed.path) ? installed : find("yt-dlp")
    }

    /// The yt-dlp process downloading right now, so quitting the app can stop it.
    @MainActor public private(set) static var running: Process?

    /// Deno or Node, which yt-dlp needs to read YouTube fully.
    public static var javaScriptRuntime: URL? { find("deno") ?? find("node") }

    static func find(_ command: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/opt/local/bin"]
            .map { URL(fileURLWithPath: $0).appending(path: command) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Downloads the latest release, verifies it against the release's SHA2-256SUMS and replaces BetterWispr's copy.
    public static func install() async throws {
        async let binary = URLSession.shared.data(from: release.appending(path: asset))
        async let sums = URLSession.shared.data(from: release.appending(path: "SHA2-256SUMS"))
        let (data, dataResponse) = try await binary
        let (checksums, sumsResponse) = try await sums
        for response in [dataResponse, sumsResponse] {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw YTDLPError.releaseUnavailable(status) }
        }
        try verify(data, sums: String(decoding: checksums, as: UTF8.self))
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = installed.appendingPathExtension("download")
        defer { try? FileManager.default.removeItem(at: partial) }
        try data.write(to: partial)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: partial.path)
        guard rename(partial.path, installed.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func verify(_ data: Data, sums: String) throws {
        let expected = sums.split(whereSeparator: \.isNewline).lazy
            .map { $0.split(whereSeparator: \.isWhitespace) }
            .first { $0.count == 2 && $0[1].trimmingPrefix("*") == asset }?[0].lowercased()
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw YTDLPError.unverified }
    }

    static func arguments(for link: MediaLink, into directory: URL, runtime: URL?) -> [String] {
        ["--no-config", "--no-playlist", "--playlist-items", "1", "--newline",
         "--progress-template", "download:\(progressMark) %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s",
         "-f", "bestaudio[ext=m4a]/bestaudio[ext=mp4]/best[ext=mp4]",
         "-o", directory.appending(path: "media.%(ext)s").path,
         "--print-to-file", "title", directory.appending(path: "title").path]
            + (runtime.map { ["--js-runtimes", "\($0.lastPathComponent):\($0.path)"] } ?? [])
            + ["--", link.url.absoluteString]
    }

    /// The fraction of the last progress line, nil while yt-dlp doesn't know the size.
    static func progress(in output: String) -> Double? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(progressMark) }) else { return nil }
        let fields = line.split(separator: " ").dropFirst().map { Double($0) }
        guard fields.count == 3, let done = fields[0], let total = fields[1] ?? fields[2], total > 0 else { return nil }
        return min(1, done / total)
    }

    static func failure(_ errors: String, status: Int32, runtime: URL?) -> YTDLPError {
        let lines = errors.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let reason = lines.last { $0.hasPrefix("ERROR:") }.map { $0.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces) }
            ?? (status == 0 ? L10n.tr("yt-dlp found no audio at this link.") : lines.last ?? L10n.tr("yt-dlp stopped with status %@.", String(status)))
        let hint = runtime == nil ? L10n.tr(" If YouTube links fail, install Deno with brew install deno so yt-dlp can read YouTube fully.") : ""
        return .download(reason + hint)
    }

    /// Downloads the link's audio, hands it to `use` with the video title, and deletes the folder afterwards, also on error and cancel.
    @MainActor
    public static func download<T>(_ link: MediaLink, using executable: URL? = YTDLP.executable, progress: (Double?) -> Void = { _ in },
                                   then use: (_ audio: URL, _ title: String) async throws -> T) async throws -> T {
        guard let executable else { throw YTDLPError.notInstalled }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appending(path: "betterwispr-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appending(path: "output")
        let errorsURL = directory.appending(path: "errors")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errorsURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdout = try FileHandle(forWritingTo: outputURL)
        let stderr = try FileHandle(forWritingTo: errorsURL)
        defer { try? stdout.close(); try? stderr.close() }
        let runtime = javaScriptRuntime
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(for: link, into: directory, runtime: runtime)
        process.currentDirectoryURL = directory
        let allowed = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"]
        var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        environment["PATH"] = "\(executable.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        running = process
        defer { running = nil }
        do {
            while process.isRunning {
                try Task.checkCancellation()
                progress(Self.progress(in: String(decoding: (try? Data(contentsOf: outputURL)) ?? Data(), as: UTF8.self)))
                try await Task.sleep(for: .milliseconds(200))
            }
            try Task.checkCancellation()
        } catch {
            await CLINotesModel.stop(process)
            throw error
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard process.terminationStatus == 0, let audio = files.first(where: { $0.deletingPathExtension().lastPathComponent == "media" }) else {
            throw failure(String(decoding: (try? Data(contentsOf: errorsURL)) ?? Data(), as: UTF8.self), status: process.terminationStatus, runtime: runtime)
        }
        let title = (try? String(contentsOf: directory.appending(path: "title"), encoding: .utf8))?
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? link.url.absoluteString
        return try await use(audio, title)
    }
}
