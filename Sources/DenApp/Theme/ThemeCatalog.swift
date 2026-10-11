import Foundation

/// Den's 41 built-in themes: 27 dark and 14 light.
enum ThemeCatalog {
    static let dark: [Theme] = [
        ThemeSpec(name: "Abyssal Trench", appearance: .dark, background: 0x0B1622, foreground: 0xC9D7E3, accentHue: 230, hueShift: -5),
        ThemeSpec(name: "Basalt Shore", appearance: .dark, background: 0x1C1F21, foreground: 0xD4D2CC, accentHue: 200, chroma: 0.8),
        ThemeSpec(name: "Cathode Amber", appearance: .dark, background: 0x17120A, foreground: 0xF2C77A, accentHue: 75, hueShift: 8, chroma: 1.1),
        ThemeSpec(name: "Charcoal Atelier", appearance: .dark, background: 0x1F1E1D, foreground: 0xE2DCD2, accentHue: 40, chroma: 0.85),
        ThemeSpec(name: "Cinder Peak", appearance: .dark, background: 0x1E1514, foreground: 0xE8D6CF, accentHue: 28),
        ThemeSpec(name: "Cobalt Foundry", appearance: .dark, background: 0x0F1A33, foreground: 0xD2DCF2, accentHue: 252, chroma: 1.1),
        ThemeSpec(name: "Ember Hollow", appearance: .dark, background: 0x1F1311, foreground: 0xF1D9CB, accentHue: 38, chroma: 1.15),
        ThemeSpec(name: "Heliotrope Haze", appearance: .dark, background: 0x1E1726, foreground: 0xE4D8F0, accentHue: 300),
        ThemeSpec(name: "Ink Meridian", appearance: .dark, background: 0x111520, foreground: 0xD5D9E6, accentHue: 240, chroma: 0.9),
        ThemeSpec(name: "Juniper Smoke", appearance: .dark, background: 0x141C19, foreground: 0xD3DED7, accentHue: 160, chroma: 0.85),
        ThemeSpec(name: "Merino Dark", appearance: .dark, background: 0x1A1D1F, foreground: 0xD9D6CF, accentHue: 245),
        ThemeSpec(name: "Midnight Tundra", appearance: .dark, background: 0x0E2A33, foreground: 0xD3E4E6, accentHue: 182),
        ThemeSpec(name: "Misty Forest", appearance: .dark, background: 0x16201B, foreground: 0xD0DDD3, accentHue: 150, chroma: 0.8),
        ThemeSpec(name: "Moss Cathedral", appearance: .dark, background: 0x172019, foreground: 0xDAE3D2, accentHue: 132),
        ThemeSpec(name: "Neon Arcade", appearance: .dark, background: 0x120E1F, foreground: 0xF0E6FF, accentHue: 322, chroma: 1.4),
        ThemeSpec(name: "Nocturne Rose", appearance: .dark, background: 0x1F1418, foreground: 0xF0DCE2, accentHue: 352),
        ThemeSpec(name: "Oxblood Library", appearance: .dark, background: 0x1E1012, foreground: 0xEAD7D2, accentHue: 18, chroma: 1.05),
        ThemeSpec(name: "Petrol Lagoon", appearance: .dark, background: 0x0D2226, foreground: 0xCFE5E5, accentHue: 198),
        ThemeSpec(name: "Phosphor Archive", appearance: .dark, background: 0x0C140C, foreground: 0xB9F2B0, accentHue: 140, chroma: 1.2),
        ThemeSpec(name: "Polar Aurora", appearance: .dark, background: 0x101826, foreground: 0xDCE8F2, accentHue: 170, chroma: 1.1),
        ThemeSpec(name: "Roasted Umber", appearance: .dark, background: 0x1F1913, foreground: 0xE8DCCB, accentHue: 55),
        ThemeSpec(name: "Saffron Nightfall", appearance: .dark, background: 0x1A1610, foreground: 0xF2E4C4, accentHue: 80),
        ThemeSpec(name: "Silver Point Dark", appearance: .dark, background: 0x1B1C1E, foreground: 0xE4E5E7, accentHue: 232, chroma: 0.6),
        ThemeSpec(name: "Sonoran Dusk", appearance: .dark, background: 0x22171A, foreground: 0xF2DDD0, accentHue: 32),
        ThemeSpec(name: "Static Noir", appearance: .dark, background: 0x101010, foreground: 0xE6E6E6, accentHue: 250, chroma: 0.35),
        ThemeSpec(name: "Velvet Dusk", appearance: .dark, background: 0x1C1A2B, foreground: 0xDCD7EE, accentHue: 285),
        ThemeSpec(name: "Whitby Bay", appearance: .dark, background: 0x121A1F, foreground: 0xD7E1E6, accentHue: 212),
    ].map(Theme.generate)

    static let light: [Theme] = [
        ThemeSpec(name: "Merino Light", appearance: .light, background: 0xFBFAF7, foreground: 0x2B2A28, accentHue: 255),
        ThemeSpec(name: "Alpine Milk", appearance: .light, background: 0xF7F9FA, foreground: 0x26313A, accentHue: 222),
        ThemeSpec(name: "Buttercream Diner", appearance: .light, background: 0xFBF4E2, foreground: 0x3A3024, accentHue: 25),
        ThemeSpec(name: "Coastal Linen", appearance: .light, background: 0xF4F1EA, foreground: 0x2C3A42, accentHue: 212),
        ThemeSpec(name: "Glacier Mint", appearance: .light, background: 0xEFF7F4, foreground: 0x22362F, accentHue: 165),
        ThemeSpec(name: "Ivory Gallery", appearance: .light, background: 0xFAF8F2, foreground: 0x2E2C29, accentHue: 40, chroma: 0.7),
        ThemeSpec(name: "Lavender Postcard", appearance: .light, background: 0xF5F1FA, foreground: 0x352C45, accentHue: 292),
        ThemeSpec(name: "Newsprint Fog", appearance: .light, background: 0xF0EFEB, foreground: 0x2A2A2A, accentHue: 250, chroma: 0.4),
        ThemeSpec(name: "Orchard Breeze", appearance: .light, background: 0xF2F8EC, foreground: 0x2C3A25, accentHue: 132),
        ThemeSpec(name: "Peach Veranda", appearance: .light, background: 0xFDF2EA, foreground: 0x43302A, accentHue: 42),
        ThemeSpec(name: "Porcelain Morning", appearance: .light, background: 0xF6F8FB, foreground: 0x283040, accentHue: 246),
        ThemeSpec(name: "Silver Point Light", appearance: .light, background: 0xF4F4F5, foreground: 0x2A2B2E, accentHue: 232, chroma: 0.6),
        ThemeSpec(name: "Sunlit Parchment", appearance: .light, background: 0xFBF6EA, foreground: 0x3A3326, accentHue: 62),
        ThemeSpec(name: "Terracotta Noon", appearance: .light, background: 0xFBF0E8, foreground: 0x40291F, accentHue: 32),
    ].map(Theme.generate)

    static let defaultDark = "Merino Dark"
    static let defaultLight = "Merino Light"

    static func named(_ name: String) -> Theme? {
        (dark + light).first { $0.name == name }
    }
}
