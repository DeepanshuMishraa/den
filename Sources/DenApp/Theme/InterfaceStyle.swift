import AppKit
import SwiftUI

/// What sits behind the window's content: Liquid Glass, a frosted blur of
/// the desktop, or nothing. Terminal text colors always come from the theme.
enum InterfaceStyle: String, CaseIterable {
    /// Liquid Glass (NSGlassEffectView) tinted with the theme.
    case modern
    /// The theme's colors, fully opaque.
    case themed
    /// The desktop, blurred (NSVisualEffectView), under a see-through coat
    /// of the theme.
    case blended

    var title: String {
        switch self {
        case .modern: "Modern"
        case .themed: "Themed"
        case .blended: "Blended"
        }
    }

    /// What sits behind the SwiftUI content at the window level.
    enum Backdrop { case none, glass, blur }

    var backdrop: Backdrop {
        switch self {
        case .modern: .glass
        case .blended: .blur
        case .themed: .none
        }
    }
}

/// Islands (rounded cards with gaps) or one surface split by hairlines.
enum Density: String, CaseIterable {
    case comfortable, compact

    var title: String { self == .comfortable ? "Comfortable Density" : "Compact Density" }
    /// Space between panes and around the pane area.
    var gap: CGFloat { self == .comfortable ? 7 : 1 }
    var outerPadding: CGFloat { self == .comfortable ? 7 : 0 }
    var cornerRadius: CGFloat { self == .comfortable ? 11 : 0 }
}

/// The fills for one theme under one interface style.
struct Surfaces {
    let windowTop: Color
    let windowBottom: Color
    let card: AnyShapeStyle
    /// Fill behind dividers in compact density.
    let hairline: Color

    @MainActor
    init(theme: Theme, style: InterfaceStyle) {
        hairline = theme.separator
        switch style {
        case .themed:
            windowTop = theme.windowTop
            windowBottom = theme.windowBottom
            card = AnyShapeStyle(theme.cardGradient)
        case .modern:
            // The glass already carries the theme's tint (see
            // `glassTint`); the chrome adds only a little depth so the
            // glass's refraction and highlights read, and panes are just
            // dense enough to keep text legible over any wallpaper.
            windowTop = theme.windowTop.opacity(0.12)
            windowBottom = theme.windowBottom.opacity(0.2)
            card = AnyShapeStyle(theme.background.color.opacity(theme.isDark ? 0.5 : 0.55))
        case .blended:
            // A clearly see-through coat over the blurred desktop.
            windowTop = theme.windowTop.opacity(theme.isDark ? 0.5 : 0.45)
            windowBottom = theme.windowBottom.opacity(theme.isDark ? 0.58 : 0.52)
            card = AnyShapeStyle(theme.background.color.opacity(theme.isDark ? 0.6 : 0.62))
        }
    }
}
