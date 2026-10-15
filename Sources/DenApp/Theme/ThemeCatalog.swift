import Foundation

/// Den's built-in themes: popular terminal themes with their published
/// palettes, copied verbatim. Each entry names its source: the theme's own
/// Ghostty port where the project ships one, else the copy bundled with
/// Ghostty (iTerm2-Color-Schemes). Den's own 41 generated themes follow.
enum ThemeCatalog {
    static let dark: [Theme] = [
        // catppuccin/ghostty
        Theme(published: "Catppuccin Mocha", background: 0x1E1E2E, foreground: 0xCDD6F4, cursor: 0xF5E0DC, selection: 0x353749,
              ansi: [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8, 0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE], selectionForeground: 0xCDD6F4),
        // catppuccin/ghostty
        Theme(published: "Catppuccin Macchiato", background: 0x24273A, foreground: 0xCAD3F5, cursor: 0xF4DBD6, selection: 0x3A3E53,
              ansi: [0x494D64, 0xED8796, 0xA6DA95, 0xEED49F, 0x8AADF4, 0xF5BDE6, 0x8BD5CA, 0xA5ADCB, 0x5B6078, 0xED8796, 0xA6DA95, 0xEED49F, 0x8AADF4, 0xF5BDE6, 0x8BD5CA, 0xB8C0E0], selectionForeground: 0xCAD3F5),
        // catppuccin/ghostty
        Theme(published: "Catppuccin Frappé", background: 0x303446, foreground: 0xC6D0F5, cursor: 0xF2D5CF, selection: 0x44495D,
              ansi: [0x51576D, 0xE78284, 0xA6D189, 0xE5C890, 0x8CAAEE, 0xF4B8E4, 0x81C8BE, 0xA5ADCE, 0x626880, 0xE78284, 0xA6D189, 0xE5C890, 0x8CAAEE, 0xF4B8E4, 0x81C8BE, 0xB5BFE2], selectionForeground: 0xC6D0F5),
        // folke/tokyonight.nvim
        Theme(published: "Tokyo Night", background: 0x1A1B26, foreground: 0xC0CAF5, cursor: 0xC0CAF5, selection: 0x283457,
              ansi: [0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6, 0x414868, 0xFF899D, 0x9FE044, 0xFABA4A, 0x8DB0FF, 0xC7A9FF, 0xA4DAFF, 0xC0CAF5], selectionForeground: 0xC0CAF5),
        // folke/tokyonight.nvim
        Theme(published: "Tokyo Night Storm", background: 0x24283B, foreground: 0xC0CAF5, cursor: 0xC0CAF5, selection: 0x2E3C64,
              ansi: [0x1D202F, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6, 0x414868, 0xFF899D, 0x9FE044, 0xFABA4A, 0x8DB0FF, 0xC7A9FF, 0xA4DAFF, 0xC0CAF5], selectionForeground: 0xC0CAF5),
        // folke/tokyonight.nvim
        Theme(published: "Tokyo Night Moon", background: 0x222436, foreground: 0xC8D3F5, cursor: 0xC8D3F5, selection: 0x2D3F76,
              ansi: [0x1B1D2B, 0xFF757F, 0xC3E88D, 0xFFC777, 0x82AAFF, 0xC099FF, 0x86E1FC, 0x828BB8, 0x444A73, 0xFF8D94, 0xC7FB6D, 0xFFD8AB, 0x9AB8FF, 0xCAABFF, 0xB2EBFF, 0xC8D3F5], selectionForeground: 0xC8D3F5),
        // Ghostty
        Theme(published: "Vesper", background: 0x101010, foreground: 0xFFFFFF, cursor: 0xACB1AB, selection: 0x988049,
              ansi: [0x101010, 0xF5A191, 0x90B99F, 0xE6B99D, 0xACA1CF, 0xE29ECA, 0xEA83A5, 0xA0A0A0, 0x7E7E7E, 0xFF8080, 0x99FFE4, 0xFFC799, 0xB9AEDA, 0xECAAD6, 0xF591B2, 0xFFFFFF], selectionForeground: 0xB9BEB8, accent: 0xFFC799),
        // Ghostty
        Theme(published: "Gruvbox Dark", background: 0x282828, foreground: 0xEBDBB2, cursor: 0xEBDBB2, selection: 0x665C54,
              ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984, 0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2], selectionForeground: 0xEBDBB2, accent: 0xFE8019),
        // Ghostty
        Theme(published: "Gruvbox Dark Hard", background: 0x1D2021, foreground: 0xEBDBB2, cursor: 0xEBDBB2, selection: 0x665C54,
              ansi: [0x1D2021, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984, 0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2], selectionForeground: 0xEBDBB2, accent: 0xFE8019),
        // Ghostty
        Theme(published: "Gruvbox Material Dark", background: 0x282828, foreground: 0xD4BE98, cursor: 0xD4BE98, selection: 0xD4BE98,
              ansi: [0x282828, 0xEA6962, 0xA9B665, 0xD8A657, 0x7DAEA3, 0xD3869B, 0x89B482, 0xD4BE98, 0x7C6F64, 0xEA6962, 0xA9B665, 0xD8A657, 0x7DAEA3, 0xD3869B, 0x89B482, 0xDDC7A1], selectionForeground: 0x282828),
        // Ghostty
        Theme(published: "One Dark", background: 0x21252B, foreground: 0xABB2BF, cursor: 0xABB2BF, selection: 0x323844,
              ansi: [0x21252B, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF, 0x767676, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF], selectionForeground: 0xABB2BF),
        // dracula/ghostty
        Theme(published: "Dracula", background: 0x282A36, foreground: 0xF8F8F2, cursor: 0xF8F8F2, selection: 0x44475A,
              ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2, 0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF], selectionForeground: 0xF8F8F2),
        // Ghostty
        Theme(published: "Nord", background: 0x2E3440, foreground: 0xD8DEE9, cursor: 0xECEFF4, selection: 0xECEFF4,
              ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0, 0x596377, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4], selectionForeground: 0x4C566A),
        // Ghostty
        Theme(published: "Solarized Dark", background: 0x002B36, foreground: 0x839496, cursor: 0x839496, selection: 0x073642,
              ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5, 0x335E69, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3], selectionForeground: 0x93A1A1),
        // rose-pine/ghostty
        Theme(published: "Rosé Pine", background: 0x191724, foreground: 0xE0DEF4, cursor: 0xE0DEF4, selection: 0x403D52,
              ansi: [0x26233A, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4, 0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4], selectionForeground: 0xE0DEF4, accent: 0xC4A7E7),
        // rose-pine/ghostty
        Theme(published: "Rosé Pine Moon", background: 0x232136, foreground: 0xE0DEF4, cursor: 0xE0DEF4, selection: 0x44415A,
              ansi: [0x393552, 0xEB6F92, 0x3E8FB0, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEA9A97, 0xE0DEF4, 0x6E6A86, 0xEB6F92, 0x3E8FB0, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEA9A97, 0xE0DEF4], selectionForeground: 0xE0DEF4, accent: 0xC4A7E7),
        // rebelot/kanagawa.nvim
        Theme(published: "Kanagawa Wave", background: 0x1F1F28, foreground: 0xDCD7BA, cursor: 0xC8C093, selection: 0x2D4F67,
              ansi: [0x16161D, 0xC34043, 0x76946A, 0xC0A36E, 0x7E9CD8, 0x957FB8, 0x6A9589, 0xC8C093, 0x727169, 0xE82424, 0x98BB6C, 0xE6C384, 0x7FB4CA, 0x938AA9, 0x7AA89F, 0xDCD7BA], selectionForeground: 0xC8C093),
        // rebelot/kanagawa.nvim
        Theme(published: "Kanagawa Dragon", background: 0x181616, foreground: 0xC5C9C5, cursor: 0xC8C093, selection: 0x2D4F67,
              ansi: [0x0D0C0C, 0xC4746E, 0x8A9A7B, 0xC4B28A, 0x8BA4B0, 0xA292A3, 0x8EA4A2, 0xC8C093, 0xA6A69C, 0xE46876, 0x87A987, 0xE6C384, 0x7FB4CA, 0x938AA9, 0x7AA89F, 0xC5C9C5], selectionForeground: 0xC8C093),
        // Ghostty
        Theme(published: "Everforest Dark", background: 0x232A2E, foreground: 0xD3C6AA, cursor: 0xE69875, selection: 0x543A48,
              ansi: [0x7A8478, 0xE67E80, 0xA7C080, 0xDBBC7F, 0x7FBBB3, 0xD699B6, 0x83C092, 0xF2EFDF, 0xA6B0A0, 0xF85552, 0x8DA101, 0xDFA000, 0x3A94C5, 0xDF69BA, 0x35A77C, 0xFFFBEF], selectionForeground: 0xD3C6AA),
        // EdenEast/nightfox.nvim
        Theme(published: "Nightfox", background: 0x192330, foreground: 0xCDCECF, cursor: 0xCDCECF, selection: 0x2B3B51,
              ansi: [0x393B44, 0xC94F6D, 0x81B29A, 0xDBC074, 0x719CD6, 0x9D79D6, 0x63CDCF, 0xDFDFE0, 0x575860, 0xD16983, 0x8EBAA4, 0xE0C989, 0x86ABDC, 0xBAA1E2, 0x7AD5D6, 0xE4E4E5], selectionForeground: 0xCDCECF),
        // EdenEast/nightfox.nvim
        Theme(published: "Carbonfox", background: 0x161616, foreground: 0xF2F4F8, cursor: 0xF2F4F8, selection: 0x2A2A2A,
              ansi: [0x282828, 0xEE5396, 0x25BE6A, 0x08BDBA, 0x78A9FF, 0xBE95FF, 0x33B1FF, 0xDFDFE0, 0x484848, 0xF16DA6, 0x46C880, 0x2DC7C4, 0x8CB6FF, 0xC8A5FF, 0x52BDFF, 0xE4E4E5], selectionForeground: 0xF2F4F8),
        // Ghostty
        Theme(published: "GitHub Dark", background: 0x0D1117, foreground: 0xE6EDF3, cursor: 0x2F81F7, selection: 0xE6EDF3,
              ansi: [0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4, 0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xFFFFFF], selectionForeground: 0x0D1117),
        // Ghostty
        Theme(published: "Ayu Dark", background: 0x0B0E14, foreground: 0xBFBDB6, cursor: 0xE6B450, selection: 0x409FFF,
              ansi: [0x11151C, 0xEA6C73, 0x7FD962, 0xF9AF4F, 0x53BDFA, 0xCDA1FA, 0x90E1C6, 0xC7C7C7, 0x686868, 0xF07178, 0xAAD94C, 0xFFB454, 0x59C2FF, 0xD2A6FF, 0x95E6CB, 0xFFFFFF], selectionForeground: 0x0B0E14),
        // Ghostty
        Theme(published: "Ayu Mirage", background: 0x1F2430, foreground: 0xCCCAC2, cursor: 0xFFCC66, selection: 0x409FFF,
              ansi: [0x171B24, 0xED8274, 0x87D96C, 0xFACC6E, 0x6DCBFA, 0xDABAFA, 0x90E1C6, 0xC7C7C7, 0x686868, 0xF28779, 0xD5FF80, 0xFFD173, 0x73D0FF, 0xDFBFFF, 0x95E6CB, 0xFFFFFF], selectionForeground: 0x1F2430),
        // Ghostty
        Theme(published: "Monokai Pro", background: 0x2D2A2E, foreground: 0xFCFCFA, cursor: 0xC1C0C0, selection: 0x5B595C,
              ansi: [0x2D2A2E, 0xFF6188, 0xA9DC76, 0xFFD866, 0xFC9867, 0xAB9DF2, 0x78DCE8, 0xFCFCFA, 0x727072, 0xFF6188, 0xA9DC76, 0xFFD866, 0xFC9867, 0xAB9DF2, 0x78DCE8, 0xFCFCFA], selectionForeground: 0xFCFCFA),
        // Ghostty
        Theme(published: "Night Owl", background: 0x011627, foreground: 0xD6DEEB, cursor: 0x7E57C2, selection: 0x5F7E97,
              ansi: [0x011627, 0xEF5350, 0x22DA6E, 0xADDB67, 0x82AAFF, 0xC792EA, 0x21C7A8, 0xFFFFFF, 0x575656, 0xEF5350, 0x22DA6E, 0xFFEB95, 0x82AAFF, 0xC792EA, 0x7FDBCA, 0xFFFFFF], selectionForeground: 0xDFE5EE),
        // Ghostty
        Theme(published: "Poimandres", background: 0x1A1E28, foreground: 0xA6ACCD, cursor: 0xFFFFFF, selection: 0xA6ACCD,
              ansi: [0x1A1E28, 0xD0679D, 0x5DE4C7, 0xFFFAC2, 0x89DDFF, 0xFCC5E9, 0xADD7FF, 0xFFFFFF, 0xA6ACCD, 0xD0679D, 0x5DE4C7, 0xFFFAC2, 0xADD7FF, 0xFAE4FC, 0x89DDFF, 0xFFFFFF], selectionForeground: 0xFFFFFF),
        // Ghostty
        Theme(published: "Oxocarbon", background: 0x161616, foreground: 0xF2F4F8, cursor: 0xFFFFFF, selection: 0x393939,
              ansi: [0x161616, 0x00DFDB, 0x00B4FF, 0xFF4297, 0x00C15A, 0xC693FF, 0xFF74B8, 0xF2F4F8, 0x585858, 0x00DFDB, 0x00B4FF, 0xFF4297, 0x00C15A, 0xC693FF, 0xFF74B8, 0xF2F4F8], selectionForeground: 0x626262),
        // Ghostty
        Theme(published: "Moonfly", background: 0x080808, foreground: 0xBDBDBD, cursor: 0x9E9E9E, selection: 0xB2CEEE,
              ansi: [0x323437, 0xFF5454, 0x8CC85F, 0xE3C78A, 0x80A0FF, 0xCF87E8, 0x79DAC8, 0xC6C6C6, 0x949494, 0xFF5189, 0x36C692, 0xC6C684, 0x74B2FF, 0xAE81FF, 0x85DC85, 0xE4E4E4], selectionForeground: 0x080808),
        // Ghostty
        Theme(published: "Flexoki Dark", background: 0x100F0F, foreground: 0xCECDC3, cursor: 0xCECDC3, selection: 0x403E3C,
              ansi: [0x100F0F, 0xD14D41, 0x879A39, 0xD0A215, 0x4385BE, 0xCE5D97, 0x3AA99F, 0x878580, 0x575653, 0xAF3029, 0x66800B, 0xAD8301, 0x205EA6, 0xA02F6F, 0x24837B, 0xCECDC3], selectionForeground: 0xCECDC3),
        // Ghostty
        Theme(published: "Melange Dark", background: 0x292522, foreground: 0xECE1D7, cursor: 0xECE1D7, selection: 0xECE1D7,
              ansi: [0x34302C, 0xBD8183, 0x78997A, 0xE49B5D, 0x7F91B2, 0xB380B0, 0x7B9695, 0xC1A78E, 0x867462, 0xD47766, 0x85B695, 0xEBC06D, 0xA3A9CE, 0xCF9BC2, 0x89B3B6, 0xECE1D7], selectionForeground: 0x403A36),
        // Ghostty
        Theme(published: "Iceberg Dark", background: 0x161821, foreground: 0xC6C8D1, cursor: 0xC6C8D1, selection: 0xC6C8D1,
              ansi: [0x1E2132, 0xE27878, 0xB4BE82, 0xE2A478, 0x84A0C6, 0xA093C7, 0x89B8C2, 0xC6C8D1, 0x6B7089, 0xE98989, 0xC0CA8E, 0xE9B189, 0x91ACD1, 0xADA0D3, 0x95C4CE, 0xD2D4DE], selectionForeground: 0x161821),
        // Ghostty
        Theme(published: "Tomorrow Night", background: 0x1D1F21, foreground: 0xC5C8C6, cursor: 0xC5C8C6, selection: 0x373B41,
              ansi: [0x000000, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xFFFFFF, 0x4C4C4C, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xFFFFFF], selectionForeground: 0xC5C8C6),
        // Ghostty
        Theme(published: "Material Ocean", background: 0x0F111A, foreground: 0x8F93A2, cursor: 0xFFCC00, selection: 0x1F2233,
              ansi: [0x546E7A, 0xFF5370, 0xC3E88D, 0xFFCB6B, 0x82AAFF, 0xC792EA, 0x89DDFF, 0xFFFFFF, 0x546E7A, 0xFF5370, 0xC3E88D, 0xFFCB6B, 0x82AAFF, 0xC792EA, 0x89DDFF, 0xFFFFFF], selectionForeground: 0x8F93A2),
        // Ghostty
        Theme(published: "Horizon", background: 0x1C1E26, foreground: 0xD5D8DA, cursor: 0x6C6F93, selection: 0x6C6F93,
              ansi: [0x000000, 0xE95678, 0x29D398, 0xFAB795, 0x26BBD9, 0xEE64AC, 0x59E1E3, 0xE5E5E5, 0x666666, 0xEC6A88, 0x3FDAA4, 0xFBC3A7, 0x3FC4DE, 0xF075B5, 0x6BE4E6, 0xE5E5E5], selectionForeground: 0x1C1E26),
        // Ghostty
        Theme(published: "Cobalt2", background: 0x132738, foreground: 0xFFFFFF, cursor: 0xF0CC09, selection: 0x18354F,
              ansi: [0x000000, 0xFF0000, 0x38DE21, 0xFFE50A, 0x1460D2, 0xFF005D, 0x00BBBB, 0xBBBBBB, 0x555555, 0xF40E17, 0x3BD01D, 0xEDC809, 0x5555FF, 0xFF55FF, 0x6AE3FA, 0xFFFFFF], selectionForeground: 0xB5B5B5),
    ] + [
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
        // catppuccin/ghostty
        Theme(published: "Catppuccin Latte", background: 0xEFF1F5, foreground: 0x4C4F69, cursor: 0xDC8A78, selection: 0xD8DAE1,
              ansi: [0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE, 0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC], selectionForeground: 0x4C4F69),
        // folke/tokyonight.nvim
        Theme(published: "Tokyo Night Day", background: 0xE1E2E7, foreground: 0x3760BF, cursor: 0x3760BF, selection: 0xB7C1E3,
              ansi: [0xB4B5B9, 0xF52A65, 0x587539, 0x8C6C3E, 0x2E7DE9, 0x9854F1, 0x007197, 0x6172B0, 0xA1A6C5, 0xFF4774, 0x5C8524, 0xA27629, 0x358AFF, 0xA463FF, 0x007EA8, 0x3760BF], selectionForeground: 0x3760BF),
        // Ghostty
        Theme(published: "Gruvbox Light", background: 0xFBF1C7, foreground: 0x3C3836, cursor: 0x3C3836, selection: 0x3C3836,
              ansi: [0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0x7C6F64, 0x928374, 0x9D0006, 0x79740E, 0xB57614, 0x076678, 0x8F3F71, 0x427B58, 0x3C3836], selectionForeground: 0xFBF1C7, accent: 0xAF3A03),
        // Ghostty
        Theme(published: "Gruvbox Material Light", background: 0xFBF1C7, foreground: 0x654735, cursor: 0x654735, selection: 0x654735,
              ansi: [0xFBF1C7, 0xC14A4A, 0x6C782E, 0xB47109, 0x45707A, 0x945E80, 0x4C7A5D, 0x654735, 0xA89984, 0xC14A4A, 0x6C782E, 0xB47109, 0x45707A, 0x945E80, 0x4C7A5D, 0x4F3829], selectionForeground: 0xFBF1C7),
        // Ghostty
        Theme(published: "One Light", background: 0xF9F9F9, foreground: 0x2A2C33, cursor: 0xBBBBBB, selection: 0xEDEDED,
              ansi: [0x000000, 0xDE3E35, 0x3F953A, 0xD2B67C, 0x2F5AF3, 0x950095, 0x3F953A, 0xBBBBBB, 0x000000, 0xDE3E35, 0x3F953A, 0xD2B67C, 0x2F5AF3, 0xA00095, 0x3F953A, 0xFFFFFF], selectionForeground: 0x2A2C33),
        // Ghostty
        Theme(published: "Solarized Light", background: 0xFDF6E3, foreground: 0x657B83, cursor: 0x657B83, selection: 0xEEE8D5,
              ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xBBB5A2, 0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3], selectionForeground: 0x586E75),
        // rose-pine/ghostty
        Theme(published: "Rosé Pine Dawn", background: 0xFAF4ED, foreground: 0x575279, cursor: 0x575279, selection: 0xDFDAD9,
              ansi: [0xF2E9E1, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279, 0x9893A5, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279], selectionForeground: 0x575279, accent: 0x907AA9),
        // rebelot/kanagawa.nvim
        Theme(published: "Kanagawa Lotus", background: 0xF2ECBC, foreground: 0x545464, cursor: 0x43436C, selection: 0xC9CBD1,
              ansi: [0x1F1F28, 0xC84053, 0x6F894E, 0x77713F, 0x4D699B, 0xB35B79, 0x597B75, 0x545464, 0x8A8980, 0xD7474B, 0x6E915F, 0x836F4A, 0x6693BF, 0x624C83, 0x5E857A, 0x43436C], selectionForeground: 0x43436C),
        // Ghostty
        Theme(published: "Everforest Light", background: 0xEFEBD4, foreground: 0x5C6A72, cursor: 0xF57D26, selection: 0xEAEDC8,
              ansi: [0x7A8478, 0xE67E80, 0x9AB373, 0xC1A266, 0x7FBBB3, 0xD699B6, 0x83C092, 0xB2AF9F, 0xA6B0A0, 0xF85552, 0x8DA101, 0xDFA000, 0x3A94C5, 0xDF69BA, 0x35A77C, 0xFFFBEF], selectionForeground: 0x5C6A72),
        // EdenEast/nightfox.nvim
        Theme(published: "Dayfox", background: 0xF6F2EE, foreground: 0x3D2B5A, cursor: 0x3D2B5A, selection: 0xE7D2BE,
              ansi: [0x352C24, 0xA5222F, 0x396847, 0xAC5402, 0x2848A9, 0x6E33CE, 0x287980, 0xF2E9E1, 0x534C45, 0xB3434E, 0x577F63, 0xB86E28, 0x4863B6, 0x8452D5, 0x488D93, 0xF4ECE6], selectionForeground: 0x3D2B5A),
        // Ghostty
        Theme(published: "GitHub Light", background: 0xFFFFFF, foreground: 0x1F2328, cursor: 0x0969DA, selection: 0x1F2328,
              ansi: [0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781, 0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F], selectionForeground: 0xFFFFFF),
        // Ghostty
        Theme(published: "Ayu Light", background: 0xF8F9FA, foreground: 0x5C6166, cursor: 0xFFAA33, selection: 0x035BD6,
              ansi: [0x000000, 0xEA6C6D, 0x6CBF43, 0xECA944, 0x3199E1, 0x9E75C7, 0x46BA94, 0xBABABA, 0x686868, 0xF07171, 0x86B300, 0xF2AE49, 0x399EE6, 0xA37ACC, 0x4CBF99, 0xD1D1D1], selectionForeground: 0xF8F9FA),
        // Ghostty
        Theme(published: "Light Owl", background: 0xFBFBFB, foreground: 0x403F53, cursor: 0x403F53, selection: 0xE0E0E0,
              ansi: [0x403F53, 0xDE3D3B, 0x08916A, 0xE0AF02, 0x288ED7, 0xD6438A, 0x2AA298, 0xBDBDBD, 0x989FB1, 0xDE3D3B, 0x08916A, 0xDAAA01, 0x288ED7, 0xD6438A, 0x2AA298, 0xF0F0F0], selectionForeground: 0x403F53),
        // Ghostty
        Theme(published: "Monokai Pro Light", background: 0xFAF4F2, foreground: 0x29242A, cursor: 0x706B6E, selection: 0xBFB9BA,
              ansi: [0xFAF4F2, 0xE14775, 0x269D69, 0xCC7A0A, 0xE16032, 0x7058BE, 0x1C8CA8, 0x29242A, 0xA59FA0, 0xE14775, 0x269D69, 0xCC7A0A, 0xE16032, 0x7058BE, 0x1C8CA8, 0x29242A], selectionForeground: 0x29242A),
        // Ghostty
        Theme(published: "Flexoki Light", background: 0xFFFCF0, foreground: 0x100F0F, cursor: 0x100F0F, selection: 0xCECDC3,
              ansi: [0x100F0F, 0xAF3029, 0x66800B, 0xAD8301, 0x205EA6, 0xA02F6F, 0x24837B, 0x6F6E69, 0xB7B5AC, 0xD14D41, 0x879A39, 0xD0A215, 0x4385BE, 0xCE5D97, 0x3AA99F, 0xCECDC3], selectionForeground: 0x100F0F),
        // Ghostty
        Theme(published: "Melange Light", background: 0xF1F1F1, foreground: 0x54433A, cursor: 0x54433A, selection: 0x54433A,
              ansi: [0xE9E1DB, 0xC77B8B, 0x6E9B72, 0xBC5C00, 0x7892BD, 0xBE79BB, 0x739797, 0x7D6658, 0xA98A78, 0xBF0021, 0x3A684A, 0xA06D00, 0x465AA4, 0x904180, 0x3D6568, 0x54433A], selectionForeground: 0xD9D3CE),
        // Ghostty
        Theme(published: "Iceberg Light", background: 0xE8E9EC, foreground: 0x33374C, cursor: 0x33374C, selection: 0x33374C,
              ansi: [0xDCDFE7, 0xCC517A, 0x668E3D, 0xC57339, 0x2D539E, 0x7759B4, 0x3F83A6, 0x33374C, 0x8389A3, 0xCC3768, 0x598030, 0xB6662D, 0x22478E, 0x6845AD, 0x327698, 0x262A3F], selectionForeground: 0xE8E9EC),
        // Ghostty
        Theme(published: "Tomorrow", background: 0xFFFFFF, foreground: 0x4D4D4C, cursor: 0x4D4D4C, selection: 0xD6D6D6,
              ansi: [0x000000, 0xC82829, 0x718C00, 0xEAB700, 0x4271AE, 0x8959A8, 0x3E999F, 0xBFBFBF, 0x000000, 0xC82829, 0x718C00, 0xEAB700, 0x4271AE, 0x8959A8, 0x3E999F, 0xFFFFFF], selectionForeground: 0x4D4D4C),
        // Ghostty
        Theme(published: "Alabaster", background: 0xF7F7F7, foreground: 0x000000, cursor: 0x007ACC, selection: 0xBFDBFE,
              ansi: [0x000000, 0xAA3731, 0x448C27, 0xCB9000, 0x325CC0, 0x7A3E9D, 0x0083B2, 0xB7B7B7, 0x777777, 0xF05050, 0x60CB00, 0xF2AF50, 0x007ACC, 0xE64CE6, 0x00AACB, 0xF7F7F7], selectionForeground: 0x000000),
    ] + [
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

    static let defaultDark = "Catppuccin Mocha"
    static let defaultLight = "Catppuccin Latte"

    static func named(_ name: String) -> Theme? {
        (dark + light).first { $0.name == name }
    }
}
