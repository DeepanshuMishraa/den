import Foundation

/// Failure while decoding a wire value. Carries enough context to log which
/// field was malformed.
public enum DecodeError: Error, Equatable, Sendable {
    case truncated(needed: Int, available: Int, field: String)
    case invalidTag(UInt8, type: String)
    case invalidUTF8(field: String)
    case unsupportedVersion(UInt16)
}

/// Little-endian binary writer used for every message on the wire.
public struct BinaryWriter: Sendable {
    public private(set) var data = Data()

    public init() {}

    /// Starts with room for `Frame`'s length prefix, filled in by
    /// `finishFrame`, so a framed message is written once, not copied into
    /// a frame after encoding.
    init(framedCapacity: Int) {
        data.reserveCapacity(4 + framedCapacity)
        data.append(contentsOf: [0, 0, 0, 0])
    }

    /// The frame: length prefix plus everything written after it.
    consuming func finishFrame() -> Data {
        let length = UInt32(data.count - 4).littleEndian
        withUnsafeBytes(of: length) { data.replaceSubrange(data.startIndex ..< data.startIndex + 4, with: $0) }
        return data
    }

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func bool(_ v: Bool) { u8(v ? 1 : 0) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }

    public mutating func bytes(_ v: Data) {
        u32(UInt32(v.count))
        data.append(v)
    }

    public mutating func string(_ v: String) { bytes(Data(v.utf8)) }

    public mutating func optionalString(_ v: String?) {
        bool(v != nil)
        if let v { string(v) }
    }

    public mutating func uuid(_ v: UUID) {
        withUnsafeBytes(of: v.uuid) { data.append(contentsOf: $0) }
    }
}

/// Little-endian binary reader. Every read is bounds-checked and reports the
/// field it was reading on failure.
public struct BinaryReader: Sendable {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var isAtEnd: Bool { offset >= data.endIndex }

    private mutating func take(_ count: Int, _ field: String) throws(DecodeError) -> Data {
        let available = data.endIndex - offset
        guard count <= available else {
            throw .truncated(needed: count, available: available, field: field)
        }
        let slice = data[offset ..< offset + count]
        offset += count
        return slice
    }

    private mutating func fixed<T: FixedWidthInteger>(_: T.Type, _ field: String) throws(DecodeError) -> T {
        let raw = try take(MemoryLayout<T>.size, field)
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: raw) }
        return T(littleEndian: value)
    }

    public mutating func u8(_ field: String) throws(DecodeError) -> UInt8 { try fixed(UInt8.self, field) }
    public mutating func bool(_ field: String) throws(DecodeError) -> Bool { try u8(field) != 0 }
    public mutating func u16(_ field: String) throws(DecodeError) -> UInt16 { try fixed(UInt16.self, field) }
    public mutating func u32(_ field: String) throws(DecodeError) -> UInt32 { try fixed(UInt32.self, field) }
    public mutating func i32(_ field: String) throws(DecodeError) -> Int32 { Int32(bitPattern: try u32(field)) }
    public mutating func u64(_ field: String) throws(DecodeError) -> UInt64 { try fixed(UInt64.self, field) }
    public mutating func f32(_ field: String) throws(DecodeError) -> Float { Float(bitPattern: try u32(field)) }

    public mutating func bytes(_ field: String) throws(DecodeError) -> Data {
        let count = Int(try u32(field))
        return Data(try take(count, field))
    }

    public mutating func string(_ field: String) throws(DecodeError) -> String {
        let raw = try bytes(field)
        guard let s = String(data: raw, encoding: .utf8) else { throw .invalidUTF8(field: field) }
        return s
    }

    public mutating func optionalString(_ field: String) throws(DecodeError) -> String? {
        try bool(field) ? try string(field) : nil
    }

    public mutating func uuid(_ field: String) throws(DecodeError) -> UUID {
        let raw = try take(16, field)
        var tuple: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &tuple) { $0.copyBytes(from: raw) }
        return UUID(uuid: tuple)
    }
}
