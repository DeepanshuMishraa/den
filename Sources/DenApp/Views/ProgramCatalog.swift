import SwiftUI

/// What a program looks like in tabs, decks and pane headers: a display
/// name, a brand-tinted tile, and a mark drawn on it.
struct ProgramKind: Equatable {
    /// Stable identity; equal programs share it.
    let id: String
    /// Shown in titles, e.g. "Node ~/site".
    let name: String
    let tileTop: Color
    let tileBottom: Color
    /// The mark's color on the tile.
    let ink: Color
    let glyph: Glyph

    enum Glyph: Equatable {
        /// `>_`, for shells.
        case prompt
        /// An SF Symbol name.
        case symbol(String)
        /// One to three letters, set tight and bold.
        case monogram(String)
        /// A real brand mark loaded from `Resources/ProgramIcons/<asset>.svg`.
        /// `template` renders the mark in the tile's ink color; otherwise the
        /// mark keeps its own brand colors on a plate (the tile colors).
        case brand(asset: String, template: Bool)
    }

    static func == (a: ProgramKind, b: ProgramKind) -> Bool { a.id == b.id }

    /// Coding agents: they get a line in Activity Mode even when they don't
    /// report OSC 7501 status.
    var isAgent: Bool { Self.agentIDs.contains(id) }
    private static let agentIDs: Set<String> = [
        "claude", "codex", "gemini", "antigravity", "grok", "opencode", "aider", "amp",
        "cursor", "copilot", "goose", "crush", "droid", "qwen",
    ]

    static let shell = ProgramKind(id: "shell", name: "shell", top: 0x45494F, bottom: 0x1D1F22, ink: 0x5EE38C, glyph: .prompt)

    /// Picks the program from the foreground process name (dend resolves
    /// interpreters to the script they run) and, for agents that run under
    /// a generic runtime, the terminal title they set.
    static func detect(process: String?, title: String?) -> ProgramKind {
        let raw = (process ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let p = raw.lowercased()
        let t = (title ?? "").lowercased()
        if t.contains("claude code") || t.hasPrefix("✳") { return catalog["claude"] ?? shell }
        if let known = catalog[p] { return known }
        // python3.12, pip3.11, ruby3.3 …
        let unversioned = String(p.prefix { !$0.isNumber && $0 != "." })
        if unversioned != p, let known = catalog[unversioned] { return known }
        if p.isEmpty { return shell }
        return unknown(raw)
    }

    /// A program outside the catalog still gets its own tile: initials on a
    /// color derived from its name, so the same tool always looks the same.
    static func unknown(_ process: String) -> ProgramKind {
        // FNV-1a: stable across launches, unlike Hasher.
        var hash: UInt32 = 2_166_136_261
        for byte in process.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let hue = Double(hash % 360) / 360
        let letters = process.filter { $0.isLetter || $0.isNumber }.prefix(2)
        return ProgramKind(
            id: "unknown:\(process.lowercased())",
            name: process,
            tileTop: Color(hue: hue, saturation: 0.5, brightness: 0.62),
            tileBottom: Color(hue: hue, saturation: 0.62, brightness: 0.38),
            ink: .white,
            glyph: .monogram(letters.isEmpty ? "?" : letters.prefix(1).uppercased() + letters.dropFirst().lowercased())
        )
    }

    init(id: String, name: String, top: UInt32, bottom: UInt32, ink: UInt32 = 0xFFFFFF, glyph: Glyph) {
        self.init(id: id, name: name, tileTop: hex(top), tileBottom: hex(bottom), ink: hex(ink), glyph: glyph)
    }

    init(id: String, name: String, tileTop: Color, tileBottom: Color, ink: Color, glyph: Glyph) {
        self.id = id
        self.name = name
        self.tileTop = tileTop
        self.tileBottom = tileBottom
        self.ink = ink
        self.glyph = glyph
    }
}

func hex(_ v: UInt32) -> Color {
    Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

// MARK: - Catalog

extension ProgramKind {
    /// Process name → program. Several names can share one program.
    static let catalog: [String: ProgramKind] = {
        var table: [String: ProgramKind] = [:]
        func add(_ names: [String], _ id: String, _ name: String, _ top: UInt32, _ bottom: UInt32, ink: UInt32 = 0xFFFFFF, _ glyph: Glyph) {
            let program = ProgramKind(id: id, name: name, top: top, bottom: bottom, ink: ink, glyph: glyph)
            for n in names { table[n] = program }
        }
        func shell(_ n: String, name: String? = nil, top: UInt32 = 0x3A3D42, bottom: UInt32 = 0x16181B, ink: UInt32 = 0x5EE38C) {
            add([n], n, name ?? n, top, bottom, ink: ink, .prompt)
        }

        // Shells: a dark screen with a green prompt, like Rex's fish.
        for n in ["fish", "zsh", "bash", "sh", "dash", "ksh", "mksh", "tcsh", "csh", "login"] { shell(n) }
        shell("nu", name: "Nushell", top: 0x3AA675, bottom: 0x1F6B4A, ink: 0xFFFFFF)
        shell("elvish", name: "Elvish")
        shell("xonsh", name: "xonsh")
        shell("pwsh", name: "PowerShell", top: 0x2D7DD2, bottom: 0x012456, ink: 0xFFFFFF)

        // Coding agents.
        add(["claude"], "claude", "Claude Code", 0xEC8A6A, 0xD25B3D, .brand(asset: "claude", template: true))
        add(["codex"], "codex", "Codex", 0xFFFFFF, 0xE3E4E8, ink: 0x0D0D0D, .brand(asset: "codex", template: true))
        add(["gemini"], "gemini", "Gemini", 0xFFFFFF, 0xE4E6EA, .brand(asset: "gemini", template: false))
        add(["antigravity"], "antigravity", "Antigravity", 0x2B2B2B, 0x0A0A0A, .brand(asset: "antigravity", template: false))
        add(["grok", "xai"], "grok", "Grok", 0xFFFFFF, 0xE3E4E8, ink: 0x0D0D0D, .brand(asset: "grok", template: true))
        add(["opencode"], "opencode", "OpenCode", 0x2B2B2B, 0x0A0A0A, .brand(asset: "opencode", template: true))
        add(["aider"], "aider", "Aider", 0x22C55E, 0x15803D, .monogram("ai"))
        add(["amp"], "amp", "Amp", 0xF6553F, 0xC2301F, .symbol("bolt.fill"))
        add(["cursor-agent", "cursor"], "cursor", "Cursor", 0x2E2E2E, 0x0B0B0B, .brand(asset: "cursor", template: true))
        add(["copilot", "github-copilot-cli"], "copilot", "Copilot", 0x3B3F46, 0x16181C, .brand(asset: "copilot", template: true))
        add(["goose"], "goose", "Goose", 0x1F1F1F, 0x000000, .monogram("g"))
        add(["crush"], "crush", "Crush", 0xFF6AC1, 0xB43A8C, .symbol("heart.fill"))
        add(["droid"], "droid", "Droid", 0xF97316, 0xC2410C, .symbol("cpu.fill"))
        add(["qwen"], "qwen", "Qwen", 0x7C6CF2, 0x4B3FC2, .brand(asset: "qwen", template: true))
        add(["llm"], "llm", "LLM", 0x64748B, 0x334155, .symbol("text.bubble.fill"))

        // Editors.
        add(["nvim"], "nvim", "Neovim", 0x2E3238, 0x111316, .brand(asset: "nvim", template: false))
        add(["vim", "vi", "view", "vimdiff"], "vim", "Vim", 0x2E3238, 0x111316, .brand(asset: "vim", template: false))
        add(["hx", "helix"], "helix", "Helix", 0x8E7BDF, 0x55449C, .monogram("hx"))
        add(["emacs", "emacsclient"], "emacs", "Emacs", 0x9269C9, 0x5B3A8E, .monogram("e"))
        add(["nano", "pico"], "nano", "nano", 0x5C6BC0, 0x303F9F, .monogram("n"))
        add(["micro"], "micro", "micro", 0x4C566A, 0x2E3440, .symbol("pencil"))
        add(["kak", "kakoune"], "kakoune", "Kakoune", 0xE3B341, 0xB0812A, ink: 0x1A1A1A, .monogram("k"))
        add(["zed"], "zed", "Zed", 0x3B82F6, 0x1E40AF, .brand(asset: "zed", template: true))

        // Version control.
        add(["git"], "git", "Git", 0xF4664B, 0xC9361C, .brand(asset: "git", template: true))
        add(["lazygit", "lg"], "lazygit", "Git Changes", 0xF4664B, 0xC9361C, .brand(asset: "git", template: true))
        add(["tig"], "tig", "tig", 0xF4664B, 0xC9361C, .symbol("list.bullet.indent"))
        add(["gitui"], "gitui", "GitUI", 0xF4664B, 0xC9361C, .brand(asset: "git", template: true))
        add(["jj", "jjui"], "jj", "Jujutsu", 0x4C9F70, 0x2D6A4A, .monogram("jj"))
        add(["gh"], "gh", "GitHub", 0x2F3337, 0x0D1117, .symbol("chevron.left.forwardslash.chevron.right"))
        add(["glab"], "glab", "GitLab", 0xFC8A4E, 0xE24329, .symbol("chevron.left.forwardslash.chevron.right"))

        // JavaScript and TypeScript.
        add(["node", "nodejs"], "node", "Node", 0xFFFFFF, 0xE4E6EA, .brand(asset: "node", template: false))
        add(["npm", "npx"], "npm", "npm", 0xFFFFFF, 0xE4E6EA, .brand(asset: "npm", template: false))
        add(["pnpm", "pnpx"], "pnpm", "pnpm", 0x2E3238, 0x111316, ink: 0x2B2B2B, .brand(asset: "pnpm", template: false))
        add(["yarn"], "yarn", "Yarn", 0xFFFFFF, 0xE4E6EA, .brand(asset: "yarn", template: false))
        add(["deno"], "deno", "Deno", 0x2B2B2B, 0x0A0A0A, .symbol("lizard.fill"))
        add(["bun", "bunx"], "bun", "Bun", 0xFCF1DC, 0xEBD2A6, ink: 0x5A4127, .brand(asset: "bun", template: false))
        add(["vite"], "vite", "Vite", 0x2E3238, 0x111316, ink: 0xFFD62E, .brand(asset: "vite", template: false))
        add(["next-server", "next"], "next", "Next.js", 0xFFFFFF, 0xE4E6EA, .brand(asset: "next", template: false))
        add(["tsx", "ts-node", "tsc"], "typescript", "TypeScript", 0xFFFFFF, 0xE4E6EA, .brand(asset: "typescript", template: false))
        add(["eslint", "biome", "prettier", "oxlint"], "lint", "Lint", 0x7C3AED, 0x4C1D95, .symbol("checkmark.seal.fill"))
        add(["vitest", "jest", "playwright"], "jstest", "Tests", 0x84CC16, 0x4D7C0F, .symbol("checkmark.diamond.fill"))

        // Python.
        add(["python", "ipython", "bpython", "ptpython"], "python", "Python", 0xFFFFFF, 0xE4E6EA, ink: 0xFFD43B, .brand(asset: "python", template: false))
        add(["uv", "uvx"], "uv", "uv", 0xDE5FE9, 0x9B2BA8, .brand(asset: "uv", template: true))
        add(["pip", "pipx", "poetry", "pdm", "hatch", "rye"], "pip", "Python Packages", 0x3E7BB6, 0x2A5A88, .symbol("shippingbox.fill"))
        add(["pytest"], "pytest", "pytest", 0x0EA5E9, 0x0369A1, .symbol("checkmark.diamond.fill"))
        add(["jupyter", "jupyter-lab"], "jupyter", "Jupyter", 0xF8A15A, 0xE46E1E, .symbol("book.pages.fill"))

        // Other languages and toolchains.
        add(["cargo", "rustc", "rustup", "bacon", "rust-analyzer"], "rust", "Rust", 0xD9603B, 0x8A2C1B, .brand(asset: "rust", template: true))
        add(["go", "gopls", "air"], "go", "Go", 0x29BEB0, 0x00839A, .brand(asset: "go", template: true))
        add(["ruby", "irb", "rails", "bundle", "bundler", "rake", "gem"], "ruby", "Ruby", 0xFFFFFF, 0xE4E6EA, .brand(asset: "ruby", template: false))
        add(["iex", "mix", "elixir", "erl"], "elixir", "Elixir", 0x7A4C9E, 0x4B275F, .symbol("drop.fill"))
        add(["java", "gradle", "gradlew", "mvn", "kotlin", "sbt", "scala"], "jvm", "Java", 0xF08A24, 0xB35A09, .symbol("cup.and.saucer.fill"))
        add(["swift", "swiftc", "xcodebuild", "xcrun", "swift-frontend"], "swift", "Swift", 0xFFFFFF, 0xE4E6EA, .brand(asset: "swift", template: false))
        add(["zig"], "zig", "Zig", 0xF7A41D, 0xC97B0C, ink: 0x1A1A1A, .monogram("zig"))
        add(["ghc", "ghci", "cabal", "stack"], "haskell", "Haskell", 0x8F6CB8, 0x5E4089, .monogram("λ"))
        add(["lua", "luajit"], "lua", "Lua", 0x3D4BC4, 0x1F2A80, .symbol("moon.fill"))
        add(["php", "composer", "artisan"], "php", "PHP", 0x8892BF, 0x4F5B93, .monogram("php"))
        add(["dotnet"], "dotnet", ".NET", 0x8A5CD6, 0x512BD4, .monogram(".N"))
        add(["perl"], "perl", "Perl", 0x4B6BA5, 0x27406E, .monogram("pl"))
        add(["make", "gmake", "cmake", "ninja", "meson", "bazel"], "make", "Make", 0x8C99A6, 0x55606B, .symbol("hammer.fill"))
        add(["just"], "just", "just", 0x8C99A6, 0x55606B, .symbol("list.bullet"))
        add(["clang", "gcc", "cc", "c++", "ld"], "cc", "Compiler", 0x5C7CFA, 0x364FC7, .symbol("wrench.and.screwdriver.fill"))

        // Monitors.
        add(["top", "htop", "btop", "btm", "bottom", "glances", "nvtop", "atop", "gotop", "zenith", "bpytop"], "monitor", "Activity",
            0x24344D, 0x0F172A, ink: 0x4ADE80, .symbol("gauge.with.dots.needle.67percent"))

        // Containers, clusters, infrastructure.
        add(["docker", "lazydocker", "docker-compose", "colima", "orb", "orbctl"], "docker", "Docker", 0x48A9F2, 0x1E6EC0, .brand(asset: "docker", template: true))
        add(["podman"], "podman", "Podman", 0xA54BC0, 0x6B2385, .symbol("shippingbox.fill"))
        add(["kubectl", "k9s", "helm", "kubectx", "kubens", "minikube", "kind"], "kubernetes", "Kubernetes", 0x4F86EC, 0x2350B8, .symbol("steeringwheel"))
        add(["terraform", "tofu", "terragrunt"], "terraform", "Terraform", 0x8F5CDB, 0x5C2DAA, .symbol("square.stack.3d.up.fill"))
        add(["aws", "gcloud", "az", "flyctl", "fly", "vercel", "wrangler", "railway"], "cloud", "Cloud", 0x60A5FA, 0x2563EB, .symbol("cloud.fill"))

        // Remote and multiplexers.
        add(["ssh", "mosh", "mosh-client", "et", "autossh", "sshpass"], "ssh", "SSH", 0x475569, 0x1E293B, .symbol("globe"))
        add(["tmux"], "tmux", "tmux", 0x2BC048, 0x158A2C, .symbol("rectangle.split.3x1.fill"))
        add(["zellij"], "zellij", "Zellij", 0xF0B356, 0xC47F1A, ink: 0x1A1A1A, .symbol("rectangle.split.2x2.fill"))
        add(["screen"], "screen", "screen", 0x64748B, 0x334155, .symbol("rectangle.split.3x1.fill"))

        // Databases.
        add(["psql", "pgcli", "postgres"], "postgres", "PostgreSQL", 0x4A7FB0, 0x2F5C85, .symbol("cylinder.split.1x2.fill"))
        add(["mysql", "mycli", "mariadb"], "mysql", "MySQL", 0x1B91AB, 0x00617A, .symbol("cylinder.split.1x2.fill"))
        add(["sqlite3", "sqlite", "litecli", "duckdb"], "sqlite", "SQLite", 0x3A9AD9, 0x0F6AA8, .symbol("cylinder.fill"))
        add(["redis-cli", "redis-server", "valkey-cli"], "redis", "Redis", 0xE5483A, 0xA8231A, .symbol("cube.fill"))
        add(["mongosh", "mongo"], "mongo", "MongoDB", 0x58B65A, 0x2F7D32, .symbol("leaf.fill"))

        // Files, docs, logs.
        add(["yazi", "ranger", "lf", "nnn", "broot", "mc", "vifm", "xplr", "superfile", "spf"], "files", "Files", 0x6BB4F5, 0x2F7FD0, .symbol("folder.fill"))
        add(["man"], "man", "Manual", 0xB98A5A, 0x7A5530, .symbol("book.closed.fill"))
        add(["less", "more", "most", "bat", "glow", "mdcat"], "pager", "Reader", 0x9AA5B1, 0x5F6B78, .symbol("doc.text.fill"))
        add(["tail", "journalctl", "lnav", "stern", "multitail"], "logs", "Logs", 0x9AA5B1, 0x5F6B78, .symbol("list.bullet.rectangle.fill"))
        add(["watch", "entr", "watchexec", "nodemon"], "watch", "Watch", 0x2DD4BF, 0x0F766E, .symbol("eye.fill"))

        // Network and misc tools.
        add(["curl", "wget", "http", "https", "xh", "httpie", "aria2c"], "http", "HTTP", 0x38BDF8, 0x0369A1, .symbol("arrow.down.circle.fill"))
        add(["ping", "mtr", "traceroute", "nmap", "dig", "nc", "netcat", "trippy"], "net", "Network", 0x22D3EE, 0x0E7490, .symbol("antenna.radiowaves.left.and.right"))
        add(["brew"], "brew", "Homebrew", 0xFBB040, 0xD9822B, ink: 0x2B1A0A, .symbol("mug.fill"))
        add(["ffmpeg", "ffprobe", "yt-dlp", "mpv"], "media", "Media", 0x4ADE80, 0x15803D, .symbol("film.fill"))
        add(["sudo", "doas", "su"], "sudo", "sudo", 0xFBBF24, 0xD97706, ink: 0x1A1A1A, .symbol("lock.fill"))
        add(["fzf", "sk", "television", "tv"], "fzf", "Finder", 0x94A3B8, 0x475569, .symbol("magnifyingglass"))
        add(["rg", "grep", "ag", "ack", "fd", "find"], "search", "Search", 0x94A3B8, 0x475569, .symbol("text.magnifyingglass"))
        add(["openssl", "gpg", "age", "op", "pass"], "crypto", "Keys", 0xFACC15, 0xCA8A04, ink: 0x1A1A1A, .symbol("key.fill"))
        add(["ollama", "lms", "mlx_lm.generate"], "ollama", "Ollama", 0xFFFFFF, 0xE5E5E5, ink: 0x111111, .brand(asset: "ollama", template: true))
        add(["ngrok"], "ngrok", "ngrok", 0xE8ECF5, 0xC9D4EA, ink: 0x10239E, .brand(asset: "ngrok", template: true))
        return table
    }()
}
