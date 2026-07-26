import Foundation

/// SMIv2 MIB parsing, the OID registration tree, value formatting and
/// private-MIB import/export.
///
/// The module is scaffolded here; the lexer, parser and repository land in
/// their own changes.
public enum MIBKit {
    /// Semantic version of the MIB subsystem, surfaced in diagnostics.
    public static let version = "0.1.0"
}
