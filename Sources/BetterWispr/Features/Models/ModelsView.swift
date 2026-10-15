import BetterWisprCore
import SwiftUI

struct ModelsView: View {
    @Bindable var model: AppModel
    @State private var editing: SpeechConnection?
    @State private var error: String?
    @State private var editingNotes = false
    @State private var forgettingVoices = false
    @State private var forgetFailure: String?

    var body: some View {
        Form {
            Section {
                ForEach(SpeechModel.catalog) { speechModel in
                    modelRow(speechModel)
                }
            } header: {
                Text("On this Mac")
            } footer: {
                Label("These models process audio on your Mac. Parakeet and Whisper need an internet connection only for installation. Parakeet sizes include the 100 MB phrase booster, which downloads once and is shared.", systemImage: "internaldrive")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(model.settings.speechConnections) { connection in
                    VStack(alignment: .leading, spacing: 8) {
                        modelRow(connection.speechModel)
                        HStack {
                            Button("Edit…") { editingNotes = false; editing = connection }
                            Button("Remove", role: .destructive) {
                                do { try model.deleteConnection(connection) }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                        .disabled(!model.canEditConnections)
                    }
                }
                Button("Add connection…", systemImage: "plus") { editingNotes = false; editing = SpeechConnection() }
                    .disabled(!model.canEditConnections)
            } header: {
                Text("Bring your own model")
            } footer: {
                Text("Choosing Use sends dictation and meeting audio to that endpoint. Provider charges and retention policies apply. API keys are kept in macOS Keychain; vocabulary replacements stay on your Mac. Open-source models need a server with a compatible transcription API.")
            }

            Section {
                builtInModelRow
                NotesModelSettings(model: model)
                ForEach(model.settings.notesConnections) { connection in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(connection.name).fontWeight(.medium)
                            Text(connection.modelID).font(.caption).foregroundStyle(.secondary)
                            Text(connection.endpoint).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { editingNotes = true; editing = connection }
                        Button("Remove", role: .destructive) {
                            do { try model.deleteConnection(connection, forNotes: true) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(!model.canEditConnections)
                }
                Button("Add notes API connection…", systemImage: "plus") {
                    var connection = SpeechConnection(api: .openAICompatible)
                    connection.name = "My notes model"
                    connection.endpoint = "https://api.openai.com/v1/chat/completions"
                    connection.modelID = ""
                    editingNotes = true
                    editing = connection
                }
                .disabled(!model.canEditConnections)
            } header: {
                Text("Meeting notes · Bring your own LLM")
            } footer: {
                Text("The selected notes model processes the transcript and your thoughts after recording, and whenever you generate a summary. The built-in model runs on this Mac and needs an internet connection only to download. Claude Code and Codex use their signed-in subscriptions. API connections use your key and provider billing. Cloud choices send meeting text to that provider; speech recognition is selected separately. When Auto cleanup in Style is Medium, this model also edits your English dictation.")
            }

            Section {
                if model.speakerDetectionInstalled {
                    Label("Speaker detection is on. After each meeting, BetterWispr tells the voices on the call apart on this Mac and labels them Speaker 1, Speaker 2 and so on. Rename them above the transcript.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Toggle(isOn: setting(\.separateRoomVoices)) {
                        Text("Tell apart people in the room")
                        Text("Also separates the voices on your microphone. The voice your microphone hears longest stays Me and the others get their own speaker numbers, so if someone near you talks more than you do, move your lines back to Me. Your microphone audio is kept on this Mac until the speakers are found, then deleted.")
                    }
                    Toggle(isOn: setting(\.rememberVoices)) {
                        Text("Remember named voices")
                        Text("When you name a speaker, a profile of that voice is saved on this Mac. In later meetings, a speaker who sounds like a saved voice shows that name as a suggestion in its name menu, and no name is filled in until you choose one. Name speakers before you quit BetterWispr, because a meeting’s voices are held only in memory until then. A voice profile can identify a person, so ask people before you name them. Profiles are never uploaded, but Time Machine backs them up. Suggestions use SpeakerKit’s cutoff for grouping voices within one meeting, which wasn’t tuned for matching across meetings.")
                    }
                    LabeledContent {
                        Button("Forget Voices…", role: .destructive) { forgettingVoices = true }
                    } label: {
                        Text("Remembered voices")
                        Text(forgetFailure ?? "Deletes every saved voice profile. Names already in your meetings stay. Deleting a meeting deletes the profiles named in it.")
                            .foregroundStyle(forgetFailure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    }
                    .confirmationDialog("Forget every remembered voice?", isPresented: $forgettingVoices) {
                        Button("Forget Voices", role: .destructive) {
                            do {
                                try model.meetings.forgetVoices()
                                forgetFailure = nil
                            } catch {
                                forgetFailure = "Couldn’t forget voices. \(error.localizedDescription)"
                            }
                        }
                    }
                } else {
                    let installation = model.installation?.id == AppModel.speakerDetectionID ? model.installation : nil
                    let installing = installation != nil && installation?.failure == nil
                    LabeledContent {
                        if installing {
                            Button("Cancel", action: model.cancelInstallation)
                        } else {
                            Button(installation == nil ? "Download" : "Retry") { model.installSpeakerDetection() }
                                .disabled(model.isInstalling)
                        }
                    } label: {
                        Text("Speaker detection")
                        Text("Tells the voices on the other side of a call apart after each meeting, so the transcript and notes show who said what. Runs on this Mac.")
                    }
                    if let installation {
                        if installing { ProgressView(value: installation.progress) }
                        Text(installation.failure.map { "Download stopped: \($0)" } ?? installation.progressLabel)
                            .font(.caption)
                            .foregroundStyle(installing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    }
                }
            } header: {
                Text("Meeting speakers")
            } footer: {
                Text("Your microphone is Me. People in the room with you stay part of Me unless speaker detection tells them apart.")
            }

            Section {
                LabeledContent {
                    Button("Open Vocabulary") { model.selectedPage = .vocabulary }
                } label: {
                    Text("Improve accuracy")
                    Text("Larger models handle accents and challenging audio better, but use more memory and take longer. A quiet microphone, the correct language and your personal vocabulary also make a difference.")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { connection in
            SpeechConnectionEditor(model: model, connection: connection, forNotes: editingNotes)
        }
        .alert("Couldn’t remove connection", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private var builtInModelRow: some View {
        let installation = model.installation?.id == AppModel.builtInModelID ? model.installation : nil
        let installing = installation != nil && installation?.failure == nil
        LabeledContent {
            if installing {
                Button("Cancel", action: model.cancelInstallation)
            } else if model.meetings.builtInModelInstalled {
                Button("Remove", role: .destructive, action: model.removeBuiltInModel)
                    .disabled(model.isInstalling || !model.canEditConnections)
            } else {
                Button(installation == nil ? "Download" : "Retry", action: model.installBuiltInModel)
                    .disabled(model.isInstalling)
            }
        } label: {
            Text("Built-in model · \(BuiltInModel.displayName)")
            Text("Writes meeting notes and edits Medium dictation on this Mac, with no app or account to set up. \(BuiltInModel.sizeLabel) download. Uses about 1.5 GB of memory while it works and frees it after five idle minutes.")
        }
        if let installation {
            if installing { ProgressView(value: installation.progress) }
            Text(installation.failure.map { "Download stopped: \($0)" } ?? installation.progressLabel)
                .font(.caption)
                .foregroundStyle(installing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { model.settings[keyPath: keyPath] = $0; model.saveSettings() })
    }

    private func modelRow(_ speechModel: SpeechModel) -> some View {
        let selected = speechModel.id == model.selectedModel.id
        let installation = model.installation?.id == speechModel.id ? model.installation : nil
        let installing = installation != nil && installation?.failure == nil
        let installed = model.isModelInstalled(speechModel)

        return HStack(alignment: .top, spacing: 12) {
            SymbolTile(
                symbol: speechModel.engine == .apple ? "apple.logo" : "waveform",
                color: speechModel.engine == .apple ? .gray : .purple,
                size: 32
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(speechModel.name).fontWeight(.medium)
                    if selected {
                        badge("Active", color: .green)
                    } else if speechModel.id == "parakeet-ultra" {
                        badge("Recommended", color: .accentColor)
                    }
                }
                Text(speechModel.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(speechModel.sizeLabel) · \(engineLabel(speechModel.engine))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let names = speechModel.languageNames {
                    if names.count == 1 {
                        Text(names[0])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        DisclosureGroup("\(names.count) languages") {
                            Text(names.formatted(.list(type: .and)))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption)
                    }
                }
                if let installation {
                    if installing { ProgressView(value: installation.progress).padding(.top, 4) }
                    Text(installation.failure.map { "Download stopped: \($0)" } ?? installation.progressLabel)
                        .font(.caption)
                        .foregroundStyle(installing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
            }
            Spacer(minLength: 8)
            if installing {
                Button("Cancel", action: model.cancelInstallation)
            } else if selected && installed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Active model")
            } else if installed {
                Button("Use") { model.selectModel(speechModel) }
                    .disabled(model.isBusy)
            } else {
                Button(installation == nil ? "Download" : "Retry") { model.installModel(speechModel) }
                    .disabled(model.isInstalling)
            }
        }
        .padding(.vertical, 4)
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func engineLabel(_ engine: SpeechEngine) -> String {
        switch engine {
        case .apple: "System speech"
        case .whisperKit: "WhisperKit · Apple Silicon"
        case .parakeet: "Parakeet · Neural Engine"
        case .api: "API connection"
        }
    }
}

private struct SpeechConnectionEditor: View {
    let model: AppModel
    @State var connection: SpeechConnection
    var forNotes = false
    @State private var key = ""
    @State private var removeKey = false
    @State private var error: String?
    @State private var language: String?
    @Environment(\.dismiss) private var dismiss

    private var spokenLanguage: Binding<String> {
        Binding(get: { language ?? ((try? connection.validateLanguage(model.settings.language)) == nil ? "en" : model.settings.language) },
                set: { language = $0 })
    }

    private var preset: Binding<String?> {
        Binding(get: { NotesAPIPreset.all.first { $0.endpoint == connection.endpoint && $0.modelID == connection.modelID }?.id },
                set: { id in
                    let preset = NotesAPIPreset.all.first { $0.id == id }
                    connection.name = preset?.name ?? connection.name
                    connection.endpoint = preset?.endpoint ?? connection.endpoint
                    connection.modelID = preset?.modelID ?? ""
                    key = ""
                    error = nil
                })
    }

    private var original: SpeechConnection? { (forNotes ? model.settings.notesConnections : model.settings.speechConnections).first { $0.id == connection.id } }
    private var canKeepKey: Bool { original?.keychainAccount == connection.keychainAccount }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if forNotes {
                        if original == nil {
                            Picker("Provider", selection: preset) {
                                Text("Custom").tag(String?.none)
                                ForEach(NotesAPIPreset.all) { Text($0.name).tag(String?.some($0.id)) }
                            }
                        }
                        LabeledContent("API format", value: "OpenAI-compatible chat completions")
                    } else {
                        Picker("Provider", selection: $connection.api) {
                            ForEach(SpeechAPI.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                    }
                    TextField("Name", text: $connection.name)
                    TextField("Model ID", text: $connection.modelID)
                    if connection.api == .openAICompatible {
                        TextField(forNotes ? "Chat completions URL" : "Transcription URL", text: $connection.endpoint)
                        Text(forNotes ? "Enter a full /chat/completions endpoint and any model ID your provider supports. Works with OpenAI-compatible services and local servers. API keys use Bearer authentication." : "Enter the full endpoint, for example http://localhost:8000/v1/audio/transcriptions. It must accept a WAV file and return JSON with a text field. API keys use Bearer authentication.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Endpoint") { Text(connection.endpoint).textSelection(.enabled) }
                    }
                    SecureField(canKeepKey ? "New API key (blank keeps saved key)" : "API key", text: $key)
                        .disabled(removeKey)
                    if connection.api == .openAICompatible {
                        Toggle("Use without an API key", isOn: $removeKey)
                    }
                    if connection.api == .smallest {
                        Picker("Spoken language", selection: spokenLanguage) {
                            ForEach(SettingsView.spokenLanguages.filter { (try? connection.validateLanguage($0.code)) != nil }, id: \.code) {
                                Text($0.name).tag($0.code)
                            }
                        }
                        Text("Smallest AI can’t detect the language automatically. Saving sets Spoken language in Settings, which every model uses. Use pulse for multilingual speech or pulse-pro for English.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(forNotes ? "Notes API connection" : original == nil ? "Add speech connection" : "Edit speech connection")
                } footer: {
                    Text(forNotes ? "Saving makes no network request. Select this connection under Notes model to send meeting text to it. Keys stay in macOS Keychain. Changing an active endpoint resets the notes choice to Apple Intelligence; select the connection again to use the new URL." : "Saving makes no network request. Choose Use in Models to send future dictation and meeting audio to this endpoint. Keys are stored only in macOS Keychain.")
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save connection") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canEditConnections)
            }
            .padding()
        }
        .frame(width: 600, height: 540)
        .onChange(of: connection.api) { _, api in
            connection.name = api.name
            connection.endpoint = api.endpoint
            connection.modelID = api.defaultModel
            key = ""
            removeKey = false
            error = nil
            language = nil
        }
    }

    private func save() {
        connection.name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.endpoint = connection.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.modelID = connection.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = spokenLanguage.wrappedValue
        do {
            if connection.api == .smallest { try connection.validateLanguage(language) }
            try model.saveConnection(connection, key: removeKey ? "" : key.isEmpty && canKeepKey ? nil : key, forNotes: forNotes)
            if connection.api == .smallest, model.settings.language != language {
                model.settings.language = language
                model.saveSettings()
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
