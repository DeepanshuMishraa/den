import CDenPTY
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import DenProtocol
import DenVT

public struct SpawnError: Error, CustomStringConvertible {
    public let shell: String
    public let errno: Int32
    public var description: String {
        "Could not start \(shell): \(String(cString: strerror(errno))). The session is unchanged; check that the shell exists and is executable."
    }
}

/// A process attached to a PTY plus dend's authoritative terminal for it.
/// Owned and mutated only by `DenServer`.
final class Pane {
    let id: PaneID
    let pid: pid_t
    let master: Int32
    let terminal: VTTerminal
    private(set) var size: GridSize
    var meta: PaneMeta
    /// OSC 7501 records this pane's programs reported.
    var status = StatusRecords()
    var statusScanner = StatusScanner()
    /// Process group that sent the latest working/blocked report; when it is
    /// gone, those records end.
    var statusOwner: pid_t?
    /// Status dend infers for an agent that doesn't report its own; nil
    /// when no agent runs or the agent speaks OSC 7501 itself.
    var agentInference: AgentStatusInference?
    /// The running program sent OSC 7501 itself, so nothing is inferred.
    var reportsOwnStatus = false
    /// Output arrived since the last inference tick, not counting echo of
    /// the user's typing.
    var agentOutput = false
    var lastInput = Date.distantPast
    let ptyWriter: FDWriter
    var readSource: DispatchSourceRead?
    var exitSource: DispatchSourceProtocol?

    var label: String?
    let command: [String]
    let keepOpen: Bool
    let createdAt = Date()
    /// Last OSC title seen, to report changes as events.
    var lastTitle: String?
    /// Set when the child exited and the pane stays open (keep-open).
    var exit: ExitState?
    /// The process was signalled and the PTY closed; never signal its pid
    /// again, since the system may have reused it.
    private(set) var stopped = false

    init(id: PaneID, session: SessionID, size: GridSize, launch: PaneLaunch, socketPath: String, queue: DispatchQueue) throws {
        let shell = Pane.userShell()
        let shellName = (shell as NSString).lastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["SHELL"] = shell
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Den"
        env["DEN_PANE_ID"] = id.raw.uuidString.lowercased()
        env["DEN_SESSION_ID"] = session.raw.uuidString.lowercased()
        // `den` run inside the pane talks to the dend that owns it.
        env["DEN_SOCKET"] = socketPath
        if let bin = Pane.bundledCLIDirectory {
            env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + bin
        }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env.removeValue(forKey: "TERM_SESSION_ID")

        let directory = launch.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        // A leading dash makes the shell a login shell so it sources the
        // user's profile even though dend was launched from the GUI. A
        // command runs through it too, so it finds programs on that PATH.
        let argv = launch.command.isEmpty
            ? ["-\(shellName)"]
            : ["-\(shellName)", "-c", "exec " + launch.command.map(Pane.shellQuoted).joined(separator: " ")]
        let envp = env.map { "\($0.key)=\($0.value)" }
        var masterFD: Int32 = -1
        let pid = withCStrings(argv) { cArgv in
            withCStrings(envp) { cEnv in
                den_spawn_pty(shell, cArgv, cEnv, directory, size.cols, size.rows,
                              UInt16(clamping: UInt32(size.cols) * size.cellWidthPx),
                              UInt16(clamping: UInt32(size.rows) * size.cellHeightPx), &masterFD)
            }
        }
        guard pid > 0 else { throw SpawnError(shell: shell, errno: errno) }

        self.id = id
        self.pid = pid
        self.master = masterFD
        self.size = size
        self.label = launch.label
        self.command = launch.command
        self.keepOpen = launch.keepOpen
        self.meta = PaneMeta(process: launch.command.first.map { ($0 as NSString).lastPathComponent } ?? shellName, cwd: directory)
        self.terminal = try VTTerminal(cols: size.cols, rows: size.rows)
        try terminal.resize(cols: size.cols, rows: size.rows, cellWidthPx: size.cellWidthPx, cellHeightPx: size.cellHeightPx)
        self.ptyWriter = FDWriter(fd: masterFD, queue: queue)

        let writer = ptyWriter
        terminal.effects = VTEffects(writeBack: { bytes in writer.write(Data(bytes)) })
    }

    func resize(_ newSize: GridSize) throws {
        guard newSize != size else { return }
        try terminal.resize(cols: newSize.cols, rows: newSize.rows, cellWidthPx: newSize.cellWidthPx, cellHeightPx: newSize.cellHeightPx)
        // A stopped pane's master fd is closed and its number may be reused.
        if !stopped {
            _ = den_pty_resize(master, newSize.cols, newSize.rows,
                               UInt16(clamping: UInt32(newSize.cols) * newSize.cellWidthPx),
                               UInt16(clamping: UInt32(newSize.rows) * newSize.cellHeightPx))
        }
        size = newSize
    }

    /// The PTY's foreground process group, if any.
    func foregroundGroup() -> pid_t? {
        guard !stopped else { return nil }
        let pgrp = den_pty_foreground(master)
        return pgrp > 0 ? pgrp : nil
    }

    /// Foreground process name and its working directory, read from the
    /// kernel so it works for programs that never emit OSC 7.
    func probeMeta() -> PaneMeta {
        guard !stopped else { return meta }
        let pgrp = den_pty_foreground(master)
        let target = pgrp > 0 ? pgrp : pid
        let process = Self.processName(target).map { ProgramName.resolve(process: $0, arguments: ProgramName.arguments(of: target)) } ?? meta.process
        return PaneMeta(process: process, cwd: Self.workingDirectory(target) ?? meta.cwd)
    }

    #if os(Linux)
    static func processName(_ pid: pid_t) -> String? {
        guard let comm = try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8) else { return nil }
        let name = comm.trimmingCharacters(in: .newlines)
        return name.isEmpty ? nil : name
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/cwd")
    }

    static func executablePath(_ pid: pid_t) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")
    }
    #else
    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [UInt8](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    static func processName(_ pid: pid_t) -> String? {
        var nameBuf = [UInt8](repeating: 0, count: 256)
        guard proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 else { return nil }
        return String(decoding: nameBuf.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
    #endif

    /// Safe to call more than once: only the first call signals.
    func terminate() {
        guard !stopped else { return }
        stopped = true
        readSource?.cancel()
        exitSource?.cancel()
        ptyWriter.cancel()
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
    }

    /// The child and the terminal's foreground process, for `den pane inspect`.
    /// Both nil once the pane stopped.
    func processes() -> (child: ProcessState?, foreground: ProcessState?) {
        guard !stopped else { return (nil, nil) }
        let pgrp = den_pty_foreground(master)
        return (Self.processState(pid), pgrp > 0 ? Self.processState(pgrp) : nil)
    }

    static func processState(_ pid: pid_t) -> ProcessState? {
        guard let name = processName(pid) else { return nil }
        return ProcessState(pid: pid, name: name, path: executablePath(pid), cwd: workingDirectory(pid))
    }

    /// POSIX single quotes, which fish, zsh, bash and nushell all read the
    /// same way for `'it'\''s'`.
    static func shellQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `Den.app/Contents/Resources/bin`, where the bundle links `den`, when
    /// dend runs from the app bundle.
    static var bundledCLIDirectory: String? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let bin = exe.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources/bin").path
        return FileManager.default.fileExists(atPath: bin + "/den") ? bin : nil
    }

    /// The shell for new panes: Den's `shell` setting, else the account's
    /// login shell from the user database. `$SHELL` is only a last resort
    /// because dend inherits it from whatever launched it.
    static func userShell() -> String {
        let fm = FileManager.default
        if let s = DenConfig.value("shell"), fm.isExecutableFile(atPath: s) { return s }
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let s = String(decoding: UnsafeRawBufferPointer(start: shell, count: strlen(shell)), as: UTF8.self)
            if fm.isExecutableFile(atPath: s) { return s }
        }
        if let s = ProcessInfo.processInfo.environment["SHELL"], fm.isExecutableFile(atPath: s) { return s }
        return ["/bin/zsh", "/bin/bash"].first(where: fm.isExecutableFile(atPath:)) ?? "/bin/sh"
    }
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { buf in
        // Always non-empty: the array holds at least the nil terminator.
        guard let base = buf.baseAddress else { preconditionFailure("C string array has a terminator") }
        return body(base)
    }
}
