import Foundation
import Testing
@testable import DenServer

@Suite struct ProgramNameTests {
    @Test func shebangToolsResolveToTheirName() {
        #expect(ProgramName.resolve(process: "node", arguments: ["node", "/opt/homebrew/bin/gemini"]) == "gemini")
        #expect(ProgramName.resolve(process: "node", arguments: ["node", "--no-warnings", "/usr/local/bin/npm", "run", "dev"]) == "npm")
        #expect(ProgramName.resolve(process: "python3.12", arguments: ["/usr/bin/python3", "/Users/me/.local/bin/httpie"]) == "httpie")
    }

    /// The pi coding agent, run directly and for `pi update --extensions`.
    @Test func piResolvesFromItsLinkOrItsBundle() {
        #expect(ProgramName.resolve(process: "node", arguments: ["node", "/opt/homebrew/bin/pi"]) == "pi")
        #expect(ProgramName.resolve(process: "node", arguments: ["node", "/opt/homebrew/bin/pi", "update", "--extensions"]) == "pi")
        #expect(ProgramName.resolve(process: "node", arguments: [
            "node", "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js", "update",
        ]) == "pi-coding-agent")
    }

    /// Claude Code's binary is named for its version
    /// (~/.local/share/claude/versions/2.1.296); argv[0] is the command.
    @Test func versionNamedBinariesResolveToTheirCommand() {
        #expect(ProgramName.resolve(process: "2.1.296", arguments: ["claude"]) == "claude")
        #expect(ProgramName.resolve(process: "2.1.296", arguments: ["/Users/me/.local/bin/claude", "--resume"]) == "claude")
        #expect(ProgramName.resolve(process: "2.1.296", arguments: []) == "2.1.296")
        #expect(ProgramName.resolve(process: "1.2.3", arguments: ["4.5.6"]) == "1.2.3")
    }

    /// Node programs that set `process.title` overwrite argv; the kernel then
    /// reports just the title (pi leaves "pi " with padding).
    @Test func selfSetTitlesNameTheProgram() {
        #expect(ProgramName.resolve(process: "node", arguments: ["pi "]) == "pi")
        #expect(ProgramName.resolve(process: "node", arguments: ["npm run dev"]) == "npm")
        #expect(ProgramName.resolve(process: "node", arguments: ["/opt/homebrew/bin/node", "-e", "1"]) == "node")
        #expect(ProgramName.resolve(process: "node", arguments: ["node"]) == "node")
    }

    @Test func pythonModulesResolveToTheModule() {
        #expect(ProgramName.resolve(process: "python3", arguments: ["python3", "-m", "pytest", "-x"]) == "pytest")
        #expect(ProgramName.resolve(process: "python3", arguments: ["python3", "-m", "http.server"]) == "http")
    }

    @Test func dottedEntriesResolveThroughTheirStem() {
        #expect(ProgramName.resolve(process: "node", arguments: ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "install"]) == "npm")
        #expect(ProgramName.resolve(process: "node", arguments: ["node", "/opt/homebrew/lib/node_modules/pnpm/dist/pnpm.cjs", "install"]) == "pnpm")
        #expect(ProgramName.resolve(process: "node", arguments: ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"]) == "codex")
        #expect(ProgramName.resolve(process: "node", arguments: ["node", "/opt/homebrew/lib/node_modules/remodex/bin/remodex.js", "run-service"]) == "remodex")
    }

    @Test func genericEntriesWalkUpToTheOwningTool() {
        #expect(ProgramName.resolve(process: "node", arguments: ["node", "/Users/me/Code/shottr-mcp/dist/main.js"]) == "shottr-mcp")
        #expect(ProgramName.resolve(process: "node", arguments: ["node", "/opt/homebrew/lib/node_modules/vite/dist/cli.js"]) == "vite")
    }

    @Test func plainScriptsAndInlineCodeKeepTheInterpreter() {
        #expect(ProgramName.resolve(process: "node", arguments: ["node", "dist/index.js"]) == "node")
        #expect(ProgramName.resolve(process: "node", arguments: ["node", "-e", "console.log(1)"]) == "node")
        #expect(ProgramName.resolve(process: "node", arguments: ["node"]) == "node")
        #expect(ProgramName.resolve(process: "python3", arguments: ["python3", "script.py"]) == "python3")
    }

    @Test func nonInterpretersAreUntouched() {
        #expect(ProgramName.resolve(process: "nvim", arguments: ["nvim", "/etc/hosts"]) == "nvim")
    }

    @Test func readsArgumentsFromTheKernel() {
        let args = ProgramName.arguments(of: getpid())
        #expect(args == CommandLine.arguments)
    }
}
