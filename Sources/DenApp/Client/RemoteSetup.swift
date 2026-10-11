import CryptoKit
import Foundation

/// Getting dend onto a host: find out what it runs, upload the matching
/// build to `~/.den/bin/dend` when it's missing or different, and start it.
/// Every remote command runs under `sh -c` so the user's login shell (fish,
/// nushell…) doesn't matter.
enum RemoteSetup {
    /// What `probeCommand` found.
    struct Probe: Equatable {
        /// `uname -s`: Linux, Darwin.
        let os: String
        /// Normalized `uname -m`: x86_64 or aarch64 (arm64 on Darwin).
        let arch: String
        /// SHA-256 of the installed dend, nil when there is none.
        let installedHash: String?
    }

    static let probeCommand = sh(#"uname -sm; f="$HOME/.den/bin/dend"; if [ -x "$f" ]; then (sha256sum "$f" 2>/dev/null || shasum -a 256 "$f") | cut -d" " -f1; else echo none; fi"#)

    /// Reads dend from stdin into place atomically, so a running dend keeps
    /// its old binary. Lingering keeps the systemd user manager, and the dend
    /// it runs, alive after the last SSH login ends.
    static let installCommand = sh(#"set -e; umask 077; mkdir -p "$HOME/.den/bin"; cat > "$HOME/.den/bin/dend.new"; chmod 755 "$HOME/.den/bin/dend.new"; mv -f "$HOME/.den/bin/dend.new" "$HOME/.den/bin/dend"; if command -v loginctl >/dev/null 2>&1; then loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true; fi"#)

    static let streamCommand = sh(#"exec "$HOME/.den/bin/dend" --stdio"#)

    /// Appends Den's public key to authorized_keys unless it's already there.
    static func authorizeCommand(publicKey: String) -> String {
        sh(#"umask 077; mkdir -p "$HOME/.ssh"; touch "$HOME/.ssh/authorized_keys"; grep -qxF "\#(publicKey)" "$HOME/.ssh/authorized_keys" || echo "\#(publicKey)" >> "$HOME/.ssh/authorized_keys""#)
    }

    /// The script must not contain single quotes.
    private static func sh(_ script: String) -> String { "sh -c '\(script)'" }

    static func parseProbe(_ output: String) -> Probe? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        // Login banners may come first; the probe's lines are the last two.
        guard lines.count >= 2 else { return nil }
        let uname = lines[lines.count - 2].split(separator: " ")
        guard uname.count == 2 else { return nil }
        let hash = lines[lines.count - 1]
        return Probe(os: String(uname[0]), arch: normalize(arch: String(uname[1]), os: String(uname[0])), installedHash: hash == "none" ? nil : hash)
    }

    static func normalize(arch: String, os: String) -> String {
        switch arch.lowercased() {
        case "amd64", "x86_64": "x86_64"
        case "arm64", "aarch64": os == "Darwin" ? "arm64" : "aarch64"
        default: arch
        }
    }

    /// The dend build for a host, shipped next to Den's executable:
    /// `dend-linux-<arch>` from scripts/build-dend-linux.sh, or Den's own
    /// dend for a Mac of the same architecture.
    static func binary(for probe: Probe) -> Result<URL, SSH.Failure> {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else {
            return .failure(.launch("Den can't locate its own executable to find dend builds."))
        }
        let fm = FileManager.default
        switch probe.os {
        case "Linux":
            let name = "dend-linux-\(probe.arch)"
            let candidates = [dir.appending(path: name), dir.deletingLastPathComponent().appending(path: "Resources/\(name)")]
            if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) { return .success(found) }
            return .failure(.launch("This Den has no dend build for Linux \(probe.arch), so nothing was installed on the host. Build it with scripts/build-dend-linux.sh (or bundle.sh), then connect again."))
        case "Darwin":
            #if arch(arm64)
            let local = "arm64"
            #else
            let local = "x86_64"
            #endif
            let own = dir.appending(path: "dend")
            guard probe.arch == local, fm.isExecutableFile(atPath: own.path) else {
                return .failure(.launch("This Den only carries dend for \(local) Macs; the host is a \(probe.arch) Mac. Nothing was installed."))
            }
            return .success(own)
        default:
            return .failure(.launch("Den runs dend on Linux and macOS hosts; this one reports \(probe.os) \(probe.arch). Nothing was installed."))
        }
    }

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Den's ed25519 key (made on first use) as an authorized_keys line.
    static func publicKey() async -> Result<String, SSH.Failure> {
        let key = SSH.keyURL
        let pub = key.appendingPathExtension("pub")
        if !FileManager.default.fileExists(atPath: key.path) {
            try? FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let machine = (Host.current().localizedName ?? "mac").filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let keygen = Process()
            keygen.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
            keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "den@\(machine)", "-f", key.path]
            keygen.standardInput = FileHandle.nullDevice
            keygen.standardOutput = FileHandle.nullDevice
            keygen.standardError = FileHandle.nullDevice
            do {
                try keygen.run()
            } catch {
                return .failure(.launch("Could not run ssh-keygen to make Den's key: \(error.localizedDescription). The password stays saved, so logins keep working."))
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    keygen.waitUntilExit()
                    continuation.resume()
                }
            }
        }
        guard let line = try? String(contentsOf: pub, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty, !line.contains("'"), !line.contains("\"") else {
            return .failure(.launch("Den's public key at \(pub.path) is missing or unreadable. The password stays saved, so logins keep working."))
        }
        return .success(line)
    }
}
