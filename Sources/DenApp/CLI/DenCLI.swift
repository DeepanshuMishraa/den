import Foundation
import DenProtocol

/// `den`: drives dend from a shell. It's the Den executable itself, run
/// through the `den` link the app bundle and installer put on PATH, so the
/// app and its CLI always match.
enum DenCLI {
    /// Runs the CLI and exits when invoked as `den` or with a command word.
    /// LaunchServices and Xcode only ever pass `-psn_…`/`-NS…` flags.
    static func runIfRequested() {
        let argv = CommandLine.arguments
        let invokedAsDen = argv.first.map { ($0 as NSString).lastPathComponent } == "den"
        let hasCommand = argv.count > 1 && !["-psn_", "-NS", "-Apple"].contains { argv[1].hasPrefix($0) }
        guard invokedAsDen || hasCommand else { return }
        exit(run(Array(argv.dropFirst())))
    }

    static func run(_ arguments: [String]) -> Int32 {
        var args = CLIArgs(arguments)
        do throws(CLIError) {
            let context = CLIContext(socket: try args.option("--socket"), json: args.flag("--json"))
            if args.flag("--version", "-V") {
                print("den \(cliVersion()) (protocol \(protocolVersion))")
                return 0
            }
            guard let name = args.next(), name != "help" || !args.words.isEmpty else {
                print(CLIHelp.overview)
                return 0
            }
            if name == "-h" || name == "--help" {
                print(CLIHelp.overview)
                return 0
            }
            if name == "help" {
                let topic = args.words.joined(separator: " ")
                guard let text = CLIHelp.usage(topic) else { throw CLIError.usage("No command “\(topic)”. `den help` lists them.") }
                print(text)
                return 0
            }
            guard let command = CLICommands.all.first(where: { $0.names.contains(name) }) else {
                throw CLIError.usage("Unknown command “\(name)”. `den help` lists them.")
            }
            if args.flag("-h", "--help") {
                print(command.usage)
                return 0
            }
            return try command.run(&args, context)
        } catch {
            CLIOutput.error(error.message)
            return error.status
        }
    }

    /// The app's version even when invoked through the `den` link.
    /// `Bundle.main` points at `…/Resources/bin/den` in that case (no
    /// Info.plist there), so resolve symlinks back to `…/MacOS/Den` and read
    /// the enclosing Den.app's Info.plist. Dev builds (`.build/…`) stay "dev".
    static func cliVersion() -> String {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return v
        }
        for raw in executableCandidates() {
            let resolved = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
            // …/Den.app/Contents/MacOS/Den → …/Den.app/Contents/Info.plist
            if let range = resolved.range(of: ".app/Contents/", options: .backwards) {
                let info = String(resolved[..<range.upperBound]) + "Info.plist"
                if let dict = NSDictionary(contentsOfFile: info),
                   let v = dict["CFBundleShortVersionString"] as? String {
                    return v
                }
            }
        }
        return "dev"
    }

    /// Paths that might lead back to the enclosing Den.app: the executable
    /// as the loader sees it, argv[0], and a PATH lookup for a bare `den`.
    /// The install-link fallbacks only apply when invoked as `den`; a direct
    /// `…/MacOS/Den` (or `.build/…/Den`) launch reports its own bundle or
    /// "dev", never another copy's version.
    private static func executableCandidates() -> [String] {
        var out: [String] = []
        if let p = Bundle.main.executableURL?.path { out.append(p) }
        let invokedAsDen = CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } == "den"
        if let arg = CommandLine.arguments.first, invokedAsDen {
            if arg.contains("/") {
                out.append(arg)
            } else {
                // Bare `den`: search PATH (covers ~/.local/bin/den).
                let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
                for dir in path.split(separator: ":") {
                    out.append((dir as NSString).appendingPathComponent(arg))
                }
            }
        } else if let arg = CommandLine.arguments.first, arg.contains("/") {
            out.append(arg)
        }
        return out
    }
}

struct CLIContext {
    let socket: String?
    let json: Bool

    func connect() throws(CLIError) -> ControlClient { try ControlClient.connect(socket: socket) }
}

struct CLICommand: Sendable {
    let names: [String]
    let summary: String
    let usage: String
    let run: @Sendable (inout CLIArgs, CLIContext) throws(CLIError) -> Int32
}

/// A `den <group> <verb>` family such as `den pane list`.
struct CLIGroup: Sendable {
    let name: String
    let verbs: [CLICommand]

    func run(_ args: inout CLIArgs, _ context: CLIContext) throws(CLIError) -> Int32 {
        guard let verb = args.next() else { print(usage); return 0 }
        guard let command = verbs.first(where: { $0.names.contains(verb) }) else {
            throw .usage("`den \(name)` has no “\(verb)”; it takes \(verbs.map { $0.names[0] }.joined(separator: ", ")).")
        }
        if args.flag("-h", "--help") { print(command.usage); return 0 }
        return try command.run(&args, context)
    }

    var usage: String {
        let width = verbs.map { $0.names[0].count }.max() ?? 0
        return "Usage: den \(name) <\(verbs.map { $0.names[0] }.joined(separator: "|"))> [options]\n\n"
            + verbs.map { "  \($0.names[0].padding(toLength: width, withPad: " ", startingAt: 0))  \($0.summary)" }.joined(separator: "\n")
            + "\n\nRun `den \(name) <verb> --help` for details."
    }
}
