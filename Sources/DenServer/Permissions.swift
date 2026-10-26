import Foundation
import DenProtocol
#if os(macOS)
import CoreGraphics
#endif

extension HostPermissions {
    /// This process's grants, checked without showing any prompt.
    public static func probe() -> HostPermissions {
        #if os(macOS)
        HostPermissions(fullDiskAccess: fullDiskAccess(), screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .missing)
        #else
        HostPermissions(fullDiskAccess: .notApplicable, screenRecording: .notApplicable)
        #endif
    }

    /// What this Mac's shells can use. macOS applies a grant only to processes
    /// started after it was given, and dend is long-lived, so a grant made
    /// while it runs is invisible to it until it restarts. A fresh copy of the
    /// same binary tells that apart from a grant that was never given.
    static func report() -> HostPermissions {
        #if os(macOS)
        let current = probe()
        if current.fullDiskAccess == .granted, current.screenRecording == .granted { return current }
        guard let fresh = freshProbe() else { return current }
        return HostPermissions(
            fullDiskAccess: .resolve(current: current.fullDiskAccess, fresh: fresh.fullDiskAccess),
            screenRecording: .resolve(current: current.screenRecording, fresh: fresh.screenRecording)
        )
        #else
        return probe()
        #endif
    }

    static func requestScreenRecording() {
        #if os(macOS)
        _ = CGRequestScreenCaptureAccess()
        #endif
    }

    #if os(macOS)
    /// macOS gates these behind Full Disk Access. Trying any of them never
    /// prompts; opening one is proof the grant is in effect. The user privacy
    /// database moved in macOS 27, so one fixed file can't answer for every
    /// macOS version.
    private static let fullDiskAccessPaths = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Safari",
        "Library/Mail",
        "Library/Messages",
        "Library/Accounts",
        "Library/Suggestions",
        "Library/PersonalizationPortrait",
        "Library/Application Support/AddressBook",
        "Library/Application Support/CallHistoryDB",
    ]

    /// access(2) can't tell: privacy checks happen at open. All the paths are
    /// skipped when absent, so a Mac that never opened Safari or Mail doesn't
    /// read as granted by accident.
    private static func fullDiskAccess() -> Access {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = fullDiskAccessPaths.map { home.appending(path: $0) }
            + [URL(filePath: "/Library/Application Support/com.apple.TCC/TCC.db")]
        for path in paths where canRead(path) { return .granted }
        return .missing
    }

    private static func canRead(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue {
            return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
        }
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// What a dend launched now would see. nil outside a real dend (tests run
    /// the server in the test runner) or when the probe can't run; the caller
    /// then reports this process's own view.
    private static func freshProbe() -> HostPermissions? {
        // Bundle.main is the running executable; argv[0] is what launchd
        // started. Take whichever names dend (tests run in the test runner).
        let candidates = [Bundle.main.executableURL, CommandLine.arguments.first.map { URL(filePath: $0) }]
        guard let executable = candidates.compactMap({ $0 }).first(where: {
            $0.lastPathComponent == "dend" && FileManager.default.isExecutableFile(atPath: $0.path)
        }) else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--check-permissions"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // The probe exits at once; cap a stuck one so it can't hold the
        // control reply for long.
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard !process.isRunning else {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return try? ControlCoding.decode(HostPermissions.self, from: data).get()
    }
    #endif
}

extension HostPermissions.Access {
    /// Keep what this process can use; turn a grant only a new process sees
    /// into a restart prompt instead of silently reporting it as missing.
    static func resolve(current: Self, fresh: Self) -> Self {
        guard current == .missing else { return current }
        return fresh == .granted ? .needsRestart : current
    }
}