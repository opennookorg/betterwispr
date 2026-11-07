import BetterWisprCore
import SwiftUI

struct NotesModelPicker: View {
    @Bindable var model: AppModel
    var title = L10n.tr("Notes provider")
    var overrideSelection: WritableKeyPath<AppSettings, NotesModelSelection?>?

    var body: some View {
        Picker(title, selection: Binding(get: { selection }, set: { select($0) })) {
            if overrideSelection != nil { Text(L10n.tr("Same as notes · %@", String(model.settings.localizedNotesModelName))).tag(NotesModelSelection?.none) }
            Text(L10n.tr("Apple Intelligence · On this Mac")).tag(NotesModelSelection?.some(.apple))
            if model.meetings.builtInModelInstalled || selection == .builtIn {
                Text(model.meetings.builtInModelInstalled ? L10n.tr("Built-in · %@ · On this Mac", String(BuiltInModel.displayName)) : L10n.tr("Built-in · Not downloaded"))
                    .tag(NotesModelSelection?.some(.builtIn))
            }
            ForEach(NotesCLI.allCases, id: \.self) { cli in
                Text(overrideSelection == nil && model.settings.allowsAnySignIn(cli)
                     ? L10n.tr("%@ · Any sign-in", String(cli.name))
                     : L10n.tr("%@ · Subscription", String(cli.name))).tag(NotesModelSelection?.some(.cli(cli)))
            }
            ForEach(ollamaModels, id: \.self) { name in
                Text("Ollama · \(name)").tag(NotesModelSelection?.some(.ollama(name)))
            }
            ForEach(model.settings.notesConnections) { connection in
                Text("\(connection.name) · \(connection.modelID)").tag(NotesModelSelection?.some(.connection(connection.id)))
            }
            if case .connection(let id) = selection, !model.settings.notesConnections.contains(where: { $0.id == id }) {
                Text(L10n.tr("Missing notes connection", table: "NotesModel")).tag(NotesModelSelection?.some(.connection(id)))
            }
        }
        if case .cli(let cli) = selection, overrideSelection == nil || model.settings.notesSelection != .cli(cli) {
            let models = model.notesCLICatalogs[cli]?.models ?? []
            Picker(L10n.tr("%@ model", String(cli.name)), selection: Binding(
                get: { model.settings.cliModel(cli) },
                set: { model.settings.setCLIModel($0, for: cli); model.saveNotesSettings() }
            )) {
                Text(L10n.tr("Choose a model")).tag("").disabled(true)
                ForEach(models) { item in
                    Text("\(item.name) · \(item.id)").tag(item.id)
                }
                let selected = model.settings.cliModel(cli)
                if !selected.isEmpty, !models.contains(where: { $0.id == selected }) {
                    Text(selected).tag(selected)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var selection: NotesModelSelection? {
        guard let overrideSelection else { return model.settings.notesSelection }
        return model.settings[keyPath: overrideSelection]
    }

    private func select(_ selection: NotesModelSelection?) {
        if let overrideSelection {
            model.selectNotesModel(selection, for: overrideSelection)
        } else if let selection {
            model.selectNotesModel(selection)
        }
    }

    private var ollamaModels: [String] {
        let installed = model.meetings.ollamaModels
        guard case .ollama(let saved) = selection, !installed.contains(saved) else { return installed }
        return installed + [saved]
    }
}

struct NotesModelSettings: View {
    @Bindable var model: AppModel
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        NotesModelPicker(model: model)
            .disabled(!model.canEditConnections || testing)
        if case .cli(let cli) = model.settings.notesSelection {
            TextField(L10n.tr("Model ID"), text: Binding(
                get: { model.settings.cliModel(cli) },
                set: {
                    model.settings.setCLIModel($0, for: cli)
                    model.saveNotesSettings()
                }
            ))
            .disabled(!model.canEditConnections || testing)
            HStack {
                Button(L10n.tr("Refresh %@ models", String(cli.name))) { Task { await model.refreshNotesCLIModels(cli) } }
                    .disabled(model.loadingNotesCatalogs.contains(cli) || testing)
                if model.loadingNotesCatalogs.contains(cli) { ProgressView().controlSize(.small) }
            }
            if let error = model.notesCatalogErrors[cli] {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else if let item = model.notesCLICatalogs[cli]?.models.first(where: { $0.id == model.settings.cliModel(cli) }) {
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
            Text(model.settings.allowsAnySignIn(cli)
                 ? L10n.tr("Install the latest %@ CLI and run %@ in Terminal. BetterWispr uses that sign-in.", String(cli.name), String(cli.loginCommand))
                 : L10n.tr("Install the latest %@ CLI and run %@ in Terminal. BetterWispr uses that sign-in; subscription limits apply.", String(cli.name), String(cli.loginCommand)))
                .font(.caption).foregroundStyle(.secondary)
            if cli == .claudeCode { ClaudeCodeAnySignInSettings(model: model, testing: testing) }
        }
        HStack {
            Button(testing ? L10n.tr("Testing…") : L10n.tr("Test notes model")) { result = nil; testing = true }
                .disabled(testing || !model.canEditConnections || model.meetings.notesAvailability != .available)
            if testing {
                ProgressView().controlSize(.small)
                Button(L10n.tr("Cancel")) { testing = false }
            }
            Button(L10n.tr("Refresh local models")) { Task { await model.meetings.refreshOllamaModels() } }
        }
        Text(L10n.tr("Test sends only a short built-in English sample to the selected notes model."))
            .font(.caption).foregroundStyle(.secondary)
        if let result { Text(result).font(.callout).textSelection(.enabled) }
        if case .unavailable(let reason) = model.meetings.notesAvailability {
            Text(reason).font(.callout).foregroundStyle(.secondary)
        }
        NotesModelPicker(model: model, title: L10n.tr("Ask provider"), overrideSelection: \.askSelection)
            .disabled(testing)
        Text(L10n.tr("Ask sends the most relevant transcript lines and thoughts from the meetings you ask about to this model."))
            .font(.caption).foregroundStyle(.secondary)
        // A view task cancels the request or CLI when this page is closed or Cancel is clicked.
        Color.clear.frame(height: 0)
            .task { await model.meetings.refreshOllamaModels() }
            .task(id: testing) {
                guard testing else { return }
                let settings = model.settings
                do {
                    let notes = try await MeetingNotesGenerator.generate(segments: [],
                        userNotes: "Synthetic test meeting: We agreed to launch on Friday. Alex will send the checklist tomorrow.",
                        settings: settings) { _, _ in }
                    try Task.checkCancellation()
                    result = L10n.tr("%@ is working. Sample summary: %@", String(notes.summary.modelName ?? settings.localizedNotesModelName), String(notes.summary.overview))
                } catch {
                    guard !Task.isCancelled else { return }
                    result = error.localizedDescription
                }
                testing = false
            }
            .onChange(of: model.settings) { _, _ in result = nil }
    }
}

private struct ClaudeCodeAnySignInSettings: View {
    @Bindable var model: AppModel
    let testing: Bool
    @State private var destination: ClaudeCodeDestination?
    @State private var problem: String?
    @State private var checks = 0

    var body: some View {
        Toggle(L10n.tr("Allow any Claude Code sign-in"), isOn: Binding(
            get: { model.settings.claudeCodeAnySignIn },
            set: {
                model.settings.claudeCodeAnySignIn = $0
                model.settings.claudeCodeConfirmedDestination = nil
                model.saveNotesSettings()
            }
        ))
        .disabled(!model.canEditConnections || testing)
        Text(L10n.tr("For meeting notes only. Meeting text goes to the destination below, such as an API account, a company cloud account or a gateway. That operator receives the text and its charges apply. Each request stops at about $1, and a long meeting takes several requests. Ask, Medium cleanup and correction review never use this switch."))
            .font(.caption).foregroundStyle(.secondary)
        if model.settings.claudeCodeAnySignIn {
            LabeledContent(L10n.tr("Sends to"), value: destination?.label ?? (problem == nil ? L10n.tr("Checking…") : L10n.tr("Unknown")))
            if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if let destination {
                    if destination.label == confirmed {
                        Label(L10n.tr("Confirmed"), systemImage: "checkmark.circle")
                    } else {
                        Button(L10n.tr("Confirm destination")) {
                            model.settings.claudeCodeConfirmedDestination = destination.label
                            model.saveNotesSettings()
                        }
                        .disabled(!model.canEditConnections || testing)
                    }
                }
                Button(L10n.tr("Check again")) { checks += 1 }
            }
            if let destination, let confirmed, destination.label != confirmed {
                Text(L10n.tr("This changed from %@. Nothing is sent until you confirm.", String(confirmed))).font(.caption).foregroundStyle(.secondary)
            }
            Color.clear.frame(height: 0).task(id: checks) { await readDestination() }
        }
    }

    private var confirmed: String? { model.settings.claudeCodeConfirmedDestination }

    private func readDestination() async {
        do {
            let current = try await ClaudeCodeDestination.current()
            destination = current
            problem = nil
        } catch is CancellationError {
        } catch {
            destination = nil
            problem = error.localizedDescription
        }
    }
}
