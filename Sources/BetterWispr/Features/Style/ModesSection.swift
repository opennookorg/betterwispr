import AppKit
import BetterWisprCore
import SwiftUI

struct ModesSection: View {
    let model: AppModel
    @State private var editing: WritingMode?

    var body: some View {
        SettingsSection("Modes") {
            ForEach(model.settings.modes) { mode in
                SettingRow(mode.name.isEmpty ? "Untitled mode" : mode.name, caption: summary(mode)) {
                    Button("Edit…") { editing = mode }
                    Toggle("Use \(mode.name)", isOn: enabled(mode))
                        .labelsHidden()
                        .controlSize(.small)
                }
                RowDivider()
            }
            HStack {
                Button("Add Mode…", systemImage: "plus") { editing = WritingMode() }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        } footer: {
            Text("A mode changes cleanup and tone in the apps and websites it lists, or when you start or end a dictation with its trigger word. A trigger word wins over a website, and a website wins over an app. Websites are detected through Accessibility in supported browsers, and the address is used only on this Mac.")
        }
        .sheet(item: $editing) { mode in
            WritingModeEditor(model: model, mode: mode)
        }
    }

    private func summary(_ mode: WritingMode) -> String {
        let uses = mode.apps.map { AppChoice($0)?.name ?? $0 } + mode.websites + mode.triggerWords.map { "“\($0)”" }
        let changes = [
            mode.cleanup.map { "\($0.title) cleanup" },
            mode.tone.map { "\($0.title) tone" },
            mode.useScreenContext.map { $0 ? "screen context on" : "screen context off" },
        ].compactMap { $0 }
        let used = uses.isEmpty ? "Add an app, website or trigger word to use this mode." : "Used for \(ListFormatter.localizedString(byJoining: uses))."
        let changed = ListFormatter.localizedString(byJoining: changes)
        return "\(used) \(changed.isEmpty ? "Keeps your default settings." : changed.prefix(1).uppercased() + changed.dropFirst() + ".")"
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
                    TextField("Name", text: $mode.name, prompt: Text("Code review"))
                } header: {
                    Text(isNew ? "Add mode" : "Edit mode")
                }

                Section {
                    ForEach(mode.apps, id: \.self) { id in
                        HStack {
                            if let app = AppChoice(id) { app.label } else { Label(id, systemImage: "app.dashed") }
                            Spacer()
                            removeButton { mode.apps.removeAll { $0 == id } }
                        }
                    }
                    Menu("Add App") {
                        ForEach(choices.filter { !mode.apps.contains($0.id) }) { app in
                            Button { mode.apps.append(app.id) } label: { app.label }
                        }
                    }
                    .fixedSize()
                } header: {
                    Text("Apps")
                } footer: {
                    Text("Lists apps that are open or that you dictated into recently.")
                }

                Section {
                    entries(\.websites)
                    entryField("Website", text: $website, prompt: "github.com or mail.google.com/mail", keyPath: \.websites)
                } header: {
                    Text("Websites")
                } footer: {
                    Text("Works in Safari, Chrome, Arc, Brave, Edge and other supported browsers. BetterWispr reads the address through Accessibility when you start dictating, uses it only on this Mac to choose a mode, and never saves or sends it.")
                }

                Section {
                    entries(\.triggerWords)
                    entryField("Trigger word", text: $triggerWord, prompt: "casual mode", keyPath: \.triggerWords)
                } header: {
                    Text("Trigger words")
                } footer: {
                    Text("Say a trigger word at the start or end of a dictation to use this mode. BetterWispr removes it from the text, so pick a phrase you wouldn’t otherwise start or end a sentence with.")
                }

                Section {
                    Picker("Cleanup", selection: $mode.cleanup) {
                        Text("Same as default (\(model.settings.cleanup.title))").tag(CleanupLevel?.none)
                        ForEach(CleanupLevel.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    Picker("Tone", selection: $mode.tone) {
                        Text("Same as app").tag(StyleTone?.none)
                        ForEach(StyleTone.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    if !mode.apps.isEmpty || !mode.websites.isEmpty {
                        Picker("Screen context", selection: $mode.useScreenContext) {
                            Text("Same as default (\(model.settings.useScreenContext ? "On" : "Off"))").tag(Bool?.none)
                            Text("On").tag(Optional(true))
                            Text("Off").tag(Optional(false))
                        }
                    }
                    if (mode.cleanup ?? model.settings.cleanup) == .medium {
                        TextField("Instructions", text: instructions, prompt: Text("Use British spelling."), axis: .vertical)
                            .lineLimit(3...8)
                    }
                } header: {
                    Text("Writing")
                } footer: {
                    Text(writingFooter)
                }

                if !isNew {
                    Section {
                        Button("Delete Mode", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Add Mode" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 600, height: 640)
        .confirmationDialog("Delete “\(mode.name)”?", isPresented: $confirmingDelete) {
            Button("Delete Mode", role: .destructive) {
                model.settings.modes.removeAll { $0.id == mode.id }
                model.saveSettings()
                dismiss()
            }
        }
        .onAppear {
            let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier)
            let ids = Set(running + model.history.compactMap(\.appBundleID)).subtracting([Bundle.main.bundleIdentifier].compactMap { $0 })
            choices = ids.compactMap(AppChoice.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private var writingFooter: String {
        let screen = "With Parakeet and the phrase booster, screen context is read on this Mac when you start dictating, so it follows this mode’s apps and websites, and the names in it fix misspelled English words\(model.settings.recognizeScreenText ? ". It may read the window from a screenshot because Read window text from the screen is on" : "")."
        guard (mode.cleanup ?? model.settings.cleanup) == .medium else { return "\(screen) Choose Medium cleanup to add instructions for your cleanup model." }
        return "Instructions go to your cleanup model with each Medium dictation in this mode. \(screen) Medium also reads it and sends it to your cleanup model, which may be a cloud service, and a trigger word can turn that off but not on."
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
            Button("Add", action: add)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button("Remove", systemImage: "minus.circle", action: action)
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

private struct AppChoice: Identifiable {
    let id: String
    let name: String
    let icon: NSImage

    init?(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        id = bundleID
        name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
    }

    var label: some View {
        Label { Text(name) } icon: { Image(nsImage: icon) }
    }
}
