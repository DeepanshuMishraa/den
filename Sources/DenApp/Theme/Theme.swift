import AppKit
import DenVT
import SwiftUI

enum Appearance: String, Sendable {
    case light, dark
}

/// A Den theme tints the terminal palette and the whole app chrome.
struct Theme: Identifiable, Equatable, Sendable {
    let name: String
    let appearance: Appearance
    let background: RGB
    let foreground: RGB
    let cursor: RGB
    let selection: RGB
    /// The 16 ANSI colors; the 256-color cube is derived.
    let ansi: [RGB]
    /// Accent used for highlights, focus and selection in menus.
    let accentRGB: RGB
    /// Text color inside the selection; nil keeps each cell's own color.
    var selectionForeground: RGB? = nil
    /// Imported themes are user files and can be deleted.
    var isCustom = false
    /// The file a custom theme was loaded from, for deleting it.
    var fileURL: URL? = nil

    var id: String { name }
    var isDark: Bool { appearance == .dark }

    var palette: [RGB] {
        var p = ansi
        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        for r in levels { for g in levels { for b in levels { p.append(RGB(r, g, b)) } } }
        for i in 0 ..< 24 {
            let v = UInt8(8 + i * 10)
            p.append(RGB(v, v, v))
        }
        return p
    }

    // MARK: Chrome

    /// Window chrome behind the cards: deeper than the terminal in dark
    /// themes, a soft accent-tinted wash in light themes.
    /// Light themes get Den's pastel wash: a pink-ish top easing into a warm
    /// bottom, both derived from the theme's accent so each theme differs.
    /// Dark chrome sits about 18% below the terminal, as measured across
    /// seven themes in Superlogical's Themed style.
    var windowTop: Color {
        isDark ? background.mixed(with: accentRGB, 0.06).darkened(0.18).color
            : background.mixed(with: pastel(accentRGB.rotated(100)), 0.55).color
    }

    var windowBottom: Color {
        isDark ? background.mixed(with: accentRGB, 0.10).darkened(0.28).color
            : background.mixed(with: pastel(accentRGB.rotated(190)), 0.6).color
    }

    private func pastel(_ c: RGB) -> RGB {
        let lab = OKLab(c)
        return OKLab(l: 0.9, c: min(lab.chroma, 0.06), h: lab.hue).rgb
    }

    /// Card fill: a gentle diagonal gradient around the terminal background.
    var cardGradient: LinearGradient {
        LinearGradient(
            colors: isDark
                ? [background.mixed(with: accentRGB, 0.07).lightened(0.035).color, background.darkened(0.06).color]
                : [background.lightened(0.6).color, background.mixed(with: pastel(accentRGB.rotated(190)), 0.35).color],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var card: Color { background.color }
    var cardBorder: Color { isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.07) }
    var cardHighlight: Color { isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.9) }
    var focusedBorder: Color { isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.13) }
    var chromeText: Color { foreground.color.opacity(0.94) }
    var secondaryText: Color { foreground.color.opacity(0.62) }
    var tertiaryText: Color { foreground.color.opacity(0.38) }
    var activeTab: Color { isDark ? Color.white.opacity(0.10) : Color.white.opacity(0.92) }
    var activeTabBorder: Color { isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.06) }
    var hover: Color { isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.045) }
    var separator: Color { isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.12) }
    var accent: Color { accentRGB.color }
    /// Text drawn on top of `accent`.
    var onAccent: Color { accentRGB.luminance > 0.45 ? .black : .white }
    /// Popover/menu surfaces (palette, session menu, tooltips).
    var menuFill: Color {
        isDark ? background.darkened(0.25).color.opacity(0.92) : Color.white.opacity(0.94)
    }
    var menuBorder: Color { isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10) }
    var nsAppearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }
    /// Tint for Modern's Liquid Glass: the theme's background, strong
    /// enough that dark themes don't turn milky grey.
    var glassTint: NSColor { background.nsColor.withAlphaComponent(isDark ? 0.6 : 0.45) }
}

extension RGB {
    var color: Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }

    init(hex: UInt32) {
        self.init(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
    }

    /// Parses `#rrggbb` or `rrggbb`.
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }

    func mixed(with other: RGB, _ t: Double) -> RGB {
        func m(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8(clamping: Int((Double(a) * (1 - t) + Double(b) * t).rounded())) }
        return RGB(m(r, other.r), m(g, other.g), m(b, other.b))
    }

    func darkened(_ t: Double) -> RGB { mixed(with: RGB(0, 0, 0), t) }
    func lightened(_ t: Double) -> RGB { mixed(with: RGB(255, 255, 255), t) }

    func rotated(_ degrees: Double) -> RGB {
        let lab = OKLab(self)
        return OKLab(l: lab.l, c: lab.chroma, h: lab.hue + degrees).rgb
    }
}

extension Theme {
    /// A theme from its published terminal palette, colors taken verbatim.
    /// Light or dark follows the background. The accent defaults to the
    /// palette's blue.
    init(published name: String, background: UInt32, foreground: UInt32, cursor: UInt32, selection: UInt32,
         ansi: [UInt32], selectionForeground: UInt32? = nil, accent: UInt32? = nil) {
        let bg = RGB(hex: background)
        let palette = ansi.map(RGB.init(hex:))
        self.init(
            name: name,
            appearance: bg.luminance < 0.2 ? .dark : .light,
            background: bg,
            foreground: RGB(hex: foreground),
            cursor: RGB(hex: cursor),
            selection: RGB(hex: selection),
            ansi: palette,
            accentRGB: accent.map(RGB.init(hex:)) ?? palette[4],
            selectionForeground: selectionForeground.map(RGB.init(hex:))
        )
    }

    /// Generates a full theme from a compact spec. ANSI hues are placed in
    /// OKLCH so every theme gets evenly weighted, legible colors.
    static func generate(_ spec: ThemeSpec) -> Theme {
        let dark = spec.appearance == .dark
        let bg = RGB(hex: spec.background)
        let fg = RGB(hex: spec.foreground)
        let c = 0.13 * spec.chroma
        let base: [(name: String, hue: Double)] = [
            ("red", 25), ("green", 145), ("yellow", 88), ("blue", 255), ("magenta", 330), ("cyan", 195),
        ]
        func color(_ hue: Double, bright: Bool) -> RGB {
            let isYellow = hue == 88
            let l: Double = dark
                ? (bright ? 0.84 : 0.75)
                : (isYellow ? (bright ? 0.62 : 0.56) : (bright ? 0.58 : 0.50))
            return OKLab(l: l, c: c + (bright ? 0.015 : 0), h: hue + spec.hueShift).rgb
        }
        let normals = base.map { color($0.hue, bright: false) }
        let brights = base.map { color($0.hue, bright: true) }
        let black: RGB, white: RGB, brightBlack: RGB, brightWhite: RGB
        if dark {
            black = bg.lightened(0.10)
            white = fg.darkened(0.12)
            brightBlack = bg.lightened(0.32)
            brightWhite = fg.lightened(0.4)
        } else {
            black = fg
            white = bg.darkened(0.22)
            brightBlack = fg.lightened(0.38)
            brightWhite = bg.darkened(0.08)
        }
        let ansi = [black] + normals + [white, brightBlack] + brights + [brightWhite]
        let accent = OKLab(l: dark ? 0.72 : 0.56, c: 0.13 * max(spec.chroma, 0.7), h: spec.accentHue).rgb
        return Theme(
            name: spec.name,
            appearance: spec.appearance,
            background: bg,
            foreground: fg,
            cursor: accent,
            selection: bg.mixed(with: accent, dark ? 0.32 : 0.22),
            ansi: ansi,
            accentRGB: accent
        )
    }
}

struct ThemeSpec {
    let name: String
    let appearance: Appearance
    let background: UInt32
    let foreground: UInt32
    let accentHue: Double
    var hueShift: Double = 0
    var chroma: Double = 1
}
