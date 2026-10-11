import Foundation

/// Length-prefixed framing: `u32 little-endian length` followed by `length`
/// payload bytes.
public enum Frame {
    /// Upper bound for a single frame. Snapshots with deep scrollback are the
    /// largest messages; anything beyond this is treated as a corrupt stream.
    public static let maxPayload = 256 * 1024 * 1024

    public static func wrap(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 4)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

public enum FrameError: Error, Equatable, Sendable {
    case oversized(length: Int, limit: Int)
}

/// Incrementally splits a byte stream into frame payloads.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) { buffer.append(bytes) }

    /// Returns the next complete payload, nil when more bytes are needed.
    public mutating func next() throws(FrameError) -> Data? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        var length: UInt32 = 0
        withUnsafeMutableBytes(of: &length) { $0.copyBytes(from: buffer[start ..< start + 4]) }
        let size = Int(UInt32(littleEndian: length))
        guard size <= Frame.maxPayload else { throw .oversized(length: size, limit: Frame.maxPayload) }
        guard buffer.count >= 4 + size else { return nil }
        let payload = Data(buffer[start + 4 ..< start + 4 + size])
        buffer.removeSubrange(start ..< start + 4 + size)
        return payload
    }
}
