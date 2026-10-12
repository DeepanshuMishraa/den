import Foundation

enum CLIHelp {
    static var overview: String {
        func section(_ title: String, _ names: [String]) -> String {
            let commands = names.compactMap { name in CLICommands.all.first { $0.names[0] == name } }
            let width = commands.map { $0.names.joined(separator: ", ").count }.max() ?? 0
            return CLIOutput.bold(title) + "\n" + commands.map {
                "  \($0.names.prefix(2).joined(separator: ", ").padding(toLength: width, withPad: " ", startingAt: 0))  \($0.summary)"
            }.joined(separator: "\n")
        }
        return """
        den drives Den's sessions from the shell. Every change shows up at once in
        each Den window attached to the same dend.

        \(CLIOutput.bold("Usage")): den <command> [options]

        \(section("Sessions and panes", ["new", "ls", "run", "split", "send", "send-key", "capture", "kill"]))

        \(section("Layout", ["move", "swap", "resize"]))

        \(section("Resources", ["session", "tab", "pane", "clients"]))

        \(section("Automation", ["wait", "events", "state"]))

        \(section("Config", ["keybinds", "config"]))

        \(CLIOutput.bold("Targets"))
          -s SESSION  a session's name or ID. Inside a Den pane it defaults to that
                      pane's session; with one session running, to that one.
          -p PANE     a pane's label, program name or ID prefix. Defaults to the
                      pane you're in, else the newest pane in the session.
          -t TAB      a tab's number (1 = first), title or ID prefix.

        \(CLIOutput.bold("Global options"))
          --json           machine-readable output where a command lists things
          --socket PATH    talk to another dend (default: Den's, or $DEN_SOCKET)
          -V, --version    print den's version

        Run `den help COMMAND` or `den COMMAND --help` for details, and
        `den config help` for the config manual.
        """
    }

    /// Usage for `den help split` or `den help pane list`.
    static func usage(_ topic: String) -> String? {
        let words = topic.split(separator: " ").map(String.init)
        guard let first = words.first, let command = CLICommands.all.first(where: { $0.names.contains(first) }) else { return nil }
        guard words.count > 1 else { return command.usage }
        let groups: [String: CLIGroup] = ["session": CLICommands.sessionGroup, "tab": CLICommands.tabGroup,
                                          "pane": CLICommands.paneGroup, "config": CLICommands.configGroup]
        return groups[command.names[0]]?.verbs.first { $0.names.contains(words[1]) }?.usage
    }
}
