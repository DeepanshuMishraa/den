#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// The processes in a pane's terminal session. Each pane's child is a
/// session leader (forkpty), and everything started from its shell stays in
/// that session unless it calls setsid: foreground and background jobs,
/// nohup'd ones, and their children after the shell is gone.
enum ProcessSession {
    /// How long programs get to exit on SIGHUP before SIGKILL.
    static let grace: TimeInterval = 0.5

    /// Every live process whose session is `sid`.
    static func members(of sid: pid_t) -> [pid_t] {
        allProcesses().filter { $0 > 1 && $0 != getpid() && getsid($0) == sid }
    }

    /// Hangs up every process in the session, then kills whatever is left
    /// after `grace`. Stopped jobs get SIGCONT so they see the hangup.
    static func end(_ sid: pid_t) {
        let members = members(of: sid)
        for pid in members {
            kill(pid, SIGHUP)
            kill(pid, SIGCONT)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            for pid in Self.members(of: sid) { kill(pid, SIGKILL) }
        }
    }

    #if os(Linux)
    private static func allProcesses() -> [pid_t] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []).compactMap { pid_t($0) }
    }
    #else
    private static func allProcesses() -> [pid_t] {
        // Room for processes started between the two calls.
        let estimate = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: estimate)
        let count = proc_listallpids(&pids, Int32(estimate * MemoryLayout<pid_t>.size))
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }
    #endif
}
