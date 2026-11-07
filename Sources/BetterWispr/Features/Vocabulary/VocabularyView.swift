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
                TextField(L10n.tr("Spoken phrase"), text: $phrase, prompt: Text(L10n.tr("English example: better whisper")))
                TextField(L10n.tr("Write as"), text: $replacement, prompt: Text(L10n.tr("Optional, e.g. BetterWispr")))
                HStack {
                    Spacer()
                    Button(L10n.tr("Add Word"), action: addEntry)
                        .disabled(!canAdd)
                }
            } header: {
                Text(L10n.tr("Add a Word"))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("Leave “Write as” empty to add a spelling hint. To fix a misheard command, write the command, such as “Kocia mark” as “question mark”. Replacements apply to whole phrases, so unrelated words stay intact."))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("Command examples are in English."))
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onSubmit { if canAdd { addEntry() } }

            if model.selectedModel.engine == .parakeet {
                phraseBoosterSection
            }

            Section {
                if model.vocabulary.isEmpty {
                    Text(L10n.tr("Add a name that often gets misspelled, a technical term or a phrase you use every day."))
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
                            .help(L10n.tr("Remove %@", String(entry.phrase)))
                            .accessibilityLabel(L10n.tr("Remove %@", String(entry.phrase)))
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(entry.phrase)
                            if entry.learned {
                                Text(L10n.tr("Learned"))
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.tint.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.tint)
                                    .help(L10n.tr("Added from a correction you made"))
                            }
                        }
                    }
                }
            } header: {
                if model.vocabulary.isEmpty {
                    Text(L10n.tr("Your Vocabulary"))
                } else {
                    Text(L10n.tr("%ld entries", model.vocabulary.count))
                }
            } footer: {
                if model.settings.learnCorrections {
                    Text(L10n.tr("Entries marked Learned come from fixes you made to a dictation, in History or right after BetterWispr pasted it. Remove any you don’t want."))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var phraseBoosterSection: some View {
        Section {
            if model.phraseBoosterInstalled {
                Label(L10n.tr("Phrase booster is on. When you speak English, it listens for these words and fixes the spelling where your voice matches one. It runs on this Mac."), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                let installation = model.installation?.id == AppModel.phraseBoosterID ? model.installation : nil
                let installing = installation != nil && installation?.failure == nil
                LabeledContent {
                    if installing {
                        Button(L10n.tr("Cancel"), action: model.cancelInstallation)
                    } else {
                        Button(installation == nil ? L10n.tr("Download") : L10n.tr("Retry")) { model.installPhraseBooster() }
                            .disabled(model.isInstalling)
                    }
                } label: {
                    Text(L10n.tr("Phrase booster"))
                    Text(L10n.tr("Helps Parakeet spell the words in this list. About 100 MB. New Parakeet downloads include it."))
                }
                if let installation {
                    if installing { ProgressView(value: installation.progress) }
                    Text(installation.failure.map { L10n.tr("Download stopped: %@", String($0)) } ?? installation.progressLabel)
                        .font(.caption)
                        .foregroundStyle(installing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
            }
        }
    }

    private func addEntry() {
        guard canAdd else { return }
        model.addVocabulary(phrase: phrase, replacement: replacement)
        phrase = ""
        replacement = ""
    }
}
