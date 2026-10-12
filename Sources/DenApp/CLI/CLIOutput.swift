import Foundation
import DenProtocol

/// Printing for the CLI: aligned tables, JSON, and bold headings on a TTY.
enum CLIOutput {
    static let isTTY = isatty(STDOUT_FILENO) == 1

    static func bold(_ text: String) -> String { isTTY ? "\u{1B}[1m\(text)\u{1B}[0m" : text }
    static func dim(_ text: String) -> String { isTTY ? "\u{1B}[2m\(text)\u{1B}[0m" : text }

    static func table(_ headers: [String], _ rows: [[String]]) {
        let widths = headers.indices.map { i in ([headers[i]] + rows.map { $0[i] }).map(\.count).max() ?? 0 }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { i, cell in
                i == cells.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        print(bold(line(headers)))
        rows.forEach { print(line($0)) }
    }

    /// `key  value` lines with the keys aligned.
    static func fields(_ pairs: [(String, String)]) {
        let width = pairs.map(\.0.count).max() ?? 0
        for (key, value) in pairs { print("\(key.padding(toLength: width, withPad: " ", startingAt: 0))  \(value)") }
    }

    static func json<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Plain value types only; encoding cannot fail.
        let data = (try? encoder.encode(value)) ?? Data("null".utf8)
        print(String(decoding: data, as: UTF8.self))
    }

    static func error(_ message: String) {
        FileHandle.standardError.write(Data("den: \(message)\n".utf8))
    }

    /// Long text goes through $PAGER (or less) when stdout is a terminal.
    static func page(_ text: String) {
        guard isTTY else { return print(text, terminator: "") }
        let pager = ProcessInfo.processInfo.environment["PAGER"].flatMap { $0.isEmpty ? nil : $0 } ?? "less -R"
        // posix_spawn rather than Process: Process puts the child in its own
        // process group, so less is a background job, stops (SIGTTIN) when it
        // reads the keyboard, and den hangs writing to it.
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return print(text, terminator: "") }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, readEnd, STDIN_FILENO)
        posix_spawn_file_actions_addclose(&actions, readEnd)
        posix_spawn_file_actions_addclose(&actions, writeEnd)
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(pager), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sh", &actions, nil, argv, environ)
        close(readEnd)
        guard rc == 0 else {
            close(writeEnd)
            return print(text, terminator: "")
        }
        // Quitting the pager early closes the pipe; SIGPIPE is ignored, so
        // the write just fails and we stop.
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(writeEnd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            offset += n
        }
        close(writeEnd)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }

    static func describe(_ exit: ExitState?) -> String {
        switch exit {
        case nil: "running"
        case .code(let code)?: "exited \(code)"
        case .signal(let signal)?: "killed by signal \(signal)"
        }
    }

    static func age(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        return s < 60 ? "\(s)s ago" : s < 3600 ? "\(s / 60)m ago" : s < 86400 ? "\(s / 3600)h ago" : "\(s / 86400)d ago"
    }
}
