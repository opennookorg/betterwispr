import AppKit
import BetterWisprCore
import Carbon.HIToolbox
import SwiftUI

/// The sheet for choosing push-to-talk, hands-free and the fixed double-tap fn trigger.
struct ShortcutsDialog: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Which list a capture edits; `index` nil means the capture adds a new trigger.
    private struct Target: Equatable {
        enum List: Equatable { case pushToTalk, handsFree }
        let list: List
        let index: Int?
    }

    @State private var target: Target?
    @State private var held: ShortcutModifiers = []
    @State private var modifierCandidate: DictationShortcut?
    @State private var monitor: Any?
    @State private var recorderID = UUID()

    private var isCapturing: Bool { target != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Dictation shortcuts"))
                    .font(.title2.weight(.semibold))
                Text(L10n.tr("Choose your shortcuts for starting dictation."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(.pushToTalk, title: L10n.tr("Push to talk"), caption: L10n.tr("Hold to say something short."),
                            triggers: model.settings.pushToTalkTriggers)
                    section(.handsFree, title: L10n.tr("Hands-free mode"),
                            caption: L10n.tr("Dictate hands-free by pressing this hotkey to start and stop."),
                            triggers: model.settings.handsFreeTriggers, showsDoubleTap: true)
                }
                .padding(2)
            }
            HStack {
                Button(L10n.tr("Reset to default")) {
                    stop()
                    model.resetDictationTriggers()
                }
                Spacer()
                Button(L10n.tr("Done")) { stop(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560, height: 520)
        .onDisappear(perform: stop)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in
            // Coming back from System Settings means Accessibility may have just been granted.
            model.refreshPermissions()
        }
        .onChange(of: model.capturingRecorder) { _, recorder in
            if recorder != recorderID { stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    @ViewBuilder
    private func section(_ list: Target.List, title: String, caption: String, triggers: [DictationTrigger], showsDoubleTap: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    if showsDoubleTap {
                        doubleTapRow
                        if !triggers.isEmpty || capturingAdds(to: list) { RowDivider() }
                    }
                    ForEach(Array(triggers.enumerated()), id: \.offset) { index, trigger in
                        if index > 0 || showsDoubleTap { RowDivider() }
                        triggerRow(trigger, list: list, index: index)
                    }
                    if capturingAdds(to: list) {
                        RowDivider()
                        captureRow
                    } else {
                        RowDivider()
                        addRow(list)
                    }
                }
            }
            if showsDoubleTap {
                // Accessibility hears the key; Input Monitoring delivers its event-tap events.
                if !model.accessibilityGranted {
                    footnote(L10n.tr("Double-tap fn needs Accessibility to hear the function key alone."),
                             allow: { model.requestAccessibility() },
                             help: L10n.tr("Allow BetterWispr to use Accessibility"))
                } else if !model.inputMonitoringGranted {
                    footnote(L10n.tr("Hearing the function key at the event level needs Input Monitoring, so double-tap fn can take its taps away from macOS."),
                             allow: { model.requestInputMonitoring() },
                             help: L10n.tr("Allow BetterWispr to hear keyboard events"))
                } else if model.functionKeySystemAction.interceptsTaps {
                    footnote(L10n.tr("Double-tap fn is always on. BetterWispr takes lone taps of the 🌐 key away from macOS, so emojis and its dictation don't appear."))
                } else {
                    footnote(L10n.tr("Double-tap fn is always on."))
                }
            }
            if list == .pushToTalk, !model.accessibilityGranted, triggers.contains(where: \.needsAccessibility) {
                footnote(L10n.tr("A trigger that is only a modifier key, such as ⌥, needs Accessibility."),
                         allow: { model.requestAccessibility() },
                         help: L10n.tr("Allow BetterWispr to use Accessibility"))
            }
        }
    }

    /// A one-line footnote with a grant button when a permission is missing.
    @ViewBuilder
    private func footnote(_ text: String, allow: (() -> Void)? = nil, help: String? = nil) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let allow {
                Button(L10n.tr("Allow…"), action: allow)
                    .help(help ?? L10n.tr("Allow BetterWispr to use Accessibility"))
            }
        }
        .padding(.horizontal, 4)
    }

    /// The fixed hands-free trigger: double-tapping the function key toggles dictation and can't be changed or removed.
    private var doubleTapRow: some View {
        HStack(spacing: 8) {
            TriggerChip(label: L10n.tr("Double-tap fn"), spoken: L10n.tr("Double-tap the function key"))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func triggerRow(_ trigger: DictationTrigger, list: Target.List, index: Int) -> some View {
        HStack(spacing: 8) {
            if capturingReplaces(list: list, index: index) {
                Text(held.isEmpty ? L10n.tr("Type shortcut…") : held.symbols + " …")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor.opacity(0.4)))
            } else {
                TriggerChip(trigger: trigger)
                Spacer()
                Button { start(Target(list: list, index: index)) } label: { Image(systemName: "pencil") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(L10n.tr("Change %@", String(trigger.displayName)))
                    .accessibilityLabel(L10n.tr("Change %@", String(trigger.spokenName)))
                Button { remove(trigger, from: list) } label: { Image(systemName: "trash") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(L10n.tr("Remove %@", String(trigger.displayName)))
                    .accessibilityLabel(L10n.tr("Remove %@", String(trigger.spokenName)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
    }

    private var captureRow: some View {
        HStack(spacing: 8) {
            Text(held.isEmpty ? L10n.tr("Type shortcut…") : held.symbols + " …")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor.opacity(0.4)))
                .accessibilityLabel(L10n.tr("%@, waiting for keys", L10n.tr("Add a shortcut")))
            Text(L10n.tr("A key combination, a modifier alone or a side mouse button. Esc cancels."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
    }

    private func addRow(_ list: Target.List) -> some View {
        HStack {
            Button { start(Target(list: list, index: nil)) } label: { Image(systemName: "plus") }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(L10n.tr("Add a shortcut"))
                .accessibilityLabel(L10n.tr("Add a shortcut"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func capturingAdds(to list: Target.List) -> Bool { target?.list == list && target?.index == nil }
    private func capturingReplaces(list: Target.List, index: Int) -> Bool { target?.list == list && target?.index == index }

    // MARK: Capture

    private func start(_ newTarget: Target) {
        stop()
        held = []
        modifierCandidate = nil
        target = newTarget
        model.beginKeyCapture(recorderID)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { event in
            MainActor.assumeIsolated { capture(event) }
            return event.type == .keyDown || event.type == .flagsChanged || recordingButton(event) ? nil : event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        target = nil
        held = []
        modifierCandidate = nil
        model.endKeyCapture(recorderID)
    }

    private func recordingButton(_ event: NSEvent) -> Bool {
        event.type == .otherMouseDown && DictationTrigger.recordableMouseButtons.contains(event.buttonNumber)
    }

    private func capture(_ event: NSEvent) {
        if event.type == .otherMouseDown {
            if recordingButton(event) { apply(.mouse(button: event.buttonNumber)) }
            return
        }
        let flags = event.modifierFlags
        var modifiers = ShortcutModifiers(KeyCapture.modifierFlags.filter { flags.contains($0.flag) }.map(\.modifier))
        // Arrow and F-key presses also carry the Fn flag, so only track Fn from its own key transitions.
        guard event.type == .keyDown else {
            if flags.contains(.function) { modifiers.insert(.function) }
            return modifiersChanged(to: modifiers, keyCode: Int(event.keyCode))
        }
        modifierCandidate = nil
        if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty { return stop() }
        let key = KeyCapture.keyNames[Int(event.keyCode)] ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        guard let shortcut = DictationShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key) else {
            return NSSound.beep()
        }
        apply(.keyboard(shortcut))
    }

    private func modifiersChanged(to modifiers: ShortcutModifiers, keyCode: Int) {
        if let candidate = modifierCandidate, candidate.keyCode == UInt32(keyCode), modifiers.isEmpty {
            return apply(.keyboard(candidate))
        }
        modifierCandidate = nil
        if held.isEmpty, !modifiers.isEmpty, modifiers == DictationShortcut.modifier(for: UInt32(keyCode)), let key = KeyCapture.keyNames[keyCode] {
            modifierCandidate = DictationShortcut(keyCode: UInt32(keyCode), modifiers: [], key: key)
        }
        held = modifiers
    }

    private func apply(_ trigger: DictationTrigger) {
        var pushToTalk = model.settings.pushToTalkTriggers
        var handsFree = model.settings.handsFreeTriggers
        switch target?.list {
        case .pushToTalk:
            if let index = target?.index, pushToTalk.indices.contains(index) { pushToTalk[index] = trigger } else { pushToTalk.append(trigger) }
        case .handsFree:
            if let index = target?.index, handsFree.indices.contains(index) { handsFree[index] = trigger } else { handsFree.append(trigger) }
        case nil: return
        }
        model.applyDictationTriggers(pushToTalk: pushToTalk, handsFree: handsFree)
        stop()
    }

    private func remove(_ trigger: DictationTrigger, from list: Target.List) {
        var pushToTalk = model.settings.pushToTalkTriggers
        var handsFree = model.settings.handsFreeTriggers
        switch list {
        case .pushToTalk: pushToTalk.removeAll { $0 == trigger }
        case .handsFree: handsFree.removeAll { $0 == trigger }
        }
        model.applyDictationTriggers(pushToTalk: pushToTalk, handsFree: handsFree)
    }
}

/// A rounded key-cap style label for a dictation trigger, such as “⌥ Space” or “Mouse 5”.
struct TriggerChip: View {
    init(trigger: DictationTrigger) {
        self.init(label: trigger.displayName, spoken: trigger.spokenName)
    }

    init(label: String, spoken: String) {
        self.label = label
        self.spoken = spoken
    }

    private let label: String
    private let spoken: String

    var body: some View {
        Text(label)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .accessibilityLabel(spoken)
    }
}

/// Names and modifier mapping for the keys a shortcut capture listens for.
enum KeyCapture {
    static let modifierFlags: [(flag: NSEvent.ModifierFlags, modifier: ShortcutModifiers)] = [
        (.control, .control), (.option, .option), (.shift, .shift), (.command, .command)
    ]

    static let keyNames: [Int: String] = [
        kVK_Control: "Left Control", kVK_RightControl: "Right Control", kVK_Option: "Left Option", kVK_RightOption: "Right Option",
        kVK_Shift: "Left Shift", kVK_RightShift: "Right Shift", kVK_Command: "Left Command", kVK_RightCommand: "Right Command",
        kVK_Function: "Fn", kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_ForwardDelete: "Forward Delete",
        kVK_Escape: "Esc", kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
    ]
}
