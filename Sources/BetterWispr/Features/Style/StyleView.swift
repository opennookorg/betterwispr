import BetterWisprCore
import SwiftUI

private extension StyleContext {
    var title: String {
        switch self {
        case .personal: L10n.tr("Personal messages")
        case .work: L10n.tr("Work messages")
        case .email: L10n.tr("Email")
        case .other: L10n.tr("Other apps")
        }
    }

    var symbol: String {
        switch self {
        case .personal: "bubble.left.and.bubble.right"
        case .work: "briefcase"
        case .email: "envelope"
        case .other: "square.grid.2x2"
        }
    }

    var apps: String {
        switch self {
        case .personal: L10n.tr("WhatsApp, Telegram, Discord, Messages, Signal and Messenger.")
        case .work: L10n.tr("Slack, Microsoft Teams, Zoom, Webex and Mattermost.")
        case .email: L10n.tr("Mail, Outlook, Superhuman, Spark, Mimestream, Airmail and Thunderbird.")
        case .other: L10n.tr("ChatGPT, Claude, Cursor, Notes, Notion, browsers and every other app. Browsers use this tone unless a mode below lists the website. Tones only change English dictation.")
        }
    }
}

extension StyleTone {
    var title: String {
        switch self {
        case .formal: L10n.tr("Formal")
        case .casual: L10n.tr("Casual")
        case .veryCasual: L10n.tr("Very casual")
        case .excited: L10n.tr("Excited")
        }
    }

    var detail: String {
        switch self {
        case .formal: L10n.tr("Caps and punctuation, exactly as cleaned up.")
        case .casual: L10n.tr("Caps, fewer commas and no final period.")
        case .veryCasual: L10n.tr("No caps, fewer commas and no final period.")
        case .excited: L10n.tr("Ends on an exclamation mark.")
        }
    }
}

extension CleanupLevel {
    var title: String {
        switch self {
        case .none: L10n.tr("None")
        case .light: L10n.tr("Light")
        case .medium: L10n.tr("Medium")
        }
    }

    var detail: String {
        switch self {
        case .none: L10n.tr("Keeps exactly what you said, including filler words.")
        case .light: StylePreview().lightCleanupDetail
        case .medium: L10n.tr("Uses your cleanup model to fix self-corrections, numbers and punctuation, and infer numbered steps or bullet lists from the meaning of English dictation. No special list phrases are needed.")
        }
    }
}

struct StyleView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let recentApps = recentAppsByContext
        let preview = StylePreview()
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsSection(L10n.tr("Cleanup in every app")) {
                    SettingRow(L10n.tr("Auto cleanup"), caption: model.settings.cleanup.detail) {
                        Picker(L10n.tr("Auto cleanup"), selection: setting(\.cleanup).animation(reveal)) {
                            ForEach(CleanupLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        example(preview.spokenTitle, preview.spokenSample, emphasized: false)
                        Image(systemName: "arrow.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        example(preview.cleanedTitle, preview.cleanedSample(for: model.settings.cleanup), emphasized: true)
                        if preview.isFrench && model.settings.cleanup != .none {
                            Text(preview.frenchCleanupNote)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8, style: .continuous))
                    .padding([.horizontal, .bottom], 16)
                    if model.settings.cleanup == .medium || model.settings.selectedTextShortcut != nil {
                        RowDivider()
                        VStack(alignment: .leading, spacing: 8) {
                            NotesModelPicker(model: model, title: L10n.tr("Cleanup provider"), overrideSelection: \.cleanupSelection)
                            if case .unavailable(let reason) = MeetingNotesGenerator.availability(settings: model.settings.cleanupSettings) {
                                Label(model.settings.cleanup == .medium ? L10n.tr("%@ Until then, Medium dictations get Light cleanup.", String(reason)) : reason,
                                      systemImage: "exclamationmark.triangle")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .transition(.opacity)
                    }
                    RowDivider()
                    SettingToggle(L10n.tr("Use screen context"), caption: Self.screenContextCaption, isOn: setting(\.useScreenContext).animation(reveal))
                    if model.settings.useScreenContext {
                        RowDivider()
                        SettingToggle(L10n.tr("Read window text from the screen"), caption: screenTextCaption, isOn: recognizeScreenText)
                            .transition(.opacity)
                    }
                } footer: {
                    Text(cleanupFooter)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(L10n.tr("Tone by app"))
                    if preview.isFrench {
                        Text(preview.frenchToneNote)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 12) {
                        ForEach(StyleContext.allCases, id: \.self) { context in
                            toneCard(context, recentApps: recentApps[context])
                        }
                    }
                }

                ModesSection(model: model)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .task { await model.meetings.refreshOllamaModels() }
    }

    private func toneCard(_ context: StyleContext, recentApps: String?) -> some View {
        let selected = model.settings.tone(for: context)
        let preview = StylePreview()
        let sample = preview.toneSample(for: context, tone: selected)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: context.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.title)
                            .font(.body.weight(.medium))
                        Text(selected.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Picker(L10n.tr("%@ tone", String(context.title), table: "WritingContext"), selection: tone(context).animation(reveal)) {
                        ForEach(context.tones, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Text(sample)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel(preview.accessibilityLabel(for: sample))
                Text([context.apps, recentApps].compactMap { $0 }.joined(separator: " "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var reveal: Animation? { reduceMotion ? nil : .smooth(duration: 0.25) }

    private var recentAppsByContext: [StyleContext: String] {
        Dictionary(grouping: Set(model.history.compactMap(\.appBundleID)), by: { AppCategory(bundleID: $0).style }).compactMapValues { ids in
            let names = ids.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.deletingPathExtension().lastPathComponent }.sorted()
            return names.isEmpty ? nil : L10n.tr("Your recent dictations here went to %@.", String(ListFormatter.localizedString(byJoining: names)))
        }
    }

    private var cleanupFooter: String {
        let original = L10n.tr("Your original words are never lost. In History, open Original transcription and choose Use Original.")
        guard model.settings.cleanup == .medium else {
            return model.settings.selectedTextShortcut == nil ? original : L10n.tr("Clean up selected text sends your selection to the cleanup provider. %@", String(original))
        }
        let provider = model.settings.cleanupSettings
        let destination = switch provider.notesSelection {
        case .apple: L10n.tr("Medium edits with Apple Intelligence on this Mac.")
        case .builtIn: L10n.tr("Medium edits with the built-in model on this Mac.")
        case .ollama: L10n.tr("Medium edits with Ollama on this Mac.")
        case .cli(let cli): L10n.tr("Medium sends English dictation to %@ through your subscription, which adds a few seconds. With any other sign-in, nothing is sent and dictation gets Light cleanup.", String(cli.name))
        case .connection: L10n.tr("Medium sends English dictation to %@ with your API key.", String(provider.localizedNotesModelName))
        }
        let results = model.settings.cleanupSelection == nil ? L10n.tr("It uses the same model as meeting notes, and results vary by model.") : L10n.tr("Results vary by model.")
        return L10n.tr("%@ %@ Other languages, very short dictations and edits that fail, take too long or rewrite too much get Light cleanup. %@", String(destination), String(results), String(original))
    }

    private func example(_ title: String, _ text: String, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(emphasized ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func tone(_ context: StyleContext) -> Binding<StyleTone> {
        Binding(get: { model.settings.tone(for: context) },
                set: { model.settings.styles[context] = $0; model.saveSettings() })
    }

    private static let screenContextCaption = L10n.tr("When you speak English to Parakeet with the phrase booster installed, reads your selected text and the window you dictate into on this Mac, and uses the names in them to fix words Parakeet heard as misspellings, such as superbase becoming Supabase. Correctly spelled words stay as heard. With Medium cleanup, your selected text, clipboard and window text also go to your cleanup model, which may be a cloud service. Nothing is read while a password field is active, and clipboard items marked as passwords are skipped.")

    private var screenTextCaption: String {
        let status = CGPreflightScreenCaptureAccess() ? L10n.tr("Screen Recording is allowed.") : L10n.tr("Needs Screen Recording. Allow BetterWispr under Privacy & Security, Screen & System Audio Recording in System Settings, then reopen BetterWispr.")
        return L10n.tr("When an app shares too little text, reads its window from a screenshot on this Mac. With Medium cleanup, that text also goes to your cleanup model, which may be a cloud service. %@", String(status))
    }

    private var recognizeScreenText: Binding<Bool> {
        Binding(get: { model.settings.recognizeScreenText }, set: { isOn in
            model.settings.recognizeScreenText = isOn
            model.saveSettings()
            if isOn, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        })
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { model.settings[keyPath: keyPath] = $0; model.saveSettings() })
    }
}
