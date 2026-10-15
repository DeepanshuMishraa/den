import Foundation
import DenProtocol

/// Every `den` command. Each validates its arguments before talking to
/// dend, and resolves names against a fresh state snapshot.
enum CLICommands {
    static let all: [CLICommand] = [
        new, list, kill, run, split, send, sendKey, capture,
        move, swap, resize,
        wait, events, state, clients,
        command(["session"], sessionGroup, "Inspect, rename and close sessions"),
        command(["tab"], tabGroup, "List, rename and close tabs"),
        command(["pane"], paneGroup, "List, inspect, label and close panes"),
        keybinds,
        command(["config"], configGroup, "Config manual, path and validation"),
        command(["agent"], agentGroup, "Teach coding agents to drive Den"),
    ]

    private static func command(_ names: [String], _ group: CLIGroup, _ summary: String) -> CLICommand {
        CLICommand(names: names, summary: summary, usage: group.usage) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
            try group.run(&args, context)
        }
    }

    // MARK: Creating

    /// `--label`, `--cwd`, `--keep-open` and `-- CMD…`, shared by new/run/split.
    /// Without --cwd the pane starts in `defaultCwd` (nil lets dend pick).
    private static func launch(_ args: inout CLIArgs, defaultCwd: String? = FileManager.default.currentDirectoryPath) throws(CLIError) -> PaneLaunch {
        let label = try args.option("--label", "-l")
        let cwd = try args.option("--cwd", "-c").map { ($0 as NSString).expandingTildeInPath }
            .map { $0.hasPrefix("/") ? $0 : FileManager.default.currentDirectoryPath + "/" + $0 }
        let keepOpen = args.flag("--keep-open", "-k")
        if keepOpen, args.rest.isEmpty { throw .usage("--keep-open needs a command after `--`; a shell pane stays open anyway.") }
        // A command pane is called by its program unless labelled.
        let defaultLabel = args.rest.first.map { ($0 as NSString).lastPathComponent }
        return PaneLaunch(label: label ?? defaultLabel, command: args.rest, cwd: cwd ?? defaultCwd, keepOpen: keepOpen)
    }

    private static func printLaunched(_ reply: ControlReply, session: Bool) throws(CLIError) {
        guard case .launched(let sid, _, let pane) = reply else { throw CLIError(message: "dend answered a launch with something else.") }
        print(session ? sid.description : pane.description)
    }

    static let new = CLICommand(
        names: ["new"], summary: "Create a session",
        usage: """
        Usage: den new [NAME] [--cwd DIR] [--label L] [--keep-open] [-- COMMAND...]

        Creates a session with one tab and prints its ID. Without NAME, Den picks
        a name like quiet-harbor. Without COMMAND the pane runs your shell.

          -c, --cwd DIR      start in DIR (default: the current directory)
          -l, --label L      name the first pane (default: the command's name)
          -k, --keep-open    keep the pane on screen after COMMAND exits

        Example: den new build -- make watch
        """
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        let launch = try launch(&args)
        let name = args.next() ?? ""
        try args.finish()
        try printLaunched(try context.connect().request(.launch(.session(name: name), launch)), session: true)
        return 0
    }

    static let run = CLICommand(
        names: ["run"], summary: "Run a command in a new tab",
        usage: """
        Usage: den run [-s SESSION] [--cwd DIR] [--label L] [--keep-open] [-- COMMAND...]

        Opens a tab in SESSION and prints the new pane's ID. Without COMMAND the
        tab runs your shell. Options as for `den new`.
        """
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        let sessionRef = try args.option("-s", "--session")
        let launch = try launch(&args)
        try args.finish()
        let client = try context.connect()
        let session = try CLITargets(state: try client.state()).session(sessionRef)
        try printLaunched(try client.request(.launch(.tab(session: session.id), launch)), session: false)
        return 0
    }

    static let split = CLICommand(
        names: ["split"], summary: "Split a pane and run a command beside it",
        usage: """
        Usage: den split [-s SESSION] [-p PANE] [--right|--left|--down|--up] [--label L]
                         [--cwd DIR] [--keep-open] [-- COMMAND...]

        Splits PANE (default: the pane you're in, else the newest one) and prints
        the new pane's ID. The new pane goes to the right unless told otherwise.

        Example: den split -s video --down --label tests --keep-open -- swift test
        """
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        let sessionRef = try args.option("-s", "--session")
        let paneRef = try args.option("-p", "--pane")
        let directions = [("--right", SplitAxis.horizontal, false), ("--left", .horizontal, true), ("--down", .vertical, false), ("--up", .vertical, true)]
            .filter { args.flag($0.0) }
        guard directions.count <= 1 else { throw .usage("Pick one of --right, --left, --down, --up.") }
        let (_, axis, before) = directions.first ?? ("--right", .horizontal, false)
        // The split pane's folder, unless --cwd says otherwise.
        let launch = try launch(&args, defaultCwd: nil)
        try args.finish()
        let client = try context.connect()
        let targets = CLITargets(state: try client.state())
        let session = try targets.session(sessionRef)
        let pane = try targets.pane(paneRef, in: session)
        try printLaunched(try client.request(.launch(.split(pane: pane.id, axis: axis, before: before), launch)), session: false)
        return 0
    }

    // MARK: Driving panes

    static let send = CLICommand(
        names: ["send"], summary: "Type text into a pane",
        usage: """
        Usage: den send [-s SESSION] [-p PANE] [--enter] TEXT...
               den send [-s SESSION] [-p PANE] [--enter] -- TEXT...

        Writes TEXT (words joined by spaces) to the pane as if typed. --enter
        presses Return afterwards. Put TEXT after `--` when it starts with a dash.

        Example: den send -p tests --enter swift test --filter Parser
        """
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        let sessionRef = try args.option("-s", "--session")
        let paneRef = try args.option("-p", "--pane")
        let enter = args.flag("--enter", "-n")
        var words: [String] = []
        while let word = args.next() { words.append(word) }
        words += args.rest
        guard !words.isEmpty || enter else { throw .usage("Nothing to send; give TEXT or --enter.") }
        let client = try context.connect()
        let targets = CLITargets(state: try client.state())
        let pane = try targets.pane(paneRef, in: try targets.session(sessionRef))
        try requireRunning(pane)
        try client.send(.input(pane.id, Data((words.joined(separator: " ") + (enter ? "\r" : "")).utf8)))
        try client.request(.state) // Waits until dend has handled the input.
        return 0
    }

    static let sendKey = CLICommand(
        names: ["send-key", "send-keys"], summary: "Press keys in a pane",
        usage: """
        Usage: den send-key [-s SESSION] [-p PANE] KEY...

        Presses each KEY in order. A KEY is one character, a name (\(KeyNames.names)),
        or a modifier prefix: ctrl-c, c-c, alt-x, m-x.

        Example: den send-key -p nvim esc : w q enter
        """
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        let sessionRef = try args.option("-s", "--session")
        let paneRef = try args.option("-p", "--pane")
        var keys: [String] = []
        while let word = args.next() { keys.append(word) }
        keys += args.rest
        guard !keys.isEmpty else { throw .usage("Name at least one KEY, e.g. `den send-key ctrl-c`.") }
        var bytes = Data()
        for key in keys {
            switch KeyNames.bytes(key) {
            case .success(let b): bytes += b
            case .failure(let error): throw error
            }
        }
        let client = try context.connect()
        let targets = CLITargets(state: try client.state())
        let pane = try targets.pane(paneRef, in: try targets.session(sessionRef))
        try requireRunning(pane)
        try client.send(.input(pane.id, bytes))
        try client.request(.state)
        return 0
    }

    private static func requireRunning(_ pane: PaneState) throws(CLIError) {
        guard let exit = pane.exit else { return }
        throw CLIError(message: "Pane \(CLITargets.paneName(pane)) has \(CLIOutput.describe(exit)); it no longer takes input. Close it with `den pane close`.")
    }

    static let capture = CLICommand(
        names: ["capture"], summary: "Print a pane's screen and scrollback",
        usage: """
        Usage: den capture [-s SESSION] [-p PANE] [--format text|vt|html] [--lines N] [--trim]

        Prints what the pane shows, scrollback included, from dend's own copy of
        the terminal. text is plain; vt keeps colors as escape sequences; html is
        a styled fragment. --lines keeps only the last N lines. --trim drops
        trailing spaces and the blank lines before and after the text.
        """
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        let sessionRef = try args.option("-s", "--session")
        let paneRef = try args.option("-p", "--pane")
        let formatName = try args.option("--format", "-f") ?? "text"
        guard let format = CaptureFormat(rawValue: formatName) else { throw .usage("--format is text, vt or html, not “\(formatName)”.") }
        let lines = try args.option("--lines", "-n").map { (value: String) throws(CLIError) -> Int in
            guard let n = Int(value), n > 0 else { throw .usage("--lines takes a positive number, not “\(value)”.") }
            return n
        }
        let trim = args.flag("--trim")
        try args.finish()
        let client = try context.connect()
        let targets = CLITargets(state: try client.state())
        let pane = try targets.pane(paneRef, in: try targets.session(sessionRef))
        guard case .text(var text) = try client.request(.capture(pane: pane.id, format: format)) else {
            throw CLIError(message: "dend answered a capture with something else.")
        }
        if trim { text = trimmed(text) }
        if let lines {
            var all = text.split(separator: "\n", omittingEmptySubsequences: false)
            while all.last?.isEmpty == true { all.removeLast() }
            text = all.suffix(lines).joined(separator: "\n")
        }
        print(text.hasSuffix("\n") ? String(text.dropLast()) : text)
        return 0
    }

    /// `capture --trim`: no trailing spaces, no blank lines around the text.
    static func trimmed(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0.reversed().drop(while: \.isWhitespace).reversed())
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: Layout

    private static let placements: [String: PanePlacement] = ["left": .left, "right": .right, "above": .above, "up": .above, "below": .below, "down": .below]

    static let move = CLICommand(
        names: ["move"], summary: "Move a pane next to another",
        usage: """
        Usage: den move [-s SESSION] PANE left|right|above|below TARGET

        Takes PANE out of its spot and splits TARGET with it. Both must be in the
        same tab; programs keep running.

        Example: den move -s video nvim below shell
        """
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        let sessionRef = try args.option("-s", "--session")
        let paneRef = try args.required("PANE")
        let where_ = try args.required("a placement (left, right, above or below)")
        guard let placement = placements[where_.lowercased()] else { throw .usage("Placement is left, right, above or below, not “\(where_)”.") }
        let targetRef = try args.required("TARGET pane")
        try args.finish()
        let client = try context.connect()
        let targets = CLITargets(state: try client.state())
        let session = try targets.session(sessionRef)
        let (pane, target) = (try targets.pane(paneRef, in: session), try targets.pane(targetRef, in: session))
        try requireSameTab(pane, target, in: session)
        try client.send(.movePane(pane.id, to: target.id, placement: placement))
        try client.request(.state)
        return 0
    }

    static let swap = CLICommand(
        names: ["swap"], summary: "Swap two panes",
        usage: "Usage: den swap [-s SESSION] PANE OTHER\n\nTrades the places of two panes in the same tab."
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        let sessionRef = try args.option("-s", "--session")
        let (aRef, bRef) = (try args.required("PANE"), try args.required("OTHER pane"))
        try args.finish()
        let client = try context.connect()
        let targets = CLITargets(state: try client.state())
        let session = try targets.session(sessionRef)
        let (a, b) = (try targets.pane(aRef, in: session), try targets.pane(bRef, in: session))
        try requireSameTab(a, b, in: session)
        try client.send(.movePane(a.id, to: b.id, placement: .swap))
        try client.request(.state)
        return 0
    }

    private static func requireSameTab(_ a: PaneState, _ b: PaneState, in session: SessionState) throws(CLIError) {
        guard a.id != b.id else { throw .usage("That's the same pane twice.") }
        guard session.tabs.contains(where: { tab in tab.panes.contains { $0.id == a.id } && tab.panes.contains { $0.id == b.id } }) else {
            throw CLIError(message: "\(CLITargets.paneName(a)) and \(CLITargets.paneName(b)) are in different tabs; panes only move within a tab.")
        }
    }

    static let resize = CLICommand(
        names: ["resize"], summary: "Move a pane's edge",
        usage: """
        Usage: den resize [-s SESSION] [-p PANE] left|right|up|down [PERCENT]

        Moves the edge of PANE nearest that direction by PERCENT of its split
        (default 5), like leader+shift+h/j/k/l. Splits stay between 10% and 90%.
        """
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        let sessionRef = try args.option("-s", "--session")
        let paneRef = try args.option("-p", "--pane")
        let directionName = try args.required("a direction (left, right, up or down)")
        let directions: [String: PaneDirection] = ["left": .left, "right": .right, "up": .up, "down": .down]
        guard let direction = directions[directionName.lowercased()] else { throw .usage("Direction is left, right, up or down, not “\(directionName)”.") }
        let percent = try args.next().map { (value: String) throws(CLIError) -> Float in
            guard let p = Float(value), p > 0, p < 90 else { throw .usage("PERCENT is a number between 0 and 90, not “\(value)”.") }
            return p
        } ?? 5
        try args.finish()
        let client = try context.connect()
        let targets = CLITargets(state: try client.state())
        let session = try targets.session(sessionRef)
        let pane = try targets.pane(paneRef, in: session)
        guard let tab = session.tabs.first(where: { $0.panes.contains { $0.id == pane.id } }) else { throw CLIError(message: "That pane just closed.") }
        let axis: SplitAxis = direction == .left || direction == .right ? .horizontal : .vertical
        guard let (path, ratio) = tab.layout.enclosingSplit(of: pane.id, axis: axis) else {
            throw CLIError(message: "\(CLITargets.paneName(pane)) has no \(axis == .horizontal ? "side-by-side" : "stacked") neighbor to give or take space from.")
        }
        let step = percent / 100 * (direction == .right || direction == .down ? 1 : -1)
        try client.send(.setSplitRatio(tab: tab.id, path: path, ratio: min(max(ratio + step, 0.1), 0.9)))
        try client.request(.state)
        return 0
    }

    // MARK: Automation

    static let wait = CLICommand(
        names: ["wait"], summary: "Wait for a pane, tab or session to end",
        usage: """
        Usage: den wait [-s SESSION] [-p PANE | -t TAB | --session-end] [--timeout SECONDS]

        Blocks until the pane's program exits (or the pane closes), the tab
        closes, or with --session-end the whole session ends. Exits with the
        program's status, so scripts can chain on it; 124 on timeout.

        Example: den split --keep-open --label build -- make && den wait -p build
        """
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        let sessionRef = try args.option("-s", "--session")
        let paneRef = try args.option("-p", "--pane")
        let tabRef = try args.option("-t", "--tab")
        let wholeSession = args.flag("--session-end")
        let timeout = try args.option("--timeout").map { (value: String) throws(CLIError) -> Double in
            guard let s = Double(value), s > 0 else { throw .usage("--timeout takes seconds, not “\(value)”.") }
            return s
        }
        try args.finish()
        guard [paneRef != nil, tabRef != nil, wholeSession].filter({ $0 }).count <= 1 else { throw .usage("Wait for one thing: -p, -t or --session-end.") }

        let client = try context.connect()
        // Watch first, then look, so nothing ends unseen in between.
        try client.request(.watchEvents)
        let targets = CLITargets(state: try client.state())
        let session = try targets.session(sessionRef)

        enum Target { case pane(PaneID), tab(TabID), session }
        let target: Target
        if wholeSession {
            target = .session
        } else if tabRef != nil {
            target = .tab(try targets.tab(tabRef, in: session).id)
        } else {
            let pane = try targets.pane(paneRef, in: session)
            if let exit = pane.exit { return exit.shellStatus }
            target = .pane(pane.id)
        }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            guard let event = try client.nextEvent(timeout: deadline.map { $0.timeIntervalSinceNow }) else {
                CLIOutput.error("Timed out; it's still running.")
                return 124
            }
            switch (target, event.kind) {
            case (.pane(let id), .paneExited(_, let pane, let exit)) where pane == id: return exit.shellStatus
            case (.pane(let id), .paneClosed(_, let pane)) where pane == id: return 0
            case (.tab(let id), .tabClosed(_, let tab)) where tab == id: return 0
            case (_, .sessionClosed(let sid)) where sid == session.id: return 0
            default: continue
            }
        }
    }

    static let events = CLICommand(
        names: ["events"], summary: "Stream what happens in dend",
        usage: """
        Usage: den events [-s SESSION] [--json]

        Prints one line per event until interrupted: sessions, tabs and panes
        appearing and closing, programs exiting, resizes, title and process
        changes, bells, and clients connecting. --json prints each event as a
        JSON object, one per line, for scripts.
        """
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        let sessionRef = try args.option("-s", "--session")
        try args.finish()
        let client = try context.connect()
        try client.request(.watchEvents)
        let state = try client.state()
        let filter = try sessionRef.map { (ref: String) throws(CLIError) in try CLITargets(state: state).session(ref).id }
        var labels: [PaneID: String] = [:]
        for pane in state.sessions.flatMap(\.panes) { labels[pane.id] = CLITargets.paneName(pane) }
        var names = Dictionary(state.sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        setvbuf(stdout, nil, _IOLBF, 0)
        while let event = try client.nextEvent(timeout: nil) {
            if let filter, event.kind.session != filter { continue }
            if context.json {
                print(String(decoding: ControlCoding.encode(event), as: UTF8.self))
                continue
            }
            switch event.kind {
            case .paneCreated(_, _, let pane, let label): labels[pane] = label ?? "shell"
            case .paneLabelChanged(_, let pane, let label?): labels[pane] = label
            case .sessionCreated(let sid, let name), .sessionRenamed(let sid, let name): names[sid] = name
            default: break
            }
            let (name, subject, detail) = EventLine.describe(event.kind, labels: labels, sessions: names)
            let time = EventLine.clock.string(from: event.time)
            print("\(time)  \(name.padding(toLength: 21, withPad: " ", startingAt: 0))  \(subject.padding(toLength: 24, withPad: " ", startingAt: 0))  \(detail)")
        }
        return 0
    }

    static let state = CLICommand(
        names: ["state", "api"], summary: "Dump dend's full state as JSON",
        usage: "Usage: den state\n\nPrints every session, tab (with its split tree), pane (with its processes) and client as JSON."
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        try args.finish()
        CLIOutput.json(try context.connect().state())
        return 0
    }

    static let clients = CLICommand(
        names: ["clients"], summary: "List connected clients",
        usage: "Usage: den clients [--json]\n\nShows what is attached to dend: Den windows, remote Dens, and den commands (this one included)."
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        try args.finish()
        let state = try context.connect().state()
        if context.json { CLIOutput.json(state.clients); return 0 }
        CLIOutput.table(["ID", "NAME", "CONNECTED", "GETS"], state.clients.map {
            ["\($0.id)", $0.name, CLIOutput.age($0.connectedAt), $0.subscribed ? "everything" : $0.watchingEvents ? "events" : "replies"]
        })
        return 0
    }

    // MARK: Sessions

    static let list = CLICommand(
        names: ["ls", "list"], summary: "List sessions",
        usage: "Usage: den ls [--json]\n\nOne line per session: name, tab and pane counts, and ID."
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        try args.finish()
        let state = try context.connect().state()
        if context.json { CLIOutput.json(state.sessions); return 0 }
        guard !state.sessions.isEmpty else { print("No sessions. Create one with `den new NAME`."); return 0 }
        let current = CLITargets(state: state).environmentSession
        CLIOutput.table(["NAME", "TABS", "PANES", "ID"], state.sessions.map {
            [$0.id == current ? "\($0.name) *" : $0.name, "\($0.tabs.count)", "\($0.panes.count)", CLITargets.shortID($0.id.raw)]
        })
        return 0
    }

    static let kill = CLICommand(
        names: ["kill"], summary: "End sessions and everything running in them",
        usage: "Usage: den kill SESSION...\n\nCloses each session's tabs and stops their programs. This can't be undone."
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        var refs: [String] = []
        while let ref = args.next() { refs.append(ref) }
        guard !refs.isEmpty else { throw .usage("Name the session(s) to end, e.g. `den kill video`.") }
        let client = try context.connect()
        let targets = CLITargets(state: try client.state())
        var sessions: [SessionState] = []
        for ref in refs { sessions.append(try targets.session(ref)) }
        for session in sessions { try client.send(.killSession(session.id)) }
        try client.request(.state)
        return 0
    }

    static let sessionGroup = CLIGroup(name: "session", verbs: [
        CLICommand(names: ["list", "ls"], summary: "List sessions", usage: list.usage, run: list.run),
        CLICommand(
            names: ["inspect", "show"], summary: "Show a session's tabs and panes",
            usage: "Usage: den session inspect [SESSION] [--json]"
        ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
            let ref = args.next()
            try args.finish()
            let state = try context.connect().state()
            let session = try CLITargets(state: state).session(ref)
            if context.json { CLIOutput.json(session); return 0 }
            CLIOutput.fields([("session", session.id.description), ("name", session.name), ("host", state.host),
                              ("tabs", "\(session.tabs.count)"), ("panes", "\(session.panes.count)")])
            print()
            CLIOutput.table(["TAB", "ID", "TITLE", "PANES"], session.tabs.enumerated().map { i, tab in
                ["\(i + 1)", CLITargets.shortID(tab.id.raw), tab.title ?? "-", tab.panes.map(CLITargets.paneName).joined(separator: ", ")]
            })
            print()
            print(CLIOutput.bold("clients") + CLIOutput.dim("  (they see every session)"))
            for c in state.clients { print("  #\(c.id)  \(c.name)  \(CLIOutput.age(c.connectedAt))") }
            return 0
        },
        CLICommand(
            names: ["rename"], summary: "Rename a session",
            usage: "Usage: den session rename [SESSION] NEW-NAME\n\nWith one name, renames the session you're in."
        ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
            let first = try args.required("NEW-NAME")
            let second = args.next()
            try args.finish()
            let (ref, name) = second.map { (Optional(first), $0) } ?? (nil, first)
            let client = try context.connect()
            let state = try client.state()
            let session = try CLITargets(state: state).session(ref)
            if state.sessions.contains(where: { $0.name == name && $0.id != session.id }) {
                throw CLIError(message: "Another session is already called “\(name)”; names must be unique for -s to find them.")
            }
            try client.send(.renameSession(session.id, name: name))
            try client.request(.state)
            return 0
        },
        CLICommand(names: ["kill", "close"], summary: "End sessions", usage: kill.usage, run: kill.run),
    ])

    // MARK: Tabs

    static let tabGroup = CLIGroup(name: "tab", verbs: [
        CLICommand(
            names: ["list", "ls"], summary: "List a session's tabs",
            usage: "Usage: den tab list [-s SESSION] [--json]"
        ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
            let ref = try args.option("-s", "--session")
            try args.finish()
            let session = try CLITargets(state: try context.connect().state()).session(ref)
            if context.json { CLIOutput.json(session.tabs); return 0 }
            CLIOutput.table(["TAB", "ID", "TITLE", "PANES"], session.tabs.enumerated().map { i, tab in
                ["\(i + 1)", CLITargets.shortID(tab.id.raw), tab.title ?? "-", "\(tab.panes.count)"]
            })
            return 0
        },
        CLICommand(names: ["new"], summary: "Open a tab (same as `den run`)", usage: run.usage, run: run.run),
        CLICommand(
            names: ["rename"], summary: "Set a tab's title",
            usage: "Usage: den tab rename [-s SESSION] [-t TAB] TITLE\n\nAn empty TITLE (\"\") goes back to the automatic title."
        ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
            let sessionRef = try args.option("-s", "--session")
            let tabRef = try args.option("-t", "--tab")
            let title = try args.required("TITLE")
            try args.finish()
            let client = try context.connect()
            let targets = CLITargets(state: try client.state())
            let tab = try targets.tab(tabRef, in: try targets.session(sessionRef))
            try client.send(.renameTab(tab.id, title: title.isEmpty ? nil : title))
            try client.request(.state)
            return 0
        },
        CLICommand(
            names: ["close"], summary: "Close a tab and its panes",
            usage: "Usage: den tab close [-s SESSION] [-t TAB]"
        ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
            let sessionRef = try args.option("-s", "--session")
            let tabRef = try args.option("-t", "--tab") ?? args.next()
            try args.finish()
            let client = try context.connect()
            let targets = CLITargets(state: try client.state())
            let tab = try targets.tab(tabRef, in: try targets.session(sessionRef))
            for pane in tab.panes { try client.send(.closePane(pane.id)) }
            try client.request(.state)
            return 0
        },
    ])

    // MARK: Panes

    static let paneGroup = CLIGroup(name: "pane", verbs: [
        CLICommand(
            names: ["list", "ls"], summary: "List a session's panes",
            usage: "Usage: den pane list [-s SESSION] [--json]"
        ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
            let ref = try args.option("-s", "--session")
            try args.finish()
            let session = try CLITargets(state: try context.connect().state()).session(ref)
            if context.json { CLIOutput.json(session.panes); return 0 }
            var rows: [[String]] = []
            for (i, tab) in session.tabs.enumerated() {
                for pane in tab.panes {
                    rows.append(["\(i + 1)", CLITargets.shortID(pane.id.raw), pane.label ?? "-", pane.process,
                                 "\(pane.cols)x\(pane.rows)", CLIOutput.describe(pane.exit)])
                }
            }
            CLIOutput.table(["TAB", "ID", "LABEL", "PROCESS", "SIZE", "STATE"], rows)
            return 0
        },
        CLICommand(
            names: ["inspect", "show", "process"], summary: "Show a pane's details and processes",
            usage: """
            Usage: den pane inspect [-s SESSION] [PANE] [--json]

            Shows the pane's label, command, folder, size and state, the process
            dend started (child) and the one in the foreground now, e.g. nvim
            running inside your shell.
            """
        ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
            let sessionRef = try args.option("-s", "--session")
            let paneRef = try args.option("-p", "--pane") ?? args.next()
            try args.finish()
            let targets = CLITargets(state: try context.connect().state())
            let session = try targets.session(sessionRef)
            let pane = try targets.pane(paneRef, in: session)
            if context.json { CLIOutput.json(pane); return 0 }
            let tabIndex = session.tabs.firstIndex { $0.panes.contains { $0.id == pane.id } }.map { "\($0 + 1)" } ?? "-"
            CLIOutput.fields([
                ("pane", pane.id.description), ("session", session.name), ("tab", tabIndex),
                ("label", pane.label ?? "-"), ("command", pane.command.isEmpty ? "(shell)" : pane.command.joined(separator: " ")),
                ("keep-open", pane.keepOpen ? "yes" : "no"), ("state", CLIOutput.describe(pane.exit)),
                ("process", pane.process), ("cwd", pane.cwd ?? "-"), ("title", pane.title ?? "-"),
                ("size", "\(pane.cols)x\(pane.rows)"), ("created", CLIOutput.age(pane.createdAt)),
            ])
            for (heading, process) in [("child", pane.child), ("foreground", pane.foreground)] {
                guard let process else { continue }
                print()
                print(CLIOutput.bold(heading))
                CLIOutput.fields([("  pid", "\(process.pid)"), ("  name", process.name), ("  path", process.path ?? "-"), ("  cwd", process.cwd ?? "-")])
            }
            return 0
        },
        CLICommand(
            names: ["label", "rename"], summary: "Name a pane",
            usage: "Usage: den pane label [-s SESSION] [-p PANE] LABEL\n\nAn empty LABEL (\"\") removes it. Labels address panes in -p and move/swap."
        ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
            let sessionRef = try args.option("-s", "--session")
            let paneRef = try args.option("-p", "--pane")
            let label = try args.required("LABEL")
            try args.finish()
            let client = try context.connect()
            let targets = CLITargets(state: try client.state())
            let session = try targets.session(sessionRef)
            let pane = try targets.pane(paneRef, in: session)
            if !label.isEmpty, session.panes.contains(where: { $0.label == label && $0.id != pane.id }) {
                throw CLIError(message: "Another pane in “\(session.name)” is already labelled “\(label)”.")
            }
            try client.request(.setLabel(pane: pane.id, label: label.isEmpty ? nil : label))
            return 0
        },
        CLICommand(
            names: ["close", "kill"], summary: "Close a pane and stop its program",
            usage: "Usage: den pane close [-s SESSION] [PANE]"
        ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
            let sessionRef = try args.option("-s", "--session")
            let paneRef = try args.option("-p", "--pane") ?? args.next()
            try args.finish()
            let client = try context.connect()
            let targets = CLITargets(state: try client.state())
            let pane = try targets.pane(paneRef, in: try targets.session(sessionRef))
            try client.send(.closePane(pane.id))
            try client.request(.state)
            return 0
        },
        CLICommand(names: ["capture"], summary: "Print a pane's screen", usage: capture.usage, run: capture.run),
        CLICommand(names: ["send"], summary: "Type text into a pane", usage: send.usage, run: send.run),
    ])

    // MARK: Config

    static let keybinds = CLICommand(
        names: ["keybinds", "keys", "keybind"], summary: "Show every shortcut, set or not",
        usage: """
        Usage: den keybinds [--unset | --custom] [--json]

        Lists every command with its shortcut as config.toml writes it and as
        macOS shows it, and whether it's Den's default, yours, or not set.
        --unset shows only commands without a shortcut; --custom only yours.
        """
    ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
        let onlyUnset = args.flag("--unset", "--not-set")
        let onlyCustom = args.flag("--custom")
        try args.finish()
        return KeybindList.print(onlyUnset: onlyUnset, onlyCustom: onlyCustom, json: context.json)
    }

    static let configGroup = CLIGroup(name: "config", verbs: [
        CLICommand(
            names: ["help", "man"], summary: "The full config manual",
            usage: "Usage: den config help [TOPIC]\n\nTopics: \(ConfigManual.topicNames). Without TOPIC, the whole manual."
        ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
            let topic = args.next()
            try args.finish()
            guard let text = ConfigManual.text(topic: topic) else {
                throw .usage("No topic “\(topic ?? "")”. Topics: \(ConfigManual.topicNames).")
            }
            CLIOutput.page(text)
            return 0
        },
        CLICommand(
            names: ["path"], summary: "Print config file locations",
            usage: "Usage: den config path"
        ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
            try args.finish()
            CLIOutput.fields([("config.toml", UserConfig.url.path), ("settings", DenConfig.url.path), ("themes", DenPaths.themes.path),
                              ("socket", DenPaths.socket.path), ("log", DenPaths.log.path)])
            return 0
        },
        CLICommand(
            names: ["check", "validate"], summary: "Check config.toml for mistakes",
            usage: "Usage: den config check\n\nParses config.toml the way Den does and reports the first problem."
        ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
            try args.finish()
            switch UserConfig.load() {
            case .success(let config):
                let exists = FileManager.default.fileExists(atPath: UserConfig.url.path)
                print(exists ? "\(UserConfig.url.path) is valid: \(config.shortcuts.count) shortcut change(s), \(config.keybinds.count) extra binding(s)."
                    : "No \(UserConfig.url.path) yet; Den uses its defaults. `den config help` explains what it can hold.")
                return 0
            case .failure(let error):
                throw CLIError(message: "\(UserConfig.url.path): \(error.message) Den keeps the last config that worked until this is fixed.")
            }
        },
    ])

    // MARK: Agents

    static let agentGroup = CLIGroup(name: "agent", verbs: [
        CLICommand(
            names: ["guide"], summary: "Print what an agent needs to drive Den",
            usage: "Usage: den agent guide\n\nMarkdown for a coding agent's context: how to open, read and type into panes."
        ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
            try args.finish()
            print(AgentGuide.markdown)
            return 0
        },
        CLICommand(
            names: ["install"], summary: "Install the den skill for coding agents",
            usage: """
            Usage: den agent install

            Writes the guide as an Agent Skill to \(AgentGuide.skillDirectories.map { "~/\($0)" }.joined(separator: " and ")),
            where Claude Code, Codex, OpenCode and other skill-aware agents find it.
            Rewrites only files Den wrote; run it again after updating Den.
            """
        ) { (args: inout CLIArgs, context: CLIContext) throws(CLIError) -> Int32 in
            try args.finish()
            var failed = false
            for (path, outcome) in AgentGuide.install() {
                switch outcome {
                case .written: print("Wrote \(path)")
                case .unchanged: print("Up to date: \(path)")
                case .occupied: CLIOutput.error("\(path) is someone else's skill; left alone. Move it to install Den's.")
                case .failed(let message): CLIOutput.error(message); failed = true
                }
            }
            return failed ? 1 : 0
        },
    ])
}

extension CLITargets {
    /// The session this shell runs in, if it runs inside Den.
    var environmentSession: SessionID? {
        guard let id = environment["DEN_PANE_ID"].flatMap(UUID.init(uuidString:)).map(PaneID.init) else { return nil }
        return session(of: id)?.id
    }
}

/// One `den events` line.
enum EventLine {
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func describe(_ kind: ControlEvent.Kind, labels: [PaneID: String], sessions: [SessionID: String]) -> (String, String, String) {
        func pane(_ id: PaneID) -> String { "\(labels[id] ?? "pane") \(CLITargets.shortID(id.raw))" }
        func session(_ id: SessionID) -> String { sessions[id] ?? CLITargets.shortID(id.raw) }
        switch kind {
        case .sessionCreated(let s, let name): return ("session_created", name, CLITargets.shortID(s.raw))
        case .sessionRenamed(let s, let name): return ("session_renamed", name, CLITargets.shortID(s.raw))
        case .sessionClosed(let s): return ("session_closed", session(s), "")
        case .tabCreated(let s, let t): return ("tab_created", "tab \(CLITargets.shortID(t.raw))", "in \(session(s))")
        case .tabRenamed(_, let t, let title): return ("tab_renamed", "tab \(CLITargets.shortID(t.raw))", title ?? "(automatic)")
        case .tabClosed(let s, let t): return ("tab_closed", "tab \(CLITargets.shortID(t.raw))", "in \(session(s))")
        case .layoutChanged(let s): return ("layout_changed", session(s), "")
        case .paneCreated(let s, _, let p, _): return ("pane_created", pane(p), "in \(session(s))")
        case .paneExited(_, let p, let exit): return ("pane_exited", pane(p), CLIOutput.describe(exit))
        case .paneClosed(_, let p): return ("pane_closed", pane(p), "")
        case .paneResized(_, let p, let cols, let rows): return ("pane_resized", pane(p), "\(cols)x\(rows)")
        case .paneProcessChanged(_, let p, let process, let cwd): return ("pane_process_changed", pane(p), "\(process)  \(cwd ?? "")")
        case .paneTitleChanged(_, let p, let title): return ("pane_title_changed", pane(p), title ?? "")
        case .paneLabelChanged(_, let p, let label): return ("pane_label_changed", pane(p), label ?? "(none)")
        case .paneBell(_, let p): return ("pane_bell", pane(p), "")
        case .clientConnected(let c, let name): return ("client_connected", "#\(c)", name)
        case .clientDisconnected(let c, let name): return ("client_disconnected", "#\(c)", name)
        }
    }
}
