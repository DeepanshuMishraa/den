import SwiftUI

/// What a pane is running; picks its favicon and header glyph.
enum ProgramKind: Equatable {
    case shell, claude, codex, node, bun, python, editor, git, monitor, ssh, docker, generic

    static func detect(process: String?, title: String?) -> ProgramKind {
        let p = (process ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let t = (title ?? "").lowercased()
        if p == "claude" || t.contains("claude code") || t.hasPrefix("✳") { return .claude }
        if p == "codex" || t.hasPrefix("codex") { return .codex }
        switch p {
        case "fish", "zsh", "bash", "sh", "nu", "elvish", "xonsh", "login", "": return .shell
        case "node", "npm", "pnpm", "yarn", "npx", "deno", "vite", "next-server": return .node
        case "bun", "bunx": return .bun
        case "python", "python3", "ipython", "uv", "pip": return .python
        case "nvim", "vim", "vi", "hx", "helix", "emacs", "nano", "micro", "kak": return .editor
        case "git", "lazygit", "lg", "tig", "gitui", "jj", "jjui": return .git
        case "top", "htop", "btop", "btm", "glances", "nvtop", "bottom": return .monitor
        case "ssh", "mosh", "mosh-client", "et": return .ssh
        case "docker", "lazydocker", "k9s", "kubectl": return .docker
        default: return .generic
        }
    }

    /// Tile gradient, top to bottom.
    var tile: (Color, Color) {
        switch self {
        case .shell: (hex(0x45494F), hex(0x1D1F22))
        case .generic: (hex(0x5A5F68), hex(0x2B2E33))
        case .claude: (hex(0xEC8A6A), hex(0xD25B3D))
        case .codex: (hex(0xFFFFFF), hex(0xE3E4E8))
        case .node: (hex(0x7BCB55), hex(0x3F8B33))
        case .bun: (hex(0xFCF1DC), hex(0xEBD2A6))
        case .python: (hex(0x5B95C9), hex(0x2F5E8F))
        case .editor: (hex(0x5BB86E), hex(0x2A6E45))
        case .git: (hex(0xF4805A), hex(0xC74B2C))
        case .monitor: (hex(0x5D93F5), hex(0x2D5CC9))
        case .ssh: (hex(0x9787F7), hex(0x5A48D2))
        case .docker: (hex(0x48A9F2), hex(0x1E6EC0))
        }
    }

    var glyphColor: Color {
        switch self {
        case .shell, .generic: hex(0x5EE38C)
        case .codex: .black
        case .bun: hex(0x5A4127)
        default: .white
        }
    }

    /// Monochrome symbol used in pane headers and on tiles.
    var symbol: String? {
        switch self {
        case .shell, .generic, .claude, .codex: nil
        case .node: "hexagon"
        case .bun: "circle.circle"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .editor: "pencil.line"
        case .git: "arrow.triangle.branch"
        case .monitor: "gauge.with.dots.needle.67percent"
        case .ssh: "globe"
        case .docker: "shippingbox"
        }
    }
}

private func hex(_ v: UInt32) -> Color {
    Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

/// The glyph for a program, drawn at a given size.
struct ProgramGlyph: View {
    let kind: ProgramKind
    let size: CGFloat
    var color: Color?

    var body: some View {
        let tint = color ?? kind.glyphColor
        switch kind {
        case .shell, .generic:
            Text(">_")
                .font(.system(size: size * 0.82, weight: .bold, design: .monospaced))
                .kerning(-size * 0.08)
                .foregroundStyle(tint)
        case .claude:
            Starburst(rays: 12)
                .fill(tint)
                .frame(width: size, height: size)
        case .codex:
            Knot()
                .stroke(tint, lineWidth: size * 0.13)
                .frame(width: size * 0.95, height: size * 0.95)
        default:
            Image(systemName: kind.symbol ?? "terminal")
                .font(.system(size: size * 0.78, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

/// Claude's sparkle: tapered rays around a center.
struct Starburst: Shape {
    let rays: Int

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        var p = Path()
        for i in 0 ..< rays {
            let a = Double(i) / Double(rays) * 2 * .pi
            let len = outer * (i % 2 == 0 ? 1 : 0.78)
            let w = 0.17
            let tip = CGPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len)
            let l = CGPoint(x: c.x + cos(a - w) * outer * 0.2, y: c.y + sin(a - w) * outer * 0.2)
            let r = CGPoint(x: c.x + cos(a + w) * outer * 0.2, y: c.y + sin(a + w) * outer * 0.2)
            p.move(to: c)
            p.addLine(to: l)
            p.addLine(to: tip)
            p.addLine(to: r)
            p.closeSubpath()
        }
        return p
    }
}

/// A loose interlocking knot, in the spirit of OpenAI's mark.
struct Knot: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        for i in 0 ..< 3 {
            let angle = Double(i) * .pi / 3
            let capsule = Path(roundedRect: CGRect(x: -r * 0.36, y: -r * 0.95, width: r * 0.72, height: r * 1.9), cornerRadius: r * 0.36)
            p.addPath(capsule, transform: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle))
        }
        return p
    }
}

/// A program's favicon: a small glossy "screen" tile.
struct ProgramTile: View {
    let kind: ProgramKind
    /// Tile height; width is 1.28× like a little display.
    var height: CGFloat = 16

    var body: some View {
        let (top, bottom) = kind.tile
        let width = height * 1.28
        let shape = RoundedRectangle(cornerRadius: height * 0.26, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            // Glass: a soft sheen on the upper half and a crisp top edge.
            shape
                .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)], startPoint: .top, endPoint: .center))
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                lineWidth: 0.6
            )
            ProgramGlyph(kind: kind, size: height * 0.62)
                .offset(x: kind == .shell || kind == .generic ? -height * 0.08 : 0)
        }
        .frame(width: width, height: height)
        .background(shape.fill(.black.opacity(0.45)).padding(-0.5))
        .shadow(color: .black.opacity(0.28), radius: 0.8, y: 0.6)
    }
}

/// Den's "Deck" icon: the focused program's tile in front, the tab's other
/// panes as cards fanned out behind it. A single-pane tab still shows one
/// card behind, like a deck.
struct DeckIcon: View {
    let deck: [ProgramKind]
    var height: CGFloat = 16
    var badge = false

    var body: some View {
        let front = deck.first ?? .shell
        let behind = deck.count > 1 ? Array(deck.dropFirst().prefix(2)) : [front]
        let step = height * 0.2
        ZStack(alignment: .leading) {
            ForEach(Array(behind.enumerated().reversed()), id: \.offset) { index, kind in
                ProgramTile(kind: kind, height: height)
                    .scaleEffect(1 - 0.1 * CGFloat(index + 1), anchor: .trailing)
                    .brightness(-0.12 * Double(index + 1))
                    .offset(x: step * CGFloat(index + 1))
            }
            ProgramTile(kind: front, height: height)
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle()
                            .fill(Color(.sRGB, red: 0.25, green: 0.55, blue: 1, opacity: 1))
                            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                            .frame(width: height * 0.42, height: height * 0.42)
                            .offset(x: height * 0.16, y: -height * 0.16)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        }
        .frame(width: height * 1.28 + step * CGFloat(behind.count), height: height, alignment: .leading)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: badge)
    }
}
