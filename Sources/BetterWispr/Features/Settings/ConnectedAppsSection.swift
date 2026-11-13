import SwiftUI
import BetterWisprCore

struct ConnectedAppsSection: View {
    @Bindable var model: AppModel

    private var executable: String { Bundle.main.executablePath ?? "/Applications/BetterWispr.app/Contents/MacOS/BetterWispr" }
    private var quotedExecutable: String { "'" + executable.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    private var desktopConfig: String {
        let config = ["mcpServers": ["betterwispr": ["command": executable, "args": ["--mcp"]]]]
        let data = try! JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    var body: some View {
        SettingsSection(L10n.tr("Connected apps")) {
            SettingToggle(L10n.tr("Share meetings with AI apps"),
                          caption: L10n.tr("Lets Claude, Cursor and other apps that support MCP list, search and read your meeting notes and transcripts. They can’t change or delete anything."),
                          isOn: Binding(get: { model.settings.mcpServer }, set: { model.settings.mcpServer = $0; model.saveSettings() }))
            if model.settings.mcpServer {
                RowDivider()
                SnippetRow(title: "Claude Code", caption: L10n.tr("Run in Terminal."), snippet: "claude mcp add --scope user betterwispr -- \(quotedExecutable) --mcp", copy: model.copyText)
                RowDivider()
                SnippetRow(title: L10n.tr("Claude Desktop and Cursor"),
                           caption: L10n.tr("Add to ~/Library/Application Support/Claude/claude_desktop_config.json or ~/.cursor/mcp.json, keeping any servers already listed, then restart the app."),
                           snippet: desktopConfig, copy: model.copyText)
                RowDivider()
                SnippetRow(title: L10n.tr("Other apps"), caption: L10n.tr("Start this command as a local (stdio) MCP server."), snippet: "\(quotedExecutable) --mcp", copy: model.copyText)
            }
        } footer: {
            Text(L10n.tr("An app you connect reads meeting titles, attendees, summaries, your notes and transcripts, and sends what it reads to its AI provider. BetterWispr itself sends nothing. Turn this off to stop sharing right away."))
        }
    }
}

private struct SnippetRow: View {
    let title: String
    let caption: String
    let snippet: String
    let copy: @MainActor (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingRow(title, caption: caption) {
                Button(L10n.tr("Copy")) { copy(snippet) }
                    .controlSize(.small)
                    .accessibilityLabel(L10n.tr("Copy %@ setup", String(title)))
            }
            Text(snippet)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 11)
        }
    }
}
