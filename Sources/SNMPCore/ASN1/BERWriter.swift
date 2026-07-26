import Foundation

/// Incremental BER encoder.
///
/// Constructed values are built by encoding the children into a nested
/// writer and wrapping the result — SNMP messages are small enough that
/// the extra copy is irrelevant next to the clarity it buys.
public struct BERWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public var data: Data { Data(bytes) }

    // MARK: - Primitives

    /// Appends a tag/length/value triple with a caller-supplied payload.
    public mutating func append(tag: UInt8, content: [UInt8]) {
        bytes.append(tag)
        bytes.append(contentsOf: Self.encodeLength(content.count))
        bytes.append(contentsOf: content)
    }

    public mutating func append(tag: ASN1Tag, content: [UInt8]) {
        append(tag: tag.rawValue, content: content)
    }

    public mutating func appendNull() {
        append(tag: .null, content: [])
    }

    public mutating func appendOctetString(_ value: [UInt8]) {
        append(tag: .octetString, content: value)
    }

    public mutating func appendOctetString(_ value: String) {
        append(tag: .octetString, content: Array(value.utf8))
    }

    /// Encodes a signed INTEGER in minimal two's-complement form.
    public mutating func appendInteger(_ value: Int64, tag: ASN1Tag = .integer) {
        append(tag: tag, content: Self.encodeSignedInteger(value))
    }

    /// Encodes an unsigned application type (Counter32/Gauge32/TimeTicks/Counter64).
    ///
    /// BER integers are signed, so a value with the high bit set needs a
    /// leading zero octet to keep it from being read back as negative.
    public mutating func appendUnsigned(_ value: UInt64, tag: ASN1Tag) {
        append(tag: tag, content: Self.encodeUnsignedInteger(value))
    }

    public mutating func appendOID(_ oid: OID) {
        append(tag: .objectIdentifier, content: Self.encodeOID(oid.nodes))
    }

    /// Wraps whatever `body` writes in a constructed tag.
    public mutating func appendConstructed(tag: ASN1Tag, _ body: (inout BERWriter) -> Void) {
        var inner = BERWriter()
        body(&inner)
        append(tag: tag, content: inner.bytes)
    }

    public mutating func appendConstructed(tag: UInt8, _ body: (inout BERWriter) -> Void) {
        var inner = BERWriter()
        body(&inner)
        append(tag: tag, content: inner.bytes)
    }

    public mutating func appendRaw(_ raw: [UInt8]) {
        bytes.append(contentsOf: raw)
    }

    // MARK: - Static encoders

    /// Definite-length form: short (< 128) or long with a leading count byte.
    public static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var lengthBytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            lengthBytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(lengthBytes.count)] + lengthBytes
    }

    public static func encodeSignedInteger(_ value: Int64) -> [UInt8] {
        if value == 0 { return [0x00] }
        var result: [UInt8] = []
        var remaining = value
        // Stop once the remaining bits are pure sign extension.
        while !(remaining == 0 && result.first.map { $0 & 0x80 == 0 } ?? false)
            && !(remaining == -1 && result.first.map { $0 & 0x80 != 0 } ?? false) {
            result.insert(UInt8(truncatingIfNeeded: remaining), at: 0)
            remaining >>= 8
        }
        return result
    }

    public static func encodeUnsignedInteger(_ value: UInt64) -> [UInt8] {
        if value == 0 { return [0x00] }
        var result: [UInt8] = []
        var remaining = value
        while remaining > 0 {
            result.insert(UInt8(truncatingIfNeeded: remaining), at: 0)
            remaining >>= 8
        }
        // Keep it from decoding as a negative signed integer.
        if result[0] & 0x80 != 0 { result.insert(0x00, at: 0) }
        return result
    }

    /// X.690 §8.19 — first two arcs pack into one octet, the rest are base-128.
    public static func encodeOID(_ nodes: [UInt32]) -> [UInt8] {
        guard nodes.count >= 2 else { return [] }
        var out: [UInt8] = [UInt8(nodes[0] * 40 + nodes[1])]
        for node in nodes.dropFirst(2) {
            out.append(contentsOf: encodeBase128(node))
        }
        return out
    }

    static func encodeBase128(_ value: UInt32) -> [UInt8] {
        if value == 0 { return [0x00] }
        var chunks: [UInt8] = []
        var remaining = value
        while remaining > 0 {
            chunks.insert(UInt8(remaining & 0x7F), at: 0)
            remaining >>= 7
        }
        // Continuation bit on every octet but the last.
        for index in 0..<(chunks.count - 1) { chunks[index] |= 0x80 }
        return chunks
    }
}
