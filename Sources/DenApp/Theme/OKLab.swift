import Foundation
import DenVT

/// Perceptual color space used for theme generation and contrast correction.
struct OKLab: Equatable {
    var l: Double
    var a: Double
    var b: Double

    init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// Builds a color from lightness, chroma and hue in degrees (OKLCH).
    init(l: Double, c: Double, h: Double) {
        let rad = h * .pi / 180
        self.init(l: l, a: c * cos(rad), b: c * sin(rad))
    }

    var chroma: Double { (a * a + b * b).squareRoot() }
    var hue: Double {
        let h = atan2(b, a) * 180 / .pi
        return h < 0 ? h + 360 : h
    }

    init(_ rgb: RGB) {
        func lin(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = lin(rgb.r), g = lin(rgb.g), bl = lin(rgb.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        self.init(
            l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    /// Converts to sRGB, reducing chroma until the color is in gamut.
    var rgb: RGB {
        var c = self
        for _ in 0 ..< 24 {
            if let v = c.rawRGB() { return v }
            c.a *= 0.9
            c.b *= 0.9
        }
        return c.rawRGB(clamp: true) ?? RGB(0, 0, 0)
    }

    private func rawRGB(clamp: Bool = false) -> RGB? {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        let eps = 0.0005
        if !clamp, [r, g, bl].contains(where: { $0 < -eps || $0 > 1 + eps }) { return nil }
        func enc(_ v: Double) -> UInt8 {
            let c = min(max(v, 0), 1)
            let s = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            return UInt8((s * 255).rounded())
        }
        return RGB(enc(r), enc(g), enc(bl))
    }
}

extension RGB {
    /// WCAG relative luminance.
    var luminance: Double {
        func ch(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)
    }

    func contrast(with other: RGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Automatic Contrast Correction: nudges a foreground that is illegible on
/// its background toward the theme's foreground hue and away from the
/// background's lightness until it meets WCAG AA (4.5:1).
enum ContrastCorrection {
    static let target = 4.5

    static func correct(_ fg: RGB, on bg: RGB, themeForeground: RGB) -> RGB {
        guard fg.contrast(with: bg) < target else { return fg }
        let lab = OKLab(fg)
        let bgLab = OKLab(bg)
        let anchor = OKLab(themeForeground)
        let goLighter = bgLab.l < 0.6
        var best = fg
        // Rotate the hue a little toward the theme so corrected colors stay
        // harmonious, then walk lightness until the contrast target is met.
        let hueBlend = 0.25
        let a = lab.a * (1 - hueBlend) + anchor.a * hueBlend
        let b = lab.b * (1 - hueBlend) + anchor.b * hueBlend
        var l = lab.l
        for _ in 0 ..< 40 {
            l += goLighter ? 0.025 : -0.025
            l = min(max(l, 0), 1)
            let candidate = OKLab(l: l, a: a, b: b).rgb
            best = candidate
            if candidate.contrast(with: bg) >= target { return candidate }
            if l == 0 || l == 1 { break }
        }
        return best
    }
}
