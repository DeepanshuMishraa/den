import CoreGraphics
import CoreText
import Metal

struct GlyphKey: Hashable {
    /// Single codepoints (the common case) avoid allocating a String.
    enum Text: Hashable {
        case scalar(UInt32)
        case cluster(String)
    }

    let text: Text
    let bold: Bool
    let italic: Bool
    let wide: Bool
}

struct Glyph {
    /// Atlas region in pixels.
    let region: SIMD4<Float>
    /// Offset of the bitmap's top-left from the cell's top-left, in pixels.
    let offset: SIMD2<Float>
    let isColor: Bool
}

/// Rasterizes glyphs with Core Text into a shared BGRA texture. Plain text is
/// stored as white coverage and tinted in the shader; emoji keep their color.
@MainActor
final class GlyphAtlas {
    let texture: MTLTexture
    private let metrics: FontMetrics
    private var cache: [GlyphKey: Glyph?] = [:]
    private var cursorX = 1, cursorY = 1, rowHeight = 0
    private let size = 2048
    /// Bumped when the atlas is wiped so callers can drop stale frames.
    private(set) var epoch = 0

    /// Core Text font smoothing (heavier strokes), per the terminal setting.
    let smoothing: Bool

    init?(device: MTLDevice, metrics: FontMetrics, smoothing: Bool) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2048, height: 2048, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        self.texture = texture
        self.metrics = metrics
        self.smoothing = smoothing
    }

    func glyph(_ key: GlyphKey) -> Glyph? {
        if let hit = cache[key] { return hit }
        let g = rasterize(key)
        cache[key] = g
        return g
    }

    // MARK: Ligatures

    /// One shaped glyph of a run: the glyph, and where it sits relative to
    /// the cell of the character it starts at, in pixels.
    struct ShapedGlyph {
        let glyph: CGGlyph
        /// Index into the run's characters (one per cell).
        let cell: Int
        let offset: CGFloat
    }

    private struct ShapeKey: Hashable {
        let text: String
        let bold: Bool
        let italic: Bool
    }

    private struct GlyphIDKey: Hashable {
        let glyph: CGGlyph
        let bold: Bool
        let italic: Bool
    }

    /// Shaped runs by text, nil when the font forms no ligature in it (the
    /// cells then draw one by one). Screens repeat frame to frame.
    private var shapes: [ShapeKey: [ShapedGlyph]?] = [:]
    private var glyphsByID: [GlyphIDKey: Glyph?] = [:]

    /// `text` (one ASCII character per cell) shaped with the font's
    /// ligatures, or nil when shaping changes nothing.
    func shape(_ text: String, bold: Bool, italic: Bool) -> [ShapedGlyph]? {
        let key = ShapeKey(text: text, bold: bold, italic: italic)
        if let hit = shapes[key] { return hit }
        if shapes.count > 8192 { shapes.removeAll(keepingCapacity: true) }
        let shaped = shapeUncached(text, font: metrics.font(bold: bold, italic: italic))
        shapes[key] = shaped
        return shaped
    }

    private func shapeUncached(_ text: String, font: CTFont) -> [ShapedGlyph]? {
        let attributed = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            // Standard and contextual ligatures (`liga`, `calt`).
            kCTLigatureAttributeName as NSAttributedString.Key: 1,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let chars = Array(text.utf16)
        var unshaped = [CGGlyph](repeating: 0, count: chars.count)
        // Every character in the primary font, so Core Text falls back to
        // none and the glyph ids below are this font's.
        guard CTFontGetGlyphsForCharacters(font, chars, &unshaped, chars.count) else { return nil }
        // The font's own advance: cells are rounded, positions are not.
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, unshaped, &advance, 1)

        var out: [ShapedGlyph] = []
        var changed = false
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            for i in 0 ..< count {
                let cell = indices[i]
                if glyphs[i] != unshaped[cell] { changed = true }
                out.append(ShapedGlyph(glyph: glyphs[i], cell: cell, offset: positions[i].x - CGFloat(cell) * advance.width))
            }
        }
        if out.count != chars.count { changed = true }
        return changed ? out : nil
    }

    /// A glyph by its id in the primary font, as shaping produced it.
    /// Ligature glyphs may overhang neighboring cells by up to a few cells.
    func glyph(id: CGGlyph, bold: Bool, italic: Bool) -> Glyph? {
        let key = GlyphIDKey(glyph: id, bold: bold, italic: italic)
        if let hit = glyphsByID[key] { return hit }
        let font = metrics.font(bold: bold, italic: italic)
        let padX = metrics.cellWidth * 4
        let padY = (metrics.cellHeight / 2).rounded()
        let g = draw(width: Int(metrics.cellWidth + padX * 2), height: Int(metrics.cellHeight + padY * 2), padX: padX, padY: padY, isColor: false) { ctx, baselineY in
            var glyph = id
            var position = CGPoint(x: padX, y: baselineY)
            CTFontDrawGlyphs(font, &glyph, &position, 1, ctx)
        }
        glyphsByID[key] = g
        return g
    }

    private func rasterize(_ key: GlyphKey) -> Glyph? {
        let string: String = switch key.text {
        case .scalar(let v): Unicode.Scalar(v).map { String(Character($0)) } ?? " "
        case .cluster(let s): s
        }
        let font = metrics.font(bold: key.bold, italic: key.italic)
        let attributed = NSAttributedString(string: string, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)

        // The font Core Text falls back to tells us whether this is emoji.
        let fallback = CTFontCreateForString(font, string as CFString, CFRange(location: 0, length: string.utf16.count))
        let isColor = CTFontGetSymbolicTraits(fallback).contains(.traitColorGlyphs)

        // Draw into a padded box so glyphs that overhang their cell survive.
        let span = key.wide ? 2.0 : 1.0
        let padX = metrics.cellWidth
        let padY = (metrics.cellHeight / 2).rounded()
        return draw(width: Int(metrics.cellWidth * span + padX * 2), height: Int(metrics.cellHeight + padY * 2),
                    padX: padX, padY: padY, isColor: isColor) { ctx, baselineY in
            var x = padX
            if isColor || key.wide {
                // Center emoji and wide glyphs inside their cells.
                let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                x += max(0, (metrics.cellWidth * span - w) / 2)
            }
            ctx.textPosition = CGPoint(x: x, y: baselineY)
            CTLineDraw(line, ctx)
        }
    }

    /// Renders `body` into a padded bitmap, trims it to the ink and stores it
    /// in the atlas. `body` gets the baseline's y in CG's bottom-up space.
    private func draw(width: Int, height: Int, padX: CGFloat, padY: CGFloat, isColor: Bool,
                      _ body: (CGContext, CGFloat) -> Void) -> Glyph? {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            ctx.setAllowsFontSmoothing(smoothing)
            ctx.setShouldSmoothFonts(smoothing)
            ctx.setShouldAntialias(true)
            ctx.textMatrix = .identity
            // CG's origin is bottom-left: baseline sits `baseline` px below the
            // cell's top edge, which is `padY` px below the bitmap's top.
            body(ctx, CGFloat(height) - padY - metrics.baseline)
            return true
        }
        guard drawn else { return nil }

        // Trim to the inked bounding box so the atlas holds more glyphs.
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            let row = y * bytesPerRow
            for x in 0 ..< width where pixels[row + x * 4 + 3] != 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        let w = maxX - minX + 1, h = maxY - minY + 1

        guard let origin = allocate(width: w, height: h) else {
            reset()
            return allocate(width: w, height: h).flatMap { upload(pixels, bytesPerRow: bytesPerRow, minX: minX, minY: minY, w: w, h: h, at: $0, padX: padX, padY: padY, isColor: isColor) }
        }
        return upload(pixels, bytesPerRow: bytesPerRow, minX: minX, minY: minY, w: w, h: h, at: origin, padX: padX, padY: padY, isColor: isColor)
    }

    private func upload(_ pixels: [UInt8], bytesPerRow: Int, minX: Int, minY: Int, w: Int, h: Int,
                        at origin: (Int, Int), padX: CGFloat, padY: CGFloat, isColor: Bool) -> Glyph {
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(origin.0, origin.1, w, h), mipmapLevel: 0,
                            withBytes: base + minY * bytesPerRow + minX * 4, bytesPerRow: bytesPerRow)
        }
        return Glyph(
            region: SIMD4(Float(origin.0), Float(origin.1), Float(w), Float(h)),
            offset: SIMD2(Float(CGFloat(minX) - padX), Float(CGFloat(minY) - padY)),
            isColor: isColor
        )
    }

    private func allocate(width: Int, height: Int) -> (Int, Int)? {
        if cursorX + width + 1 > size {
            cursorX = 1
            cursorY += rowHeight + 1
            rowHeight = 0
        }
        guard cursorY + height + 1 <= size, width + 2 <= size else { return nil }
        let origin = (cursorX, cursorY)
        cursorX += width + 1
        rowHeight = max(rowHeight, height)
        return origin
    }

    private func reset() {
        cache.removeAll()
        glyphsByID.removeAll()
        cursorX = 1
        cursorY = 1
        rowHeight = 0
        epoch += 1
    }
}
