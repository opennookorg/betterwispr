import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import BetterWisprCore

@Test func aSendKeystrokeTakesABareKeyButNotAModifierAlone() {
    #expect(SendKeystroke(keyCode: UInt32(kVK_Return), modifiers: [], key: "Return") == .return)
    #expect(SendKeystroke(keyCode: UInt32(kVK_Tab), modifiers: [], key: "Tab") != nil)
    #expect(SendKeystroke(keyCode: UInt32(kVK_Return), modifiers: [.command], key: "Return") != nil)
    #expect(SendKeystroke(keyCode: UInt32(kVK_ANSI_K), modifiers: [.control, .option], key: "K") != nil)
    // A modifier submits nothing on its own, Fn isn't a flag a posted event can hold, and an unnamed key can't be shown.
    #expect(SendKeystroke(keyCode: UInt32(kVK_Command), modifiers: [], key: "Left Command") == nil)
    #expect(SendKeystroke(keyCode: UInt32(kVK_Function), modifiers: [], key: "Fn") == nil)
    #expect(SendKeystroke(keyCode: UInt32(kVK_Return), modifiers: [.function], key: "Return") == nil)
    #expect(SendKeystroke(keyCode: UInt32(kVK_Return), modifiers: [], key: "") == nil)
}

@Test func aSendKeystrokeIsNamedTheWayTheRestOfTheShortcutUIIs() {
    #expect(SendKeystroke.return.displayName == "Return")
    #expect(SendKeystroke.return.spokenName == "Return")
    let commandReturn = try? #require(SendKeystroke(keyCode: UInt32(kVK_Return), modifiers: [.command, .shift], key: "Return"))
    #expect(commandReturn?.displayName == "⇧⌘ Return")
    #expect(commandReturn?.spokenName == "Shift Command Return")
}

@Test func sendRulesAreEmptyByDefaultAndSurviveASaveLoadRound() throws {
    let saved = #"{"autoPaste":true,"language":"auto","launchAtLogin":false,"saveHistory":true,"selectedModelID":"parakeet-v3","showCapsule":true,"silenceThreshold":0.002}"#
    let old = try JSONDecoder().decode(AppSettings.self, from: Data(saved.utf8))
    #expect(old.sendRules.isEmpty && !old.sendsAfterPaste)
    var settings = AppSettings()
    let keystroke = try #require(SendKeystroke(keyCode: UInt32(kVK_Return), modifiers: [.command], key: "Return"))
    settings.sendRules = [AppSendRule(bundleID: "org.mikelyons.harness", keystroke: keystroke)]
    let loaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(loaded.sendRules == settings.sendRules)
    #expect(loaded.sendRules.first?.keystroke == keystroke)
}

@Test @MainActor func aFileSavedWithSendToClaudeBeforeRulesKeepsItsSendAndOnlySendsToAClaudePrompt() async throws {
    let saved = #"{"autoPaste":true,"language":"auto","launchAtLogin":false,"saveHistory":true,"selectedModelID":"parakeet-v3","showCapsule":true,"silenceThreshold":0.002,"sendToClaude":true,"sendDelayMilliseconds":250}"#
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(saved.utf8))
    #expect(settings.sendToClaude && settings.sendsAfterPaste && settings.sendRules.isEmpty)
    #expect(settings.sendDelay == .milliseconds(250))
    #expect(await SendAfterPaste.keystroke(for: .current, settings: settings) == nil)
}

@Test @MainActor func onlyARuleSendsWithoutARecordedField() {
    let field = AXUIElementCreateApplication(1)
    let other = AXUIElementCreateApplication(2)
    #expect(!FocusedAppIntegration.sendFocusMatches(nil, current: field, requiringRecorded: true))
    #expect(FocusedAppIntegration.sendFocusMatches(nil, current: field, requiringRecorded: false))
    #expect(FocusedAppIntegration.sendFocusMatches(field, current: field, requiringRecorded: true))
    #expect(!FocusedAppIntegration.sendFocusMatches(field, current: other, requiringRecorded: false))
    #expect(!FocusedAppIntegration.sendFocusMatches(field, current: nil, requiringRecorded: false))
}

@Test @MainActor func aKeyCodeOutsideTheKeyboardRangeBuildsNoEvents() throws {
    let keystroke = try #require(SendKeystroke(keyCode: 70_000, modifiers: [], key: "X"))
    #expect(FocusedAppIntegration.keystrokeEvents(for: keystroke) == nil)
}

@Test func aRuleOnlyCountsAsSendingWhileItIsOn() {
    var settings = AppSettings()
    #expect(!settings.sendsAfterPaste)
    settings.sendRules = [AppSendRule(bundleID: "org.mikelyons.harness", isEnabled: false)]
    #expect(!settings.sendsAfterPaste)
    settings.sendRules[0].isEnabled = true
    #expect(settings.sendsAfterPaste)
    settings.sendRules = []
    settings.sendToClaude = true
    #expect(settings.sendsAfterPaste)
}

@Test @MainActor func onlyAnEnabledRuleForTheFrontmostAppMatches() {
    var settings = AppSettings()
    settings.sendRules = [
        AppSendRule(bundleID: "org.mikelyons.harness", keystroke: .return),
        AppSendRule(bundleID: "com.tinyspeck.slackmacgap", keystroke: .return, isEnabled: false),
    ]
    #expect(SendAfterPaste.rule(for: "org.mikelyons.harness", settings: settings)?.keystroke == .return)
    #expect(SendAfterPaste.rule(for: "com.tinyspeck.slackmacgap", settings: settings) == nil)
    #expect(SendAfterPaste.rule(for: "com.apple.Terminal", settings: settings) == nil)
    #expect(SendAfterPaste.rule(for: nil, settings: settings) == nil)
}

@Test @MainActor func aScriptableTerminalNeverGetsARuleEvenIfOneWasSaved() {
    #expect(ClaudePrompt.scriptableTerminals == ["com.apple.Terminal", "com.googlecode.iterm2"])
    var settings = AppSettings()
    for terminal in ClaudePrompt.scriptableTerminals {
        #expect(!SendAfterPaste.allowsRule(for: terminal))
        settings.sendRules = [AppSendRule(bundleID: terminal, keystroke: .return)]
        #expect(SendAfterPaste.rule(for: terminal, settings: settings) == nil)
    }
    #expect(SendAfterPaste.allowsRule(for: "org.mikelyons.harness"))
}

@Test @MainActor func keysThatQuitCloseOrEraseAreRefused() throws {
    func refusal(_ keyCode: Int, _ modifiers: ShortcutModifiers, _ key: String) throws -> String? {
        SendAfterPaste.refusal(of: try #require(SendKeystroke(keyCode: UInt32(keyCode), modifiers: modifiers, key: key)), shortcut: .optionSpace)
    }
    #expect(try refusal(kVK_ANSI_Q, [.command], "Q") == "⌘ Q could quit the app or close its window.")
    #expect(try refusal(kVK_ANSI_W, [.command], "W") == "⌘ W could quit the app or close its window.")
    #expect(try refusal(kVK_ANSI_Q, [.command, .shift], "Q") != nil)
    #expect(try refusal(kVK_ANSI_W, [.command, .option], "W") != nil)
    let azertyQ = try refusal(kVK_ANSI_A, [.command], "Q")
    #expect(azertyQ != nil)
    #expect(try refusal(kVK_Delete, [], "Delete") == "Delete would erase what you dictated.")
    #expect(try refusal(kVK_ForwardDelete, [], "Forward Delete") == "Forward Delete would erase what you dictated.")
    #expect(try refusal(kVK_Delete, [.command], "Delete") != nil)

    #expect(try refusal(kVK_ANSI_Q, [], "Q") == nil)
    #expect(try refusal(kVK_ANSI_W, [.control], "W") == nil)
    #expect(try refusal(kVK_Return, [.command], "Return") == nil)
    #expect(try refusal(kVK_Tab, [], "Tab") == nil)
}

@Test @MainActor func aKeyThatWouldHitTheDictationShortcutIsRefused() throws {
    let optionSpace = try #require(SendKeystroke(keyCode: UInt32(kVK_Space), modifiers: [.option], key: "Space"))
    #expect(SendAfterPaste.refusal(of: optionSpace, shortcut: .optionSpace) == "⌥ Space clashes with your dictation shortcut, ⌥ Space.")
    let shiftOptionSpace = try #require(SendKeystroke(keyCode: UInt32(kVK_Space), modifiers: [.option, .shift], key: "Space"))
    #expect(SendAfterPaste.refusal(of: shiftOptionSpace, shortcut: .optionSpace) != nil)
    let controlSpace = try #require(SendKeystroke(keyCode: UInt32(kVK_Space), modifiers: [.control], key: "Space"))
    #expect(SendAfterPaste.refusal(of: controlSpace, shortcut: .optionSpace) == nil)
    let bareSpace = try #require(SendKeystroke(keyCode: UInt32(kVK_Space), modifiers: [], key: "Space"))
    #expect(SendAfterPaste.refusal(of: bareSpace, shortcut: .optionSpace) == nil)

    let leftCommand = try #require(DictationShortcut(keyCode: UInt32(kVK_Command), modifiers: [], key: "Left Command"))
    let rightCommand = try #require(DictationShortcut(keyCode: UInt32(kVK_RightCommand), modifiers: [], key: "Right Command"))
    let commandReturn = try #require(SendKeystroke(keyCode: UInt32(kVK_Return), modifiers: [.command], key: "Return"))
    #expect(SendAfterPaste.refusal(of: commandReturn, shortcut: leftCommand) != nil)
    #expect(SendAfterPaste.refusal(of: commandReturn, shortcut: rightCommand) == nil)
    #expect(SendAfterPaste.refusal(of: .return, shortcut: leftCommand) == nil)
}

@Test @MainActor func aSavedRuleThatIsNowRefusedKeepsItsKeyButDoesNotFire() throws {
    let harness = "org.mikelyons.harness"
    let commandQ = try #require(SendKeystroke(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.command], key: "Q"))
    var settings = AppSettings()
    settings.sendRules = [AppSendRule(bundleID: harness, keystroke: commandQ)]
    #expect(SendAfterPaste.rule(for: harness, settings: settings) == nil)
    let loaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(loaded.sendRules.first?.keystroke == commandQ)

    let commandReturn = try #require(SendKeystroke(keyCode: UInt32(kVK_Return), modifiers: [.command], key: "Return"))
    settings.sendRules = [AppSendRule(bundleID: harness, keystroke: commandReturn)]
    #expect(SendAfterPaste.rule(for: harness, settings: settings)?.keystroke == commandReturn)
    settings.shortcut = try #require(DictationShortcut(keyCode: UInt32(kVK_Return), modifiers: [.command], key: "Return"))
    #expect(SendAfterPaste.rule(for: harness, settings: settings) == nil)
}

@Test @MainActor func aBareKeystrokeIsPostedWithNoModifiersHeld() throws {
    let events = try #require(FocusedAppIntegration.keystrokeEvents(for: .return))
    #expect(events.count == 2)
    #expect(events.map(\.type) == [.keyDown, .keyUp])
    #expect(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Return) })
    // Modifiers still held from the dictation shortcut must not turn this into Option- or Shift-Return.
    #expect(events.allSatisfy { $0.flags.isEmpty })
}

@Test @MainActor func aModifierKeystrokeBracketsTheKeyWithFlagsChangedEvents() throws {
    let keystroke = try #require(SendKeystroke(keyCode: UInt32(kVK_Return), modifiers: [.command], key: "Return"))
    let events = try #require(FocusedAppIntegration.keystrokeEvents(for: keystroke))
    #expect(events.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
    #expect(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }
        == [Int64(kVK_Command), Int64(kVK_Return), Int64(kVK_Return), Int64(kVK_Command)])
    #expect(events.dropLast().allSatisfy { $0.flags.contains(.maskCommand) })
    // The last event releases Command, so nothing is left held in the target app.
    #expect(events.last?.flags.isEmpty == true)
}

@Test @MainActor func theGenericPosterReproducesTheCommandVThePastePathSends() throws {
    let commandV = try #require(SendKeystroke(keyCode: 9, modifiers: [.command], key: "V"))
    let generic = try #require(FocusedAppIntegration.keystrokeEvents(for: commandV))
    let paste = try #require(FocusedAppIntegration.pasteKeystroke())
    #expect(generic.map(\.type) == paste.map(\.type))
    #expect(generic.map(\.flags.rawValue) == paste.map(\.flags.rawValue))
    #expect(generic.map { $0.getIntegerValueField(.keyboardEventKeycode) }
        == paste.map { $0.getIntegerValueField(.keyboardEventKeycode) })
}

@Test @MainActor func eachModifierIsPressedAndReleasedInOrder() throws {
    let keystroke = try #require(SendKeystroke(keyCode: UInt32(kVK_Return), modifiers: [.control, .option, .shift, .command], key: "Return"))
    let events = try #require(FocusedAppIntegration.keystrokeEvents(for: keystroke))
    #expect(events.map(\.type) == [.flagsChanged, .flagsChanged, .flagsChanged, .flagsChanged,
                                   .keyDown, .keyUp,
                                   .flagsChanged, .flagsChanged, .flagsChanged, .flagsChanged])
    let keyDown = try #require(events.first { $0.type == .keyDown })
    #expect(keyDown.flags.isSuperset(of: [.maskControl, .maskAlternate, .maskShift, .maskCommand]))
    #expect(events.last?.flags.isEmpty == true)
}
