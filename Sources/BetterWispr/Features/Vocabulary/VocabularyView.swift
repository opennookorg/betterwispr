import BetterWisprCore
import SwiftUI

struct VocabularyView: View {
    @Bindable var model: AppModel
    @State private var phrase = ""
    @State private var replacement = ""

    private var canAdd: Bool { !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Form {
            Section {
                TextField("Spoken phrase", text: $phrase, prompt: Text("better whisper"))
                TextField("Write as", text: $replacement, prompt: Text("Optional, e.g. BetterWispr"))
            } header: {
                Text("Add a Word")
            } footer: {
                HStack(alignment: .top) {
                    Text("Leave “Write as” empty to add a spelling hint. To fix a misheard command, write the command, such as “Kocia mark” as “question mark”. Replacements apply to whole phrases, so unrelated words stay intact.")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 20)
                    Button("Add Word", action: addEntry)
                        .disabled(!canAdd)
                }
            }
            .onSubmit { if canAdd { addEntry() } }

            if model.selectedModel.engine == .parakeet {
                phraseBoosterSection
            }

            if model.settings.learnCorrections || model.vocabulary.contains(where: \.learned) {
                Section {
                    Toggle(isOn: setting(\.replaceLearnedWords)) {
                        Text("Replace with learned words")
                        Text("When off, learned entries only help the speech model hear them, and words you said are no longer swapped for them afterwards.")
                    }
                }
            }

            Section {
                if model.vocabulary.isEmpty {
                    Text("Add a name that often gets misspelled, a technical term or a phrase you use every day.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.vocabulary) { entry in
                    LabeledContent {
                        HStack(spacing: 10) {
                            Text(entry.replacement.isEmpty ? entry.phrase : entry.replacement)
                                .foregroundStyle(.primary)
                            Button { model.deleteVocabulary(entry) } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove \(entry.phrase)")
                            .accessibilityLabel("Remove \(entry.phrase)")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(entry.phrase)
                            if entry.learned {
                                Text("Learned")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.tint.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.tint)
                                    .help("Added from a correction you made")
                            }
                        }
                    }
                }
            } header: {
                if model.vocabulary.isEmpty {
                    Text("Your Vocabulary")
                } else {
                    Text("^[\(model.vocabulary.count) entry](inflect: true)")
                }
            } footer: {
                if model.settings.learnCorrections {
                    Text("Entries marked Learned come from fixes you made to a dictation, in History or right after BetterWispr pasted it. Remove any you don’t want.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var phraseBoosterSection: some View {
        Section {
            if model.phraseBoosterInstalled {
                Toggle(isOn: setting(\.usePhraseBooster)) {
                    Text("Use phrase booster")
                    Text("When you speak English, it listens for these words and fixes the spelling where your voice matches one. It runs on this Mac.")
                }
            } else {
                let installation = model.installation?.id == AppModel.phraseBoosterID ? model.installation : nil
                let installing = installation != nil && installation?.failure == nil
                LabeledContent {
                    if installing {
                        Button("Cancel", action: model.cancelInstallation)
                    } else {
                        Button(installation == nil ? "Download" : "Retry") { model.installPhraseBooster() }
                            .disabled(model.isInstalling)
                    }
                } label: {
                    Text("Phrase booster")
                    Text("Helps Parakeet spell the words in this list. About 100 MB. New Parakeet downloads include it.")
                }
                if let installation {
                    if installing { ProgressView(value: installation.progress) }
                    Text(installation.failure.map { "Download stopped: \($0)" } ?? installation.progressLabel)
                        .font(.caption)
                        .foregroundStyle(installing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
            }
        }
    }

    private func setting(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { model.settings[keyPath: keyPath] = $0; model.saveSettings() })
    }

    private func addEntry() {
        guard canAdd else { return }
        model.addVocabulary(phrase: phrase, replacement: replacement)
        phrase = ""
        replacement = ""
    }
}
