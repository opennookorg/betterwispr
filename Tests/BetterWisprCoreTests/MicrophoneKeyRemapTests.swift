import AppKit
import Darwin
import Foundation
import Testing
@testable import BetterWispr
@testable import BetterWisprCore

@Test @MainActor func microphoneRemapPreservesUnrelatedRulesAndRefusesConflicts() throws {
    let microphone = MicrophoneKeyRemap.microphoneToF5
    let capsToEscape = MicrophoneKeyRemap.Rule(source: 0x700000039, destination: 0x700000029)
    #expect(try MicrophoneKeyRemap.addingRule(to: [capsToEscape]) == [capsToEscape, microphone])

    for existing in [
        microphone,
        .init(source: microphone.source, destination: capsToEscape.destination),
        .init(source: microphone.destination, destination: capsToEscape.destination),
        .init(source: capsToEscape.source, destination: microphone.destination)
    ] {
        #expect(throws: MicrophoneKeyRemap.RemapError.self) {
            try MicrophoneKeyRemap.addingRule(to: [existing])
        }
    }
}

@MainActor
private final class RemapFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var boot = "first-boot"
    var services = "Services:\n0x0 0x0 0x11e 1 6 0x100000cad FIFO Keyboard Internal (null) 1\nDevices:"
    var mapping = "(null)"
    var writes = 0
    var refusesWrite = false
    var onReadMapping: (() throws -> Void)?

    func makeRemap() -> MicrophoneKeyRemap {
        MicrophoneKeyRemap(directory: directory, runCommand: { [self] arguments in
            if arguments.first == "list" { return services }
            try onReadMapping?()
            return "RegistryID Key Value\n100000cad UserKeyMapping \(mapping)"
        }, bootSession: { [self] in boot }, writeCommand: { [self] arguments, _ in
            writes += 1
            if refusesWrite { throw MicrophoneKeyRemap.RemapError.write }
            let json = try #require(arguments.last)
            let payload = try JSONDecoder().decode([String: [[String: UInt64]]].self, from: Data(json.utf8))
            let rows = try #require(payload["UserKeyMapping"])
            mapping = "(" + rows.map { row in
                "{" + row.map { "\($0.key) = \($0.value);" }.joined() + "}"
            }.joined(separator: ",") + ")"
        })
    }
}

@Test @MainActor func activationConflictDoesNotRemoveAnIdenticalForeignMapping() {
    let fixture = RemapFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var reads = 0
    fixture.onReadMapping = { [unowned fixture] in
        reads += 1
        if reads == 2 {
            fixture.mapping = "({HIDKeyboardModifierMappingSrc = 51539607759; HIDKeyboardModifierMappingDst = 30064771134;})"
        }
    }
    let remap = fixture.makeRemap()
    #expect(throws: MicrophoneKeyRemap.RemapError.conflict) { try remap.enable() }
    #expect(fixture.writes == 0)
    #expect(fixture.mapping.contains("51539607759"))
    #expect(!remap.needsRecovery)
}

@Test @MainActor func recoveryDiscardsPreparedJournalWithoutTouchingTheKeyboard() throws {
    let fixture = RemapFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    let journal = #"{"boot":"first-boot","serviceID":4294970589,"previous":[],"preparedOnly":true}"#
    try Data(journal.utf8).write(to: fixture.directory.appendingPathComponent("microphone-key-remap.json"))
    fixture.onReadMapping = { Issue.record("Prepared recovery should not read the keyboard") }
    let remap = fixture.makeRemap()
    try remap.restore()
    #expect(!remap.needsRecovery)
    #expect(fixture.writes == 0)
}

@Test @MainActor func failedOwnerRestorationKeepsTheLockUntilRetrySucceeds() throws {
    let fixture = RemapFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = fixture.makeRemap()
    try owner.enable()
    fixture.refusesWrite = true
    #expect(throws: MicrophoneKeyRemap.RemapError.write) { try owner.restore() }
    fixture.refusesWrite = false
    let other = fixture.makeRemap()
    #expect(throws: MicrophoneKeyRemap.RemapError.inUse) { try other.restore() }
    #expect(fixture.writes == 2)
    try owner.restore()
    #expect(!other.needsRecovery)
    #expect(fixture.mapping == "()")
}

@Test @MainActor func failedActivationRollbackKeepsTheLockUntilRetrySucceeds() throws {
    let fixture = RemapFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    fixture.onReadMapping = { [unowned fixture] in
        // The first write applied the mapping, but its verification failed.
        if fixture.writes == 1, !fixture.refusesWrite {
            fixture.refusesWrite = true
            throw MicrophoneKeyRemap.RemapError.write
        }
    }
    let owner = fixture.makeRemap()
    #expect(throws: MicrophoneKeyRemap.RemapError.write) { try owner.enable() }
    #expect(owner.needsRecovery)
    #expect(fixture.writes == 2)
    #expect(fixture.mapping.contains("51539607759"))

    let other = fixture.makeRemap()
    fixture.refusesWrite = false
    #expect(throws: MicrophoneKeyRemap.RemapError.inUse) { try other.restore() }
    try owner.restore()
    #expect(!other.needsRecovery)
    #expect(fixture.mapping == "()")
}

@MainActor
private final class TestDictationHotKey: DictationHotKey {
    var isRegistered = false
    var wantsShift = false
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var occupied = true
    var attempts: [DictationShortcut] = []

    func register(_ shortcut: DictationShortcut, withShift: Bool) throws {
        unregister()
        attempts.append(shortcut)
        guard !occupied else { throw ShortcutError.unavailable(shortcut) }
        wantsShift = withShift
        isRegistered = true
    }

    func unregister() { isRegistered = false }
}

private enum RecoveryTiming: CaseIterable {
    case idle, dictating, dictatingWithShortcutCapture
}

@Test(arguments: RecoveryTiming.allCases)
@MainActor private func launchRetriesRecoveryAfterTheWriterReleasesTheLock(timing: RecoveryTiming) async throws {
    let fixture = RemapFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var owner: MicrophoneKeyRemap? = fixture.makeRemap()
    try owner?.enable()
    let recovery = fixture.makeRemap()
    let hotKey = TestDictationHotKey()
    let model = AppModel(store: LocalStore(directory: fixture.directory), startsServices: false,
                         microphoneKeyRemap: recovery, globalShortcut: hotKey)
    model.settings.shortcut = .f5
    let retry = try #require(model.startDictationShortcut(retryDelay: .zero))
    let recorder = UUID()
    if timing == .dictatingWithShortcutCapture { model.beginKeyCapture(recorder) }
    if timing != .idle { model.phase = .recording }
    #expect(model.microphoneKeyRecoveryNeeded)
    #expect(fixture.writes == 1)
    #expect(!hotKey.isRegistered)
    hotKey.occupied = false
    owner = nil
    await retry.value
    #expect(!model.microphoneKeyRecoveryNeeded)
    #expect(!recovery.needsRecovery)
    #expect(fixture.mapping == "()")
    if timing != .idle {
        if timing == .dictatingWithShortcutCapture { model.endKeyCapture(recorder) }
        #expect(!hotKey.isRegistered)
        #expect(hotKey.attempts == [.f5])
        model.phase = .transcribing
        #expect(hotKey.attempts == [.f5])
        model.phase = .idle
    }
    #expect(hotKey.isRegistered)
    #expect(hotKey.attempts == [.f5, .f5])
}

private enum MicrophoneKeyExit: CaseIterable {
    case clean, forced, disabled
}

@Test(arguments: MicrophoneKeyExit.allCases)
@MainActor private func microphoneRemapPreferenceSurvivesRelaunch(exit: MicrophoneKeyExit) throws {
    let fixture = RemapFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LocalStore(directory: fixture.directory)
    // The workspace predates the microphone-key preference.
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    var state = SavedState()
    state.settings.shortcut = .f5
    let encoded = try JSONEncoder().encode(state)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var legacySettings = try #require(legacy["settings"] as? [String: Any])
    legacySettings.removeValue(forKey: "usesInternalMicrophoneKey")
    legacy["settings"] = legacySettings
    try JSONSerialization.data(withJSONObject: legacy).write(to: store.stateURL)
    let hotKey = TestDictationHotKey()
    hotKey.occupied = false
    do {
        let original = AppModel(store: store, startsServices: false, microphoneKeyRemap: fixture.makeRemap(), globalShortcut: hotKey)
        original.startDictationShortcut()
        #expect(!original.microphoneKeyRemapped)
        original.setMicrophoneKeyRemapped(true)
        #expect(original.microphoneKeyRemapped)
        #expect(try store.load().settings.usesInternalMicrophoneKey)
        switch exit {
        case .clean:
            #expect(original.restoreMicrophoneKey(quitting: true))
            #expect(fixture.mapping == "()")
            #expect(try store.load().settings.usesInternalMicrophoneKey)
        case .forced:
            #expect(fixture.writes == 1)
        case .disabled:
            original.setMicrophoneKeyRemapped(false)
            #expect(fixture.mapping == "()")
            #expect(!((try store.load()).settings.usesInternalMicrophoneKey))
            #expect(original.restoreMicrophoneKey(quitting: true))
        }
    }
    let nextHotKey = TestDictationHotKey()
    nextHotKey.occupied = false
    let relaunched = AppModel(store: store, startsServices: false, microphoneKeyRemap: fixture.makeRemap(), globalShortcut: nextHotKey)
    relaunched.startDictationShortcut()
    #expect(nextHotKey.attempts == [.f5])
    #expect(!relaunched.microphoneKeyRecoveryNeeded)
    #expect(relaunched.microphoneKeyRemapped == (exit == .clean))
    #expect(try store.load().settings.usesInternalMicrophoneKey == (exit == .clean))
    #expect(fixture.writes == (exit == .clean ? 3 : 2))
    if exit == .forced {
        #expect(fixture.mapping == "()")
        relaunched.setMicrophoneKeyRemapped(true)
        #expect(relaunched.microphoneKeyRemapped)
        #expect(try store.load().settings.usesInternalMicrophoneKey)
    }
}

@Test(arguments: [false, true])
@MainActor func recoveryKeepsJournalWhenSavingDeactivationFails(relaunch: Bool) throws {
    let fixture = RemapFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LocalStore(directory: fixture.directory)
    var state = SavedState()
    state.settings.shortcut = .f5
    state.settings.usesInternalMicrophoneKey = true
    try store.save(state)
    var owner: MicrophoneKeyRemap? = fixture.makeRemap()
    try owner?.enable()
    owner = nil

    let remap = fixture.makeRemap()
    let hotKey = TestDictationHotKey()
    hotKey.occupied = false
    let model = AppModel(store: store, startsServices: false, microphoneKeyRemap: remap, globalShortcut: hotKey)
    // Block the atomic workspace replacement after the model loads its saved settings.
    let backup = fixture.directory.appendingPathComponent("workspace-backup.json")
    try FileManager.default.moveItem(at: store.stateURL, to: backup)
    try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
    model.startDictationShortcut()
    #expect(model.microphoneKeyRecoveryNeeded)
    #expect(model.microphoneKeyError != nil)
    #expect(!model.microphoneKeyRemapped)
    #expect(remap.needsRecovery)
    #expect(fixture.mapping == "()")
    #expect(fixture.writes == 2)

    // An unrelated tool installs the same rule after ours was removed.
    let externalMapping = "({HIDKeyboardModifierMappingSrc = 51539607759; HIDKeyboardModifierMappingDst = 30064771134;})"
    fixture.mapping = externalMapping
    fixture.services = ""
    try FileManager.default.removeItem(at: store.stateURL)
    try FileManager.default.moveItem(at: backup, to: store.stateURL)
    #expect(try store.load().settings.usesInternalMicrophoneKey)
    let recovered: AppModel
    if relaunch {
        recovered = AppModel(store: store, startsServices: false, microphoneKeyRemap: fixture.makeRemap(), globalShortcut: hotKey)
        recovered.startDictationShortcut()
    } else {
        recovered = model
        #expect(recovered.retryMicrophoneKeyRecovery())
    }
    #expect(!recovered.microphoneKeyRecoveryNeeded)
    #expect(!recovered.microphoneKeyRemapped)
    #expect(!remap.needsRecovery)
    #expect(fixture.writes == 2)
    #expect(fixture.mapping == externalMapping)
    #expect(try store.load().settings.usesInternalMicrophoneKey == false)
}

@Test @MainActor func recoveryClearsStoredPreferenceWithoutOverwritingNewerSettings() throws {
    let fixture = RemapFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LocalStore(directory: fixture.directory)
    var state = SavedState()
    state.settings.shortcut = .f5
    try store.save(state)
    let hotKey = TestDictationHotKey()
    hotKey.occupied = false
    let recovery = AppModel(store: store, startsServices: false, microphoneKeyRemap: fixture.makeRemap(), globalShortcut: hotKey)
    #expect(!recovery.settings.usesInternalMicrophoneKey)

    var owner: MicrophoneKeyRemap? = fixture.makeRemap()
    try owner?.enable()
    state.settings.usesInternalMicrophoneKey = true
    state.settings.showInDock = true
    try store.save(state)
    owner = nil

    recovery.startDictationShortcut()
    #expect(!recovery.microphoneKeyRecoveryNeeded)
    #expect(!recovery.microphoneKeyOptionEnabled)
    #expect(fixture.mapping == "()")
    state.settings.usesInternalMicrophoneKey = false
    #expect(try store.load() == state)
}

@Test(arguments: [false, true])
@MainActor func changingShortcutDuringRecoveryPreservesNewerWorkspaceData(failPermissions: Bool) throws {
    let fixture = RemapFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LocalStore(directory: fixture.directory)
    var state = SavedState()
    state.settings.shortcut = .f5
    state.settings.rememberVoices = true
    try store.save(state)
    let hotKey = TestDictationHotKey()
    hotKey.occupied = false
    let replacement = TestDictationHotKey()
    replacement.occupied = false
    let remap = fixture.makeRemap()
    let appStore = failPermissions ? LocalStore(directory: fixture.directory) { _ in
        throw POSIXError(.EPERM)
    } : store
    let model = AppModel(store: appStore, startsServices: false, microphoneKeyRemap: remap,
                         globalShortcut: hotKey, makeReplacementShortcut: { replacement })
    model.meetings.remembersVoices = model.settings.rememberVoices
    model.meetings.notesSettings = model.settings
    var owner: MicrophoneKeyRemap? = fixture.makeRemap()
    try owner?.enable()
    state.settings.usesInternalMicrophoneKey = true
    state.settings.showInDock = true
    state.settings.rememberVoices = false
    state.settings.sendToClaude = true
    state.settings.historyRetention = .latest100
    state.history = [.init(text: "Recent", rawText: "Recent", duration: 1, modelName: "Test", language: "en")]
    state.vocabulary = [.init(phrase: "whisper", replacement: "BetterWispr")]
    try store.save(state)
    owner = nil
    let services = fixture.services
    fixture.services = ""
    model.startDictationShortcut()
    #expect(model.microphoneKeyRecoveryNeeded)
    fixture.services = services

    if failPermissions {
        model.changeShortcut(.optionSpace)
        #expect(try store.load() == state)
        #expect(remap.needsRecovery)
        #expect(model.settings.shortcut == .f5)
        #expect(hotKey.isRegistered)
        #expect(!replacement.isRegistered)
        #expect(!model.microphoneKeyRemapped)
        #expect(fixture.writes == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
            .allSatisfy { UUID(uuidString: $0) == nil })
        return
    }

    // The replacement registers, but the workspace is briefly unreadable.
    let backup = fixture.directory.appendingPathComponent("workspace-backup.json")
    try FileManager.default.moveItem(at: store.stateURL, to: backup)
    try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
    let older = Transcript(createdAt: .distantPast, text: "Earlier", rawText: "Earlier",
                           duration: 1, modelName: "Test", language: "en")
    #expect(throws: (any Error).self) { try model.addToHistory(older) }
    model.changeShortcut(.optionSpace)
    #expect(remap.needsRecovery)
    #expect(model.settings.shortcut == .f5)
    #expect(hotKey.isRegistered)
    #expect(!replacement.isRegistered)
    try FileManager.default.removeItem(at: store.stateURL)
    try FileManager.default.moveItem(at: backup, to: store.stateURL)
    state.history = (1...100).map { index in
        Transcript(createdAt: Date.now.addingTimeInterval(-Double(index)), text: "Recent \(index)",
                   rawText: "Recent \(index)", duration: 1, modelName: "Test", language: "en")
    }
    try store.save(state)

    model.changeShortcut(.optionSpace)
    #expect(!remap.needsRecovery)
    #expect(!model.microphoneKeyRecoveryNeeded)
    #expect(!model.microphoneKeyOptionEnabled)
    #expect(model.settings.shortcut == .optionSpace)
    #expect(!hotKey.isRegistered)
    #expect(replacement.isRegistered)
    #expect(fixture.writes == 2)
    state.settings.shortcut = .optionSpace
    state.settings.usesInternalMicrophoneKey = false
    #expect(try store.load() == state)
    #expect(model.meetings.notesSettings == state.settings)
    #expect(!model.meetings.remembersVoices)
    #expect(replacement.wantsShift)
    #expect(model.history == state.history + [older])
    let next = Transcript(text: "Next", rawText: "Next", duration: 1, modelName: "Test", language: "en")
    try model.addToHistory(next)
    let afterDictation = try store.load()
    #expect(afterDictation.history == [next] + Array(state.history.prefix(99)))
    #expect(afterDictation.vocabulary == state.vocabulary)
    #expect(afterDictation.settings.showInDock)
    #expect(afterDictation.settings.shortcut == .optionSpace)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.stateURL.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
}

@Test @MainActor func changingShortcutAppliesRecoveredSendAudioAndIdleSettings() async throws {
    let fixture = RemapFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LocalStore(directory: fixture.directory)
    let audioStore = FailedDictationStore(directory: fixture.directory.appendingPathComponent("Failed Dictations"))
    let source = fixture.directory.appendingPathComponent("sample.wav")
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: source)
    let keptAudio = try audioStore.keep(source)
    let apple = try #require(SpeechModel.catalog.first { $0.engine == .apple })
    var state = SavedState()
    state.settings.shortcut = .f5
    state.settings.selectedModelID = apple.id
    state.settings.soundEffects = false
    state.settings.sendToClaude = true
    state.settings.unloadModelWhenIdle = .fiveMinutes
    try store.save(state)

    let hotKey = TestDictationHotKey()
    hotKey.occupied = false
    let replacement = TestDictationHotKey()
    replacement.occupied = false
    let model = AppModel(store: store, startsServices: false, microphoneKeyRemap: fixture.makeRemap(),
                         globalShortcut: hotKey, makeReplacementShortcut: { replacement })
    model.selectModel(apple, prepared: AppleSpeechProvider())
    model.startDictationShortcut()
    model.setMicrophoneKeyRemapped(true)
    try #require(model.microphoneKeyRemapped)
    try #require(model.failedDictations.map(\.url) == [keptAudio])

    var resolutionStarted = false
    var cancelledSend = 0
    model.pressSendKey(in: .current, after: .milliseconds(20), using: FocusedAppIntegration(keepsCopy: false),
                       otherwise: { cancelledSend += 1 }, resolving: { _, _ in
        resolutionStarted = true
        return nil
    })
    model.scheduleIdleUnload(after: .milliseconds(20))

    state = try store.load()
    state.settings.sendRules = [AppSendRule(bundleID: "test.target")]
    state.settings.saveHistory = false
    state.settings.unloadModelWhenIdle = .never
    try store.save(state)
    model.changeShortcut(.optionSpace)

    #expect(model.settings.shortcut == .optionSpace)
    #expect(model.settings.sendsAfterPaste)
    #expect(model.phase == .idle)
    #expect(cancelledSend == 1)
    #expect(model.failedDictations.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: keptAudio.path))
    try await Task.sleep(for: .milliseconds(150))
    #expect(!resolutionStarted)
    #expect(cancelledSend == 1)
    #expect(model.isSpeechModelLoaded)
}

@Test @MainActor func savedMicrophoneKeyOptionCanBeDisabledWhenF5IsUnavailable() throws {
    let fixture = RemapFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LocalStore(directory: fixture.directory)
    var state = SavedState()
    state.settings.shortcut = .f5
    state.settings.usesInternalMicrophoneKey = true
    try store.save(state)
    let hotKey = TestDictationHotKey()
    let model = AppModel(store: store, startsServices: false, microphoneKeyRemap: fixture.makeRemap(), globalShortcut: hotKey)
    model.startDictationShortcut()
    #expect(!model.microphoneKeyRemapped)
    #expect(model.microphoneKeyOptionEnabled)
    #expect(model.microphoneKeyError != nil)

    model.setMicrophoneKeyRemapped(false)
    #expect(!model.microphoneKeyOptionEnabled)
    #expect(model.microphoneKeyError == nil)
    #expect(model.settings.shortcut == .f5)
    hotKey.occupied = false
    let relaunched = AppModel(store: store, startsServices: false, microphoneKeyRemap: fixture.makeRemap(), globalShortcut: hotKey)
    relaunched.startDictationShortcut()
    #expect(!relaunched.microphoneKeyOptionEnabled)
    #expect(fixture.writes == 0)
}

@Test @MainActor func recoverySurfacesUnavailableF5AndActivationCanRetryIt() throws {
    let fixture = RemapFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var owner: MicrophoneKeyRemap? = fixture.makeRemap()
    try owner?.enable()
    let hotKey = TestDictationHotKey()
    let model = AppModel(store: LocalStore(directory: fixture.directory), startsServices: false,
                         microphoneKeyRemap: fixture.makeRemap(), globalShortcut: hotKey)
    model.settings.shortcut = .f5
    owner = nil

    #expect(model.retryMicrophoneKeyRecovery())
    #expect(!model.microphoneKeyRecoveryNeeded)
    #expect(model.microphoneKeyError == ShortcutError.unavailable(.f5).localizedDescription)
    model.setMicrophoneKeyRemapped(true)
    #expect(!model.microphoneKeyRemapped)
    #expect(fixture.writes == 2)

    hotKey.occupied = false
    model.setMicrophoneKeyRemapped(true)
    #expect(model.microphoneKeyRemapped)
    #expect(model.microphoneKeyError == nil)
    #expect(model.restoreMicrophoneKey())
}

@Test @MainActor func recoveryRetainsJournalUntilTheOriginalKeyboardIsReadable() throws {
    let fixture = RemapFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var first: MicrophoneKeyRemap? = fixture.makeRemap()
    try first?.enable()
    #expect(fixture.writes == 1)
    first = nil

    let recovery = fixture.makeRemap()
    let services = fixture.services
    for incomplete in ["", "Devices:\nBuilt-in keyboard", "Services:\nDevices:"] {
        fixture.services = incomplete
        #expect(throws: MicrophoneKeyRemap.RemapError.self) { try recovery.restore() }
        #expect(recovery.needsRecovery)
        #expect(fixture.writes == 1)
    }
    fixture.services = services
    fixture.refusesWrite = true
    #expect(throws: MicrophoneKeyRemap.RemapError.self) { try recovery.restore() }
    #expect(recovery.needsRecovery)
    fixture.refusesWrite = false
    try recovery.restore()
    #expect(!recovery.needsRecovery)
    #expect(fixture.mapping == "()")
}

@Test @MainActor func recoveryAfterRebootDoesNotWriteToTheNewKeyboardService() throws {
    let fixture = RemapFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var first: MicrophoneKeyRemap? = fixture.makeRemap()
    try first?.enable()
    first = nil
    fixture.boot = "new-boot"
    fixture.services = ""
    let recovery = fixture.makeRemap()
    try recovery.restore()
    #expect(!recovery.needsRecovery)
    #expect(fixture.writes == 1)
}

@Test @MainActor func recoveryCannotOverwriteAnotherInstancesActiveRemap() throws {
    let fixture = RemapFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = fixture.makeRemap()
    try owner.enable()
    let second = fixture.makeRemap()
    #expect(throws: MicrophoneKeyRemap.RemapError.inUse) { try second.restore() }
    #expect(second.needsRecovery)
    #expect(fixture.writes == 1)
    try owner.restore()
    #expect(!second.needsRecovery)
    #expect(fixture.writes == 2)
}

@Test @MainActor func remapWriterInheritsTheLockedFileAsStandardInput() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("lock")
    try Data("writer-lock\n".utf8).write(to: file)
    let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    try #require(descriptor > STDERR_FILENO)
    defer { close(descriptor) }
    try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    // Read the marker through the inherited FD. /dev/fd paths don't support test -ef on macOS.
    try MicrophoneKeyRemap.runLockedWriter("/bin/sh",
                                          arguments: ["-c", "IFS= read -r marker && test \"$marker\" = writer-lock"],
                                          lock: descriptor)
}
