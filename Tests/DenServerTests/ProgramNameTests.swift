import Foundation
import Testing
@testable import DenServer

@Suite struct ProgramNameTests {
    @Test func shebangToolsResolveToTheirName() {
        #expect(ProgramName.resolve(process: "node", arguments: ["node", "/opt/homebrew/bin/gemini"]) == "gemini")
        #expect(ProgramName.resolve(process: "node", arguments: ["node", "--no-warnings", "/usr/local/bin/npm", "run", "dev"]) == "npm")
        #expect(ProgramName.resolve(process: "python3.12", arguments: ["/usr/bin/python3", "/Users/me/.local/bin/httpie"]) == "httpie")
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
