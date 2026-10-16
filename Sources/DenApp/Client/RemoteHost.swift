import Foundation

/// Which dend a session, tab or pane lives on.
enum HostID: Hashable, Sendable {
    case local
    case remote(RemoteHost.ID)
}

/// A saved SSH destination running dend. Holds no secrets: passwords live in
/// the Keychain (`SSHPasswords`).
struct RemoteHost: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    /// Host name, Tailscale MagicDNS name or IP address.
    var address: String
    /// nil lets ssh decide (its config, else the local user name).
    var user: String?
    var port: UInt16?
    /// A name you gave it; shown instead of the address.
    var name: String?
    /// Whether Den connects on launch and keeps retrying drops. Cleared by
    /// an explicit disconnect; set again by any explicit connect. Saved with
    /// the host, so a disconnect sticks across restarts.
    var autoConnect: Bool = true

    // Custom decoding so hosts saved before autoConnect existed still load
    // (defaulting to connecting, the old behavior) instead of failing the
    // whole saved-hosts read.
    private enum CodingKeys: String, CodingKey {
        case id, address, user, port, name, autoConnect, keyLogin
    }

    init(id: UUID, address: String, user: String? = nil, port: UInt16? = nil, name: String? = nil, autoConnect: Bool = true, keyLogin: KeyLogin? = nil) {
        self.id = id
        self.address = address
        self.user = user
        self.port = port
        self.name = name
        self.autoConnect = autoConnect
        self.keyLogin = keyLogin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        address = try c.decode(String.self, forKey: .address)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        keyLogin = try c.decodeIfPresent(KeyLogin.self, forKey: .keyLogin)
    }
    /// Whether Den's own SSH key should go on the host after a password
    /// login; nil means it should. Once it's there, logins stop reading the
    /// password from the Keychain.
    var keyLogin: KeyLogin?

    enum KeyLogin: String, Codable, Sendable {
        case wanted, declined, installed
    }

    /// `user@address`, what ssh connects to.
    var destination: String { user.map { "\($0)@\(address)" } ?? address }
    var label: String { name ?? destination }

    /// The Keychain account for this host's password.
    var account: String { "\(user ?? "")@\(address):\(port ?? 22)" }

    func sameDestination(as other: RemoteHost) -> Bool {
        address.caseInsensitiveCompare(other.address) == .orderedSame && user == other.user && (port ?? 22) == (other.port ?? 22)
    }

    /// Reads `host`, `user@host`, `host:2222`, `user@[fe80::1]:2222`, and
    /// tolerates a pasted `ssh://` or `https://` prefix and trailing slash.
    static func parse(_ text: String) -> RemoteHost? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["ssh://", "https://", "http://"] where rest.lowercased().hasPrefix(scheme) {
            rest = String(rest.dropFirst(scheme.count))
        }
        while rest.hasSuffix("/") { rest.removeLast() }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            let name = String(rest[..<at])
            guard !name.isEmpty else { return nil }
            user = name
            rest = String(rest[rest.index(after: at)...])
        }
        var port: UInt16?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            // Bracketed IPv6, optionally with a port.
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") {
                guard let p = UInt16(after.dropFirst()) else { return nil }
                port = p
            } else if !after.isEmpty {
                return nil
            }
            rest = String(rest[rest.index(after: rest.startIndex) ..< close])
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            guard let p = UInt16(rest[rest.index(after: colon)...]) else { return nil }
            port = p
            rest = String(rest[..<colon])
        }
        guard !rest.isEmpty, !rest.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        return RemoteHost(id: UUID(), address: rest, user: user, port: port == 22 ? nil : port)
    }
}

/// Saved hosts, in the order they were added.
enum RemoteHostStore {
    private static let key = "remoteHosts"

    static func load(_ defaults: UserDefaults = .standard) -> [RemoteHost] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RemoteHost].self, from: data)) ?? []
    }

    static func save(_ hosts: [RemoteHost], _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Where a remote host's connection stands, as the session menu shows it.
enum RemoteState: Equatable {
    /// `step` says what's happening ("Installing dend…").
    case connecting(step: String)
    /// Sending dend to the host; bytes handed to ssh so far.
    case uploading(sent: Int, total: Int, isUpdate: Bool)
    /// Key authentication failed and no saved password worked.
    case needsLogin
    case connected(hostName: String)
    /// The connection dropped; another attempt follows in `retryIn` seconds.
    case reconnecting(reason: String, retryIn: Int)
    case failed(String)
    /// The host's dend is from an older Den and refused this one; it needs
    /// restarting, which ends its sessions. No retries meanwhile.
    case needsRestart
    /// You disconnected it; no retries until you connect again.
    case disconnected

    var isConnected: Bool { if case .connected = self { true } else { false } }
}

/// The login form: shown when a host needs a user name and password.
struct LoginRequest: Equatable {
    let host: RemoteHost.ID
    var user: String
    /// Why it's asking again, e.g. after a wrong password.
    var message: String?
}
