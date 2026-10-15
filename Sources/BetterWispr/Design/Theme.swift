import AppKit
import BetterWisprCore
import SwiftUI

struct SymbolTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    @Entry var appTheme: AppTheme = .system
}

extension Color {
    fileprivate static let systemCardFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.045) : .white
    })
    static let cardStroke = Color.primary.opacity(0.08)
    static let creamPage = Color(red: 248 / 255, green: 245 / 255, blue: 238 / 255)
    static let creamCard = Color(red: 255 / 255, green: 253 / 255, blue: 248 / 255)
}

struct ThemedFill: ShapeStyle {
    let standard: Color
    let cream: Color

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.appTheme == .cream ? cream : standard
    }
}

extension ShapeStyle where Self == ThemedFill {
    static var cardFill: ThemedFill { ThemedFill(standard: .systemCardFill, cream: .creamCard) }
    static var pageFill: ThemedFill { ThemedFill(standard: Color(nsColor: .textBackgroundColor), cream: .creamPage) }
}

struct ThemedPage: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(theme == .cream ? .hidden : .automatic)
            .background(theme == .cream ? Color.creamPage : .clear)
    }
}

extension Animation {
    static let ui = Animation.smooth(duration: 0.3)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.cardFill, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cardStroke))
    }
}

struct SectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 4)
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Small borderless link that moves to another page, e.g. "View all ›".
struct PageLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
            }
            .font(.callout)
            .foregroundStyle(hovering ? .primary : .secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.ui, value: hovering)
    }
}

struct KeyCap: View {
    let shortcut: DictationShortcut

    var body: some View {
        Text(shortcut.displayName)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .accessibilityLabel(shortcut.spokenName)
    }
}

/// Gives custom buttons an immediate press response; reduced motion keeps only the dimming.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label {
                    Text("Allowed")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .foregroundStyle(.secondary)
            } else {
                Button("Allow…", action: action)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

func durationLabel(_ duration: TimeInterval) -> String {
    let seconds = max(0, Int(duration))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
