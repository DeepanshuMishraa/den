import CDenPTY
import Darwin
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
    var exitSource: DispatchSourceProcess?

    init(id: PaneID, size: GridSize, cwd: String?, queue: DispatchQueue) throws {
        let shell = Pane.userShell()
        let shellName = (shell as NSString).lastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["SHELL"] = shell
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Den"
        env["DEN_PANE_ID"] = id.raw.uuidString.lowercased()
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env.removeValue(forKey: "TERM_SESSION_ID")

        let directory = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        // A leading dash makes the shell a login shell so it sources the
        // user's profile even though dend was launched from the GUI.
        let argv = ["-\(shellName)"]
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
        self.meta = PaneMeta(process: shellName, cwd: directory)
        self.terminal = try VTTerminal(cols: size.cols, rows: size.rows)
        try terminal.resize(cols: size.cols, rows: size.rows, cellWidthPx: size.cellWidthPx, cellHeightPx: size.cellHeightPx)
        self.ptyWriter = FDWriter(fd: masterFD, queue: queue)

        let writer = ptyWriter
        terminal.effects = VTEffects(writeBack: { bytes in writer.write(Data(bytes)) })
    }

    func resize(_ newSize: GridSize) throws {
        guard newSize != size else { return }
        try terminal.resize(cols: newSize.cols, rows: newSize.rows, cellWidthPx: newSize.cellWidthPx, cellHeightPx: newSize.cellHeightPx)
        _ = den_pty_resize(master, newSize.cols, newSize.rows,
                           UInt16(clamping: UInt32(newSize.cols) * newSize.cellWidthPx),
                           UInt16(clamping: UInt32(newSize.rows) * newSize.cellHeightPx))
        size = newSize
    }

    /// The PTY's foreground process group, if any.
    func foregroundGroup() -> pid_t? {
        let pgrp = den_pty_foreground(master)
        return pgrp > 0 ? pgrp : nil
    }

    /// Foreground process name and its working directory, read from the
    /// kernel so it works for programs that never emit OSC 7.
    func probeMeta() -> PaneMeta {
        let pgrp = den_pty_foreground(master)
        let target = pgrp > 0 ? pgrp : pid
        var nameBuf = [UInt8](repeating: 0, count: 256)
        let process = proc_name(target, &nameBuf, UInt32(nameBuf.count)) > 0
            ? ProgramName.resolve(process: String(decoding: nameBuf.prefix(while: { $0 != 0 }), as: UTF8.self), arguments: ProgramName.arguments(of: target))
            : meta.process
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let cwd: String? = proc_pidinfo(target, PROC_PIDVNODEPATHINFO, 0, &info, size) == size
            ? withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            : meta.cwd
        return PaneMeta(process: process, cwd: cwd)
    }

    func terminate() {
        readSource?.cancel()
        exitSource?.cancel()
        ptyWriter.cancel()
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
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
        return "/bin/zsh"
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
