import AppKit
import SwiftUI

/// A brand mark loaded from `Resources/ProgramIcons/<asset>.svg`.
/// `template` marks render in the given tint; full-color marks keep their
/// brand colors. Images are cached per asset.
struct BrandIcon: View {
    let asset: String
    let template: Bool
    let size: CGFloat
    var tint: Color = .white

    private static var cache: [String: NSImage] = [:]

    var body: some View {
        Group {
            if let image = Self.image(named: asset, template: template) {
                if template {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(tint)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
        }
        .frame(width: size, height: size)
    }

    static func image(named asset: String, template: Bool) -> NSImage? {
        if let hit = cache[asset] { return hit }
        guard let url = Bundle.module.url(
            forResource: asset, withExtension: "svg", subdirectory: "ProgramIcons"
        ) else {
            NSLog("Den: missing program icon %@", asset)
            return nil
        }
        guard let raw = NSImage(contentsOf: url) else {
            NSLog("Den: could not rasterize program icon %@", asset)
            return nil
        }
        raw.isTemplate = template
        cache[asset] = raw
        return raw
    }
}

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
        case .brand(let asset, let template):
            BrandIcon(asset: asset, template: template, size: size, tint: tint)
        }
    }
}

/// A program's favicon: a small glossy "screen" tile. Full-color brand marks
/// drop the tile and show raw, like a browser favicon.
struct ProgramTile: View {
    let kind: ProgramKind
    /// Tile height; width is 1.28× like a little display.
    var height: CGFloat = 16

    /// Full-color brands skip the tinted tile.
    private var isRawBrand: Bool {
        if case .brand(_, template: false) = kind.glyph { return true }
        return false
    }

    var body: some View {
        if isRawBrand {
            BrandIcon(asset: brandAsset, template: false, size: height * 1.02)
                .frame(width: height * 1.28, height: height)
                .shadow(color: .black.opacity(0.28), radius: 0.8, y: 0.6)
        } else {
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

    private var brandAsset: String {
        if case .brand(let asset, _) = kind.glyph { return asset }
        return ""
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
