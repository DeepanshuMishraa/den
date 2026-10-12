import Foundation

/// The words after a command. Options are taken out as they're read; what
/// remains are positionals. Everything after `--` is kept verbatim.
struct CLIArgs {
    private(set) var words: [String]
    /// After `--`: a command to run, or text to send as is.
    let rest: [String]

    init(_ arguments: [String]) {
        if let dash = arguments.firstIndex(of: "--") {
            words = Array(arguments[..<dash])
            rest = Array(arguments[(dash + 1)...])
        } else {
            words = arguments
            rest = []
        }
    }

    /// `--name value` or `--name=value`, under any of `names`.
    mutating func option(_ names: String...) throws(CLIError) -> String? {
        for (i, word) in words.enumerated() {
            for name in names {
                if word == name {
                    guard i + 1 < words.count else { throw .usage("\(name) needs a value.") }
                    let value = words[i + 1]
                    words.removeSubrange(i ... i + 1)
                    return value
                }
                if name.hasPrefix("--"), word.hasPrefix(name + "=") {
                    words.remove(at: i)
                    return String(word.dropFirst(name.count + 1))
                }
            }
        }
        return nil
    }

    mutating func flag(_ names: String...) -> Bool {
        guard let i = words.firstIndex(where: names.contains) else { return false }
        words.remove(at: i)
        return true
    }

    mutating func next() -> String? {
        words.isEmpty ? nil : words.removeFirst()
    }

    mutating func required(_ what: String) throws(CLIError) -> String {
        guard let word = next() else { throw .usage("Missing \(what).") }
        return word
    }

    /// Fails on anything not consumed, so typos don't silently do nothing.
    func finish() throws(CLIError) {
        guard let extra = words.first else { return }
        throw .usage(extra.hasPrefix("-") ? "Unknown option \(extra)." : "Unexpected argument “\(extra)”.")
    }
}
