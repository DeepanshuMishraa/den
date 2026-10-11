import Darwin
import Foundation

/// Names the program in a pane's foreground. For scripts run by an
/// interpreter the kernel only reports the interpreter ("node"), so the
/// script on the command line names it instead: `node /opt/homebrew/bin/gemini`
/// is gemini, `python3 -m pytest` is pytest.
enum ProgramName {
    static let interpreters: Set<String> = ["node", "nodejs", "bun", "deno", "python", "ruby", "perl", "php", "lua", "luajit", "java", "osascript"]

    static func resolve(process: String, arguments: [String]) -> String {
        let bare = String(process.prefix { !$0.isNumber && $0 != "." })
        guard interpreters.contains(bare) else { return process }
        var args = arguments.dropFirst()
        while let arg = args.first {
            args = args.dropFirst()
            if arg == "-m", let module = args.first {
                // python -m http.server → http
                return String(module.split(separator: ".").first ?? Substring(module))
            }
            // Options, and inline code (`node -e "…"`) which is never a path.
            if arg.hasPrefix("-") { continue }
            guard arg.contains("/") else { return process }
            let name = (arg as NSString).lastPathComponent
            // `node dist/index.js` says nothing; an extensionless path is a
            // shebang-launched tool, usually a symlink named for it.
            return name.isEmpty || name.contains(".") ? process : name
        }
        return process
    }

    /// The process's argv, from the kernel (KERN_PROCARGS2).
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        // Layout: argc, the exec path, NUL padding, then argc strings.
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start ..< i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
