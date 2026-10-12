import SwiftUI

/// How a remote host's connection reads in menus.
enum HostStatus {
    private static func percent(_ sent: Int, _ total: Int) -> Int { total > 0 ? sent * 100 / total : 0 }

    static func short(_ state: RemoteState) -> String {
        switch state {
        case .connecting: "Connecting…"
        case .uploading(let sent, let total, let isUpdate): "\(isUpdate ? "Updating" : "Installing") dend \(percent(sent, total))%"
        case .needsLogin: "Needs login"
        case .connected: "Connected"
        case .reconnecting(_, let retryIn): "Retrying in \(retryIn)s"
        case .failed: "Failed"
        case .disconnected: "Disconnected"
        }
    }

    /// The full explanation, for tooltips and the session menu.
    static func detail(_ state: RemoteState) -> String {
        switch state {
        case .connecting(let step): step
        case .uploading(let sent, let total, let isUpdate):
            "\(isUpdate ? "Updating" : "Installing") dend on the host: \(sent >> 20) of \(total >> 20) MB sent. Slow links take a few minutes."
        case .needsLogin: "Key login was refused. Log in with a user name and password."
        case .connected(let hostName): "Connected to \(hostName)"
        case .reconnecting(let reason, let retryIn): "\(reason) Retrying in \(retryIn)s."
        case .failed(let reason): reason
        case .disconnected: "Disconnected. Sessions keep running on the host; connect again to pick them up."
        }
    }

    static func color(_ state: RemoteState?, theme: Theme) -> Color {
        switch state {
        case .connected: .green
        case .connecting, .uploading, .reconnecting: .orange
        case .needsLogin, .failed: .red
        case .disconnected, nil: theme.tertiaryText
        }
    }
}

/// Asks for a host's user name and password. The password goes to the
/// Keychain; with "install a key", later logins don't need it.
struct LoginForm: View {
    @Environment(AppModel.self) private var model
    let request: LoginRequest
    @State private var user = ""
    @State private var password = ""
    @State private var installKey = true
    @FocusState private var focus: Field?

    private enum Field { case user, password }

    var body: some View {
        let theme = model.theme
        let address = model.remoteHost(request.host)?.address ?? "host"
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(theme.tertiaryText)
                Text("Log in to \(address)").uiFont(size: 14, weight: .semibold).lineLimit(1).truncationMode(.middle)
            }
            if let message = request.message {
                Text(message).uiFont(size: 12).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                field("User", text: $user, secure: false).focused($focus, equals: .user)
                field("Password", text: $password, secure: true).focused($focus, equals: .password)
            }
            Toggle("Install a key so the password isn't needed next time", isOn: $installKey)
                .toggleStyle(.checkbox)
                .uiFont(size: 12)
                .foregroundStyle(theme.secondaryText)
            Text("The password is saved in your login Keychain.")
                .uiFont(size: 11)
                .foregroundStyle(theme.tertiaryText)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelLogin() }
                    .keyboardShortcut(.cancelAction)
                Button("Log In") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(user.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
        }
        .foregroundStyle(theme.chromeText)
        .padding(18)
        .frame(width: 360)
        .background(MenuSurface(theme: theme))
        .onAppear {
            user = request.user
            KeyboardFocus.takeFromTerminal { focus = request.user.isEmpty ? .user : .password }
        }
    }

    private func field(_ title: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure {
                SecureField(title, text: text)
            } else {
                TextField(title, text: text)
            }
        }
        .textFieldStyle(.plain)
        .uiFont(size: 13)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(model.theme.hover))
        .onSubmit(submit)
    }

    private func submit() {
        guard !user.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { return }
        var updated = request
        updated.user = user
        model.logIn(updated, password: password, installKey: installKey)
    }
}

/// Rename and remove for a saved host, shown on hover in host lists.
/// Removing takes a second click, since it disconnects the host's sessions.
struct HostActions: View {
    let host: RemoteHost.ID
    /// Icon color, so the controls read on a highlighted row too.
    let color: Color
    let rename: () -> Void
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        let theme = model.theme
        HStack(spacing: 2) {
            if confirming {
                Button { model.removeRemoteHost(host) } label: {
                    Text("Remove")
                        .uiFont(size: 11, weight: .semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            } else {
                if model.remoteStates[host]?.isConnected == true {
                    HostActionButton(symbol: "power", color: color, theme: theme) { model.disconnectHost(host) }
                        .denTooltip("Disconnect")
                }
                HostActionButton(symbol: "pencil", color: color, theme: theme, action: rename)
                    .denTooltip("Rename Host")
                HostActionButton(symbol: "trash", color: color, theme: theme) { confirming = true }
                    .denTooltip("Remove Host")
            }
        }
        .animation(.denFast, value: confirming)
        .onHover { if !$0 { confirming = false } }
    }
}

private struct HostActionButton: View {
    let symbol: String
    let color: Color
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
