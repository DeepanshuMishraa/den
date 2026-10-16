import Foundation
import CTermyEngine

/// A kitty graphics image on the viewport. Rectangles are x, y, width,
/// height in pixels from the grid's top-left, for the cell size asked for:
/// the image is stretched over `image` and shows only inside `clip`.
public struct VTImagePlacement: Equatable, Sendable {
    /// Names an image's pixels: the same key always has the same pixels.
    public struct Key: Hashable, Sendable {
        public let id: UInt32
        public let generation: UInt64
    }

    /// Where the image draws relative to the cells, from its z-index.
    public enum Layer: Sendable {
        case belowBackgrounds, belowText, aboveText
    }

    public let key: Key
    public let layer: Layer
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let clip: SIMD4<Float>
    public let image: SIMD4<Float>
}

public enum VTImagePixels: Sendable {
    /// Rows of `pixelWidth * 4` bytes, straight (not premultiplied) alpha.
    case rgba(Data)
    case png(Data)
}

extension VTImagePlacement.Layer {
    /// Kitty's z-index bands: below -1073741824 under cell backgrounds,
    /// below 0 under text, otherwise over it.
    init(zIndex: Int32) {
        self = zIndex < -1_073_741_824 ? .belowBackgrounds : zIndex < 0 ? .belowText : .aboveText
    }
}

extension VTTerminal {
    /// Images on the viewport for the given cell size in pixels, lowest z
    /// first. Asking again with another cell size lays them out for it.
    public func imagePlacements(cellWidth: Float, cellHeight: Float) throws(VTError) -> [VTImagePlacement] {
        var ptr: UnsafePointer<TermyEngineImagePlacement>?
        var count = 0
        try check(termy_engine_image_placements(handle, cellWidth, cellHeight, &ptr, &count), "image_placements")
        guard let ptr, count > 0 else { return [] }
        return UnsafeBufferPointer(start: ptr, count: count).map { p in
            VTImagePlacement(
                key: .init(id: p.image_id, generation: p.image_generation),
                layer: .init(zIndex: p.z_index),
                pixelWidth: Int(p.image_width),
                pixelHeight: Int(p.image_height),
                clip: SIMD4(p.clip_x, p.clip_y, p.clip_width, p.clip_height),
                image: SIMD4(p.image_x, p.image_y, p.image_draw_width, p.image_draw_height)
            )
        }
    }

    /// The pixels of an image from the last `imagePlacements` call.
    public func imagePixels(_ key: VTImagePlacement.Key) throws(VTError) -> VTImagePixels {
        var format: UInt32 = 0
        let bytes = try takeBytes("image_data(\(key.id), generation \(key.generation))") {
            termy_engine_image_data(handle, key.id, key.generation, &format, $0)
        }
        switch Int32(format) {
        case TERMY_ENGINE_IMAGE_RGBA: return .rgba(bytes)
        case TERMY_ENGINE_IMAGE_PNG: return .png(bytes)
        default: throw VTError(operation: "image_data returned unknown format \(format)", code: TERMY_ENGINE_INVALID_ARGUMENT.rawValue)
        }
    }
}
