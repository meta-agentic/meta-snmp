import Foundation

/// An SNMP object identifier.
///
/// Named `OID` rather than `ObjectIdentifier` to avoid colliding with the
/// standard library type of that name.
///
/// Ordering is lexicographic over the sub-identifiers, which is exactly the
/// order an agent walks its MIB in — so `<` is the walk-termination test.
public struct OID: Sendable, Hashable {
    public let nodes: [UInt32]

    /// - Throws: `SNMPError.invalidOID` if the arc sequence isn't a legal OID.
    public init(nodes: [UInt32]) throws {
        guard nodes.count >= 2 else {
            throw SNMPError.invalidOID("an OID needs at least two arcs")
        }
        guard nodes[0] <= 2 else {
            throw SNMPError.invalidOID("first arc must be 0, 1 or 2 — got \(nodes[0])")
        }
        // Arcs under 0 and 1 are packed into one octet as 40*arc0+arc1, so
        // arc1 has to stay below 40 for the encoding to round-trip.
        guard nodes[0] == 2 || nodes[1] < 40 else {
            throw SNMPError.invalidOID("second arc must be < 40 when the first is \(nodes[0])")
        }
        self.nodes = nodes
    }

    /// Parses dotted-decimal form, with or without a leading dot.
    public init(_ string: String) throws {
        let trimmed = string.hasPrefix(".") ? String(string.dropFirst()) : string
        guard !trimmed.isEmpty else { throw SNMPError.invalidOID("empty OID string") }
        var parsed: [UInt32] = []
        for component in trimmed.split(separator: ".") {
            guard let value = UInt32(component) else {
                throw SNMPError.invalidOID("'\(component)' is not a valid sub-identifier")
            }
            parsed.append(value)
        }
        try self.init(nodes: parsed)
    }

    public var description: String { nodes.map(String.init).joined(separator: ".") }

    /// True when `self` is the given OID or sits underneath it.
    public func isDescendant(of prefix: OID) -> Bool {
        guard nodes.count >= prefix.nodes.count else { return false }
        return Array(nodes.prefix(prefix.nodes.count)) == prefix.nodes
    }

    /// The OID extended by one arc — used to address a table instance.
    public func appending(_ node: UInt32) -> OID {
        // Safe by construction: a valid OID stays valid when extended.
        try! OID(nodes: nodes + [node])
    }
}

extension OID: Comparable {
    /// Lexicographic order — the order in which an agent walks the MIB.
    public static func < (lhs: OID, rhs: OID) -> Bool {
        for (left, right) in zip(lhs.nodes, rhs.nodes) where left != right {
            return left < right
        }
        return lhs.nodes.count < rhs.nodes.count
    }
}

extension OID: CustomStringConvertible {}

extension OID: ExpressibleByArrayLiteral {
    /// Literal form for known-good OIDs in source; traps on an invalid literal.
    public init(arrayLiteral elements: UInt32...) {
        try! self.init(nodes: elements)
    }
}
