import AppKit
import BetterWisprCore
import Carbon.HIToolbox
import IOKit.hidsystem
import Testing
@testable import BetterWispr

@Test @MainActor func standaloneOptionDeliversOnePressAndReleaseForTheRecordedSide() throws {
    let listener = GlobalShortcut()
    let shortcut = try #require(DictationShortcut(keyCode: UInt32(kVK_Option), modifiers: [], key: "Left Option"))
    var transitions: [Bool] = []
    listener.onPress = { transitions.append(true) }
    listener.onRelease = { transitions.append(false) }
    let left = NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICELALTKEYMASK)).union(.option)
    let right = NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICERALTKEYMASK)).union(.option)

    func send(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) throws {
        let event = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                                                timestamp: 0, windowNumber: 0, context: nil, characters: "",
                                                charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(keyCode)))
        listener.handleModifierEvent(event, shortcut: shortcut)
    }

    try send(kVK_RightOption, right)
    try send(kVK_RightOption, [])
    try send(kVK_Option, left.union(.command))
    try send(kVK_Option, .command)
    #expect(transitions.isEmpty)

    try send(kVK_Option, left)
    try send(kVK_Option, left)
    try send(kVK_RightOption, left.union(right))
    try send(kVK_Option, right) // Releasing left must finish even while right is down.
    try send(kVK_RightOption, [])
    #expect(transitions == [true, false])

    try send(kVK_Option, left)
    try send(kVK_Option, .command) // Added modifiers must not swallow the release.
    #expect(transitions == [true, false, true, false])
    listener.unregister()
    try send(kVK_Option, [])
    #expect(transitions == [true, false, true, false])
}

@Test func escapeCancelsUnderTheModifiersStillHeldFromTheDictationShortcutExceptCommand() throws {
    let rightCommand = try #require(DictationShortcut(keyCode: UInt32(kVK_RightCommand), modifiers: [], key: "Right Command"))
    let f5 = try #require(DictationShortcut(keyCode: UInt32(kVK_F5), modifiers: [], key: "F5"))
    let optionEscape = try #require(DictationShortcut(keyCode: UInt32(kVK_Escape), modifiers: .option, key: "Esc"))
    let controlShiftD = try #require(DictationShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: [.control, .shift], key: "D"))
    let commandOptionD = try #require(DictationShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: [.command, .option], key: "D"))
    #expect(DictationShortcut.optionSpace.cancelModifiers == [[], .option])
    #expect(controlShiftD.cancelModifiers == [[], [.control, .shift]])
    #expect(rightCommand.cancelModifiers == [[]])
    #expect(commandOptionD.cancelModifiers == [[]])
    #expect(f5.cancelModifiers == [[]])
    #expect(optionEscape.cancelModifiers == [[]])
    let fn = try #require(DictationShortcut(keyCode: UInt32(kVK_Function), modifiers: [], key: "Fn"))
    #expect(fn.cancelModifiers == [[]])
}

@Test @MainActor func eachShortcutAnswersOnlyItsOwnCarbonHotKey() throws {
    let dictation = GlobalShortcut()
    let cancel = GlobalShortcut(id: 2)
    var fired: [String] = []
    dictation.onPress = { fired.append("dictation press") }
    dictation.onRelease = { fired.append("dictation release") }
    cancel.onPress = { fired.append("cancel press") }
    cancel.onRelease = { fired.append("cancel release") }

    func send(_ kind: Int, signature: OSType = 0x42575350, id: UInt32) throws -> [OSStatus] {
        var event: EventRef?
        try #require(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kind), 0, EventAttributes(kEventAttributeNone), &event) == noErr)
        let created = try #require(event)
        defer { ReleaseEvent(created) }
        var hotKey = EventHotKeyID(signature: signature, id: id)
        try #require(SetEventParameter(created, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       MemoryLayout<EventHotKeyID>.size, &hotKey) == noErr)
        return [dictation.handle(created), cancel.handle(created)]
    }

    let handled = OSStatus(noErr)
    let passed = OSStatus(eventNotHandledErr)
    #expect(try send(kEventHotKeyPressed, id: 2) == [passed, handled])
    #expect(fired == ["cancel press"])
    #expect(try send(kEventHotKeyPressed, id: 1) == [handled, passed])
    #expect(try send(kEventHotKeyReleased, id: 1) == [handled, passed])
    #expect(fired == ["cancel press", "dictation press", "dictation release"])
    #expect(try send(kEventHotKeyPressed, signature: 0x4F544852, id: 1) == [passed, passed])
    #expect(try send(kEventHotKeyPressed, signature: 0x4F544852, id: 2) == [passed, passed])
    #expect(fired == ["cancel press", "dictation press", "dictation release"])
}

@Test @MainActor func aShortcutThatGoesAwayFreesItsKeyForTheNextOne() throws {
    let f16 = try #require(DictationShortcut(keyCode: UInt32(kVK_F16), modifiers: [], key: "F16"))
    for _ in 0..<20 {
        try GlobalShortcut(id: 8).register(f16)
    }
}

@Test @MainActor func standaloneFnDeliversPressAndReleaseOnlyWhenAlone() throws {
    let listener = GlobalShortcut()
    let shortcut = try #require(DictationShortcut(keyCode: UInt32(kVK_Function), modifiers: [], key: "Fn"))
    var transitions: [Bool] = []
    listener.onPress = { transitions.append(true) }
    listener.onRelease = { transitions.append(false) }

    func send(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) throws {
        let event = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                                                timestamp: 0, windowNumber: 0, context: nil, characters: "",
                                                charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(keyCode)))
        listener.handleModifierEvent(event, shortcut: shortcut)
    }

    try send(kVK_Function, [.function, .command])
    try send(kVK_Function, .command)
    #expect(transitions.isEmpty)

    try send(kVK_Function, .function)
    try send(kVK_Function, [])
    #expect(transitions == [true, false])
}

@Test @MainActor func cancelShortcutRefusesTheDictationShortcutAndAModifierAloneThenSavesAKeyAndClears() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    let leftOption = try #require(DictationShortcut(keyCode: UInt32(kVK_Option), modifiers: [], key: "Left Option"))
    let fn = try #require(DictationShortcut(keyCode: UInt32(kVK_Function), modifiers: [], key: "Fn"))
    let f19 = try #require(DictationShortcut(keyCode: UInt32(kVK_F19), modifiers: [], key: "F19"))

    model.changeCancelShortcut(model.settings.shortcut)
    #expect(model.settings.cancelShortcut == nil)
    model.changeCancelShortcut(leftOption)
    #expect(model.settings.cancelShortcut == nil)
    model.changeCancelShortcut(fn)
    #expect(model.settings.cancelShortcut == nil)
    model.changeCancelShortcut(f19)
    #expect(model.settings.cancelShortcut == f19)
    model.changeShortcut(f19)
    #expect(model.settings.shortcut == .optionSpace)
    model.changeCancelShortcut(nil)
    #expect(model.settings.cancelShortcut == nil)
}

@Test @MainActor func selectedTextShortcutRefusesAModifierAloneAndTheOtherShortcutsThenHoldsAKeyUntilCleared() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    let leftOption = try #require(DictationShortcut(keyCode: UInt32(kVK_Option), modifiers: [], key: "Left Option"))
    let f17 = try #require(DictationShortcut(keyCode: UInt32(kVK_F17), modifiers: [], key: "F17"))
    let f18 = try #require(DictationShortcut(keyCode: UInt32(kVK_F18), modifiers: [], key: "F18"))
    let optionEscape = try #require(DictationShortcut(keyCode: UInt32(kVK_Escape), modifiers: [.option], key: "Esc"))
    let other = GlobalShortcut(id: 9)
    defer { other.unregister() }

    model.changeSelectedTextShortcut(leftOption)
    model.changeSelectedTextShortcut(optionEscape)
    model.changeSelectedTextShortcut(model.settings.shortcut)
    model.changeCancelShortcut(f17)
    model.changeSelectedTextShortcut(f17)
    #expect(model.settings.selectedTextShortcut == nil)

    model.changeSelectedTextShortcut(f18)
    #expect(model.settings.selectedTextShortcut == f18)
    #expect(AppModel(store: LocalStore(directory: folder), startsServices: false).settings.selectedTextShortcut == f18)
    #expect(throws: ShortcutError.self) { try other.register(f18) }
    model.suspendShortcut()
    model.changeShortcut(f18)
    model.suspendShortcut()
    model.changeCancelShortcut(f18)
    #expect(model.settings.shortcut == .optionSpace)
    #expect(model.settings.cancelShortcut == f17)

    model.registerShortcut()
    #expect(throws: ShortcutError.self) { try other.register(f18) }
    model.changeSelectedTextShortcut(nil)
    #expect(model.settings.selectedTextShortcut == nil)
    #expect(AppModel(store: LocalStore(directory: folder), startsServices: false).settings.selectedTextShortcut == nil)
    try other.register(f18)
}
