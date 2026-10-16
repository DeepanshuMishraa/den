import AppKit
import SwiftUI

/// Shown once after an update: what the new version changed, from its
/// release notes. Quiet on purpose: a caption, a title, the notes, and one
/// way out.
struct WhatsNewPanel: View {
    @Environment(AppModel.self) private var model
    let whatsNew: WhatsNew
    @FocusState private var focused: Bool

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 0) {
            Text("Den \(whatsNew.version)")
                .uiFont(size: 11, weight: .medium)
                .foregroundStyle(theme.tertiaryText)
            Text("What's new")
                .uiFont(size: 17, weight: .semibold)
                .foregroundStyle(theme.chromeText)
                .padding(.top, 2)
            notes(theme)
                .padding(.top, 16)
            HStack(alignment: .center) {
                ReleaseLink(url: whatsNew.page, theme: theme)
                Spacer()
                PillButton(title: "Continue", theme: theme) { model.dismissWhatsNew() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(22)
        .frame(width: 400)
        .background(MenuSurface(theme: theme))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) {
            model.dismissWhatsNew()
            return .handled
        }
        .onAppear { KeyboardFocus.takeFromTerminal { focused = true } }
    }

    @ViewBuilder
    private func notes(_ theme: Theme) -> some View {
        switch whatsNew.notes {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 72)
        case .unavailable(let reason):
            Text(reason)
                .uiFont(size: 12.5)
                .foregroundStyle(theme.secondaryText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .loaded(let blocks):
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(shown(blocks).enumerated()), id: \.offset) { index, block in
                        row(block, first: index == 0, theme: theme)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The release's own "What's new" heading repeats the title.
    private func shown(_ blocks: [ReleaseNotes.Block]) -> [ReleaseNotes.Block] {
        if case .heading(let title) = blocks.first, title.lowercased().hasPrefix("what") { return Array(blocks.dropFirst()) }
        return blocks
    }

    @ViewBuilder
    private func row(_ block: ReleaseNotes.Block, first: Bool, theme: Theme) -> some View {
        switch block {
        case .heading(let title):
            Text(title.uppercased())
                .uiFont(size: 10, weight: .semibold)
                .tracking(0.6)
                .foregroundStyle(theme.tertiaryText)
                .padding(.top, first ? 0 : 6)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("–").uiFont(size: 12.5).foregroundStyle(theme.tertiaryText)
                body(text, theme: theme)
            }
        case .paragraph(let text):
            body(text, theme: theme)
        }
    }

    private func body(_ text: AttributedString, theme: Theme) -> some View {
        Text(text)
            .uiFont(size: 12.5)
            .foregroundStyle(theme.secondaryText)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Release notes ↗": opens the release on GitHub.
private struct ReleaseLink: View {
    let url: URL
    let theme: Theme
    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 3) {
                Text("Release notes")
                Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .semibold))
            }
            .uiFont(size: 11.5)
            .foregroundStyle(hovering ? theme.secondaryText : theme.tertiaryText)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A quiet capsule, like the toast's buttons.
private struct PillButton: View {
    let title: String
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .uiFont(size: 12, weight: .semibold)
                .foregroundStyle(theme.chromeText)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.isDark ? Color.white.opacity(hovering ? 0.14 : 0.09) : Color.black.opacity(hovering ? 0.1 : 0.06)))
                .overlay(Capsule().strokeBorder(theme.menuBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
