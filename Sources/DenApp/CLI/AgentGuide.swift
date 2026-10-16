import Foundation

/// What coding agents need to know to drive Den from inside a pane, and the
/// Agent Skill that carries it to them. `den agent guide` prints it for any
/// agent; `den agent install` writes it where agents look for skills.
enum AgentGuide {
    static let markdown = """
    # Den

    You're running inside a pane of Den, a terminal whose `den` command controls
    its panes. `$TERM_PROGRAM` is `Den` and `$DEN_PANE_ID` is your own pane.
    Everything you do with `den` shows up at once in the user's window.

    ## See what's there

    ```sh
    den pane list                              # panes in this session: label, program, ID
    den capture -p dev --lines 60 --trim       # what a pane shows, scrollback included
    den pane inspect dev                       # its processes, cwd and exit status
    ```

    ## Run long-lived things beside you

    Put dev servers, watchers and log tails in their own pane instead of a
    background job: the user can watch them and you can read them later.

    ```sh
    den split --right --label dev -- pnpm dev  # prints the new pane's ID
    den split --down --label tests --keep-open -- swift test && den wait -p tests
    ```

    `den wait` exits with the command's status (124 on `--timeout`). Without
    `--keep-open` a pane closes when its command exits and its output goes with
    it, so pass `--keep-open` when you need to read the output afterwards.

    ## Act on a pane

    ```sh
    den send -p dev --enter 'pnpm dev --port 5421'
    den send-key -p dev ctrl-c
    den pane close dev
    ```

    ## Rules

    - `-p` takes a pane's label, program name or ID prefix. Inside Den, `-p`
      defaults to your own pane, so always pass `-p` when you mean another one.
      Never `send` or `send-key` to your own pane.
    - Label the panes you open so you can find them again.
    - Read a pane with `den capture` before saying what it shows.
    - Don't close or type into panes you didn't open unless the user asks.
    - `den help COMMAND` has every option; `den state` prints everything as JSON.
    """

    /// Marks a SKILL.md as Den's, so install may rewrite it.
    static let marker = "<!-- Written by Den (`den agent install`), which rewrites this file. -->"

    static let skill = """
    ---
    name: den
    description: Drive the Den terminal from inside it. Open panes beside you for dev servers, builds and tests, read what other panes show, and type into them. Use when $TERM_PROGRAM is Den and the user asks to run something in a split, pane or tab, check a server's or build's output, or fix something shown in another pane.
    ---
    \(marker)

    \(markdown)

    """

    /// Skill folders, relative to home: the cross-agent Agent Skills location
    /// and Claude Code's own.
    static let skillDirectories = [".agents/skills/den", ".claude/skills/den"]

    enum Outcome: Equatable {
        case written, unchanged
        /// A SKILL.md that isn't Den's is there; it's left alone.
        case occupied
        case failed(String)
    }

    /// Writes SKILL.md into each skill folder under `home`. Never replaces a
    /// file without Den's marker.
    static func install(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(path: String, outcome: Outcome)] {
        skillDirectories.map { install(into: $0, home: home) }
    }

    /// Writes SKILL.md into one skill folder (relative to `home`).
    static func install(into relative: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (path: String, outcome: Outcome) {
        let file = home.appending(path: relative).appending(path: "SKILL.md")
        return (file.path, install(at: file))
    }

    private static func install(at file: URL) -> Outcome {
        if let existing = try? String(contentsOf: file, encoding: .utf8) {
            if existing == skill { return .unchanged }
            guard existing.contains(marker) else { return .occupied }
        } else if FileManager.default.fileExists(atPath: file.path) {
            return .occupied
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try skill.write(to: file, atomically: true, encoding: .utf8)
            return .written
        } catch {
            return .failed("Could not write \(file.path): \(error.localizedDescription). Nothing else changed; agents can still read `den agent guide`.")
        }
    }
}
