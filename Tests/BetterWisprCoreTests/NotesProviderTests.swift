import AVFoundation
import Foundation
import Testing
@testable import BetterWisprCore
@testable import BetterWispr

@MainActor
@Test func meetingCoordinatorCancelsBeforeLaunchAndKeepsThePreviousSummaryOnFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let meeting = Meeting(title: "My title", notes: "Updated personal thought", summary: MeetingSummary(overview: "Previous summary"), modelName: "Parakeet", language: "en")
    try store.save(meeting)
    let model = MeetingModel(store: store)
    model.notesSettings.notesSelection = .connection(UUID())
    model.generateNotes(meeting.id)
    #expect(model.runs[meeting.id]?.phase == .generating)
    model.cancelNotes(meeting.id)
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.runs.isEmpty)
    #expect(model.meeting(meeting.id) == meeting)
    model.generateNotes(meeting.id)
    for _ in 0..<100 {
        if model.runs.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.runs.isEmpty)
    #expect(model.message?.contains("selected notes connection is missing") == true)
    #expect(store.load().meetings == [meeting])
}

@MainActor
@Test func meetingNotesRunPerMeetingSoCancellingOneLeavesTheOtherRunning() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let earlier = Meeting(title: "Earlier", notes: "A thought", modelName: "Parakeet", language: "en")
    let later = Meeting(title: "Later", notes: "Another thought", modelName: "Parakeet", language: "en")
    try store.save(earlier)
    try store.save(later)
    let model = MeetingModel(store: store)
    model.notesSettings.notesSelection = .connection(UUID())
    model.generateNotes(earlier.id)
    model.generateNotes(later.id)
    #expect(model.runs[earlier.id]?.phase == .generating)
    #expect(model.runs[later.id]?.phase == .generating)
    model.generateNotes(later.id)
    #expect(model.runs.count == 2)
    model.cancelNotes(earlier.id)
    #expect(model.runs[earlier.id] == nil)
    #expect(model.runs[later.id]?.phase == .generating)
    for _ in 0..<100 {
        if model.runs.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.runs.isEmpty)
    #expect(model.message?.contains("selected notes connection is missing") == true)
}

@Test func notesChoicesMigrateWithoutChangingSpeechOrLeakingKeys() throws {
    let legacy = #"{"autoPaste":true,"language":"auto","launchAtLogin":false,"saveHistory":true,"selectedModelID":"apple","showCapsule":true,"silenceThreshold":0.002,"notesModel":"llama3.1:8b"}"#
    var settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
    #expect(settings.notesSelection == .ollama("llama3.1:8b"))
    #expect(settings.notesConnections.isEmpty)
    let connection = SpeechConnection(api: .openAICompatible)
    settings.notesConnections = [connection]
    for selection in [NotesModelSelection.connection(connection.id), .cli(.claudeCode), .cli(.codex), .apple] {
        settings.notesSelection = selection
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
        #expect(settings.selectedModelID == "apple")
        #expect(settings.speechConnections.isEmpty)
        #expect(!String(decoding: data, as: UTF8.self).contains("apiKey"))
    }
    settings.notesSelection = .connection(UUID())
    #expect(MeetingNotesGenerator.availability(settings: settings) != .available)
    #expect(throws: MeetingNotesError.self) { try NotesDraft.decode("{}") }
    #expect(try NotesDraft.decode("```json\n\(NotesEndpointStub.draft)\n```").title == "Friday launch")
}

@MainActor
@Test func meetingAudioThroughSpeechAndNotesAPIsPersistsAndExports() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [NotesEndpointStub.self]
    var speech = SpeechConnection(api: .openAICompatible)
    speech.endpoint = "https://notes.example/\(UUID())/speech"
    let provider = APISpeechProvider(configuration: config, key: { _ in "speech-test-key" })
    try await provider.prepare(model: speech.speechModel, download: false)

    // Real capture chunk writer, CAF conversion and selected speech provider; only HTTP is stubbed.
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
    buffer.frameLength = 48_000
    let samples = try #require(buffer.floatChannelData)[0]
    for i in 0..<48_000 { samples[i] = 0.1 * sin(Float(i) * 0.03) }
    var meeting = Meeting(title: "My title", notes: "Keep the budget fixed.", modelName: speech.name, language: "en")
    for speaker in [Speaker.me, .them] {
        let writer = try MeetingChunkWriter(speaker: speaker, format: format, threshold: 0.002, policy: ChunkPolicy(), startOffset: speaker == .me ? 0 : 1)
        _ = writer.write(buffer)
        writer.finish()
        let chunk = try #require(writer.takeReady().chunks.first)
        defer { try? FileManager.default.removeItem(at: chunk.url) }
        #expect(chunk.hasSpeech)
        let raw = try await provider.transcribe(audioURL: chunk.url, language: "en", vocabulary: [])
        let text = TranscriptCleaner.clean(raw, language: "en")
        meeting.insert(MeetingSegment(speaker: speaker, start: chunk.start, duration: chunk.duration, text: text, rawText: raw))
    }
    let notesConnection = notesConnection()
    let keys = SpeechAPIKeyStore(service: "org.betterwispr.tests.notes.\(UUID())")
    defer { try? keys.save("", for: notesConnection) }
    try keys.save("notes-test-key", for: notesConnection)
    let llm = APINotesModel(connection: notesConnection, keys: keys, configuration: config)
    let generated = try await NotesWriter.write(parts: TranscriptChunker.chunks(meeting.segments, budget: 6000),
                                               notes: meeting.notes, model: llm) { _, _ in }
    meeting.summary = generated.summary
    meeting.summary?.actionItems[0].isDone = true
    try store.save(meeting)
    let loaded = try #require(store.load().meetings.first)
    #expect(loaded == meeting)
    #expect(loaded.title == "My title")
    #expect(loaded.segments.count == 2)
    #expect(loaded.segments.allSatisfy { $0.rawText == "We agreed to launch Friday." })
    #expect(loaded.markdown.contains("- [x] Alex: send the checklist"))
    let requests = await NotesEndpointStub.probe.requests
    let request = try #require(requests.first { $0.url == notesConnection.endpoint })
    #expect(request.authorization == "Bearer notes-test-key")
    #expect(request.body.contains("Me: We agreed to launch Friday."))
    #expect(request.body.contains("Them: We agreed to launch Friday."))
    #expect(request.body.contains("Keep the budget fixed."))
    #expect(request.body.contains(notesConnection.modelID))
    #expect(!request.body.contains("notes-test-key"))
}

@Test(arguments: ["unauthorized", "quota", "redirect", "malformed", "truncated", "empty"])
func notesAPIFailuresNeverProduceASummary(path: String) async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [NotesEndpointStub.self]
    let model = APINotesModel(connection: notesConnection(path), configuration: config)
    do {
        _ = try await model.draft("Synthetic private source")
        Issue.record("Failed requests must not produce a summary")
    } catch {
        #expect(!error.localizedDescription.contains("private-provider-error"))
    }
}

@Test func notesAPICancellationStopsTheRequest() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [NotesEndpointStub.self]
    let connection = notesConnection("wait")
    let model = APINotesModel(connection: connection, configuration: config)
    let task = Task { try await model.draft("Synthetic source") }
    for _ in 0..<200 {
        if await NotesEndpointStub.probe.requests.contains(where: { $0.url == connection.endpoint }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled request completed") }
    catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    for _ in 0..<100 {
        if await NotesEndpointStub.probe.stopped.contains(connection.endpoint) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await NotesEndpointStub.probe.stopped.contains(connection.endpoint))
}

@MainActor
@Test func notesCLIRunnerHandlesLargeOutputTimeoutAndCancellation() async throws {
    let executable = URL(fileURLWithPath: "/usr/bin/python3")
    let output = try await CLINotesModel.run(executable, arguments: ["-c", "print('x' * 100000)"], input: "", cli: .codex)
    #expect(output.count == 100_000)
    let reply = try await CLINotesModel.run(executable,
        arguments: ["-u", "-c", "import sys,time; print(sys.stdin.readline().strip()); time.sleep(60)"],
        input: "catalog reply\n", cli: .codex, timeout: .seconds(3), until: { $0.contains("catalog reply") })
    #expect(reply.trimmingCharacters(in: .whitespacesAndNewlines) == "catalog reply")
    await #expect(throws: MeetingNotesError.self) {
        try await CLINotesModel.run(executable, arguments: ["-c", "import time; time.sleep(60)"], input: "", cli: .codex, timeout: .milliseconds(100))
    }
    let task = Task { try await CLINotesModel.run(executable, arguments: ["-c", "import time; time.sleep(60)"], input: "", cli: .codex) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func notesCLILookupSearchesNixFoldersAndTheLoginShellPATH() {
    let directories = NotesCLI.searchDirectories(home: "/Users/me", user: "me", processPATH: "/usr/bin:/bin:relative:",
                                                 loginShellPATH: "/Users/me/.volta/bin:/Users/me/.npm-global/bin")
    #expect(directories == ["/Users/me/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/Users/me/.nix-profile/bin",
                            "/etc/profiles/per-user/me/bin", "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin",
                            "/usr/bin", "/bin", "/Users/me/.volta/bin", "/Users/me/.npm-global/bin"])
    let nixOnly = NotesCLI.locate("claude", in: directories) { $0 == "/run/current-system/sw/bin/claude" }
    #expect(nixOnly?.path == "/run/current-system/sw/bin/claude")
    let shellOnly = NotesCLI.locate("codex", in: directories) { $0 == "/Users/me/.npm-global/bin/codex" }
    #expect(shellOnly?.path == "/Users/me/.npm-global/bin/codex")
    #expect(NotesCLI.locate("claude", in: directories) { _ in false } == nil)
    #expect(NotesCLI.searchDirectories(home: "/Users/me", user: "me", processPATH: nil, loginShellPATH: nil).count == 7)
}

@MainActor
@Test func notesCLILookupResolvesTheLoginShellPATHPastABannerAndRetriesAfterABrokenShell() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bin = directory.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let claude = bin.appendingPathComponent("claude").path
    let brokenShell = directory.appendingPathComponent("broken-shell").path
    let loginShell = directory.appendingPathComponent("login-shell").path
    let bannerThenPATHThenCommand = """
    #!/bin/sh
    [ "$1 $2" = "-l -i" ] || exit 1
    /usr/bin/head -c 3000000 /dev/zero | /usr/bin/tr '\\0' x; echo
    /bin/sleep 0.3
    export PATH="\(bin.path):$PATH"
    shift $(($# - 1))
    eval "$1"

    """
    #expect(FileManager.default.createFile(atPath: claude, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]))
    #expect(FileManager.default.createFile(atPath: brokenShell, contents: Data("#!/bin/sh\nexit 1\n".utf8), attributes: [.posixPermissions: 0o755]))
    #expect(FileManager.default.createFile(atPath: loginShell, contents: Data(bannerThenPATHThenCommand.utf8), attributes: [.posixPermissions: 0o755]))
    let onlyTheFakeInstall: (String) -> Bool = { $0.hasPrefix(bin.path) && FileManager.default.isExecutableFile(atPath: $0) }
    let afterBrokenShell = await NotesCLI.claudeCode.locateExecutable(shell: brokenShell, isExecutable: onlyTheFakeInstall)
    #expect(afterBrokenShell == nil)
    let found = await NotesCLI.claudeCode.locateExecutable(shell: loginShell, isExecutable: onlyTheFakeInstall)
    #expect(found?.path == claude)
}

@Test func claudeCatalogResolvesAliasesAndKeepsExactModelChoices() throws {
    let output = #"{"type":"control_response","response":{"request_id":"models","response":{"models":[{"value":"default","resolvedModel":"claude-sonnet-example","displayName":"Default"},{"value":"sonnet","resolvedModel":"claude-sonnet-example","displayName":"Sonnet"},{"value":"claude-sonnet-example","displayName":"Sonnet duplicate"},{"value":"claude-haiku-example","displayName":"Haiku"}]}}}"#
    let catalog = try NotesCLICatalog.claudeCatalog("unrelated log\n" + output)
    #expect(catalog.models.map(\.id) == ["claude-sonnet-example", "claude-haiku-example"])
    #expect(catalog.defaultID == "claude-sonnet-example")
    #expect(throws: MeetingNotesError.self) { try NotesCLICatalog.claudeCatalog("{}") }
    var settings = AppSettings()
    settings.notesSelection = .cli(.claudeCode)
    #expect(MeetingNotesGenerator.availability(settings: settings) != .available)
    settings.setCLIModel(catalog.models[1].id, for: .claudeCode)
    #expect(settings.notesModelName == "Claude Code · claude-haiku-example")
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).claudeNotesModel == "claude-haiku-example")
}

@Test func claudeSignInNeedsASubscriptionUnlessAnySignInIsAllowed() throws {
    let subscription = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}"#
    let gateway = #"{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}"#
    let signedOut = #"{"loggedIn":false,"authMethod":"none"}"#
    #expect(CLINotesModel.claudeSignInProblem(subscription, anySignIn: false) == nil)
    #expect(CLINotesModel.claudeSignInProblem(gateway, anySignIn: false)?.contains("Allow any Claude Code sign-in") == true)
    #expect(CLINotesModel.claudeSignInProblem(gateway, anySignIn: true) == nil)
    #expect(CLINotesModel.claudeSignInProblem(signedOut, anySignIn: true) != nil)
    #expect(CLINotesModel.claudeSignInProblem("not json", anySignIn: true) != nil)
    for method in ["oauth_token", "api_key", "api_key_helper", "third_party"] {
        let status = #"{"loggedIn":true,"authMethod":"\#(method)"}"#
        #expect(CLINotesModel.claudeSignInProblem(status, anySignIn: false) != nil)
        #expect(CLINotesModel.claudeSignInProblem(status, anySignIn: true) == nil)
    }
    #expect(CLINotesModel(cli: .claudeCode, model: "", anySignIn: true).arguments == CLINotesModel(cli: .claudeCode, model: "").arguments)

    let saved = #"{"autoPaste":true,"language":"auto","launchAtLogin":false,"saveHistory":true,"selectedModelID":"parakeet-v3","showCapsule":true,"silenceThreshold":0.002,"notesCLI":"claudeCode","claudeNotesModel":"claude-haiku-example"}"#
    var settings = try JSONDecoder().decode(AppSettings.self, from: Data(saved.utf8))
    #expect((try MeetingNotesGenerator.languageModel(settings) as? CLINotesModel)?.anySignIn == false)
    settings.claudeCodeAnySignIn = true
    let loaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect((try MeetingNotesGenerator.languageModel(loaded) as? CLINotesModel)?.anySignIn == true)
    #expect(loaded.allowsAnySignIn(.claudeCode))
    #expect(!loaded.allowsAnySignIn(.codex))
}

@Test func claudeSignInChoiceAppliesWhereverClaudeCodeIsSelected() {
    var settings = AppSettings()
    #expect(!settings.selectsClaudeCode)
    settings.askSelection = .cli(.claudeCode)
    #expect(settings.selectsClaudeCode)
    settings.askSelection = .cli(.codex)
    settings.cleanupSelection = .cli(.claudeCode)
    #expect(settings.selectsClaudeCode)
    settings.claudeCodeAnySignIn = true
    #expect((try? MeetingNotesGenerator.languageModel(settings.cleanupSettings) as? CLINotesModel)?.anySignIn == true)
    settings.cleanupSelection = nil
    settings.notesSelection = .cli(.claudeCode)
    #expect(settings.selectsClaudeCode)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERWISPR_LIVE_NOTES"] == "1"),
      arguments: ["claude", "codex", "api"])
func liveNotesProvidersGenerateFromSyntheticMeeting(provider: String) async throws {
    var settings = AppSettings()
    if provider == "api" {
        var connection = SpeechConnection(api: .openAICompatible)
        connection.name = "Local Ollama API test"
        connection.endpoint = "http://127.0.0.1:11434/v1/chat/completions"
        connection.modelID = "llama3.1:8b"
        settings.notesConnections = [connection]
        settings.notesSelection = .connection(connection.id)
    } else {
        let cli: NotesCLI = provider == "claude" ? .claudeCode : .codex
        let catalog = try await NotesCLICatalog.load(cli)
        let selected = try #require(catalog.defaultID)
        #expect(catalog.models.contains(where: { $0.id == selected }))
        settings.notesSelection = .cli(cli)
        settings.setCLIModel(selected, for: cli)
    }
    let generated = try await MeetingNotesGenerator.generate(segments: [
        MeetingSegment(speaker: .me, start: 0, duration: 4, text: "We agreed to launch on Friday. Alex will send the checklist tomorrow.", rawText: ""),
        MeetingSegment(speaker: .them, start: 4, duration: 3, text: "Agreed. Keep the budget at five hundred dollars.", rawText: ""),
    ], userNotes: "Synthetic meeting for testing only.", settings: settings) { _, _ in }
    #expect(!generated.title.isEmpty)
    #expect(!generated.summary.overview.isEmpty)
    #expect(!generated.summary.actionItems.isEmpty)
    if let cli = settings.notesCLI {
        #expect(generated.summary.modelName?.contains(settings.cliModel(cli)) == true)
    }
}

private func notesConnection(_ path: String = "notes") -> SpeechConnection {
    var connection = SpeechConnection(api: .openAICompatible)
    connection.endpoint = "https://notes.example/\(UUID())/\(path)"
    connection.modelID = "user-chosen-model"
    return connection
}

private actor NotesRequestProbe {
    struct Request { var url: String; var body: String; var authorization: String? }
    var requests: [Request] = []
    var stopped: Set<String> = []
    func add(_ request: Request) { requests.append(request) }
    func stop(_ url: String) { stopped.insert(url) }
}

// URLSession invokes URLProtocol on its own threads. No mutable instance state is shared;
// the probe is actor-isolated, and each request is recorded before its response is delivered.
private final class NotesEndpointStub: URLProtocol, @unchecked Sendable {
    static let probe = NotesRequestProbe()
    static let draft = #"{"title":"Friday launch","overview":"We agreed to launch Friday.","keyPoints":["Budget stays fixed"],"decisions":["Launch Friday"],"actionItems":["Alex: send the checklist"]}"#
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let recorded = NotesRequestProbe.Request(url: request.url!.absoluteString, body: String(decoding: body, as: UTF8.self), authorization: request.value(forHTTPHeaderField: "Authorization"))
        Task { await NotesEndpointStub.probe.add(recorded) }
        if path == "wait" { return }
        let status = ["unauthorized": 401, "quota": 429, "redirect": 307][path] ?? 200
        let data: Data
        if path == "speech" { data = Data(#"{"text":"We agreed to launch Friday."}"#.utf8) }
        else if status != 200 { data = Data("private-provider-error".utf8) }
        else if path == "malformed" { data = Data("{}".utf8) }
        else {
            data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": path == "empty" ? "" : Self.draft], "finish_reason": path == "truncated" ? "length" : "stop"]]])
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        let url = request.url!.absoluteString
        Task { await NotesEndpointStub.probe.stop(url) }
    }
}
