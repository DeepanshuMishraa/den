#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Names the program in a pane's foreground. For scripts run by an
/// interpreter the kernel only reports the interpreter ("node"), so the
/// script on the command line names it instead: `node /opt/homebrew/bin/gemini`
/// is gemini, `python3 -m pytest` is pytest.
enum ProgramName {
    static let interpreters: Set<String> = ["node", "nodejs", "bun", "deno", "python", "ruby", "perl", "php", "lua", "luajit", "java", "osascript"]

    /// File stems and directories that name the packaging convention, not the
    /// tool: `main.js`, `cli.js`, `dist/`, `node_modules/`, `.bin/`.
    static let genericNames: Set<String> = [
        "cli", "main", "index", "server", "app", "run", "start",
        "bin", "lib", "dist", "build", "bundle", "out", "src", "node_modules", ".bin",
    ]

    static func resolve(process: String, arguments: [String]) -> String {
        // Binaries named for their version (Claude Code runs
        // …/claude/versions/2.1.296) say nothing; the command typed does.
        if isVersion(process), let first = arguments.first?.split(separator: " ").first {
            let name = String(first.split(separator: "/").last ?? first)
            return isVersion(name) ? process : name
        }
        let bare = String(process.prefix { !$0.isNumber && $0 != "." })
        guard interpreters.contains(bare) else { return process }
        // A program that set its own title (node's process.title) has
        // overwritten argv, so argv[0] is that title: `pi`, `npm run dev`.
        if let first = arguments.first?.split(separator: " ").first {
            let name = String(first.split(separator: "/").last ?? first)
            if !interpreters.contains(String(name.prefix { !$0.isNumber && $0 != "." })) { return name }
        }
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
            let parts = arg.split(separator: "/").map(String.init)
            guard let file = parts.last, !file.isEmpty else { return process }
            // Extensionless paths are shebang-launched tools named for
            // themselves: `/opt/homebrew/bin/codex` is codex.
            guard file.contains(".") else { return file }
            // Dotted entries name the tool through their stem:
            // `npm-cli.js` → npm, `pnpm.cjs` → pnpm, `codex.js` → codex.
            var stem = file.split(separator: ".").first.map(String.init) ?? file
            if stem.hasSuffix("-cli") || stem.hasSuffix("_cli") { stem = String(stem.dropLast(4)) }
            if !genericNames.contains(stem.lowercased()) { return stem }
            // Generic entries (`main.js`, `cli.js`) say nothing on their own,
            // so walk up past packaging dirs to the owning tool or project:
            // `shottr-mcp/dist/main.js` is shottr-mcp.
            for dir in parts.dropLast().reversed() {
                let clean = dir.lowercased()
                if clean.isEmpty || genericNames.contains(clean) || clean.hasPrefix(".") { continue }
                return dir.hasPrefix("@") ? String(dir.dropFirst()) : dir
            }
            return process
        }
        return process
    }

    /// "2.1.296": digits and dots, with at least one dot.
    static func isVersion(_ name: String) -> Bool {
        name.contains(".") && name.allSatisfy { $0.isNumber || $0 == "." }
    }

    #if os(Linux)
    /// The process's argv, from /proc.
    static func arguments(of pid: pid_t) -> [String] {
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline") else { return [] }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }
    #else
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
    #endif
}
