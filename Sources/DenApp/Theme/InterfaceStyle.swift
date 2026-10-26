import AppKit
import SwiftUI

/// How the chrome and panes are drawn. Rex's current model has two surface
/// styles; the theme tint decides whether they carry the theme's colors or
/// macOS's neutral surfaces. Together they reproduce Rex's four older
/// materials: Glass untinted is Modern, Glass tinted is Blend Theme,
/// Classic untinted is System, and Classic tinted is Use Theme.
enum InterfaceStyle: String, CaseIterable, Sendable {
    /// Liquid Glass (NSGlassEffectView) behind the window's content.
    case glass
    /// Opaque surfaces: the native window background or the theme's colors.
    case classic

    var title: String {
        switch self {
        case .glass: "Glass"
        case .classic: "Classic"
        }
    }

    /// Reads a stored style, including Rex's four retired styles and the
    /// two Den used before them.
    init?(stored raw: String) {
        switch raw {
        case "glass", "modern", "blendTheme", "blended": self = .glass
        case "classic", "system", "useTheme", "themed": self = .classic
        default: return nil
        }
    }

    /// The theme tint a retired stored value implied. Nil when the value is
    /// already one of the two current styles, or unknown.
    static func storedThemeTint(_ raw: String) -> Bool? {
        switch raw {
        case "modern", "system": false
        case "useTheme", "blendTheme", "themed", "blended": true
        default: nil
        }
    }

    /// What sits behind the SwiftUI content at the window level.
    enum Backdrop: Equatable { case none, glass, system }

    func backdrop(themeTint: Bool) -> Backdrop {
        switch self {
        case .glass: .glass
        // Untinted Classic is the native window; tinted Classic paints the
        // window itself, so nothing sits behind it.
        case .classic: themeTint ? .none : .system
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
    init(theme: Theme, style: InterfaceStyle, themeTint: Bool) {
        var hairlineColor = theme.separator
        var top: Color
        var bottom: Color
        var cardFill: AnyShapeStyle

        switch (style, themeTint) {
        case (.classic, true):
            // The theme's colors, fully opaque.
            top = theme.windowTop
            bottom = theme.windowBottom
            cardFill = AnyShapeStyle(theme.cardGradient)
        case (.classic, false):
            // The native macOS window background, with neutral panes.
            top = .clear
            bottom = .clear
            cardFill = AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
            hairlineColor = Color(nsColor: .separatorColor)
        case (.glass, true):
            // A clearly see-through coat of the theme over the glass.
            top = theme.windowTop.opacity(theme.isDark ? 0.5 : 0.45)
            bottom = theme.windowBottom.opacity(theme.isDark ? 0.58 : 0.52)
            cardFill = AnyShapeStyle(theme.background.color.opacity(theme.isDark ? 0.6 : 0.62))
        case (.glass, false):
            // The glass carries the material; neutral panes keep text
            // legible without pulling the theme into the interface.
            top = .clear
            bottom = .clear
            cardFill = AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(theme.isDark ? 0.55 : 0.62))
            hairlineColor = Color(nsColor: .separatorColor)
        }

        windowTop = top
        windowBottom = bottom
        card = cardFill
        hairline = hairlineColor
    }
}
