import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import BetterWisprCore
@testable import BetterWispr

@Test func mouseTriggersGetTheNamesUsersKnow() {
    #expect(DictationTrigger.mouse(button: 3).displayName == "Mouse 4")
    #expect(DictationTrigger.mouse(button: 4).displayName == "Mouse 5")
    #expect(DictationTrigger.mouse(button: 4).spokenName == "Mouse 5")
    #expect(!DictationTrigger.mouse(button: 4).isFunctionTap)
}

@Test func onlyTheFunctionKeyAloneCarriesTheDoubleTapTrigger() {
    #expect(DictationTrigger.keyboard(.functionTap).isFunctionTap)
    #expect(!DictationTrigger.keyboard(.optionSpace).isFunctionTap)
    #expect(!DictationTrigger.keyboard(.fnControl).isFunctionTap)
}

@Test func onlyModifierOnlyTriggersNeedAccessibility() throws {
    #expect(DictationTrigger.keyboard(.functionTap).needsAccessibility)
    let leftOption = try #require(DictationShortcut(keyCode: 58, modifiers: [], key: "Left Option"))
    #expect(DictationTrigger.keyboard(leftOption).needsAccessibility)
    #expect(!DictationTrigger.keyboard(.optionSpace).needsAccessibility)
    #expect(!DictationTrigger.mouse(button: 4).needsAccessibility)
}

@Test func macOSClaimsTheFunctionKeyUnlessItIsSetToDoNothing() {
    #expect(!FunctionKeySystemAction.doNothing.interceptsTaps)
    for action in [FunctionKeySystemAction.changeInputSource, .showEmojiAndSymbols, .startDictation, .startSpotlight] {
        #expect(action.interceptsTaps)
    }
    // An absent preference means the macOS default, which shows emojis and symbols.
    #expect(FunctionKeySystemAction.current().interceptsTaps || FunctionKeySystemAction.current() == .doNothing)
}

@Test @MainActor func theTapKeepsFunctionKeyTransitionsAndMarksAChordPressForPutBack() throws {
    let tap = FunctionKeyTap()
    func fnEvent(_ down: Bool) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Function), keyDown: down)!
        event.type = .flagsChanged
        event.flags = down ? .maskSecondaryFn : []
        return event
    }
    var presses = 0, releases = 0
    tap.onPress = { presses += 1 }
    tap.onRelease = { releases += 1 }
    let proxy: CGEventTapProxy? = nil
    #expect(tap.handle(proxy, .flagsChanged, fnEvent(true)) == nil)
    #expect(tap.handle(proxy, .flagsChanged, fnEvent(false)) == nil)
    #expect(presses == 1 && releases == 1)
    // A key during the hold makes it a chord and asks for the press to be put back.
    #expect(tap.handle(proxy, .flagsChanged, fnEvent(true)) == nil)
    let backspace = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Delete), keyDown: true)!
    #expect(tap.handle(proxy, .keyDown, backspace) != nil)
    #expect(tap.heldDownPutBack)
    #expect(tap.handle(proxy, .flagsChanged, fnEvent(false)) != nil)
    #expect(!tap.heldDownPutBack)
    #expect(presses == 2 && releases == 2)
}

@Test func triggersRoundTripThroughCoding() throws {
    var settings = AppSettings()
    settings.pushToTalkTriggers = [.keyboard(.fnControl), .mouse(button: 4)]
    settings.handsFreeTriggers = [.keyboard(.optionSpace), .mouse(button: 3)]
    let data = try JSONEncoder().encode(settings)
    let restored = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(restored.pushToTalkTriggers == [.keyboard(.fnControl), .mouse(button: 4)])
    #expect(restored.handsFreeTriggers == [.keyboard(.optionSpace), .mouse(button: 3)])
}

@Test func freshSettingsStartWithOptionSpaceForPushToTalk() {
    let settings = AppSettings()
    #expect(settings.pushToTalkTriggers == [.keyboard(.optionSpace)])
    #expect(settings.handsFreeTriggers.isEmpty)
    #expect(settings.primaryShortcut == .optionSpace)
    #expect(settings.primaryShortcutIsHeld)
}

@Test func thePrimaryShortcutKnowsWhetherItIsHeld() {
    var settings = AppSettings()
    settings.pushToTalkTriggers = [.mouse(button: 3)]
    settings.handsFreeTriggers = [.keyboard(.optionSpace)]
    #expect(settings.primaryShortcut == .optionSpace)
    #expect(!settings.primaryShortcutIsHeld)
}

@Test func aLegacyToggleShortcutBecomesHandsFree() throws {
    let restored = try decodeLegacySettings(mode: "toggle")
    #expect(restored.pushToTalkTriggers.isEmpty)
    #expect(restored.handsFreeTriggers == [.keyboard(.optionSpace)])
    #expect(restored.primaryShortcut == .optionSpace)
}

@Test func aLegacyHoldShortcutBecomesPushToTalk() throws {
    let restored = try decodeLegacySettings(mode: "hold")
    #expect(restored.pushToTalkTriggers == [.keyboard(.optionSpace)])
    #expect(restored.handsFreeTriggers.isEmpty)
}

@Test func aLegacyWorkspaceWithoutAModeBecomesPushToTalk() throws {
    let restored = try decodeLegacySettings(mode: nil)
    #expect(restored.pushToTalkTriggers == [.keyboard(.optionSpace)])
    #expect(restored.handsFreeTriggers.isEmpty)
}

/// Encodes today's settings, strips the trigger lists and restores the old `shortcut` and `dictationMode` keys.
private func decodeLegacySettings(mode: String?) throws -> AppSettings {
    let data = try JSONEncoder().encode(AppSettings())
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "pushToTalkTriggers")
    object.removeValue(forKey: "handsFreeTriggers")
    object["shortcut"] = ["keyCode": 49, "modifiers": 2048, "key": "Space"]
    if let mode { object["dictationMode"] = mode }
    return try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func doubleTapRecognizesTwoQuickTaps() {
    var tracker = DoubleTapTracker()
    let start = Date(timeIntervalSince1970: 1_000)
    tracker.press(start)
    #expect(tracker.release(start.addingTimeInterval(0.1)) == .firstTap)
    tracker.press(start.addingTimeInterval(0.25))
    #expect(tracker.release(start.addingTimeInterval(0.35)) == .secondTap)
    // A finished double-tap leaves nothing pending.
    tracker.press(start.addingTimeInterval(2))
    #expect(tracker.release(start.addingTimeInterval(2.1)) == .firstTap)
}

@Test func aLongHoldIsNeverATap() {
    var tracker = DoubleTapTracker()
    let start = Date(timeIntervalSince1970: 1_000)
    tracker.press(start)
    #expect(tracker.release(start.addingTimeInterval(DoubleTapTracker.tapLimit + 0.01)) == .longPress)
    // A release without a pending press says nothing about taps.
    #expect(tracker.release(start.addingTimeInterval(1)) == .longPress)
    tracker.press(start.addingTimeInterval(2))
    #expect(tracker.release(start.addingTimeInterval(2.1)) == .firstTap)
}

@Test func aGapPastTheWindowStartsANewTap() {
    var tracker = DoubleTapTracker()
    let start = Date(timeIntervalSince1970: 1_000)
    tracker.press(start)
    _ = tracker.release(start.addingTimeInterval(0.1))
    tracker.press(start.addingTimeInterval(0.1 + DoubleTapTracker.window + 0.01))
    _ = tracker.release(start.addingTimeInterval(0.2 + DoubleTapTracker.window + 0.01))
    // The gap put the first tap out of reach, so this one stands alone and a fresh pair can still follow.
    tracker.press(start.addingTimeInterval(0.3 + DoubleTapTracker.window + 0.01))
    #expect(tracker.release(start.addingTimeInterval(0.4 + DoubleTapTracker.window + 0.01)) == .secondTap)
}

@Test func twoTapsJustInsideTheWindowCount() {
    var tracker = DoubleTapTracker()
    let start = Date(timeIntervalSince1970: 1_000)
    tracker.press(start)
    _ = tracker.release(start.addingTimeInterval(0.1))
    tracker.press(start.addingTimeInterval(0.1 + DoubleTapTracker.window - 0.1))
    #expect(tracker.release(start.addingTimeInterval(0.1 + DoubleTapTracker.window - 0.01)) == .secondTap)
}

@Test func resettingClearsAPendingTap() {
    var tracker = DoubleTapTracker()
    let start = Date(timeIntervalSince1970: 1_000)
    tracker.press(start)
    _ = tracker.release(start.addingTimeInterval(0.1))
    tracker.reset()
    tracker.press(start.addingTimeInterval(0.15))
    // The forgotten first tap can't turn this into a double-tap.
    #expect(tracker.release(start.addingTimeInterval(0.25)) == .firstTap)
}

@Test func theLegacyMirrorFollowsTheTriggerLists() {
    var settings = AppSettings()
    settings.pushToTalkTriggers = []
    settings.handsFreeTriggers = [.keyboard(.fnControl)]
    settings.syncLegacyShortcut()
    #expect(settings.shortcut == .fnControl)
    #expect(settings.dictationMode == .toggle)
    settings.pushToTalkTriggers = [.keyboard(.optionSpace)]
    settings.handsFreeTriggers = []
    settings.syncLegacyShortcut()
    #expect(settings.shortcut == .optionSpace)
    #expect(settings.dictationMode == .hold)
}

@Test @MainActor func applyingTriggersSavesAndResetRestoresTheDefault() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LocalStore(directory: folder)
    let model = AppModel(store: store, startsServices: false)
    let f19 = try #require(DictationShortcut(keyCode: 103, modifiers: [], key: "F19"))
    model.applyDictationTriggers(pushToTalk: [.keyboard(f19)], handsFree: [.mouse(button: 4)])
    #expect(model.settings.pushToTalkTriggers == [.keyboard(f19)])
    #expect(model.settings.handsFreeTriggers == [.mouse(button: 4)])
    #expect(try store.load().settings.pushToTalkTriggers == [.keyboard(f19)])
    #expect(try store.load().settings.handsFreeTriggers == [.mouse(button: 4)])
    model.resetDictationTriggers()
    #expect(model.settings.pushToTalkTriggers == [.keyboard(.optionSpace)])
    #expect(model.settings.handsFreeTriggers.isEmpty)
}

@Test @MainActor func aTriggerAlreadyUsedByAnotherFeatureIsRejected() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LocalStore(directory: folder)
    let model = AppModel(store: store, startsServices: false)
    model.settings.formatShortcut = .fnControl
    model.applyDictationTriggers(pushToTalk: [.keyboard(.optionSpace)], handsFree: [.keyboard(.fnControl)])
    #expect(model.settings.handsFreeTriggers.isEmpty)
    #expect(try store.load().settings.handsFreeTriggers.isEmpty)
}

@Test @MainActor func everyRegisteredTriggerAnswersPressesAndReleases() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    let f19 = try #require(DictationShortcut(keyCode: 103, modifiers: [], key: "F19"))
    model.applyDictationTriggers(pushToTalk: [.keyboard(f19)], handsFree: [.keyboard(.optionSpace)])
    // A trigger whose listener carries no handlers would swallow presses silently.
    for entry in model.pushToTalkShortcuts + model.handsFreeShortcuts {
        #expect(entry.shortcut.onPress != nil && entry.shortcut.onRelease != nil, "unwired trigger \(entry.trigger.displayName)")
    }
    #expect(model.functionTapShortcut.onPress != nil && model.functionTapShortcut.onRelease != nil)
}

@Test @MainActor func theSameTriggerCantBeInBothLists() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LocalStore(directory: folder)
    let model = AppModel(store: store, startsServices: false)
    // The whole application is atomic: a duplicate mouse button rejects both lists, leaving the defaults.
    model.applyDictationTriggers(pushToTalk: [.keyboard(.optionSpace), .mouse(button: 4)], handsFree: [.mouse(button: 4)])
    #expect(model.settings.handsFreeTriggers.isEmpty)
    #expect(model.settings.pushToTalkTriggers == [.keyboard(.optionSpace)])
}

@Test @MainActor func theFixedFunctionTapCannotBeAddedToHandsFree() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LocalStore(directory: folder)
    let model = AppModel(store: store, startsServices: false)
    model.applyDictationTriggers(pushToTalk: [.keyboard(.optionSpace)], handsFree: [.keyboard(.functionTap)])
    #expect(model.settings.handsFreeTriggers.isEmpty)
    #expect(model.settings.pushToTalkTriggers == [.keyboard(.optionSpace)])
    #expect(try store.load().settings.handsFreeTriggers.isEmpty)
}
