import Foundation

/// BER identifier octets used by SNMP (RFC 3416 / RFC 2578).
///
/// SNMP only ever uses low-tag-number, definite-length BER, so a single
/// byte identifier is sufficient — we never need multi-byte tag numbers.
public enum ASN1Tag: UInt8, Sendable, CaseIterable {
    // Universal
    case integer = 0x02
    case octetString = 0x04
    case null = 0x05
    case objectIdentifier = 0x06
    case sequence = 0x30

    // Application (RFC 2578 §7.1)
    case ipAddress = 0x40
    case counter32 = 0x41
    case gauge32 = 0x42
    case timeTicks = 0x43
    case opaque = 0x44
    case counter64 = 0x46

    // Context-specific exceptions in a VarBind (RFC 3416 §4.1)
    case noSuchObject = 0x80
    case noSuchInstance = 0x81
    case endOfMibView = 0x82

    // Context-specific constructed — the PDU types (RFC 3416 §3)
    case getRequest = 0xA0
    case getNextRequest = 0xA1
    case response = 0xA2
    case setRequest = 0xA3
    case trapV1 = 0xA4
    case getBulkRequest = 0xA5
    case informRequest = 0xA6
    case trapV2 = 0xA7
    case report = 0xA8

    /// True when the tag's constructed bit (0x20) is set.
    public var isConstructed: Bool { rawValue & 0x20 != 0 }
}
