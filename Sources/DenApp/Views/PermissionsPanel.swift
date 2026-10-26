import AppKit
import DenProtocol
import SwiftUI

/// A macOS privacy grant Den's shells need, as the panel and Settings show it.
enum DendPermission: CaseIterable, Identifiable {
    case fullDiskAccess, screenRecording

    var id: Self { self }

    var title: String {
        switch self {
        case .fullDiskAccess: "Full Disk Access"
        case .screenRecording: "Screen & System Audio Recording"
        }
    }

    var detail: String {
        switch self {
        case .fullDiskAccess: "Lets shells, command-line tools and agents open files in protected folders, like ~/Downloads and other apps' data."
        case .screenRecording: "Lets command-line tools and agents capture the screen, windows and system audio."
        }
    }

    var symbol: String {
        switch self {
        case .fullDiskAccess: "externaldrive"
        case .screenRecording: "rectangle.inset.filled.badge.record"
        }
    }

    /// nil while unknown: dend isn't connected, or predates the check.
    @MainActor func access(_ model: AppModel) -> HostPermissions.Access? {
        switch self {
        case .fullDiskAccess: model.permissions?.fullDiskAccess
        case .screenRecording: model.permissions?.screenRecording
        }
    }

    @MainActor func grant(_ model: AppModel) {
        switch self {
        case .fullDiskAccess: PrivacySettings.grantFullDiskAccess()
        case .screenRecording: Task { await model.requestScreenRecording() }
        }
    }
}

/// Asks for the privacy grants up front, so shells don't hit "Operation
/// not permitted" later. Each row turns into a check once macOS has it;
/// coming back from System Settings re-checks.
struct PermissionsPanel: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "lock").font(.system(size: 11.5, weight: .medium))
                Text("Grant Permissions for Den").uiFont(size: 12.5, weight: .medium)
                Spacer()
            }
            .foregroundStyle(theme.secondaryText)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .padding(.top, 22)
                .padding(.bottom, 24)

            VStack(spacing: 0) {
                ForEach(DendPermission.allCases) { permission in
                    if permission != DendPermission.allCases.first { theme.separator.frame(height: 0.5).padding(.horizontal, 14) }
                    PermissionRow(permission: permission)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.hover))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.menuBorder, lineWidth: 0.5))

            HStack(alignment: .center, spacing: 12) {
                Text(footer)
                    .uiFont(size: 11.5)
                    .foregroundStyle(theme.tertiaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                PillButton(title: "Done", theme: theme) { model.dismissPermissions() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: 480)
        .background(MenuSurface(theme: theme))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) {
            model.dismissPermissions()
            return .handled
        }
        .onAppear { KeyboardFocus.takeFromTerminal { focused = true } }
        .refreshesPermissions()
    }

    private var footer: String {
        guard !DendPermission.allCases.contains(where: { $0.access(model) == .needsRestart }) else {
            return "macOS has the grant, but dend started before you gave it. Restart dend to apply it; its sessions will end."
        }
        return "These go to dend, the process that runs your shells. For Full Disk Access, drag dend from the Finder window into the list."
    }
}

private struct PermissionRow: View {
    let permission: DendPermission
    @Environment(AppModel.self) private var model

    var body: some View {
        let theme = model.theme
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.symbol)
                .font(.system(size: 17))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 26, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(permission.title)
                    .uiFont(size: 13.5, weight: .semibold)
                    .foregroundStyle(theme.chromeText)
                Text(permission.detail)
                    .uiFont(size: 12)
                    .foregroundStyle(theme.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            PermissionStatus(permission: permission, theme: theme)
        }
        .padding(14)
    }
}

/// A check once granted; otherwise the button that asks for it.
struct PermissionStatus: View {
    let permission: DendPermission
    let theme: Theme
    @Environment(AppModel.self) private var model

    var body: some View {
        switch permission.access(model) {
        case .granted?:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .uiFont(size: 12, weight: .medium)
                .foregroundStyle(.green)
                .frame(height: 28)
        case .needsRestart?:
            VStack(alignment: .trailing, spacing: 3) {
                PillButton(title: "Restart dend…", theme: theme) { model.restartDendForPermissions() }
                    .help("macOS has this grant, but this dend started before you gave it. Restarting applies it and ends dend's sessions.")
                Text("Granted; restart to apply")
                    .uiFont(size: 10.5)
                    .foregroundStyle(theme.tertiaryText)
            }
        case .notApplicable?:
            EmptyView()
        case .missing?, nil:
            PillButton(title: "Grant…", theme: theme) { permission.grant(model) }
        }
    }
}

extension View {
    /// Re-reads dend's grants on appear and whenever Den comes back to the
    /// front, as it does after a trip to System Settings.
    func refreshesPermissions() -> some View {
        modifier(RefreshesPermissions())
    }
}

private struct RefreshesPermissions: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .task { await model.refreshPermissions() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.refreshPermissions() }
            }
    }
}
