import Metal
import MetalKit
import DenVT

struct RectInstance {
    var rect: SIMD4<Float>
    var color: SIMD4<Float>
    /// x: corner radius in pixels.
    var params: SIMD4<Float> = .zero
}

struct GlyphInstance {
    var rect: SIMD4<Float>
    var uv: SIMD4<Float>
    var color: SIMD4<Float>
    /// x: 1 for color (emoji) glyphs.
    var flags: SIMD4<Float>
}

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

// viewport: size of the drawable in grid pixels (larger than the drawable
// when a thumbnail scales the grid down). atlasSize: glyph atlas size.
struct Uniforms { float2 viewport; float2 atlasSize; };
struct RectInstance { float4 rect; float4 color; float4 params; };
struct GlyphInstance { float4 rect; float4 uv; float4 color; float4 flags; };

struct RectOut { float4 position [[position]]; float4 color; float2 local; float2 size; float radius; };
struct GlyphOut { float4 position [[position]]; float2 uv; float4 color; float isColor; };

static float4 toClip(float2 px, float2 viewport) {
    float2 ndc = px / viewport * 2.0 - 1.0;
    return float4(ndc.x, -ndc.y, 0, 1);
}

vertex RectOut rect_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           constant Uniforms &u [[buffer(0)]],
                           const device RectInstance *rects [[buffer(1)]]) {
    RectInstance r = rects[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    RectOut out;
    out.position = toClip(r.rect.xy + corner * r.rect.zw, u.viewport);
    out.color = r.color;
    out.local = corner * r.rect.zw;
    out.size = r.rect.zw;
    out.radius = r.params.x;
    return out;
}

fragment float4 rect_fragment(RectOut in [[stage_in]]) {
    float alpha = in.color.a;
    if (in.radius > 0.0) {
        float2 half_size = in.size * 0.5;
        float2 p = abs(in.local - half_size) - (half_size - in.radius);
        float d = length(max(p, 0.0)) + min(max(p.x, p.y), 0.0) - in.radius;
        alpha *= clamp(0.5 - d, 0.0, 1.0);
    }
    return float4(in.color.rgb * alpha, alpha);
}

vertex GlyphOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             constant Uniforms &u [[buffer(0)]],
                             const device GlyphInstance *glyphs [[buffer(1)]]) {
    GlyphInstance g = glyphs[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    GlyphOut out;
    out.position = toClip(g.rect.xy + corner * g.rect.zw, u.viewport);
    out.uv = (g.uv.xy + corner * g.uv.zw) / u.atlasSize;
    out.color = g.color;
    out.isColor = g.flags.x;
    return out;
}

fragment float4 glyph_fragment(GlyphOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float4 texel = atlas.sample(s, in.uv);
    if (in.isColor > 0.5) { return texel * in.color.a; }
    float a = texel.a * in.color.a;
    return float4(in.color.rgb * a, a);
}

// A kitty image: the quad covers clip, and the texture is stretched over
// image, so only the part inside clip shows.
struct ImageInstance { float4 clip; float4 image; };
struct ImageOut { float4 position [[position]]; float2 uv; };

vertex ImageOut image_vertex(uint vid [[vertex_id]],
                             constant Uniforms &u [[buffer(0)]],
                             constant ImageInstance &i [[buffer(1)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    float2 px = i.clip.xy + corner * i.clip.zw;
    ImageOut out;
    out.position = toClip(px, u.viewport);
    out.uv = (px - i.image.xy) / i.image.zw;
    return out;
}

// Textures hold premultiplied alpha and mipmaps, for downscaled photos.
fragment float4 image_fragment(ImageOut in [[stage_in]], texture2d<float> image [[texture(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    return image.sample(s, in.uv);
}
"""

/// Pipelines shared by every terminal view.
@MainActor
final class RenderPipelines {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let rect: MTLRenderPipelineState
    let glyph: MTLRenderPipelineState
    let image: MTLRenderPipelineState

    static let shared: RenderPipelines? = RenderPipelines()

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: vertex)
                d.fragmentFunction = library.makeFunction(name: fragment)
                let a = d.colorAttachments[0]
                a?.pixelFormat = .bgra8Unorm
                a?.isBlendingEnabled = true
                a?.sourceRGBBlendFactor = .one
                a?.sourceAlphaBlendFactor = .one
                a?.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: d)
            }
            rect = try pipeline("rect_vertex", "rect_fragment")
            glyph = try pipeline("glyph_vertex", "glyph_fragment")
            image = try pipeline("image_vertex", "image_fragment")
        } catch {
            NSLog("Den: Metal pipeline setup failed: \(error)")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    private var atlases: [CGFloat: (FontMetrics, GlyphAtlas)] = [:]

    func atlas(for metrics: FontMetrics, smoothing: Bool) -> GlyphAtlas? {
        if let (m, a) = atlases[metrics.scale], m == metrics, a.smoothing == smoothing { return a }
        guard let a = GlyphAtlas(device: device, metrics: metrics, smoothing: smoothing) else { return nil }
        atlases[metrics.scale] = (metrics, a)
        return a
    }

    private struct ContrastKey: Hashable {
        let fg: RGB, bg: RGB, theme: RGB
    }

    /// Memoized contrast corrections; computing one costs a few dozen OKLab
    /// round trips, a lookup costs nanoseconds.
    private var contrastCache: [ContrastKey: RGB] = [:]

    func corrected(_ fg: RGB, on bg: RGB, themeForeground: RGB) -> RGB {
        let key = ContrastKey(fg: fg, bg: bg, theme: themeForeground)
        if let hit = contrastCache[key] { return hit }
        let result = ContrastCorrection.correct(fg, on: bg, themeForeground: themeForeground)
        if contrastCache.count > 50_000 { contrastCache.removeAll() }
        contrastCache[key] = result
        return result
    }
}

extension RGB {
    func simd(_ alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float(r) / 255, Float(g) / 255, Float(b) / 255, alpha)
    }
}

/// Builds one frame's instances from a render state.
@MainActor
struct FrameBuilder {
    let metrics: FontMetrics
    let atlas: GlyphAtlas
    let pipelines: RenderPipelines
    let origin: SIMD2<Float>
    let theme: Theme
    let cursorFocused: Bool
    let showCursor: Bool
    let contrastCorrection: Bool
    /// Shape symbol runs with the font's ligatures (`->`, `!=`, `=>`).
    let ligatures: Bool
    /// 1 solid, 0 hidden: where a blinking cursor is in its cycle.
    let cursorOpacity: Float

    var backgrounds: [RectInstance] = []
    var selections: [RectInstance] = []
    var decorations: [RectInstance] = []
    var glyphs: [GlyphInstance] = []
    /// Premultiplied fill for the whole view, padding included. Nil when the
    /// app draws on the card (or its canvas folds into it): the view stays
    /// transparent so the card's gradient shows through.
    var clear: SIMD4<Float>?

    init(metrics: FontMetrics, atlas: GlyphAtlas, pipelines: RenderPipelines, origin: SIMD2<Float>, theme: Theme,
         cursorFocused: Bool, showCursor: Bool, contrastCorrection: Bool, ligatures: Bool, cursorOpacity: Float = 1) {
        self.metrics = metrics
        self.atlas = atlas
        self.pipelines = pipelines
        self.origin = origin
        self.theme = theme
        self.cursorFocused = cursorFocused
        self.showCursor = showCursor
        self.contrastCorrection = contrastCorrection
        self.ligatures = ligatures
        self.cursorOpacity = cursorOpacity
    }

    /// Adjacent ASCII cells of one row and font style, drawn shaped when the
    /// font makes ligatures of them.
    private struct LigatureRun {
        var row = -1, start = 0
        var bold = false, italic = false
        var scalars: [UInt32] = []
        var colors: [SIMD4<Float>] = []

        /// A ligature glyph takes one color, so a color change ends the run.
        func continues(row: Int, col: Int, bold: Bool, italic: Bool, color: SIMD4<Float>) -> Bool {
            row == self.row && col == start + scalars.count && bold == self.bold && italic == self.italic && colors.last == color
        }

        /// Ligatures are made of symbols; letters and digits never form one.
        var mayLigate: Bool {
            scalars.count > 1 && scalars.contains { !(0x30 ... 0x39).contains($0) && !(0x41 ... 0x5A).contains($0) && !(0x61 ... 0x7A).contains($0) }
        }
    }

    private static func instance(_ glyph: Glyph, x: Float, y: Float, color: SIMD4<Float>) -> GlyphInstance {
        GlyphInstance(rect: SIMD4(x + glyph.offset.x, y + glyph.offset.y, glyph.region.z, glyph.region.w),
                      uv: glyph.region, color: color, flags: SIMD4(glyph.isColor ? 1 : 0, 0, 0, 0))
    }

    /// The run's glyphs: shaped if the font ligates it, else cell by cell.
    private static func glyphs(for run: LigatureRun, atlas: GlyphAtlas, origin: SIMD2<Float>, cellWidth cw: Float, cellHeight ch: Float) -> [GlyphInstance] {
        guard !run.scalars.isEmpty else { return [] }
        let y = origin.y + Float(run.row) * ch
        func x(_ cell: Int) -> Float { origin.x + Float(run.start + cell) * cw }
        if run.mayLigate {
            let text = String(String.UnicodeScalarView(run.scalars.compactMap(Unicode.Scalar.init)))
            if let shaped = atlas.shape(text, bold: run.bold, italic: run.italic) {
                return shaped.compactMap { s in
                    atlas.glyph(id: s.glyph, bold: run.bold, italic: run.italic)
                        .map { instance($0, x: x(s.cell) + Float(s.offset), y: y, color: run.colors[s.cell]) }
                }
            }
        }
        return run.scalars.enumerated().compactMap { i, scalar in
            atlas.glyph(GlyphKey(text: .scalar(scalar), bold: run.bold, italic: run.italic, wide: false))
                .map { instance($0, x: x(i), y: y, color: run.colors[i]) }
        }
    }

    /// Underlines a link under the mouse, in the theme's foreground.
    mutating func underline(_ link: TerminalLink) {
        let cw = Float(metrics.cellWidth), ch = Float(metrics.cellHeight)
        let thick = Float(metrics.underlineThickness)
        for span in link.spans {
            let x = origin.x + Float(span.columns.lowerBound) * cw
            let y = origin.y + Float(span.row) * ch + Float(metrics.underlinePosition)
            decorations.append(RectInstance(rect: SIMD4(x, y, Float(span.columns.count) * cw, thick), color: theme.foreground.simd()))
        }
    }

    mutating func build(_ state: VTRenderState) {
        let colors = state.colors
        let defaultBg = colors.background
        // Cell fills wait until the whole grid is seen: whether the app has
        // a canvas to fold decides how each one draws.
        var cellBackgrounds: [(SIMD4<Float>, RGB)] = []
        var coverage: [RGB: Int] = [:]
        let cw = Float(metrics.cellWidth), ch = Float(metrics.cellHeight)
        let cursor = showCursor ? state.cursor : nil
        let cursorColor = colors.cursor ?? theme.cursor
        let radius = Float(metrics.scale) * 3

        // Selection and find-bar matches: runs of one fill along a row.
        // Every match tints with the accent; the current one is solid.
        let matchFill = theme.background.mixed(with: theme.accentRGB, theme.isDark ? 0.42 : 0.32)
        let currentFill = theme.accentRGB
        let onCurrent = currentFill.luminance > 0.45 ? RGB(0, 0, 0) : RGB(255, 255, 255)
        var selectionRow = -1
        var selectionStart = 0
        var selectionEnd = 0
        var selectionFill = theme.selection
        // Local so the cell closure below doesn't overlap `self.selections`.
        var selectionRects: [RectInstance] = []
        // Locals too, for the same reason: the run being collected, and the
        // glyphs of runs already drawn.
        var run = LigatureRun()
        // Runs flush in cell order, so later text draws over any overhang.
        func flushRun() {
            glyphs += Self.glyphs(for: run, atlas: atlas, origin: origin, cellWidth: cw, cellHeight: ch)
            run = LigatureRun()
        }
        let atlas = atlas, origin = origin
        func flushSelection(_ rects: inout [RectInstance]) {
            guard selectionRow >= 0 else { return }
            let x = origin.x + Float(selectionStart) * cw
            let y = origin.y + Float(selectionRow) * ch
            rects.append(RectInstance(rect: SIMD4(x, y, Float(selectionEnd - selectionStart + 1) * cw, ch),
                                      color: selectionFill.simd(), params: SIMD4(radius, 0, 0, 0)))
            selectionRow = -1
        }

        state.forEachCell { cell in
            let fill: RGB? = if cell.selected {
                theme.selection
            } else {
                switch cell.found {
                case .current: currentFill
                case .match: matchFill
                case .none: nil
                }
            }
            if let fill {
                if selectionRow == cell.row, cell.col == selectionEnd + 1, fill == selectionFill {
                    selectionEnd = cell.col + (cell.width == .wide ? 1 : 0)
                } else {
                    flushSelection(&selectionRects)
                    selectionRow = cell.row
                    selectionStart = cell.col
                    selectionEnd = cell.col + (cell.width == .wide ? 1 : 0)
                    selectionFill = fill
                }
            }
            if cell.width == .spacerTail || cell.width == .spacerHead { return }
            let span: Float = cell.width == .wide ? 2 : 1
            let x = origin.x + Float(cell.col) * cw
            let y = origin.y + Float(cell.row) * ch

            var fg = cell.foreground ?? colors.foreground
            var bg = cell.background
            if cell.style.inverse {
                let oldFg = fg
                fg = bg ?? defaultBg
                bg = oldFg
            }

            // Past the middle of a blink's fade the text under a block
            // cursor goes back to its own color.
            let isCursorCell = cursor.map { $0.shape == .block && cursorFocused && cursorOpacity > 0.5 && $0.x == cell.col && $0.y == cell.row } ?? false
            if isCursorCell { fg = defaultBg }
            if cell.selected, !isCursorCell, let selected = theme.selectionForeground { fg = selected }
            if !cell.selected, cell.found == .current, !isCursorCell { fg = onCurrent }

            if let bg {
                cellBackgrounds.append((SIMD4(x, y, cw * span, ch), bg))
                coverage[bg, default: 0] += Int(span)
            }
            guard !cell.codepoints.isEmpty, !cell.style.invisible else { return }
            if contrastCorrection, !isCursorCell {
                fg = pipelines.corrected(fg, on: fill ?? bg ?? defaultBg, themeForeground: theme.foreground)
            }
            let alpha: Float = cell.style.faint ? 0.6 : 1

            if cell.style.underline != .none {
                let uy = origin.y + Float(cell.row) * ch + Float(metrics.underlinePosition)
                let thick = Float(metrics.underlineThickness)
                let color = (cell.style.underlineColor ?? fg).simd(alpha)
                decorations.append(RectInstance(rect: SIMD4(x, uy, cw * span, thick), color: color))
                if cell.style.underline == .double {
                    decorations.append(RectInstance(rect: SIMD4(x, uy + thick * 2, cw * span, thick), color: color))
                }
            }
            if cell.style.strikethrough {
                decorations.append(RectInstance(rect: SIMD4(x, y + ch * 0.52, cw * span, Float(metrics.underlineThickness)), color: fg.simd(alpha)))
            }

            let first = cell.codepoints[0]
            if cell.codepoints.count == 1, first == 0x20 { return }
            // Ligature candidates wait in a run; the cursor's cell breaks it
            // so typing never draws into a ligature.
            if ligatures, cell.codepoints.count == 1, (0x21 ... 0x7E).contains(first), cell.width == .narrow, !isCursorCell {
                let bold = cell.style.bold, italic = cell.style.italic, color = fg.simd(alpha)
                if !run.continues(row: cell.row, col: cell.col, bold: bold, italic: italic, color: color) {
                    flushRun()
                    run = LigatureRun(row: cell.row, start: cell.col, bold: bold, italic: italic)
                }
                run.scalars.append(first)
                run.colors.append(color)
                return
            }
            let text: GlyphKey.Text = cell.codepoints.count == 1
                ? .scalar(first)
                : .cluster(String(String.UnicodeScalarView(cell.codepoints.compactMap(Unicode.Scalar.init))))
            let key = GlyphKey(text: text, bold: cell.style.bold, italic: cell.style.italic, wide: cell.width == .wide)
            flushRun()
            guard let glyph = atlas.glyph(key) else { return }
            glyphs.append(GlyphInstance(
                rect: SIMD4(x + glyph.offset.x, y + glyph.offset.y, glyph.region.z, glyph.region.w),
                uv: glyph.region,
                color: fg.simd(alpha),
                flags: SIMD4(glyph.isColor ? 1 : 0, 0, 0, 0)
            ))
        }
        flushRun()
        flushSelection(&selectionRects)
        selections = selectionRects

        let (cols, rows) = state.size
        let fold = BackgroundFold(theme: theme.background, defaultBackground: defaultBg, coverage: coverage, cellCount: cols * rows)
        clear = fold.clear
        var layers: [RGB: SIMD4<Float>?] = [:]
        for (rect, color) in cellBackgrounds {
            let layer = layers[color] ?? {
                let l = fold.layer(color)
                layers[color] = l
                return l
            }()
            if let layer { backgrounds.append(RectInstance(rect: rect, color: layer)) }
        }

        if let cursor {
            let x = origin.x + Float(cursor.x) * cw
            let y = origin.y + Float(cursor.y) * ch
            let c = cursorColor.simd(cursorOpacity)
            let t = max(Float(metrics.scale), 1) * 1.5
            let shape: CursorShape = cursorFocused ? cursor.shape : .hollowBlock
            switch shape {
            case .block:
                // Drawn beneath glyphs so the character stays readable.
                backgrounds.append(RectInstance(rect: SIMD4(x, y, cw, ch), color: c, params: SIMD4(Float(metrics.scale), 0, 0, 0)))
            case .bar:
                decorations.append(RectInstance(rect: SIMD4(x, y, t, ch), color: c))
            case .underline:
                decorations.append(RectInstance(rect: SIMD4(x, y + ch - t, cw, t), color: c))
            case .hollowBlock:
                decorations.append(RectInstance(rect: SIMD4(x, y, cw, t), color: c))
                decorations.append(RectInstance(rect: SIMD4(x, y + ch - t, cw, t), color: c))
                decorations.append(RectInstance(rect: SIMD4(x, y, t, ch), color: c))
                decorations.append(RectInstance(rect: SIMD4(x + cw - t, y, t, ch), color: c))
            }
        }
    }
}
