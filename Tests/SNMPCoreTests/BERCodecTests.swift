import XCTest

@testable import SNMPCore

final class BERCodecTests: XCTestCase {

    // MARK: - Length

    func testShortFormLength() {
        XCTAssertEqual(BERWriter.encodeLength(0), [0x00])
        XCTAssertEqual(BERWriter.encodeLength(127), [0x7F])
    }

    func testLongFormLength() {
        // 128 needs the long form even though it fits in one octet.
        XCTAssertEqual(BERWriter.encodeLength(128), [0x81, 0x80])
        XCTAssertEqual(BERWriter.encodeLength(256), [0x82, 0x01, 0x00])
        XCTAssertEqual(BERWriter.encodeLength(65_535), [0x82, 0xFF, 0xFF])
    }

    func testLengthRoundTrip() throws {
        for length in [0, 1, 127, 128, 255, 256, 4096, 100_000] {
            var reader = BERReader(BERWriter.encodeLength(length))
            XCTAssertEqual(try reader.readLength(), length, "length \(length)")
        }
    }

    // MARK: - Integers

    func testSignedIntegerEncoding() {
        XCTAssertEqual(BERWriter.encodeSignedInteger(0), [0x00])
        XCTAssertEqual(BERWriter.encodeSignedInteger(127), [0x7F])
        // 128 takes a leading zero so it doesn't read back as -128.
        XCTAssertEqual(BERWriter.encodeSignedInteger(128), [0x00, 0x80])
        XCTAssertEqual(BERWriter.encodeSignedInteger(-1), [0xFF])
        XCTAssertEqual(BERWriter.encodeSignedInteger(-128), [0x80])
        XCTAssertEqual(BERWriter.encodeSignedInteger(-129), [0xFF, 0x7F])
    }

    func testSignedIntegerRoundTrip() throws {
        let values: [Int64] = [0, 1, -1, 127, 128, -128, -129, 32_767, -32_768,
                               2_147_483_647, -2_147_483_648, Int64.max, Int64.min]
        for value in values {
            var writer = BERWriter()
            writer.appendInteger(value)
            var reader = BERReader(writer.bytes)
            XCTAssertEqual(try reader.readInteger(), value, "value \(value)")
        }
    }

    /// A Gauge32 above 2^31 must not come back negative — the classic
    /// signed/unsigned bug in hand-rolled SNMP codecs.
    func testUnsignedHighBitDoesNotDecodeAsNegative() throws {
        let value: UInt64 = 4_294_967_295  // UInt32.max
        var writer = BERWriter()
        writer.appendUnsigned(value, tag: .gauge32)

        var reader = BERReader(writer.bytes)
        let (tag, content) = try reader.readTLV()
        XCTAssertEqual(tag, ASN1Tag.gauge32.rawValue)
        XCTAssertEqual(try BERReader.decodeUnsignedInteger(content.contentBytes), value)
    }

    func testCounter64RoundTrip() throws {
        for value: UInt64 in [0, 1, 255, 256, UInt64(UInt32.max), UInt64.max] {
            var writer = BERWriter()
            writer.appendUnsigned(value, tag: .counter64)
            var reader = BERReader(writer.bytes)
            let (_, content) = try reader.readTLV()
            XCTAssertEqual(try BERReader.decodeUnsignedInteger(content.contentBytes), value,
                           "value \(value)")
        }
    }

    // MARK: - Octet strings and null

    func testOctetStringRoundTrip() throws {
        var writer = BERWriter()
        writer.appendOctetString("public")
        var reader = BERReader(writer.bytes)
        XCTAssertEqual(try reader.readOctetString(), Array("public".utf8))
    }

    func testEmptyOctetStringRoundTrip() throws {
        var writer = BERWriter()
        writer.appendOctetString([])
        var reader = BERReader(writer.bytes)
        XCTAssertEqual(try reader.readOctetString(), [])
    }

    func testNullRoundTrip() throws {
        var writer = BERWriter()
        writer.appendNull()
        XCTAssertEqual(writer.bytes, [0x05, 0x00])
        var reader = BERReader(writer.bytes)
        XCTAssertNoThrow(try reader.readNull())
    }

    // MARK: - OIDs

    /// 1.3.6.1.2.1.1.1.0 (sysDescr.0) — the canonical worked example.
    func testKnownOIDEncoding() {
        let encoded = BERWriter.encodeOID([1, 3, 6, 1, 2, 1, 1, 1, 0])
        XCTAssertEqual(encoded, [0x2B, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00])
    }

    func testMultiByteSubIdentifier() throws {
        // 1.3.6.1.4.1.9 — arc 311 crosses the 128 boundary.
        let nodes: [UInt32] = [1, 3, 6, 1, 4, 1, 311]
        let encoded = BERWriter.encodeOID(nodes)
        XCTAssertEqual(encoded.suffix(2), [0x82, 0x37])
        XCTAssertEqual(try BERReader.decodeOID(encoded), nodes)
    }

    func testOIDRoundTripIncludingLargeArcs() throws {
        let cases: [[UInt32]] = [
            [0, 0],
            [1, 3, 6, 1],
            [2, 100, 3],
            [1, 3, 6, 1, 4, 1, 4_294_967_295],
        ]
        for nodes in cases {
            XCTAssertEqual(try BERReader.decodeOID(BERWriter.encodeOID(nodes)), nodes,
                           "nodes \(nodes)")
        }
    }

    func testOIDOrderingIsLexicographic() throws {
        // A walk terminates on the first OID that isn't greater than the last,
        // so this ordering has to be right.
        XCTAssertLessThan(try OID("1.3.6.1.2.1.1.1"), try OID("1.3.6.1.2.1.1.2"))
        XCTAssertLessThan(try OID("1.3.6.1.2.1.1"), try OID("1.3.6.1.2.1.1.0"))
        XCTAssertLessThan(try OID("1.3.6.1.2.1.9"), try OID("1.3.6.1.2.1.10"))
    }

    func testOIDDescendantCheck() throws {
        let subtree = try OID("1.3.6.1.2.1.2.2")
        XCTAssertTrue(try OID("1.3.6.1.2.1.2.2.1.10.3").isDescendant(of: subtree))
        XCTAssertTrue(subtree.isDescendant(of: subtree))
        XCTAssertFalse(try OID("1.3.6.1.2.1.2.3").isDescendant(of: subtree))
        XCTAssertFalse(try OID("1.3.6.1.2").isDescendant(of: subtree))
    }

    func testInvalidOIDsAreRejected() {
        XCTAssertThrowsError(try OID("1"))              // too few arcs
        XCTAssertThrowsError(try OID("3.1.1"))          // first arc > 2
        XCTAssertThrowsError(try OID("1.40.1"))         // second arc >= 40 under arc 1
        XCTAssertThrowsError(try OID(""))               // empty
        XCTAssertThrowsError(try OID("1.3.six.1"))      // non-numeric
    }

    // MARK: - Constructed values

    func testConstructedSequenceRoundTrip() throws {
        var writer = BERWriter()
        writer.appendConstructed(tag: .sequence) { inner in
            inner.appendInteger(1)
            inner.appendOctetString("public")
        }

        var reader = BERReader(writer.bytes)
        var sequence = try reader.readTLV(expecting: .sequence)
        XCTAssertEqual(try sequence.readInteger(), 1)
        XCTAssertEqual(try sequence.readOctetString(), Array("public".utf8))
        XCTAssertTrue(sequence.isAtEnd)
    }

    /// A nested value must not be able to read past its parent's bounds.
    func testScopedReaderCannotOverrun() throws {
        var writer = BERWriter()
        writer.appendConstructed(tag: .sequence) { $0.appendInteger(42) }
        writer.appendInteger(99)  // sibling, outside the sequence

        var reader = BERReader(writer.bytes)
        var sequence = try reader.readTLV(expecting: .sequence)
        XCTAssertEqual(try sequence.readInteger(), 42)
        XCTAssertTrue(sequence.isAtEnd)
        XCTAssertThrowsError(try sequence.readInteger())

        // The outer reader still sees the sibling.
        XCTAssertEqual(try reader.readInteger(), 99)
    }

    // MARK: - Malformed input

    func testTruncatedValueThrows() {
        // Claims 8 content bytes, supplies 2.
        var reader = BERReader([0x04, 0x08, 0x01, 0x02])
        XCTAssertThrowsError(try reader.readTLV())
    }

    func testIndefiniteLengthIsRejected() {
        var reader = BERReader([0x30, 0x80, 0x00, 0x00])
        XCTAssertThrowsError(try reader.readTLV())
    }

    func testOversizedLengthFieldIsRejected() {
        // Starts at the length octet, not the tag: 0x89 declares nine length
        // bytes. Fed the tag first, this read the short form and never reached
        // the guard it names.
        var reader = BERReader([0x89] + [UInt8](repeating: 0xFF, count: 9))
        XCTAssertThrowsError(try reader.readLength())
    }

    /// The `count == 8` boundary specifically. Eight 0xFF length octets sit
    /// inside the `count <= 8` guard and used to wrap to -1.
    func testEightByteLengthFieldIsRejected() {
        var reader = BERReader([0x88] + [UInt8](repeating: 0xFF, count: 8))
        XCTAssertThrowsError(try reader.readLength())
    }

    /// The same length reached the way an attacker reaches it: through a TLV.
    func testEightByteLengthIsRejectedThroughReadTLV() {
        var reader = BERReader([0x04, 0x88] + [UInt8](repeating: 0xFF, count: 8))
        XCTAssertThrowsError(try reader.readTLV())
        XCTAssertGreaterThanOrEqual(reader.offset, 0)
    }

    /// 0x80 followed by seven zeros is Int.min — the most hostile of the
    /// eight-octet encodings, and the one that drives the cursor furthest back.
    func testMostNegativeLengthIsRejected() {
        var reader = BERReader([0x04, 0x88, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try reader.readTLV())
        XCTAssertGreaterThanOrEqual(reader.offset, 0)
    }

    /// No length field of any width may decode to a negative number.
    func testReadLengthIsNeverNegative() {
        let octets: [UInt8] = [0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF]
        for count in 1...8 {
            for filler in octets {
                for leading in octets {
                    var field: [UInt8] = [0x80 | UInt8(count), leading]
                    field += [UInt8](repeating: filler, count: count - 1)
                    var reader = BERReader(field)
                    guard let length = try? reader.readLength() else { continue }
                    XCTAssertGreaterThanOrEqual(
                        length, 0, "length field \(field) decoded to \(length)")
                }
            }
        }
    }

    /// Fuzz `readTLV` with attacker-shaped buffers: it must terminate, never
    /// trap, and never move the cursor backwards.
    func testReadTLVTerminatesAndNeverRewindsTheCursor() {
        var rng = SplitMix64(seed: 0x5EED_5EED_5EED_5EED)
        for _ in 0..<2_000 {
            let size = Int(rng.next() % 24) + 2
            var buffer = [UInt8]()
            for index in 0..<size {
                // Bias toward long-form length octets so the hostile paths are
                // actually reached instead of drowned out by short forms.
                buffer.append(index % 2 == 1 && rng.next() % 2 == 0
                    ? 0x80 | UInt8(rng.next() % 12)
                    : UInt8(rng.next() % 256))
            }

            var reader = BERReader(buffer)
            var previous = reader.offset
            var steps = 0
            while !reader.isAtEnd {
                guard (try? reader.readTLV()) != nil else { break }
                XCTAssertGreaterThan(
                    reader.offset, previous, "cursor did not advance over \(buffer)")
                previous = reader.offset
                steps += 1
                XCTAssertLessThanOrEqual(steps, buffer.count, "did not terminate over \(buffer)")
                if steps > buffer.count { break }
            }
        }
    }

    func testEmptyIntegerIsRejected() {
        XCTAssertThrowsError(try BERReader.decodeSignedInteger([]))
    }

    func testUnexpectedTagIsReported() {
        var reader = BERReader([0x04, 0x01, 0x00])  // OCTET STRING
        XCTAssertThrowsError(try reader.readTLV(expecting: .integer)) { error in
            guard case .unexpectedTag(let expected, let actual) = error as? SNMPError else {
                return XCTFail("expected .unexpectedTag, got \(error)")
            }
            XCTAssertEqual(expected, ASN1Tag.integer.rawValue)
            XCTAssertEqual(actual, ASN1Tag.octetString.rawValue)
        }
    }

    func testTruncatedOIDSubIdentifierIsRejected() {
        // Trailing octet has the continuation bit set with nothing following.
        XCTAssertThrowsError(try BERReader.decodeOID([0x2B, 0x82]))
    }

    func testEmptyOIDIsRejected() {
        XCTAssertThrowsError(try BERReader.decodeOID([]))
    }

    func testReadingPastEndThrows() {
        var reader = BERReader([UInt8]())
        XCTAssertThrowsError(try reader.readByte())
    }
}

/// Deterministic generator, so a fuzz failure is reproducible from the seed.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
