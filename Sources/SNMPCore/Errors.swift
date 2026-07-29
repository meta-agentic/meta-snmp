import Foundation

/// Every failure the engine can report.
///
/// Decoder input is untrusted network data, so the codec throws these rather
/// than trapping — a malformed packet must never take the app down.
public enum SNMPError: Error, Sendable, Equatable {
    /// The bytes are not well-formed BER, or not well-formed for SNMP.
    case malformedMessage(String)
    /// A TLV carried a tag the grammar doesn't allow at that position.
    case unexpectedTag(expected: UInt8, actual: UInt8)
    /// An arc sequence or dotted string isn't a legal object identifier.
    case invalidOID(String)
}

extension SNMPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedMessage(let detail):
            "Malformed SNMP message: \(detail)."
        case .unexpectedTag(let expected, let actual):
            "Expected ASN.1 tag 0x\(hex(expected)) but found 0x\(hex(actual))."
        case .invalidOID(let detail):
            "Invalid object identifier: \(detail)."
        }
    }

    private func hex(_ byte: UInt8) -> String {
        String(byte, radix: 16, uppercase: true).leftPadded(to: 2, with: "0")
    }
}

private extension String {
    func leftPadded(to width: Int, with pad: Character) -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
    }
}
