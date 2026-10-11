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

    init?(device: MTLDevice, metrics: FontMetrics) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2048, height: 2048, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        self.texture = texture
        self.metrics = metrics
    }

    func glyph(_ key: GlyphKey) -> Glyph? {
        if let hit = cache[key] { return hit }
        let g = rasterize(key)
        cache[key] = g
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
        let width = Int(metrics.cellWidth * span + padX * 2)
        let height = Int(metrics.cellHeight + padY * 2)
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            ctx.setAllowsFontSmoothing(false)
            ctx.setShouldAntialias(true)
            ctx.textMatrix = .identity
            // CG's origin is bottom-left: baseline sits `baseline` px below the
            // cell's top edge, which is `padY` px below the bitmap's top.
            var x = padX
            if isColor || key.wide {
                // Center emoji and wide glyphs inside their cells.
                let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                x += max(0, (metrics.cellWidth * span - w) / 2)
            }
            ctx.textPosition = CGPoint(x: x, y: CGFloat(height) - padY - metrics.baseline)
            CTLineDraw(line, ctx)
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
        cursorX = 1
        cursorY = 1
        rowHeight = 0
        epoch += 1
    }
}
