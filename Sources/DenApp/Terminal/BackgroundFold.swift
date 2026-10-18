import DenVT

/// Folds the backgrounds an app paints into Den's card, so full-screen apps
/// read as drawn on the terminal rather than as a flat sheet laid over it.
///
/// Two steps:
/// - Canvas: an app that floods the grid (or sets OSC 11) has a canvas. One
///   in the theme's own register (dark on dark, light on light, near
///   neutral) is treated as the card itself, and the app's other backgrounds
///   shift with it so panels keep their relation to it. Any other canvas
///   fills the whole pane, padding included, instead of an inset rectangle.
/// - Layering: every remaining background becomes a translucent layer that
///   over the flat base reproduces the color exactly ("color to alpha"), so
///   the card's gradient and any window blur carry through it.
struct BackgroundFold {
    enum Canvas: Equatable {
        /// The app draws on the terminal's background.
        case none
        /// Drawn as the card; the app's backgrounds shift by its offset.
        case folded(RGB)
        /// Kept as the app's own color, filling the whole pane.
        case filled(RGB)
    }

    let theme: RGB
    let canvas: Canvas

    /// Share of the grid one background must cover to count as a canvas.
    static let canvasCoverage = 0.35
    /// How far a canvas's hue and chroma may sit from the theme's (OKLab
    /// a/b distance) and still fold: wide enough for any neutral dark or
    /// light canvas, too narrow to swallow a deliberately colored one.
    static let canvasTint = 0.08
    /// Differences below this are invisible; such cells draw nothing.
    static let invisible = 0.012

    private let shift: (l: Double, a: Double, b: Double)

    /// - Parameters:
    ///   - theme: the theme background behind the grid.
    ///   - defaultBackground: the terminal's default background (OSC 11).
    ///   - coverage: cells each explicit background covers this frame.
    ///   - cellCount: cells in the grid.
    init(theme: RGB, defaultBackground: RGB, coverage: [RGB: Int], cellCount: Int) {
        self.theme = theme
        let candidate: RGB? = if defaultBackground != theme {
            defaultBackground
        } else if let top = coverage.max(by: { $0.value < $1.value }),
                  Double(top.value) >= Double(max(cellCount, 1)) * Self.canvasCoverage {
            top.key
        } else {
            nil
        }
        guard let candidate else {
            canvas = .none
            shift = (0, 0, 0)
            return
        }
        let from = OKLab(candidate), to = OKLab(theme)
        let sameRegister = (from.l < 0.6) == (to.l < 0.6)
        let tint = ((from.a - to.a) * (from.a - to.a) + (from.b - to.b) * (from.b - to.b)).squareRoot()
        if sameRegister, tint <= Self.canvasTint {
            canvas = .folded(candidate)
            shift = (to.l - from.l, to.a - from.a, to.b - from.b)
        } else {
            canvas = .filled(candidate)
            shift = (0, 0, 0)
        }
    }

    /// What cell layers are composited over.
    var base: RGB {
        if case let .filled(color) = canvas { color } else { theme }
    }

    /// The pane's clear color, premultiplied: a filled canvas as a layer over
    /// the card. Nil leaves the view transparent.
    var clear: SIMD4<Float>? {
        guard case let .filled(color) = canvas, let layer = Self.colorToAlpha(color, over: theme) else { return nil }
        return SIMD4(layer.x * layer.w, layer.y * layer.w, layer.z * layer.w, layer.w)
    }

    /// The fill to draw for an app background, premultiplication left to the
    /// shader; nil when it matches what's beneath and nothing should be drawn.
    func layer(_ color: RGB) -> SIMD4<Float>? {
        let target = rebased(color)
        guard Self.distance(target, base) >= Self.invisible else { return nil }
        return Self.colorToAlpha(target, over: base)
    }

    /// The color moved by a folded canvas's offset from the theme.
    func rebased(_ color: RGB) -> RGB {
        guard case .folded = canvas else { return color }
        let lab = OKLab(color)
        return OKLab(l: lab.l + shift.l, a: lab.a + shift.a, b: lab.b + shift.b).rgb
    }

    /// The most transparent color that, blended over `base`, gives `target`:
    /// alpha is the least that keeps every channel in range.
    static func colorToAlpha(_ target: RGB, over base: RGB) -> SIMD4<Float>? {
        let t = target.simd(), b = base.simd()
        var alpha: Float = 0
        for i in 0 ..< 3 {
            let need = t[i] > b[i] ? (t[i] - b[i]) / max(1 - b[i], 1e-6)
                : t[i] < b[i] ? (b[i] - t[i]) / max(b[i], 1e-6)
                : 0
            alpha = max(alpha, need)
        }
        guard alpha >= 1 / 255 else { return nil }
        alpha = min(alpha, 1)
        let c = b + (t - b) / alpha
        return SIMD4(min(max(c.x, 0), 1), min(max(c.y, 0), 1), min(max(c.z, 0), 1), alpha)
    }

    static func distance(_ x: RGB, _ y: RGB) -> Double {
        let p = OKLab(x), q = OKLab(y)
        let dl = p.l - q.l, da = p.a - q.a, db = p.b - q.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}
