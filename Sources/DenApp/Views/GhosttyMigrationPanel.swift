import SwiftUI

/// The palette's Ghostty migration: steps tick off as they run, then a
/// summary with the way out.
struct GhosttyMigrationPanel: View {
    let run: GhosttyMigrationRun
    let theme: Theme
    let openConfig: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            VStack(alignment: .leading, spacing: 1) {
                ForEach(run.steps) { step in
                    stepRow(step)
                }
            }
            switch run.phase {
            case .running: EmptyView()
            case .finished: footer(message: nil)
            case .failed(let message): footer(message: message)
            }
        }
        .animation(.denFast, value: run)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Group {
                switch run.phase {
                case .running: ProgressView().controlSize(.small).scaleEffect(0.8)
                case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent)
                case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(theme.tertiaryText)
                }
            }
            .uiFont(size: 14)
            .frame(width: 16, height: 16)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .id(phaseKey)
            Text(title)
                .uiFont(size: 13.5, weight: .medium)
                .foregroundStyle(theme.chromeText)
                .contentTransition(.opacity)
            Spacer()
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.hover))
    }

    private var phaseKey: String {
        switch run.phase {
        case .running: "running"
        case .finished: "finished"
        case .failed: "failed"
        }
    }

    private var title: String {
        switch run.phase {
        case .running: "Migrating from Ghostty…"
        case .finished: "Migrated from Ghostty"
        case .failed: "Migration stopped"
        }
    }

    private func stepRow(_ step: GhosttyMigrationRun.Step) -> some View {
        let dim = theme.tertiaryText
        let pending = step.status == .pending
        return HStack(spacing: 8) {
            glyph(step.status)
                .frame(width: 16)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .id(glyphKey(step.status))
            Text(step.id.title)
                .uiFont(size: 13.5)
                .foregroundStyle(pending ? dim : theme.chromeText)
            Spacer(minLength: 10)
            if let detail = detail(step.status) {
                Text(detail)
                    .uiFont(size: 12.5)
                    .foregroundStyle(dim)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
    }

    @ViewBuilder
    private func glyph(_ status: GhosttyMigrationRun.Status) -> some View {
        switch status {
        case .pending: Circle().strokeBorder(theme.tertiaryText.opacity(0.5), lineWidth: 1).frame(width: 9, height: 9)
        case .running: ProgressView().controlSize(.small).scaleEffect(0.6)
        case .done: Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.accent)
        case .skipped: Image(systemName: "minus").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.tertiaryText)
        case .failed: Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.tertiaryText)
        }
    }

    private func glyphKey(_ status: GhosttyMigrationRun.Status) -> String {
        switch status {
        case .pending: "pending"
        case .running: "running"
        case .done: "done"
        case .skipped: "skipped"
        case .failed: "failed"
        }
    }

    private func detail(_ status: GhosttyMigrationRun.Status) -> String? {
        switch status {
        case .pending, .running: nil
        case .done(let s), .skipped(let s), .failed(let s): s
        }
    }

    private func footer(message: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message {
                Text(message)
                    .uiFont(size: 12.5)
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
            }
            HStack(spacing: 6) {
                Spacer()
                PanelButton(title: "Open Config", shortcut: "⌥⌘,", prominent: false, theme: theme, action: openConfig)
                PanelButton(title: "Done", shortcut: "↩", prominent: true, theme: theme, action: done)
            }
        }
        .padding(.top, 4)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

private struct PanelButton: View {
    let title: String
    let shortcut: String
    let prominent: Bool
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).uiFont(size: 12.5, weight: .medium)
                Text(shortcut).uiFont(size: 11.5).opacity(0.7)
            }
            .foregroundStyle(prominent ? theme.onAccent : theme.chromeText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? theme.accent : (hovering ? theme.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.hitArea)
        .onHover { hovering = $0 }
    }
}
