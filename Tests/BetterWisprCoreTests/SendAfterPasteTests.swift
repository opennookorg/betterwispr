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

@Test func onlyAnEnabledRuleForTheFrontmostAppMatches() {
    let rules = [
        AppSendRule(bundleID: "org.mikelyons.harness", keystroke: .return),
        AppSendRule(bundleID: "com.tinyspeck.slackmacgap", keystroke: .return, isEnabled: false),
    ]
    #expect(SendAfterPaste.rule(for: "org.mikelyons.harness", in: rules)?.keystroke == .return)
    #expect(SendAfterPaste.rule(for: "com.tinyspeck.slackmacgap", in: rules) == nil)
    #expect(SendAfterPaste.rule(for: "com.apple.Terminal", in: rules) == nil)
    #expect(SendAfterPaste.rule(for: nil, in: rules) == nil)
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
