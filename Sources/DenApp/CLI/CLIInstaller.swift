import Foundation

/// Links `den` onto PATH on explicit request (command palette): a link at
/// ~/.local/bin/den to the copy inside this bundle. Panes get the bundle's
/// bin folder on PATH regardless (dend adds it).
enum CLIInstaller {
    /// `Den.app/Contents/Resources/bin/den`, nil when not running from a bundle.
    static var bundledCLI: URL? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Resources/bin/den")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var linkURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/den")
    }

    enum Outcome: Equatable {
        case linked, alreadyLinked, notBundled
        /// Something that isn't a link to a Den is there; it's left alone.
        case occupied
        case failed(String)
    }

    /// Never replaces a file or a link to something other than a Den.app.
    /// Runs on every launch (including the relaunch after a Sparkle update),
    /// so the link tracks whichever copy of the app is running: same-path
    /// updates need no relink (the link resolves into the new bundle), and a
    /// copy launched from a new location takes the link over.
    @discardableResult
    static func install() -> Outcome {
        guard let target = bundledCLI else { return .notBundled }
        let fm = FileManager.default
        let link = linkURL
        let want = URL(fileURLWithPath: target.path).standardizedFileURL.path
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            let have = URL(fileURLWithPath: existing).standardizedFileURL.path
            if have == want { return .alreadyLinked }
            guard existing.hasSuffix(".app/Contents/Resources/bin/den") else { return .occupied }
            try? fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            return .occupied
        }
        do {
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
            return .linked
        } catch {
            return .failed("Could not link \(link.path) to \(target.path): \(error.localizedDescription). Den works as before; link it yourself to use den outside Den panes.")
        }
    }
}
