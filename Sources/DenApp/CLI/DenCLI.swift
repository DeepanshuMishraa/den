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
                print("den \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (protocol \(protocolVersion))")
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
