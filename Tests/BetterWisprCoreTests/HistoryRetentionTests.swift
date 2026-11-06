import Foundation
import Testing
@testable import BetterWisprCore
@testable import BetterWispr

@Test @MainActor func changingHistoryRetentionDeletesAndSavesOlderDictations() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LocalStore(directory: folder)
    let model = AppModel(store: store, startsServices: false)
    let old = Transcript(createdAt: .now.addingTimeInterval(-5 * 86_400), text: "old", rawText: "old", duration: 1, modelName: "test", language: "en")
    let recent = Transcript(text: "recent", rawText: "recent", duration: 1, modelName: "test", language: "en")
    model.history = [recent, old]
    #expect(model.historyRemoved(by: .threeDays) == 1)
    model.setHistoryRetention(.threeDays)
    #expect(model.history == [recent])
    let saved = try store.load()
    #expect(saved.history == [recent])
    #expect(saved.settings.historyRetention == .threeDays)
}
