import AppKit
import BetterWisprCore
import SwiftUI

struct ModesSection: View {
    let model: AppModel
    @State private var editing: WritingMode?

    var body: some View {
        SettingsSection(L10n.tr("Modes")) {
            ForEach(model.settings.modes) { mode in
                SettingRow(mode.name.isEmpty ? L10n.tr("Untitled mode") : mode.name, caption: summary(mode)) {
                    Button(L10n.tr("Edit…")) { editing = mode }
                    Toggle(L10n.tr("Use %@", String(mode.name)), isOn: enabled(mode))
                        .labelsHidden()
                        .controlSize(.small)
                }
                RowDivider()
            }
            HStack {
                Button(L10n.tr("Add Mode…"), systemImage: "plus") { editing = WritingMode() }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        } footer: {
            Text(L10n.tr("A mode changes cleanup and tone in the apps and websites it lists, or when you start or end a dictation with its trigger word. A trigger word wins over a website, and a website wins over an app. Websites are detected through Accessibility in supported browsers, and the address is used only on this Mac."))
        }
        .sheet(item: $editing) { mode in
            WritingModeEditor(model: model, mode: mode)
        }
    }

    private func summary(_ mode: WritingMode) -> String {
        let uses = mode.apps.map { AppChoice($0)?.name ?? $0 } + mode.websites + mode.triggerWords.map { "“\($0)”" }
        let changes = [
            mode.cleanup.map { L10n.tr("%@ cleanup", String($0.title)) },
            mode.tone.map { L10n.tr("%@ tone", String($0.title)) },
            mode.useScreenContext.map { $0 ? L10n.tr("screen context on") : L10n.tr("screen context off") },
        ].compactMap { $0 }
        let used = uses.isEmpty ? L10n.tr("Add an app, website or trigger word to use this mode.") : L10n.tr("Used for %@.", String(ListFormatter.localizedString(byJoining: uses)))
        let changed = ListFormatter.localizedString(byJoining: changes)
        return changed.isEmpty
            ? L10n.tr("%@ Keeps your default settings.", used)
            : L10n.tr("%@ Changes: %@.", used, changed)
    }

    private func enabled(_ mode: WritingMode) -> Binding<Bool> {
        Binding(get: { mode.isEnabled }, set: { isOn in
            guard let index = model.settings.modes.firstIndex(where: { $0.id == mode.id }) else { return }
            model.settings.modes[index].isEnabled = isOn
            model.saveSettings()
        })
    }
}

private struct WritingModeEditor: View {
    let model: AppModel
    @State var mode: WritingMode
    @State private var website = ""
    @State private var triggerWord = ""
    @State private var choices: [AppChoice] = []
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    private var isNew: Bool { !model.settings.modes.contains { $0.id == mode.id } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(L10n.tr("Name"), text: $mode.name, prompt: Text(L10n.tr("Code review")))
                } header: {
                    Text(isNew ? L10n.tr("Add mode") : L10n.tr("Edit mode"))
                }

                Section {
                    ForEach(mode.apps, id: \.self) { id in
                        HStack {
                            if let app = AppChoice(id) { app.label } else { Label(id, systemImage: "app.dashed") }
                            Spacer()
                            removeButton { mode.apps.removeAll { $0 == id } }
                        }
                    }
                    Menu(L10n.tr("Add App")) {
                        ForEach(choices.filter { !mode.apps.contains($0.id) }) { app in
                            Button { mode.apps.append(app.id) } label: { app.label }
                        }
                    }
                    .fixedSize()
                } header: {
                    Text(L10n.tr("Apps"))
                } footer: {
                    Text(L10n.tr("Lists apps that are open or that you dictated into recently."))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    entries(\.websites)
                    entryField(L10n.tr("Website"), text: $website, prompt: L10n.tr("github.com or mail.google.com/mail"), keyPath: \.websites)
                } header: {
                    Text(L10n.tr("Websites"))
                } footer: {
                    Text(L10n.tr("Works in Safari, Chrome, Arc, Brave, Edge and other supported browsers. BetterWispr reads the address through Accessibility when you start dictating, uses it only on this Mac to choose a mode, and never saves or sends it."))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    entries(\.triggerWords)
                    entryField(L10n.tr("Trigger word"), text: $triggerWord, prompt: L10n.tr("casual mode"), keyPath: \.triggerWords)
                } header: {
                    Text(L10n.tr("Trigger words"))
                } footer: {
                    Text(L10n.tr("Say a trigger word at the start or end of a dictation to use this mode. BetterWispr removes it from the text, so pick a phrase you wouldn’t otherwise start or end a sentence with."))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    Picker(L10n.tr("Cleanup"), selection: $mode.cleanup) {
                        Text(L10n.tr("Same as default (%@)", String(model.settings.cleanup.title))).tag(CleanupLevel?.none)
                        ForEach(CleanupLevel.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    Picker(L10n.tr("Tone"), selection: $mode.tone) {
                        Text(L10n.tr("Same as app")).tag(StyleTone?.none)
                        ForEach(StyleTone.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    if !mode.apps.isEmpty || !mode.websites.isEmpty {
                        Picker(L10n.tr("Screen context"), selection: $mode.useScreenContext) {
                            Text((model.settings.useScreenContext ? L10n.tr("Same as default (On)") : L10n.tr("Same as default (Off)"))).tag(Bool?.none)
                            Text(L10n.tr("On")).tag(Optional(true))
                            Text(L10n.tr("Off")).tag(Optional(false))
                        }
                    }
                    if (mode.cleanup ?? model.settings.cleanup) == .medium {
                        TextField(L10n.tr("Instructions"), text: instructions, prompt: Text("Use British spelling."), axis: .vertical)
                            .lineLimit(3...8)
                        Text(L10n.tr("English example"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L10n.tr("Writing"))
                } footer: {
                    Text(writingFooter)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !isNew {
                    Section {
                        Button(L10n.tr("Delete Mode"), role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? L10n.tr("Add Mode") : L10n.tr("Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 600, height: 640)
        .confirmationDialog(L10n.tr("Delete “%@”?", String(mode.name)), isPresented: $confirmingDelete) {
            Button(L10n.tr("Delete Mode"), role: .destructive) {
                model.settings.modes.removeAll { $0.id == mode.id }
                model.saveSettings()
                dismiss()
            }
        }
        .onAppear { choices = AppChoice.offered(recent: model.history.compactMap(\.appBundleID)) }
    }

    private var writingFooter: String {
        let screen = model.settings.recognizeScreenText
            ? L10n.tr("With Parakeet and the phrase booster, screen context is read on this Mac when you start dictating, so it follows this mode’s apps and websites, and the names in it fix misspelled English words. It may read the window from a screenshot because Read window text from the screen is on.")
            : L10n.tr("With Parakeet and the phrase booster, screen context is read on this Mac when you start dictating, so it follows this mode’s apps and websites, and the names in it fix misspelled English words.")
        guard (mode.cleanup ?? model.settings.cleanup) == .medium else { return L10n.tr("%@ Choose Medium cleanup to add instructions for your cleanup model.", String(screen)) }
        return L10n.tr("Instructions go to your cleanup model with each Medium dictation in this mode. %@ Medium also reads it and sends it to your cleanup model, which may be a cloud service, and a trigger word can turn that off but not on.", String(screen))
    }

    private var instructions: Binding<String> {
        Binding(get: { mode.instructions }, set: { mode.instructions = String($0.prefix(WritingMode.instructionLimit)) })
    }

    private func entries(_ keyPath: WritableKeyPath<WritingMode, [String]>) -> some View {
        ForEach(mode[keyPath: keyPath], id: \.self) { entry in
            HStack {
                Text(entry)
                Spacer()
                removeButton { mode[keyPath: keyPath].removeAll { $0 == entry } }
            }
        }
    }

    private func entryField(_ title: String, text: Binding<String>, prompt: String, keyPath: WritableKeyPath<WritingMode, [String]>) -> some View {
        let add = {
            mode[keyPath: keyPath] = Self.cleaned(mode[keyPath: keyPath] + [text.wrappedValue])
            text.wrappedValue = ""
        }
        return HStack {
            TextField(title, text: text, prompt: Text(prompt))
                .onSubmit(add)
            Button(L10n.tr("Add"), action: add)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(L10n.tr("Remove"), systemImage: "minus.circle", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
    }

    private func save() {
        mode.name = mode.name.trimmingCharacters(in: .whitespacesAndNewlines)
        mode.websites = Self.cleaned(mode.websites + [website])
        mode.triggerWords = Self.cleaned(mode.triggerWords + [triggerWord])
        if mode.apps.isEmpty && mode.websites.isEmpty { mode.useScreenContext = nil }
        mode.instructions = mode.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = model.settings.modes.firstIndex(where: { $0.id == mode.id }) {
            model.settings.modes[index] = mode
        } else {
            model.settings.modes.append(mode)
        }
        model.saveSettings()
        dismiss()
    }

    private static func cleaned(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return entries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

