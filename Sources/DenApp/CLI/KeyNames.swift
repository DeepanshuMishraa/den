import Foundation

/// `den send-key` names → the bytes a terminal sends for them (xterm
/// legacy encoding, which every program accepts).
enum KeyNames {
    static func bytes(_ name: String) -> Result<Data, CLIError> {
        let lower = name.lowercased()
        for prefix in ["ctrl-", "ctrl+", "c-"] where lower.hasPrefix(prefix) && lower.count > prefix.count {
            return control(String(lower.dropFirst(prefix.count)), original: name)
        }
        for prefix in ["alt-", "alt+", "opt-", "opt+", "m-"] where lower.hasPrefix(prefix) && name.count > prefix.count {
            return bytes(String(name.dropFirst(prefix.count))).map { Data([0x1B]) + $0 }
        }
        if let named = named[lower] { return .success(Data(named.utf8)) }
        if name.count == 1 { return .success(Data(name.utf8)) }
        return .failure(.usage("Unknown key “\(name)”. Use a character, a name (\(names)), ctrl-X or alt-X."))
    }

    private static func control(_ key: String, original: String) -> Result<Data, CLIError> {
        let special: [String: UInt8] = ["space": 0x00, "@": 0x00, "[": 0x1B, "\\": 0x1C, "]": 0x1D, "^": 0x1E, "_": 0x1F, "?": 0x7F]
        if let byte = special[key] { return .success(Data([byte])) }
        guard key.count == 1, let scalar = key.unicodeScalars.first, scalar.isASCII, ("a" ... "z").contains(Character(scalar)) else {
            return .failure(.usage("ctrl- takes a letter, space or one of @[\\]^_? in “\(original)”."))
        }
        return .success(Data([UInt8(scalar.value) & 0x1F]))
    }

    private static let named: [String: String] = {
        var keys: [String: String] = [
            "enter": "\r", "return": "\r", "tab": "\t", "btab": "\u{1B}[Z", "shift-tab": "\u{1B}[Z",
            "escape": "\u{1B}", "esc": "\u{1B}", "space": " ", "backspace": "\u{7F}", "bs": "\u{7F}",
            "delete": "\u{1B}[3~", "del": "\u{1B}[3~", "insert": "\u{1B}[2~",
            "up": "\u{1B}[A", "down": "\u{1B}[B", "right": "\u{1B}[C", "left": "\u{1B}[D",
            "home": "\u{1B}[H", "end": "\u{1B}[F",
            "pageup": "\u{1B}[5~", "pgup": "\u{1B}[5~", "page_up": "\u{1B}[5~",
            "pagedown": "\u{1B}[6~", "pgdn": "\u{1B}[6~", "page_down": "\u{1B}[6~",
            "f1": "\u{1B}OP", "f2": "\u{1B}OQ", "f3": "\u{1B}OR", "f4": "\u{1B}OS",
        ]
        for (n, code) in [(5, 15), (6, 17), (7, 18), (8, 19), (9, 20), (10, 21), (11, 23), (12, 24)] {
            keys["f\(n)"] = "\u{1B}[\(code)~"
        }
        return keys
    }()

    static let names = "enter, tab, btab, esc, space, backspace, delete, insert, up, down, left, right, home, end, pgup, pgdn, f1–f12"
}
