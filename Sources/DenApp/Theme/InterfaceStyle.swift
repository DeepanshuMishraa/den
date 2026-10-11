import AppKit
import SwiftUI

/// How much of the window the theme paints, from full Liquid Glass to solid
/// system colors. Terminal text colors always come from the theme.
enum InterfaceStyle: String, CaseIterable {
    /// Liquid Glass: the desktop shows through window and panes.
    case modern
    /// Solid macOS window and text-background colors.
    case system
    /// The theme tints everything, fully opaque.
    case themed
    /// The theme's colors over a subtle glass backdrop.
    case blended

    var title: String {
        switch self {
        case .modern: "Modern"
        case .system: "System"
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
        case .system, .themed: .none
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
        case .system:
            let window = Color(nsColor: .windowBackgroundColor)
            windowTop = window
            windowBottom = window
            card = AnyShapeStyle(Color(nsColor: .textBackgroundColor))
        case .modern:
            // Most see-through: the desktop's hue reads clearly, but the
            // theme color keeps chrome and text contrast intact.
            windowTop = theme.windowTop.opacity(theme.isDark ? 0.5 : 0.45)
            windowBottom = theme.windowBottom.opacity(theme.isDark ? 0.58 : 0.5)
            card = AnyShapeStyle(theme.background.color.opacity(theme.isDark ? 0.62 : 0.6))
        case .blended:
            // Mostly theme, with just a hint of the desktop.
            windowTop = theme.windowTop.opacity(0.82)
            windowBottom = theme.windowBottom.opacity(0.88)
            card = AnyShapeStyle(theme.background.color.opacity(0.9))
        }
    }
}
