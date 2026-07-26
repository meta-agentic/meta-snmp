import Foundation

/// Cursor-based BER decoder over a byte buffer.
///
/// Every read is bounds-checked and throws `SNMPError.malformedMessage`
/// rather than trapping — decoder input is untrusted network data.
public struct BERReader: Sendable {
    public let bytes: [UInt8]
    public private(set) var offset: Int
    private let end: Int

    public init(_ data: Data) {
        self.bytes = Array(data)
        self.offset = 0
        self.end = self.bytes.count
    }

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
        self.end = bytes.count
    }

    private init(bytes: [UInt8], offset: Int, end: Int) {
        self.bytes = bytes
        self.offset = offset
        self.end = end
    }

    public var isAtEnd: Bool { offset >= end }
    public var remaining: Int { max(0, end - offset) }

    // MARK: - Low level

    public mutating func readByte() throws -> UInt8 {
        guard offset < end else { throw SNMPError.malformedMessage("unexpected end of data") }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= end else {
            throw SNMPError.malformedMessage("truncated value of \(count) bytes")
        }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    /// Peeks the next identifier octet without consuming it.
    public func peekTag() throws -> UInt8 {
        guard offset < end else { throw SNMPError.malformedMessage("unexpected end of data") }
        return bytes[offset]
    }

    public mutating func readLength() throws -> Int {
        let first = try readByte()
        if first & 0x80 == 0 { return Int(first) }
        let count = Int(first & 0x7F)
        guard count > 0 else {
            throw SNMPError.malformedMessage("indefinite length is not permitted in SNMP")
        }
        guard count <= 8 else { throw SNMPError.malformedMessage("length field too large") }
        var value = 0
        for _ in 0..<count { value = (value << 8) | Int(try readByte()) }
        return value
    }

    /// Reads a TLV header and returns the tag plus a reader scoped to its content.
    public mutating func readTLV() throws -> (tag: UInt8, content: BERReader) {
        let tag = try readByte()
        let length = try readLength()
        guard offset + length <= end else {
            throw SNMPError.malformedMessage("value length \(length) exceeds buffer")
        }
        let scoped = BERReader(bytes: bytes, offset: offset, end: offset + length)
        offset += length
        return (tag, scoped)
    }

    /// Reads a TLV and asserts the tag, for the many places where only one is legal.
    public mutating func readTLV(expecting expected: ASN1Tag) throws -> BERReader {
        let (tag, content) = try readTLV()
        guard tag == expected.rawValue else {
            throw SNMPError.unexpectedTag(expected: expected.rawValue, actual: tag)
        }
        return content
    }

    // MARK: - Typed reads

    public mutating func readInteger() throws -> Int64 {
        let content = try readTLV(expecting: .integer)
        return try Self.decodeSignedInteger(content.contentBytes)
    }

    public mutating func readOctetString() throws -> [UInt8] {
        let content = try readTLV(expecting: .octetString)
        return content.contentBytes
    }

    public mutating func readOID() throws -> OID {
        let content = try readTLV(expecting: .objectIdentifier)
        return try OID(nodes: Self.decodeOID(content.contentBytes))
    }

    public mutating func readNull() throws {
        _ = try readTLV(expecting: .null)
    }

    /// All bytes from the cursor to this reader's scoped end.
    public var contentBytes: [UInt8] {
        guard offset < end else { return [] }
        return Array(bytes[offset..<end])
    }

    // MARK: - Static decoders

    public static func decodeSignedInteger(_ raw: [UInt8]) throws -> Int64 {
        guard !raw.isEmpty else { throw SNMPError.malformedMessage("empty INTEGER") }
        guard raw.count <= 9 else { throw SNMPError.malformedMessage("INTEGER too wide") }
        // Sign-extend from the first octet's high bit.
        var value: Int64 = (raw[0] & 0x80) != 0 ? -1 : 0
        for byte in raw { value = (value << 8) | Int64(byte) }
        return value
    }

    public static func decodeUnsignedInteger(_ raw: [UInt8]) throws -> UInt64 {
        guard !raw.isEmpty else { throw SNMPError.malformedMessage("empty unsigned integer") }
        // Agents legally emit a leading zero pad; anything wider is malformed.
        let significant = raw.first == 0x00 ? Array(raw.dropFirst()) : raw
        guard significant.count <= 8 else {
            throw SNMPError.malformedMessage("unsigned integer too wide")
        }
        var value: UInt64 = 0
        for byte in significant { value = (value << 8) | UInt64(byte) }
        return value
    }

    public static func decodeOID(_ raw: [UInt8]) throws -> [UInt32] {
        guard let first = raw.first else { throw SNMPError.malformedMessage("empty OID") }
        // The first octet packs arcs 1 and 2; arc 1 is capped at 2.
        var nodes: [UInt32] = first >= 80
            ? [2, UInt32(first) - 80]
            : [UInt32(first / 40), UInt32(first % 40)]

        var accumulator: UInt32 = 0
        var pending = false
        for byte in raw.dropFirst() {
            let (shifted, overflow) = accumulator.multipliedReportingOverflow(by: 128)
            guard !overflow else { throw SNMPError.malformedMessage("OID sub-identifier overflow") }
            accumulator = shifted | UInt32(byte & 0x7F)
            pending = true
            if byte & 0x80 == 0 {
                nodes.append(accumulator)
                accumulator = 0
                pending = false
            }
        }
        guard !pending else { throw SNMPError.malformedMessage("truncated OID sub-identifier") }
        return nodes
    }
}
