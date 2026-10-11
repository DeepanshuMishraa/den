import AppKit
import CoreText

/// Font discovery and fallback. Den ships JetBrains Mono Nerd Font (the
/// same default Ghostty embeds) so Nerd Font icons work out of the box, and
/// every chosen font falls back to a Nerd Font before the system fallback.
@MainActor
enum FontRegistry {
    /// Core Text's (typographic) family name for the bundled files.
    nonisolated static let bundledFamily = "JetBrainsMono Nerd Font"

    /// Registers the bundled fonts for this process. Safe to call repeatedly.
    static func registerBundled() {
        guard !registered else { return }
        registered = true
        guard let dir = Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            NSLog("Den: bundled fonts are missing from the app's resources; falling back to system fonts. Nerd Font icons may not render.")
            return
        }
        // Synchronous on purpose: the first terminal measures its font right
        // after launch, and the async API would race it.
        for url in files where url.pathExtension == "ttf" {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                NSLog("Den: could not register \(url.lastPathComponent): \(String(describing: error?.takeRetainedValue())). Nerd Font icons may fall back to other fonts.")
            }
        }
    }

    /// Resolves a family name (not a PostScript name) to a font, or nil.
    private static func font(named family: String, size: CGFloat) -> CTFont? {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        return (CTFontCopyFamilyName(font) as String) == family ? font : nil
    }

    private static var registered = false

    /// Nerd Font families tried, in order, for glyphs the primary font lacks.
    static var nerdFallbacks: [String] {
        // Resolve through Core Text: NSFontManager doesn't list fonts
        // registered for this process only, like the bundled one.
        [bundledFamily, "Symbols Nerd Font Mono", "Symbols Nerd Font", "Hack Nerd Font Mono", "JetBrainsMono Nerd Font Mono"]
            .filter { font(named: $0, size: 12) != nil }
    }

    /// Monospaced families installed on this Mac, for the font picker.
    static func monospacedFamilies() -> [String] {
        let fm = NSFontManager.shared
        let families = fm.availableFontFamilies.filter { family in
            guard let members = fm.availableMembers(ofFontFamily: family), let first = members.first,
                  let name = first.first as? String, let font = NSFont(name: name, size: 13) else { return false }
            return font.isFixedPitch || family.localizedCaseInsensitiveContains("mono")
        }
        return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The primary font with the Nerd Font cascade attached, so Core Text
    /// picks icons from a Nerd Font before falling back to system fonts.
    static func font(family: String, size: CGFloat) -> CTFont {
        let base = font(named: family, size: size)
            ?? font(named: bundledFamily, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        let cascade = nerdFallbacks
            .filter { $0 != (CTFontCopyFamilyName(base) as String) }
            .map { CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: $0] as CFDictionary) }
        guard !cascade.isEmpty else { return base }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute: cascade] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
    }
}
