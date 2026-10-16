import CoreGraphics
import ImageIO
import Metal
import DenVT

/// Textures for one terminal's kitty images, by the key that names their
/// pixels, so an image uploads once however often it's drawn. Images not
/// drawn in a frame are dropped once the cache is over its byte budget.
@MainActor
final class ImageTextures {
    private struct Entry {
        /// Nil when the image couldn't be turned into a texture; kept so a
        /// broken image fails once, not every frame.
        let texture: MTLTexture?
        let bytes: Int
        var frame: UInt64
    }

    /// Past this, images the last frame didn't draw are released.
    static let budgetBytes = 256 * 1024 * 1024
    /// Metal's largest 2D texture on every Mac Den supports; bigger images
    /// are scaled down to fit, and they're drawn smaller than that anyway.
    static let maxDimension = 16384

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var entries: [VTImagePlacement.Key: Entry] = [:]
    private var bytes = 0
    private var frame: UInt64 = 0
    /// Image ids are per terminal: another terminal starts the cache over.
    private weak var terminal: VTTerminal?

    init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
    }

    /// Call once per drawn frame, before `texture(for:in:)`.
    func beginFrame(_ terminal: VTTerminal) {
        frame &+= 1
        if terminal !== self.terminal {
            entries.removeAll()
            bytes = 0
            self.terminal = terminal
        }
    }

    func texture(for placement: VTImagePlacement, in terminal: VTTerminal) -> MTLTexture? {
        if let entry = entries[placement.key] {
            entries[placement.key]?.frame = frame
            return entry.texture
        }
        let texture: MTLTexture?
        do {
            texture = try makeTexture(try terminal.imagePixels(placement.key), width: placement.pixelWidth, height: placement.pixelHeight)
        } catch {
            NSLog("Den: kitty image \(placement.key.id) can't be drawn and is skipped: \(error)")
            texture = nil
        }
        let size = texture.map { $0.width * $0.height * 4 * 4 / 3 } ?? 0
        entries[placement.key] = Entry(texture: texture, bytes: size, frame: frame)
        bytes += size
        return texture
    }

    /// Releases images this frame didn't draw, if over budget.
    func endFrame() {
        guard bytes > Self.budgetBytes else { return }
        for (key, entry) in entries where entry.frame != frame {
            entries[key] = nil
            bytes -= entry.bytes
        }
    }

    private enum TextureError: Error, CustomStringConvertible {
        case undecodablePNG
        case wrongPixelCount(expected: Int, actual: Int)
        case allocation(width: Int, height: Int)

        var description: String {
            switch self {
            case .undecodablePNG: "the PNG data doesn't decode"
            case .wrongPixelCount(let expected, let actual): "expected \(expected) bytes of RGBA, got \(actual)"
            case .allocation(let width, let height): "couldn't allocate a \(width)x\(height) texture"
            }
        }
    }

    private func makeTexture(_ pixels: VTImagePixels, width: Int, height: Int) throws -> MTLTexture {
        let image: CGImage
        switch pixels {
        case .png(let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw TextureError.undecodablePNG }
            image = decoded
        case .rgba(let data):
            guard data.count == width * height * 4 else { throw TextureError.wrongPixelCount(expected: width * height * 4, actual: data.count) }
            guard let provider = CGDataProvider(data: data as CFData),
                  let decoded = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { throw TextureError.allocation(width: width, height: height) }
            image = decoded
        }

        // Redrawn into premultiplied RGBA, the format the shader blends.
        let fit = min(1, Double(Self.maxDimension) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * fit)), h = max(1, Int(Double(image.height) * fit))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { throw TextureError.allocation(width: w, height: h) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw TextureError.allocation(width: w, height: h) }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        if texture.mipmapLevelCount > 1, let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
        }
        return texture
    }
}
