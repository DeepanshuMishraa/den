import Foundation
import Security

/// SSH passwords in the login Keychain, one generic password per host
/// (`RemoteHost.account`). Only Den's own binary reads them back: the app,
/// and the same binary acting as ssh's askpass helper.
enum SSHPasswords {
    static let service = "Den SSH"

    struct Failure: Error, CustomStringConvertible {
        let operation: String
        let status: OSStatus
        var description: String {
            let reason = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
            return "Keychain \(operation) failed: \(reason)"
        }
    }

    static func password(for account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether a password is saved, read from its attributes only: unlike
    /// reading the password, this never brings up a Keychain prompt.
    static func exists(for account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ password: String, for account: String) -> Result<Void, Failure> {
        let match: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let data = Data(password.utf8)
        let update = SecItemUpdate(match as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return .success(()) }
        guard update == errSecItemNotFound else { return .failure(Failure(operation: "update", status: update)) }
        var add = match
        add[kSecValueData] = data
        add[kSecAttrLabel] = "Den SSH (\(account))"
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess ? .success(()) : .failure(Failure(operation: "add", status: status))
    }

    static func delete(for account: String) {
        let match: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(match as CFDictionary)
    }
}

/// Den's binary doubles as ssh's `SSH_ASKPASS` program: ssh runs it with the
/// prompt as its argument and `DEN_ASKPASS_ACCOUNT` inherited from Den, and
/// reads the answer from stdout.
enum Askpass {
    static let accountVariable = "DEN_ASKPASS_ACCOUNT"

    /// Answers password prompts from the Keychain and declines everything
    /// else (key passphrases, one-time codes), which makes ssh move on or
    /// fail with "Permission denied" so Den can ask the user.
    static func runIfRequested() {
        guard let account = ProcessInfo.processInfo.environment[accountVariable] else { return }
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ").lowercased()
        guard prompt.contains("password"), let password = SSHPasswords.password(for: account) else { exit(1) }
        FileHandle.standardOutput.write(Data((password + "\n").utf8))
        exit(0)
    }
}
