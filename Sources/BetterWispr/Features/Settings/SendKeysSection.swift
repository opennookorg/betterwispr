import AppKit
import BetterWisprCore
import Carbon.HIToolbox
import SwiftUI

/// Per-app send keys: the key BetterWispr presses after pasting into an app it can't recognize on its own, such as a
/// chat or agent client whose prompt field looks like any other text area.
struct SendKeysSection: View {
    let model: AppModel
    @State private var choices: [AppChoice] = []
    @State private var refusal: String?

    var body: some View {
        SettingsSection(L10n.tr("Send keys")) {
            ForEach(model.settings.sendRules) { rule in
                SettingRow(AppChoice(rule.bundleID)?.name ?? rule.bundleID, caption: caption(rule)) {
                    SendKeystrokeRecorder(model: model, rule: rule, refusal: $refusal)
                    Toggle(L10n.tr("Send in %@", AppChoice(rule.bundleID)?.name ?? rule.bundleID), isOn: enabled(rule))
                        .labelsHidden()
                        .controlSize(.small)
                    Button(L10n.tr("Remove"), systemImage: "minus.circle") { remove(rule) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(L10n.tr("Stop sending in this app"))
                }
                RowDivider()
            }
            HStack {
                Menu(L10n.tr("Add App…")) {
                    ForEach(choices.filter { choice in !model.settings.sendRules.contains { $0.bundleID == choice.id } }) { choice in
                        Button { add(choice.id) } label: { choice.label }
                    }
                }
                .fixedSize()
                .disabled(model.isBusy)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        } footer: {
            Text(L10n.tr("BetterWispr presses the key you record after pasting into these apps, so a dictation submits instead of sitting in the field. Lists apps that are open or that you dictated into recently. Unlike Send to Claude, a send key fires wherever you are in the app, so pick one that can’t do damage in the app’s other fields, and hold Shift while dictating to paste only. Terminal and iTerm2 aren’t listed, because a key there could run a shell command; Send to Claude covers Claude Code in them. Needs Accessibility."))
        }
        .onAppear { choices = AppChoice.offered(recent: model.history.compactMap(\.appBundleID)).filter { SendAfterPaste.allowsRule(for: $0.id) } }
        .onChange(of: refusal) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
    }

    private func caption(_ rule: AppSendRule) -> String {
        if model.capturingRecorder == rule.id, let refusal { return L10n.tr("%@ Press another key, or Esc to cancel.", refusal) }
        guard SendAfterPaste.allowsRule(for: rule.bundleID) else {
            return L10n.tr("Nothing is pressed here, because a key could run a shell command. Send to Claude covers Claude Code here.")
        }
        if let refused = SendAfterPaste.refusal(of: rule.keystroke, shortcut: model.settings.shortcut) {
            return L10n.tr("%@ Nothing is pressed until you record another key.", refused)
        }
        let key = L10n.tr("Presses %@ after pasting.", rule.keystroke.displayName)
        guard AppChoice(rule.bundleID) != nil else { return L10n.tr("%@ This app isn’t installed on this Mac.", key) }
        return rule.isEnabled ? key : L10n.tr("%@ Turned off.", key)
    }

    private func enabled(_ rule: AppSendRule) -> Binding<Bool> {
        Binding(get: { rule.isEnabled }, set: { isOn in
            guard let index = model.settings.sendRules.firstIndex(where: { $0.id == rule.id }) else { return }
            model.settings.sendRules[index].isEnabled = isOn
            model.saveSettings()
        })
    }

    private func add(_ bundleID: String) {
        model.settings.sendRules.append(AppSendRule(bundleID: bundleID))
        model.saveSettings()
        // Electron apps build their accessibility tree only once an assistive app asks, before the first dictation reads it.
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleID }
            .forEach(ClaudePrompt.enableManualAccessibility)
    }

    private func remove(_ rule: AppSendRule) {
        model.settings.sendRules.removeAll { $0.id == rule.id }
        model.saveSettings()
    }
}

/// Records the keystroke one app's rule sends, refusing a modifier alone and anything `SendAfterPaste.refusal` names.
private struct SendKeystrokeRecorder: View {
    let model: AppModel
    let rule: AppSendRule
    @Binding var refusal: String?
    @State private var monitor: Any?
    @State private var held: ShortcutModifiers = []

    private var isCapturing: Bool { monitor != nil }

    var body: some View {
        let button = Button {
            if isCapturing { stop() } else { start() }
        } label: {
            Text(isCapturing ? (held.isEmpty ? L10n.tr("Press a key…") : held.symbols + " …") : rule.keystroke.displayName)
                .frame(minWidth: 72)
                .contentTransition(.opacity)
        }
        .disabled(model.isBusy)
        .accessibilityLabel(isCapturing ? L10n.tr("Send key, waiting for a key") : L10n.tr("Send key, %@", rule.keystroke.spokenName))
        .accessibilityHint(L10n.tr("Click, then press the key that submits in this app, such as Return."))
        .help(isCapturing ? L10n.tr("Press the key that submits in this app. Esc cancels.") : L10n.tr("Record the key to press after pasting"))
        .onDisappear(perform: stop)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
        .onChange(of: model.capturingRecorder) { _, recorder in
            if recorder != rule.id { stop() }
        }

        if isCapturing { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
    }

    private func start() {
        held = []
        refusal = nil
        model.beginKeyCapture(rule.id)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            MainActor.assumeIsolated { capture(event) }
            return nil
        }
    }

    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        model.endKeyCapture(rule.id)
    }

    private func capture(_ event: NSEvent) {
        let flags = event.modifierFlags
        let modifiers = ShortcutModifiers(Self.modifierFlags.filter { flags.contains($0.flag) }.map(\.modifier))
        guard event.type == .keyDown else {
            held = modifiers
            return
        }
        // Esc leaves the recorded key as it is, so it can't be recorded on its own; ⇧Esc and ⌘Esc still can.
        if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty { return stop() }
        let key = Self.keyNames[Int(event.keyCode)] ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        guard let keystroke = SendKeystroke(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key) else {
            return NSSound.beep()
        }
        if let reason = SendAfterPaste.refusal(of: keystroke, shortcut: model.settings.shortcut) {
            refusal = reason
            return NSSound.beep()
        }
        if let index = model.settings.sendRules.firstIndex(where: { $0.id == rule.id }) {
            model.settings.sendRules[index].keystroke = keystroke
            model.saveSettings()
        }
        stop()
    }

    private static let modifierFlags: [(flag: NSEvent.ModifierFlags, modifier: ShortcutModifiers)] = [
        (.control, .control), (.option, .option), (.shift, .shift), (.command, .command)
    ]

    private static let keyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_ANSI_KeypadEnter: "Enter", kVK_Tab: "Tab", kVK_Delete: "Delete",
        kVK_ForwardDelete: "Forward Delete", kVK_Escape: "Esc", kVK_Home: "Home", kVK_End: "End",
        kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
    ]
}
