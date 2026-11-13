import AppKit
import BetterWisprCore
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var permissionCheck = 0
    @State private var terminals: [ScriptableTerminal] = []
    @State private var pendingRetention: HistoryRetention?

    private static let voiceCommands = [
        ("“comma”, “question mark”, “full stop”", ", ? ."),
        ("“add a period”, “add a colon”", ". :"),
        ("“new line”, “new paragraph”", L10n.tr("Line breaks")),
        ("“scratch that”, “sorry, remove that”", L10n.tr("Deletes the last sentence")),
        ("“at the rate KV”, “at sign KV”", "@KV"),
        ("“write an email to Sam saying …, best regards, Kartik”", L10n.tr("Hi Sam, body and sign-off")),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsSection(L10n.tr("Appearance")) {
                    SettingRow(L10n.tr("Theme")) {
                        Picker(L10n.tr("Theme"), selection: setting(\.theme)) {
                            Text(L10n.tr("System")).tag(AppTheme.system)
                            Text(L10n.tr("Light", table: "Appearance")).tag(AppTheme.light)
                            Text(L10n.tr("Cream")).tag(AppTheme.cream)
                            Text(L10n.tr("Dark")).tag(AppTheme.dark)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                SettingsSection(L10n.tr("Shortcut")) {
                    ShortcutRecorder(model: model, kind: .dictation)
                    RowDivider()
                    ShortcutRecorder(model: model, kind: .cancel)
                    RowDivider()
                    ShortcutRecorder(model: model, kind: .selectedText)
                    RowDivider()
                    SettingRow(L10n.tr("Behavior"), caption: model.settings.dictationMode == .hold
                        ? L10n.tr("Hold to speak and release to finish. Or tap once to dictate hands-free, then press again or click ✓ to finish.")
                        : L10n.tr("Press once to speak. Press again or click ✓ to finish.")) {
                        Picker(L10n.tr("Behavior"), selection: setting(\.dictationMode)) {
                            Text(L10n.tr("Hold or tap")).tag(DictationMode.hold)
                            Text(L10n.tr("Press to toggle")).tag(DictationMode.toggle)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(model.isBusy)
                    }
                }

                SettingsSection(L10n.tr("Microphone and language")) {
                    SettingRow(L10n.tr("Microphone"), caption: (model.settings.microphone == nil ? L10n.tr("Follows your Sound settings.") : L10n.tr("Used whenever it’s connected."))
                        + L10n.tr(" Bluetooth headphones drop to call quality while recording.")) {
                        MicrophonePicker(model: model) { Text(L10n.tr("Microphone")) }
                            .labelsHidden()
                            .frame(maxWidth: 240)
                    }
                    RowDivider()
                    SettingRow(L10n.tr("Spoken language"), caption: L10n.tr("A fixed language gives more consistent results.")) {
                        Picker(L10n.tr("Spoken language"), selection: setting(\.language)) {
                            Text(model.selectedModel.engine == .apple ? L10n.tr("System language") : L10n.tr("Detect automatically")).tag("auto")
                            ForEach(languageChoices, id: \.code) { Text($0.name).tag($0.code) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if [.whisperKit, .parakeet].contains(model.selectedModel.engine) && model.settings.language == "auto" {
                        RowDivider()
                        SettingRow(L10n.tr("Dictation languages"), caption: L10n.tr("Automatic detection chooses only among these.")) {
                            Menu(dictationLanguagesLabel) {
                                Toggle(L10n.tr("All languages"), isOn: Binding(
                                    get: { dictationLanguageNames.isEmpty },
                                    set: { if $0 { setting(\.dictationLanguages).wrappedValue = [] } }
                                ))
                                Divider()
                                ForEach(languageChoices, id: \.code) { Toggle($0.name, isOn: dictates($0.code)) }
                            }
                            .fixedSize()
                        }
                    }
                    if showsChineseScript {
                        RowDivider()
                        SettingRow(L10n.tr("Chinese script"), caption: L10n.tr("Converts Chinese dictation to these characters.")) {
                            Picker(L10n.tr("Chinese script"), selection: setting(\.chineseScript)) {
                                Text(L10n.tr("As recognized")).tag(ChineseScript?.none)
                                Text(L10n.tr("Simplified")).tag(ChineseScript?.some(.simplified))
                                Text(L10n.tr("Traditional")).tag(ChineseScript?.some(.traditional))
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    RowDivider()
                    SettingRow(L10n.tr("Vocabulary"), caption: vocabularyCaption) {
                        Button(L10n.tr("Open Vocabulary")) { model.selectedPage = .vocabulary }
                    }
                    RowDivider()
                    SettingRow(L10n.tr("Unload speech model when idle"), caption: L10n.tr("Frees memory between dictations. The next dictation loads the model again, so it can take a moment longer to finish.")) {
                        Picker(L10n.tr("Unload speech model when idle"), selection: Binding(
                            get: { model.settings.unloadModelWhenIdle },
                            set: { model.settings.unloadModelWhenIdle = $0; model.saveSettings(); model.scheduleIdleUnload() }
                        )) {
                            Text(L10n.tr("Never")).tag(ModelIdleUnload.never)
                            Text(L10n.tr("After 5 minutes")).tag(ModelIdleUnload.fiveMinutes)
                            Text(L10n.tr("After 15 minutes")).tag(ModelIdleUnload.fifteenMinutes)
                            Text(L10n.tr("After 1 hour")).tag(ModelIdleUnload.oneHour)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    RowDivider()
                    SettingRow(L10n.tr("Input sensitivity"), caption: L10n.tr("Lower filters help quiet voices but let more background noise through.")) {
                        Picker(L10n.tr("Input sensitivity"), selection: setting(\.silenceThreshold)) {
                            Text(L10n.tr("Standard")).tag(Float(0.002))
                            Text(L10n.tr("Quiet voice")).tag(Float(0.0005))
                            Text(L10n.tr("No filter")).tag(Float(0))
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(model.isBusy)
                    }
                }

                SettingsSection(L10n.tr("After you speak")) {
                    SettingToggle(L10n.tr("Write numbers as digits"), caption: L10n.tr("“Two tickets for PR forty-two” becomes “2 tickets for PR 42”, in any language. Turn off to keep numbers as spoken words."), isOn: setting(\.writesNumbersAsDigits))
                    RowDivider()
                    SettingToggle(L10n.tr("Paste into the active app"), caption: L10n.tr("Needs Accessibility. Otherwise, text is copied."), isOn: setting(\.autoPaste))
                    RowDivider()
                    SettingToggle(L10n.tr("Add a space after pasting"), caption: L10n.tr("So the next dictation doesn’t run into this one. Skipped after Chinese or Japanese."), isOn: setting(\.appendTrailingSpace))
                        .disabled(!model.settings.autoPaste)
                    RowDivider()
                    SettingToggle(L10n.tr("Send to Claude"), caption: L10n.tr("Press Return after pasting into Claude Desktop, or into Claude Code in the VS Code panel, Terminal or iTerm2. Elsewhere, text is only pasted. Hold Shift to paste only. Return also answers a Claude Code question, such as a permission prompt."), isOn: sendToClaude)
                        .task(id: permissionCheck) { await loadTerminals() }
                        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in permissionCheck += 1 }
                    if model.settings.sendsAfterPaste {
                        RowDivider()
                        SettingRow(L10n.tr("Wait before sending"), caption: L10n.tr("The capsule counts down before the send key. Dictate again during it to add more, and the next dictation sends both, or click Don’t send.")) {
                            Picker(L10n.tr("Wait before sending"), selection: setting(\.sendDelayMilliseconds)) {
                                ForEach(ClaudePrompt.delayChoices, id: \.self) { milliseconds in
                                    let label = milliseconds < 1_000 ? L10n.tr("%@ ms", String(milliseconds)) : L10n.tr("%ld seconds", milliseconds / 1_000)
                                    Text(milliseconds == ClaudePrompt.defaultDelay ? L10n.tr("%@ (default)", String(label)) : label)
                                        .tag(milliseconds == ClaudePrompt.defaultDelay ? Int?.none : Optional(milliseconds))
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    if model.settings.sendToClaude {
                        ForEach(terminals, id: \.bundleID) { terminal in
                            RowDivider()
                            SettingRow(terminal.name, caption: terminal.allowed ? L10n.tr("Allowed to tell BetterWispr which tab is in front.") : L10n.tr("BetterWispr asks %@ which tab is in front, to send only where Claude Code runs. Open %@ to allow it.", String(terminal.name), String(terminal.name))) {
                                if !terminal.allowed {
                                    Button(L10n.tr("Allow…")) { Task { await ClaudePrompt.requestTerminalPermission(); permissionCheck += 1 } }
                                        .disabled(!terminal.isOpen)
                                }
                            }
                        }
                    }
                    RowDivider()
                    SettingToggle(L10n.tr("Copy to clipboard"), caption: L10n.tr("Keep each dictation ready to paste again. When off, your clipboard is left as it was."), isOn: setting(\.copyToClipboard))
                    RowDivider()
                    SettingToggle(L10n.tr("Learn from my corrections"), caption: L10n.tr("Words you fix in History, or in the text field within 30 seconds of a paste, are added to Vocabulary. With Medium cleanup, each English fix and a few words around it are first reviewed by the selected notes model."), isOn: setting(\.learnCorrections))
                    if model.settings.learnCorrections {
                        RowDivider()
                        SettingToggle(L10n.tr("Notify when a word is learned"), caption: L10n.tr("Show what was added to Vocabulary, with Undo. When off, words are still learned quietly; review them in Vocabulary."), isOn: setting(\.notifyLearnedCorrections))
                    }
                }

                SendKeysSection(model: model)

                SettingsSection(L10n.tr("App")) {
                    SettingToggle(L10n.tr("Show in Dock"), caption: L10n.tr("When off, use the menu bar to open BetterWispr. Your dictation shortcut still works."), isOn: setting(\.showInDock))
                    RowDivider()
                    SettingToggle(L10n.tr("Dictation sounds"), caption: L10n.tr("Soft cues when dictation starts listening, finishes, cancels or needs attention. Quiet during meeting capture."), isOn: setting(\.soundEffects))
                    if model.settings.soundEffects {
                        RowDivider()
                        SettingRow(L10n.tr("Sound volume")) {
                            Slider(value: setting(\.soundVolume), in: AppSettings.soundVolumeRange) {
                                Text(L10n.tr("Sound volume"))
                            } onEditingChanged: { editing in
                                if !editing { model.playFeedback(.started) }
                            }
                            .labelsHidden()
                            .frame(width: 160)
                        }
                    }
                    if model.settings.soundEffects {
                        ForEach(DictationSound.allCases, id: \.self) { cue in
                            let overridden = cue.url(in: DictationSound.overrideDirectory) != nil
                            RowDivider()
                            SettingRow(L10n.tr("%@ sound", String(cue.title)), caption: overridden ? L10n.tr("Plays %@.wav from your SoundOverrides folder instead.", String(cue.rawValue)) : nil) {
                                Picker(L10n.tr("%@ sound", String(cue.title)), selection: sound(cue)) {
                                    ForEach(DictationSound.systemSoundNames, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                                .fixedSize()
                                .disabled(overridden)
                            }
                        }
                    }
                    RowDivider()
                    SettingToggle(L10n.tr("Pause music while dictating"), caption: L10n.tr("Pauses Music and Spotify while you speak, then resumes them. Browsers and other players keep playing. macOS asks for permission for each of these apps that is open when you turn this on."), isOn: pauseMediaWhileDictating)
                    if #available(macOS 14.2, *) {
                        RowDivider()
                        SettingToggle(L10n.tr("Mute other apps while dictating"), caption: L10n.tr("Silences other apps, such as a video in your browser, while you speak. Videos keep playing silently, and your volume and mute settings don’t change. Nothing is muted if meeting notes are recording, or if a browser or a known call app such as Zoom, Teams or FaceTime is using the microphone when you start. Any other call goes silent while you speak. macOS asks to use system audio when you turn this on. Whether other apps come back on their own if BetterWispr crashes during a dictation hasn’t been tested."), isOn: muteOtherAppsWhileDictating)
                    }
                    RowDivider()
                    SettingToggle(L10n.tr("Floating recording capsule"), caption: L10n.tr("A small voice control at the bottom of your screen."), isOn: setting(\.showCapsule))
                    RowDivider()
                    SettingToggle(L10n.tr("Hide capsule while dictating"), caption: L10n.tr("Keeps the capsule out of sight while you speak and while text is transcribed. Errors, Undo and the warning before a long dictation stops still appear. The menu bar icon turns into a microphone while you speak."), isOn: setting(\.hideCapsuleWhileDictating))
                    RowDivider()
                    SettingToggle(L10n.tr("Tell me when no speech is heard"), caption: L10n.tr("Shows “No speech heard.” with a sound when a dictation ends without words. When off, it closes quietly."), isOn: setting(\.showNoSpeechNotice))
                    RowDivider()
                    SettingToggle(L10n.tr("Show words as you speak"), caption: L10n.tr("Previews Parakeet’s recognition in the capsule while you record. The pasted text is still the full recognition."), isOn: setting(\.showLiveText))
                        .disabled(model.settings.hideCapsuleWhileDictating)
                    RowDivider()
                    SettingToggle(L10n.tr("Detect meetings"), caption: L10n.tr("Offer the notetaker when Zoom, Google Meet, Teams, a Slack huddle or another call starts using the microphone. Calls in a browser need Accessibility."), isOn: setting(\.detectMeetings))
                    if model.settings.detectMeetings {
                        RowDivider()
                        SettingRow(L10n.tr("Meeting prompt position"), caption: L10n.tr("Where “Meeting detected” appears, on the screen showing the call. At the top it sits below the menu bar and camera.")) {
                            Picker(L10n.tr("Meeting prompt position"), selection: setting(\.meetingPromptPosition)) {
                                Text(L10n.tr("Top center")).tag(MeetingPromptPosition.top)
                                Text(L10n.tr("Bottom center")).tag(MeetingPromptPosition.bottom)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        RowDivider()
                        SettingRow(L10n.tr("Close meeting prompt"), caption: L10n.tr("A countdown shows beside Start notetaker. When it ends, nothing is recorded and the prompt doesn’t return until that call ends.")) {
                            Picker(L10n.tr("Close meeting prompt"), selection: setting(\.meetingPromptTimeout)) {
                                Text(L10n.tr("After 15 seconds")).tag(MeetingPromptTimeout.fifteenSeconds)
                                Text(L10n.tr("After 30 seconds")).tag(MeetingPromptTimeout.thirtySeconds)
                                Text(L10n.tr("After 60 seconds")).tag(MeetingPromptTimeout.sixtySeconds)
                                Text(L10n.tr("Never")).tag(MeetingPromptTimeout.never)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    RowDivider()
                    SettingToggle(L10n.tr("Open at login"), caption: L10n.tr("Have BetterWispr ready when your Mac starts."), isOn: setting(\.launchAtLogin))
                    RowDivider()
                    SettingToggle(L10n.tr("Save dictation history"), caption: model.settings.saveHistory ? L10n.tr("Keep text on this Mac so you can find and reuse it, and the audio of dictations that couldn’t be transcribed. Turning this off deletes that audio.") : L10n.tr("New dictations aren’t saved and no audio is kept. Dictations already saved stay, and Keep history deletes nothing while this is off."), isOn: setting(\.saveHistory))
                    if model.settings.saveHistory {
                        RowDivider()
                        SettingRow(L10n.tr("Keep history"), caption: L10n.tr("Older dictations are deleted from this Mac when BetterWispr opens and after each dictation. Usage totals and Insights count only the dictations kept. Audio kept from failed dictations follows the same age limit.")) {
                            Picker(L10n.tr("Keep history"), selection: Binding(
                                get: { model.settings.historyRetention },
                                set: { retention in
                                    if model.historyRemoved(by: retention) > 0 { pendingRetention = retention } else { model.setHistoryRetention(retention) }
                                }
                            )) {
                                Text(L10n.tr("Forever")).tag(HistoryRetention.forever)
                                Text(L10n.tr("Latest 100")).tag(HistoryRetention.latest100)
                                Text(L10n.tr("3 days")).tag(HistoryRetention.threeDays)
                                Text(L10n.tr("2 weeks")).tag(HistoryRetention.twoWeeks)
                                Text(L10n.tr("3 months")).tag(HistoryRetention.threeMonths)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }

                SettingsSection(L10n.tr("Calendar")) {
                    SettingToggle(L10n.tr("Use Calendar"), caption: model.settings.useCalendar && !model.calendarGranted
                                      ? L10n.tr("Waiting for Calendar access. Choose Allow… for Calendar under Permissions.")
                                      : L10n.tr("A meeting note started during an event takes its title and the people invited."),
                                  isOn: Binding(get: { model.settings.useCalendar }, set: { model.useCalendar($0) }))
                    if model.settings.useCalendar, model.calendarGranted {
                        ForEach(model.calendarAccounts) { account in
                            RowDivider()
                            Text(account.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(account.calendars) { calendar in
                                if calendar.id != account.calendars.first?.id { RowDivider() }
                                SettingToggle(calendar.title, isOn: includes(calendar))
                            }
                        }
                    }
                } footer: {
                    Text(L10n.tr("Reads the accounts in the Calendar app on this Mac, including shared and subscribed calendars, and works offline. The event title and invitees go to your notes model with the transcript."))
                }

                ConnectedAppsSection(model: model)

                SettingsSection(L10n.tr("Permissions")) {
                    PermissionStatusRow(title: L10n.tr("Microphone"), caption: L10n.tr("Needed to hear your voice."), granted: model.microphoneGranted, action: model.requestMicrophone)
                    RowDivider()
                    PermissionStatusRow(title: L10n.tr("Accessibility"), caption: L10n.tr("Needed for automatic paste, modifier-key shortcuts and cleaning up selected text."), granted: model.accessibilityGranted, action: model.requestAccessibility)
                    RowDivider()
                    PermissionStatusRow(title: L10n.tr("Calendar"), caption: L10n.tr("Optional. Turns on Use Calendar for meeting notes."), granted: model.calendarGranted) { model.useCalendar(true) }
                } footer: {
                    Label(L10n.tr("Built-in models process speech on this Mac. A selected API connection sends audio to its endpoint. Codex subscription transcription sends audio directly to ChatGPT through an unofficial endpoint. Temporary recordings are removed after processing; external providers control their own retention."), systemImage: "lock.shield")
                }

                SettingsSection(L10n.tr("Voice commands")) {
                    ForEach(Array(Self.voiceCommands.enumerated()), id: \.offset) { index, command in
                        if index > 0 { RowDivider() }
                        SettingRow(command.0) {
                            Text(command.1)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06), in: .capsule)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } footer: {
                    Text(L10n.tr("Say these while dictating in English or Auto language. Words like “the Oxford comma” stay as written."))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .toggleStyle(.switch)
        .animation(.ui, value: model.microphoneGranted)
        .animation(.ui, value: model.accessibilityGranted)
        .animation(.ui, value: model.calendarGranted)
        .animation(.ui, value: model.settings.useCalendar)
        .animation(.ui, value: model.calendarAccounts)
        .alert(L10n.tr("Delete older dictations?"), isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } }),
               presenting: pendingRetention) { retention in
            Button(L10n.tr("Delete"), role: .destructive) { model.setHistoryRetention(retention) }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: { retention in
            let count = model.historyRemoved(by: retention)
            Text(L10n.tr("%ld dictations will be deleted from this Mac. Usage totals and Insights will shrink, because they count saved dictations. This can’t be undone.", count))
        }
    }

    static let spokenLanguages = [
        (code: "en", name: L10n.tr("English")), (code: "hi", name: L10n.tr("Hindi")), (code: "es", name: L10n.tr("Spanish")),
        (code: "fr", name: L10n.tr("French")), (code: "de", name: L10n.tr("German")), (code: "it", name: L10n.tr("Italian")),
        (code: "pt", name: L10n.tr("Portuguese")), (code: "ja", name: L10n.tr("Japanese")), (code: "ko", name: L10n.tr("Korean")),
        (code: "zh", name: L10n.tr("Chinese")), (code: "ar", name: L10n.tr("Arabic")), (code: "tr", name: L10n.tr("Turkish")),
    ]

    private var languageChoices: [(code: String, name: String)] {
        let selected = model.selectedModel
        let choices = selected.languages.map { codes in
            codes.map { (code: $0, name: L10n.locale.localizedString(forLanguageCode: $0) ?? $0) }.sorted { $0.name < $1.name }
        } ?? Self.spokenLanguages
        let current = model.settings.language
        guard current != "auto", !choices.contains(where: { $0.code == current }) else { return choices }
        let name = L10n.locale.localizedString(forLanguageCode: current) ?? current
        return choices + [(code: current, name: L10n.tr("%@ (not supported by %@)", String(name), String(selected.name)))]
    }

    private var dictationLanguageNames: [String] {
        languageChoices.filter { model.settings.dictationLanguages.contains($0.code) }.map(\.name)
    }

    private var dictationLanguagesLabel: String {
        let names = dictationLanguageNames
        return names.isEmpty ? L10n.tr("All languages") : names.count > 2 ? L10n.tr("%@ languages", String(names.count)) : names.joined(separator: ", ")
    }

    private var showsChineseScript: Bool {
        let language = model.settings.language
        return language == "auto" ? model.selectedModel.languages?.contains("zh") ?? true : SpeechModel.engineLanguage(language) == "zh"
    }

    private func dictates(_ code: String) -> Binding<Bool> {
        Binding(
            get: { model.settings.dictationLanguages.contains(code) },
            set: { isOn in
                if isOn { model.settings.dictationLanguages.insert(code) } else { model.settings.dictationLanguages.remove(code) }
                model.saveSettings()
            }
        )
    }

    private var vocabularyCaption: String {
        guard model.selectedModel.engine == .parakeet, model.settings.usePhraseBooster else {
            return L10n.tr("Add the names and terms you say often so they’re written your way.")
        }
        return model.phraseBoosterInstalled
            ? L10n.tr("Add the names and terms you say often. When you speak English, the phrase booster listens for them and fixes their spelling.")
            : L10n.tr("Add the names and terms you say often, then download the phrase booster there so Parakeet listens for them. About 100 MB, runs on this Mac.")
    }

    private var sendToClaude: Binding<Bool> {
        Binding(get: { model.settings.sendToClaude }, set: { isOn in
            model.settings.sendToClaude = isOn
            model.saveSettings()
            guard isOn else { return }
            // Let open Electron apps build their accessibility tree before the first dictation reads it.
            NSWorkspace.shared.runningApplications.forEach(ClaudePrompt.prepare)
            Task { await ClaudePrompt.requestTerminalPermission(); permissionCheck += 1 }
        })
    }

    private struct ScriptableTerminal {
        let bundleID: String
        let name: String
        let isOpen: Bool
        let allowed: Bool
    }

    /// Installed scriptable terminals and whether BetterWispr may ask them for their focused tab, checked off the main thread.
    private func loadTerminals() async {
        guard model.settings.sendToClaude else { return }
        var found: [ScriptableTerminal] = []
        for bundleID in ClaudePrompt.scriptableTerminals {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let allowed = await ClaudePrompt.terminalAllowed(bundleID)
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            found.append(ScriptableTerminal(bundleID: bundleID, name: name, isOpen: allowed != nil, allowed: allowed == true))
        }
        terminals = found
    }

    private var pauseMediaWhileDictating: Binding<Bool> {
        Binding(get: { model.settings.pauseMediaWhileDictating }, set: { isOn in
            model.settings.pauseMediaWhileDictating = isOn
            model.saveSettings()
            if isOn { Task { await AppleEventMediaPlayers.requestPermission() } }
        })
    }

    private var muteOtherAppsWhileDictating: Binding<Bool> {
        Binding(get: { model.settings.muteOtherAppsWhileDictating }, set: { isOn in
            model.settings.muteOtherAppsWhileDictating = isOn
            model.saveSettings()
            guard isOn, #available(macOS 14.2, *) else { return }
            Task { await SystemAudioMute.requestPermission() }
        })
    }

    private func includes(_ calendar: CalendarInfo) -> Binding<Bool> {
        Binding(
            get: { !model.settings.excludedCalendarIDs.contains(calendar.id) },
            set: { isOn in
                if isOn { model.settings.excludedCalendarIDs.remove(calendar.id) } else { model.settings.excludedCalendarIDs.insert(calendar.id) }
                model.saveSettings()
            }
        )
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0; model.saveSettings() }
        )
    }

    private func sound(_ cue: DictationSound) -> Binding<String> {
        Binding(
            get: { model.settings.soundName(for: cue) },
            set: { model.settings.sounds[cue] = $0; model.saveSettings(); model.playFeedback(cue) }
        )
    }
}

private struct ShortcutRecorder: View {
    enum Kind { case dictation, cancel, selectedText }

    let model: AppModel
    let kind: Kind
    @State private var monitor: Any?
    @State private var held: ShortcutModifiers = []
    @State private var modifierCandidate: DictationShortcut?
    @State private var feedback: String?
    @State private var recorderID = UUID()

    private var isCapturing: Bool { monitor != nil }
    private var shortcut: DictationShortcut? {
        switch kind {
        case .dictation: model.settings.shortcut
        case .cancel: model.settings.cancelShortcut
        case .selectedText: model.settings.selectedTextShortcut
        }
    }
    private var title: String {
        switch kind {
        case .dictation: L10n.tr("Keyboard shortcut")
        case .cancel: L10n.tr("Cancel shortcut")
        case .selectedText: L10n.tr("Clean up selected text")
        }
    }
    private var placeholder: String { kind == .dictation ? "" : L10n.tr("Set Shortcut…") }

    var body: some View {
        SettingRow(title, caption: caption) {
            HStack(spacing: 6) {
                if kind == .dictation, shortcut != .optionSpace, !isCapturing {
                    Button(L10n.tr("Reset to %@", String(DictationShortcut.optionSpace.spokenName)), systemImage: "arrow.counterclockwise") {
                        stop()
                        model.changeShortcut(.optionSpace)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(L10n.tr("Reset to %@", String(DictationShortcut.optionSpace.displayName)))
                    .transition(.opacity)
                } else if kind != .dictation, shortcut != nil, !isCapturing {
                    Button(L10n.tr("Clear"), systemImage: "xmark.circle") { change(nil) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(kind == .cancel ? L10n.tr("Remove the cancel shortcut") : L10n.tr("Remove the clean up shortcut"))
                    .transition(.opacity)
                }
                recordButton
                    .accessibilityLabel(isCapturing ? L10n.tr("%@, waiting for keys", String(title)) : L10n.tr("%@, %@", String(title), String(shortcut?.spokenName ?? L10n.tr("not set"))))
                    .accessibilityHint(kind == .dictation ? L10n.tr("Click, then press a shortcut, or press and release a modifier key such as Option.")
                                                          : L10n.tr("Click, then press a shortcut that includes a key, such as Control Option K."))
            }
            .disabled(model.isBusy)
        }
        .animation(.ui, value: isCapturing)
        .onChange(of: feedback) { _, text in if let text { AccessibilityNotification.Announcement(text).post() } }
        .onChange(of: model.capturingRecorder) { _, recorder in
            if recorder != recorderID { stop() }
        }
        .onDisappear(perform: stop)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private var caption: String? {
        if isCapturing {
            return feedback ?? (kind == .dictation ? L10n.tr("Press and release ⌃, ⌥, ⇧, ⌘ or Fn alone, use a key combination, or press an F-key. Esc cancels.")
                                                   : L10n.tr("Hold ⌃, ⌥ or ⌘ and press a key, or press an F-key. Esc leaves it as is."))
        }
        switch kind {
        case .dictation:
            if shortcut?.keyCode == UInt32(kVK_Function) { return L10n.tr("Needs Accessibility. Set “Press 🌐 key to” to “Do Nothing” in Keyboard settings.") }
            return shortcut?.isModifierOnly == true ? L10n.tr("Needs Accessibility. Uses the left or right key you recorded.") : L10n.tr("Starts dictation from any app.")
        case .cancel: return L10n.tr("Also cancels a dictation from any app. Esc always does.")
        case .selectedText: return L10n.tr("Edits the text you select in any app with your cleanup provider from Style. English only.")
        }
    }

    @ViewBuilder private var recordButton: some View {
        let button = Button {
            if isCapturing { stop() } else { start() }
        } label: {
            Text(isCapturing ? (held.isEmpty ? L10n.tr("Type shortcut…") : held.symbols + " …") : (shortcut?.displayName ?? placeholder))
                .frame(minWidth: 96)
                .contentTransition(.opacity)
        }
        if isCapturing { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
    }

    private func start() {
        held = []
        modifierCandidate = nil
        feedback = nil
        model.beginKeyCapture(recorderID)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            MainActor.assumeIsolated { capture(event) }
            return nil
        }
    }

    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        modifierCandidate = nil
        model.endKeyCapture(recorderID)
    }

    private func change(_ shortcut: DictationShortcut?) {
        switch kind {
        case .dictation: if let shortcut { model.changeShortcut(shortcut) }
        case .cancel: model.changeCancelShortcut(shortcut)
        case .selectedText: model.changeSelectedTextShortcut(shortcut)
        }
    }

    private func capture(_ event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers = ShortcutModifiers(Self.modifierFlags.filter { flags.contains($0.flag) }.map(\.modifier))
        // Arrow and F-key presses also carry the Fn flag, so only track Fn from its own key transitions.
        guard event.type == .keyDown else {
            if flags.contains(.function) { modifiers.insert(.function) }
            return modifiersChanged(to: modifiers, keyCode: Int(event.keyCode))
        }
        modifierCandidate = nil
        if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty { return stop() }
        let key = Self.keyNames[Int(event.keyCode)] ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        guard let shortcut = DictationShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key) else {
            let displayedKey = DictationShortcut.localizedKeyName(keyCode: UInt32(event.keyCode), fallback: key)
            let pressed = modifiers.isEmpty ? displayedKey : modifiers.symbols + " " + displayedKey
            feedback = key.isEmpty ? L10n.tr("That key can’t be a shortcut. Try another.")
                                   : L10n.tr("%@ is for typing, so it can’t be a shortcut. Hold ⌃, ⌥ or ⌘ with it.", String(pressed))
            return NSSound.beep()
        }
        change(shortcut)
        stop()
    }

    private func modifiersChanged(to modifiers: ShortcutModifiers, keyCode: Int) {
        if let candidate = modifierCandidate, candidate.keyCode == UInt32(keyCode), modifiers.isEmpty {
            change(candidate)
            return stop()
        }
        modifierCandidate = nil
        if held.isEmpty, !modifiers.isEmpty {
            feedback = nil
            if modifiers == DictationShortcut.modifier(for: UInt32(keyCode)), let key = Self.keyNames[keyCode] {
                modifierCandidate = DictationShortcut(keyCode: UInt32(keyCode), modifiers: [], key: key)
            }
        } else if !modifiers.isSuperset(of: held), feedback == nil {
            feedback = L10n.tr("Press and release one modifier alone, or hold the modifiers and press another key.")
        }
        held = modifiers
    }

    private static let modifierFlags: [(flag: NSEvent.ModifierFlags, modifier: ShortcutModifiers)] = [
        (.control, .control), (.option, .option), (.shift, .shift), (.command, .command)
    ]

    private static let keyNames: [Int: String] = [
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

/// Picks the input for dictation and meetings; switching applies to a running meeting immediately.
struct MicrophonePicker<Label: View>: View {
    let model: AppModel
    @ViewBuilder let label: Label

    var body: some View {
        Picker(selection: Binding(get: { model.settings.microphone?.id },
                                  set: { id in model.selectMicrophone(model.microphoneChoices.first { $0.id == id }) })) {
            Text(model.automaticMicrophone.map { L10n.tr("Automatic (%@)", String($0.name)) } ?? L10n.tr("Automatic")).tag(String?.none)
            ForEach(model.microphoneChoices) { device in
                Text(model.microphones.contains { $0.id == device.id } ? device.name : L10n.tr("%@ (not connected)", String(device.name)))
                    .tag(Optional(device.id))
            }
        } label: {
            label
        }
    }
}

struct SettingsSection<Content: View, Footer: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title)
            Card(padding: 0) {
                VStack(spacing: 0) { content }
            }
            footer
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }
}

extension SettingsSection where Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content) { EmptyView() }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder let control: Control

    init(_ title: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption {
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .animation(.ui, value: caption)
    }
}

struct SettingToggle: View {
    let title: String
    let caption: String?
    @Binding var isOn: Bool

    init(_ title: String, caption: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.caption = caption
        _isOn = isOn
    }

    var body: some View {
        SettingRow(title, caption: caption) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 16)
    }
}

struct PermissionStatusRow: View {
    let title: String
    let caption: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        SettingRow(title, caption: caption) {
            if granted {
                Label(L10n.tr("Allowed"), systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
                    .transition(.opacity)
            } else {
                Button(L10n.tr("Allow…"), action: action)
                    .transition(.opacity)
            }
        }
    }
}
