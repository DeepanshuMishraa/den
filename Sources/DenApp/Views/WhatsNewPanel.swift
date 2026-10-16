import AppKit
import SwiftUI

/// Shown once after an update: what the new version changed, from its
/// release notes.
struct WhatsNewPanel: View {
    @Environment(AppModel.self) private var model
    let whatsNew: WhatsNew
    @FocusState private var focused: Bool

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(theme.accent)
                Text("What's new in Den \(whatsNew.version)").uiFont(size: 14, weight: .semibold)
                Spacer()
            }
            notes(theme)
            HStack {
                Button("View on GitHub") { NSWorkspace.shared.open(whatsNew.page) }
                Spacer()
                Button("Done") { model.dismissWhatsNew() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(theme.chromeText)
        .padding(18)
        .frame(width: 440)
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
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading the release notes…").uiFont(size: 12).foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        case .unavailable(let reason):
            Text("\(reason) The full notes are on GitHub.")
                .uiFont(size: 12)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        case .loaded(let blocks):
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        row(block, theme: theme)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func row(_ block: ReleaseNotes.Block, theme: Theme) -> some View {
        switch block {
        case .heading(let title):
            Text(title)
                .uiFont(size: 12, weight: .semibold)
                .foregroundStyle(theme.secondaryText)
                .padding(.top, 4)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(theme.accent).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                Text(text).uiFont(size: 12.5).fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph(let text):
            Text(text).uiFont(size: 12.5).fixedSize(horizontal: false, vertical: true)
        }
    }
}
