import BetterWisprCore
import SwiftUI

struct AboutView: View {
    @Bindable var updater: AppUpdater
    let shortcut: DictationShortcut
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.tr("Development")
    static let changelog = URL(string: "https://betterwispr.com/changelog")!
    private let repository = URL(string: "https://github.com/opennookorg/betterwispr")!

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    BrandMark(size: 72)
                    Text("BetterWispr").font(.title.weight(.semibold))
                    Text(L10n.tr("Version %@", String(Self.version)))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(L10n.tr("Dictation for your Mac. Press %@ in any app, speak, and your words appear where you’re typing. Speech runs on this Mac by default. Choosing an API connection or Codex subscription transcription sends audio to that provider.", String(shortcut.displayName)))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 480)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                Toggle(isOn: $updater.automaticallyChecksForUpdates) {
                    Text(L10n.tr("Check for updates automatically"))
                    Text(L10n.tr("Looks for a new release on GitHub once a day."))
                }
                Toggle(isOn: $updater.automaticallyDownloadsUpdates) {
                    Text(L10n.tr("Download and install automatically"))
                    Text(L10n.tr("New versions install the next time BetterWispr quits."))
                }
                .disabled(!updater.automaticallyChecksForUpdates)
                Button(L10n.tr("Check for Updates…"), action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } header: {
                Text(L10n.tr("Updates"))
            } footer: {
                Text(L10n.tr("Update checks contact GitHub only. They never include your audio or text."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Link(L10n.tr("View on GitHub"), destination: repository)
                } label: {
                    Text(L10n.tr("Source code"))
                    Text(L10n.tr("Browse the code and every release."))
                }
                LabeledContent {
                    Link(L10n.tr("Open an Issue"), destination: repository.appending(path: "issues"))
                } label: {
                    Text(L10n.tr("Feedback"))
                    Text(L10n.tr("Report a bug or suggest a feature."))
                }
                LabeledContent {
                    Link(L10n.tr("What’s New"), destination: Self.changelog)
                } label: {
                    Text(L10n.tr("Changelog"))
                    Text(L10n.tr("See what changed in each release."))
                }
                LabeledContent {
                    Link(L10n.tr("Buy Me a Coffee"), destination: URL(string: "https://buymeacoffee.com/code_kartik")!)
                } label: {
                    Text(L10n.tr("Support"))
                    Text(L10n.tr("Help fund BetterWispr’s development."))
                }
            } header: {
                Text(L10n.tr("Open Source"))
            } footer: {
                Text(L10n.tr("BetterWispr is free and open source under the Apache 2.0 license. If it saves you some typing, a star on GitHub helps others find it."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.tr("Credits")) {
                LabeledContent(L10n.tr("Created by"), value: "Kartik Labhshetwar")
                LabeledContent(L10n.tr("Follow along")) {
                    Link(L10n.tr("@code_kartik on X"), destination: URL(string: "https://x.com/code_kartik")!)
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}
