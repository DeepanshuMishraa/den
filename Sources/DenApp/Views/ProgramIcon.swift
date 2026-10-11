import SwiftUI

/// A program's mark, drawn at a given size.
struct ProgramGlyph: View {
    let kind: ProgramKind
    let size: CGFloat
    /// Overrides the program's ink, e.g. monochrome in pane headers.
    var color: Color?

    var body: some View {
        let tint = color ?? kind.ink
        switch kind.glyph {
        case .prompt:
            Text(">_")
                .font(.system(size: size * 0.82, weight: .bold, design: .monospaced))
                .kerning(-size * 0.08)
                .foregroundStyle(tint)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.76, weight: .semibold))
                .foregroundStyle(tint)
        case .monogram(let letters):
            Text(letters)
                .font(.system(size: size * (letters.count > 2 ? 0.58 : letters.count == 2 ? 0.72 : 0.9), weight: .heavy, design: .rounded))
                .kerning(-size * 0.04)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(tint)
        case .starburst:
            Starburst(rays: 12)
                .fill(tint)
                .frame(width: size, height: size)
        case .knot:
            Knot()
                .stroke(tint, lineWidth: size * 0.13)
                .frame(width: size * 0.95, height: size * 0.95)
        case .sparkle:
            Sparkle()
                .fill(tint)
                .frame(width: size * 0.95, height: size * 0.95)
        case .bun:
            BunFace(ink: tint)
                .frame(width: size * 1.05, height: size * 0.9)
        }
    }
}

/// Gemini's mark: a four-point star with concave sides.
struct Sparkle: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2, ry = rect.height / 2
        let tips = [CGPoint(x: c.x, y: c.y - ry), CGPoint(x: c.x + rx, y: c.y), CGPoint(x: c.x, y: c.y + ry), CGPoint(x: c.x - rx, y: c.y)]
        var p = Path()
        p.move(to: tips[0])
        for i in 1 ... 4 {
            // Each side bows in toward the center.
            p.addQuadCurve(to: tips[i % 4], control: c)
        }
        p.closeSubpath()
        return p
    }
}

/// Bun's bun: a soft dome with two eyes and a smile.
struct BunFace: View {
    let ink: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Ellipse()
                    .fill(Color(.sRGB, red: 0.98, green: 0.88, blue: 0.70))
                    .overlay(Ellipse().strokeBorder(ink, lineWidth: max(w * 0.08, 0.8)))
                    .frame(width: w, height: h * 0.86)
                    .offset(y: h * 0.07)
                HStack(spacing: w * 0.22) {
                    Circle().fill(ink).frame(width: w * 0.14)
                    Circle().fill(ink).frame(width: w * 0.14)
                }
                .offset(y: h * 0.04)
                Capsule().fill(Color(.sRGB, red: 0.95, green: 0.42, blue: 0.42))
                    .frame(width: w * 0.2, height: h * 0.1)
                    .offset(y: h * 0.24)
            }
            .frame(width: w, height: h)
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
        // Chunky rounded rays, alternating long and short, so the mark
        // still reads at favicon size.
        let thickness = outer * 0.24
        for i in 0 ..< rays {
            let angle = Double(i) / Double(rays) * 2 * .pi
            let length = outer * (i % 2 == 0 ? 1 : 0.74)
            let ray = Path(roundedRect: CGRect(x: -thickness / 2, y: -length, width: thickness, height: length), cornerRadius: thickness / 2)
            p.addPath(ray, transform: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle))
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
        let top = kind.tileTop, bottom = kind.tileBottom
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
                .offset(x: kind.glyph == .prompt ? -height * 0.08 : 0)
        }
        .frame(width: width, height: height)
        .background(shape.fill(.black.opacity(0.45)).padding(-0.5))
        .shadow(color: .black.opacity(0.28), radius: 0.8, y: 0.6)
    }
}

/// Den's "Deck" icon: the focused program's tile in front, the tab's other
/// panes as cards fanned out behind it. A single-pane tab is a single tile.
struct DeckIcon: View {
    let deck: [ProgramKind]
    var height: CGFloat = 16
    var badge = false

    var body: some View {
        let front = deck.first ?? .shell
        let behind = Array(deck.dropFirst().prefix(2))
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
