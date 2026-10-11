import AppKit
import CoreText

/// Font and cell geometry in device pixels for one backing scale.
struct FontMetrics: Equatable {
    let regular: CTFont
    let bold: CTFont
    let italic: CTFont
    let boldItalic: CTFont
    let scale: CGFloat
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// Distance from the cell's top edge to the text baseline.
    let baseline: CGFloat
    let underlinePosition: CGFloat
    let underlineThickness: CGFloat

    static let defaultFamily = FontRegistry.bundledFamily
    static let defaultSize: CGFloat = 13

    let family: String
    let pointSize: CGFloat

    @MainActor
    init(family: String = defaultFamily, pointSize: CGFloat = defaultSize, scale: CGFloat) {
        self.family = family
        self.pointSize = pointSize
        let size = pointSize * scale
        let font = FontRegistry.font(family: family, size: size)
        regular = font
        bold = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) ?? font
        italic = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitItalic, .traitItalic) ?? font
        boldItalic = CTFontCreateCopyWithSymbolicTraits(font, size, nil, [.traitBold, .traitItalic], [.traitBold, .traitItalic]) ?? bold
        self.scale = scale

        var glyph = CGGlyph()
        var m: UniChar = 0x4D // "M"
        CTFontGetGlyphsForCharacters(font, &m, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        cellWidth = advance.width.rounded()
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        cellHeight = (ascent + descent + leading).rounded(.up) + (2 * scale).rounded()
        baseline = ((cellHeight - (ascent + descent)) / 2 + ascent).rounded()
        underlinePosition = (baseline - CTFontGetUnderlinePosition(font)).rounded()
        underlineThickness = max(1, CTFontGetUnderlineThickness(font).rounded())
    }

    func font(bold isBold: Bool, italic isItalic: Bool) -> CTFont {
        switch (isBold, isItalic) {
        case (false, false): regular
        case (true, false): bold
        case (false, true): italic
        case (true, true): boldItalic
        }
    }

    static func == (a: FontMetrics, b: FontMetrics) -> Bool {
        a.scale == b.scale && a.family == b.family && a.pointSize == b.pointSize
    }
}
