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

private func claudeStatus(_ method: String, provider: String = "firstParty") -> String {
    #"{"loggedIn":true,"authMethod":"\#(method)","apiProvider":"\#(provider)"}"#
}

private func claudeDestination(_ method: String, provider: String = "firstParty", settings: [String] = []) throws -> ClaudeCodeDestination {
    try ClaudeCodeDestination(status: claudeStatus(method, provider: provider), settingsFiles: settings.map { Data($0.utf8) })
}

@Test func claudeDestinationNamesTheRouteAndNeverASecret() throws {
    #expect(try claudeDestination("claude.ai").label == "Anthropic · Claude subscription")
    #expect(try claudeDestination("claude.ai").isSubscription)
    #expect(try claudeDestination("api_key").label == "Anthropic · API key")
    #expect(try claudeDestination("api_key").isSubscription == false)
    #expect(try claudeDestination("third_party", provider: "bedrock").label == "Amazon Bedrock · cloud provider sign-in")
    #expect(try claudeDestination("claude.ai", provider: "bedrock").isSubscription == false)
    #expect(try claudeDestination("something_new", provider: "elsewhere").label == "elsewhere · something_new")

    let gateway = #"{"env":{"ANTHROPIC_BASE_URL":"https://me:hunter2@gateway.example.com:8443/v1?token=hunter2","ANTHROPIC_API_KEY":"hunter2","OTHER":"x"}}"#
    let routed = try claudeDestination("oauth_token", settings: [#"{"model":"x"}"#, gateway])
    #expect(routed.label == "https://gateway.example.com:8443/v1 · OAuth token")
    #expect(!routed.label.contains("hunter2"))
    #expect(try claudeDestination("claude.ai", settings: [gateway]).isSubscription == false)
    let managed = #"{"env":{"ANTHROPIC_BEDROCK_BASE_URL":"https://bedrock.example.com/"}}"#
    #expect(try claudeDestination("api_key", settings: [gateway, managed]).label
        == "https://bedrock.example.com · https://gateway.example.com:8443/v1 · API key")
}

@Test func claudeDestinationFailsClosedWhenItCannotTell() {
    for status in ["not json", #"{"loggedIn":false,"authMethod":"none"}"#, #"{"loggedIn":true}"#, #"{"loggedIn":true,"authMethod":""}"#] {
        #expect(throws: MeetingNotesError.self) { try ClaudeCodeDestination(status: status, settingsFiles: []) }
    }
    #expect(throws: MeetingNotesError.self) { try ClaudeCodeDestination(status: claudeStatus("api_key"), settingsFiles: [nil]) }
    for settings in ["", "not json", "[]", #"{"env":"x"}"#, #"{"env":{"ANTHROPIC_BASE_URL":42}}"#, #"{"env":{"ANTHROPIC_BASE_URL":"gateway:8443"}}"#, #"{"env":{"ANTHROPIC_FOUNDRY_BASE_URL":""}}"#] {
        #expect(throws: MeetingNotesError.self) { try claudeDestination("claude.ai", settings: [settings]) }
    }
}

@Test func claudeSignInNeedsASubscriptionOrAConfirmedDestination() throws {
    let subscription = try claudeDestination("claude.ai")
    #expect(CLINotesModel.claudeSignInProblem(subscription, anySignIn: false, confirmed: nil) == nil)
    for method in ["oauth_token", "api_key", "api_key_helper", "third_party"] {
        let destination = try claudeDestination(method)
        #expect(CLINotesModel.claudeSignInProblem(destination, anySignIn: false, confirmed: destination.label)?.contains("Allow any Claude Code sign-in") == true)
        #expect(CLINotesModel.claudeSignInProblem(destination, anySignIn: true, confirmed: nil)?.contains("Confirm") == true)
        #expect(CLINotesModel.claudeSignInProblem(destination, anySignIn: true, confirmed: subscription.label)?.contains(destination.label) == true)
        #expect(CLINotesModel.claudeSignInProblem(destination, anySignIn: true, confirmed: destination.label) == nil)
    }
    let custom = try claudeDestination("claude.ai", settings: [#"{"env":{"ANTHROPIC_BASE_URL":"https://gateway.example.com"}}"#])
    #expect(CLINotesModel.claudeSignInProblem(custom, anySignIn: false, confirmed: nil)?.contains("https://gateway.example.com") == true)
}

@Test func anyClaudeSignInAppliesOnlyToMeetingNotes() throws {
    var settings = AppSettings()
    settings.notesSelection = .cli(.claudeCode)
    settings.claudeCodeAnySignIn = true
    settings.claudeCodeConfirmedDestination = "Anthropic · API key"
    let notes = try #require(try MeetingNotesGenerator.meetingNotesModel(settings) as? CLINotesModel)
    #expect(notes.anySignIn)
    #expect(notes.confirmedDestination == "Anthropic · API key")
    #expect(notes.arguments.suffix(2) == ["--max-budget-usd", "1.00"])

    settings.cleanupSelection = .cli(.claudeCode)
    settings.askSelection = .cli(.claudeCode)
    for other in [settings, settings.cleanupSettings, settings.askSettings] {
        let model = try #require(try MeetingNotesGenerator.languageModel(other, lowLatency: true) as? CLINotesModel)
        #expect(!model.anySignIn)
        #expect(model.confirmedDestination == nil)
        #expect(!model.arguments.contains("--max-budget-usd"))
    }

    settings.notesSelection = .cli(.codex)
    #expect((try MeetingNotesGenerator.meetingNotesModel(settings) as? CLINotesModel)?.anySignIn == false)
    settings.notesSelection = .apple
    #expect(!(try MeetingNotesGenerator.meetingNotesModel(settings) is CLINotesModel))
    settings.notesSelection = .cli(.claudeCode)
    settings.claudeCodeAnySignIn = false
    #expect((try MeetingNotesGenerator.meetingNotesModel(settings) as? CLINotesModel)?.anySignIn == false)
}

@Test func claudeConfirmedDestinationDecodesOldAndCorruptFiles() throws {
    let saved = #"{"autoPaste":true,"language":"auto","launchAtLogin":false,"saveHistory":true,"selectedModelID":"parakeet-v3","showCapsule":true,"silenceThreshold":0.002,"notesCLI":"claudeCode","claudeNotesModel":"claude-haiku-example"%@}"#
    let old = try JSONDecoder().decode(AppSettings.self, from: Data(String(format: saved, "").utf8))
    #expect(old.claudeCodeConfirmedDestination == nil)
    #expect(!old.claudeCodeAnySignIn)
    #expect(!(try #require(try MeetingNotesGenerator.meetingNotesModel(old) as? CLINotesModel)).anySignIn)

    let corrupt = try JSONDecoder().decode(AppSettings.self, from: Data(String(format: saved, #","claudeCodeAnySignIn":true,"claudeCodeConfirmedDestination":42"#).utf8))
    #expect(corrupt.claudeCodeConfirmedDestination == nil)
    #expect(corrupt.claudeCodeAnySignIn)
    #expect(corrupt.claudeNotesModel == "claude-haiku-example")

    var settings = old
    settings.claudeCodeConfirmedDestination = "Anthropic · API key"
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).claudeCodeConfirmedDestination == "Anthropic · API key")
}

private struct FakeClaude {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID())")
    var log: URL { directory.appendingPathComponent("log") }
    var input: URL { directory.appendingPathComponent("input") }

    init(status: String, reply: String, exit: Int = 0) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(reply.utf8).write(to: directory.appendingPathComponent("reply"))
        try setStatus(status)
        let script = """
        #!/bin/sh
        echo "$*" >> '\(log.path)'
        if [ "$1" = auth ]; then /bin/cat '\(directory.path)/status'; exit 0; fi
        /bin/cat > '\(input.path)'
        /bin/cat '\(directory.path)/reply'
        exit \(exit)
        """
        #expect(FileManager.default.createFile(atPath: directory.appendingPathComponent("claude").path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755]))
    }

    func setStatus(_ status: String) throws { try Data(status.utf8).write(to: directory.appendingPathComponent("status")) }

    func route(_ settings: AppSettings, notes: Bool = true) throws -> CLINotesModel {
        var model = try #require(try (notes ? MeetingNotesGenerator.meetingNotesModel(settings) : MeetingNotesGenerator.languageModel(settings, lowLatency: true)) as? CLINotesModel)
        model.locatedExecutable = directory.appendingPathComponent("claude")
        model.settingsFiles = { [] }
        return model
    }

    var sentPrompt: Bool { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("--print") || FileManager.default.fileExists(atPath: input.path) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private let claudeNotesReply = #"{"is_error":false,"result":"{\"title\":\"T\",\"overview\":\"O\",\"keyPoints\":[],\"decisions\":[],\"actionItems\":[]}","modelUsage":{"claude-x":{}}}"#

@Test func meetingNotesSendNothingUntilTheCurrentDestinationIsConfirmed() async throws {
    let fake = try FakeClaude(status: claudeStatus("api_key"), reply: claudeNotesReply)
    defer { fake.remove() }
    var settings = AppSettings()
    settings.notesSelection = .cli(.claudeCode)
    settings.claudeCodeAnySignIn = true
    for confirmed in [nil, "Anthropic · Claude subscription"] as [String?] {
        settings.claudeCodeConfirmedDestination = confirmed
        await #expect(throws: MeetingNotesError.self) { try await fake.route(settings).draft("Secret meeting text") }
        #expect(!fake.sentPrompt)
    }

    settings.claudeCodeConfirmedDestination = "Anthropic · API key"
    let draft = try await fake.route(settings).draft("Secret meeting text")
    #expect(draft.generatedWith == "Claude Code · claude-x · Anthropic · API key")
    #expect(try String(contentsOf: fake.input, encoding: .utf8).contains("Secret meeting text"))
    #expect(try String(contentsOf: fake.log, encoding: .utf8).contains("--max-budget-usd 1.00"))

    try FileManager.default.removeItem(at: fake.input)
    try FileManager.default.removeItem(at: fake.log)
    try fake.setStatus(claudeStatus("oauth_token"))
    await #expect(throws: MeetingNotesError.self) { try await fake.route(settings).draft("Secret meeting text") }
    #expect(!fake.sentPrompt)
}

@Test func dictationNeverReachesANonSubscriptionClaudeSignIn() async throws {
    let fake = try FakeClaude(status: claudeStatus("api_key"), reply: claudeNotesReply)
    defer { fake.remove() }
    var settings = AppSettings()
    settings.notesSelection = .cli(.claudeCode)
    settings.claudeCodeAnySignIn = true
    settings.claudeCodeConfirmedDestination = "Anthropic · API key"
    await #expect(throws: MeetingNotesError.self) { try await fake.route(settings.cleanupSettings, notes: false).respond(to: "Spoken words") }
    #expect(!fake.sentPrompt)

    try fake.setStatus(claudeStatus("claude.ai"))
    #expect(try await fake.route(settings.cleanupSettings, notes: false).respond(to: "Spoken words").contains("title"))
    #expect(fake.sentPrompt)
}

@Test(arguments: [0, 1])
func claudeSpendingLimitSaysSoAndKeepsTheMeeting(exit: Int) async throws {
    let reply = #"{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":1.01}"#
    let fake = try FakeClaude(status: claudeStatus("api_key"), reply: reply, exit: exit)
    defer { fake.remove() }
    var settings = AppSettings()
    settings.notesSelection = .cli(.claudeCode)
    settings.claudeCodeAnySignIn = true
    settings.claudeCodeConfirmedDestination = "Anthropic · API key"
    await #expect {
        try await fake.route(settings).draft("Secret meeting text")
    } throws: { error in
        let message = error.localizedDescription
        return message.contains("spending limit") && message.contains("Your meeting is still saved")
    }
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
