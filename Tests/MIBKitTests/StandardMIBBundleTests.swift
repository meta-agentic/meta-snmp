import Foundation
import XCTest

@testable import MIBKit

/// The checks SNMP-24 asks to be mechanical rather than asserted in prose.
///
/// The set itself, and the reason each module is in it, are recorded in
/// `docs/bundled-mibs.md`; the licences are recorded in `NOTICE`.
final class StandardMIBBundleTests: XCTestCase {

    /// The candidate set from SNMP-24 AC1, plus the three additions ENTITY-MIB's
    /// IMPORTS force. Written out here so that adding or removing a file from the
    /// resource directory without recording the change fails the build.
    static let expectedModules: Set<String> = [
        "SNMPv2-SMI", "SNMPv2-TC", "SNMPv2-CONF", "SNMPv2-MIB", "SNMPv2-TM",
        "INET-ADDRESS-MIB", "IANAifType-MIB", "IANA-ADDRESS-FAMILY-NUMBERS-MIB",
        "IF-MIB", "IP-MIB", "TCP-MIB", "UDP-MIB", "HOST-RESOURCES-MIB",
        "ENTITY-MIB", "BRIDGE-MIB",
        "SNMP-FRAMEWORK-MIB", "UUID-TC-MIB", "IANA-ENTITY-MIB",
    ]

    // MARK: - AC1: the set is what it says it is

    func testBundleContainsExactlyTheRecordedSet() async throws {
        let names = Set(try await StandardMIBBundle.shared.moduleNames())
        XCTAssertEqual(
            names, Self.expectedModules,
            """
            The bundled module set differs from the set recorded in \
            docs/bundled-mibs.md. Additions and removals must be recorded with a \
            reason (SNMP-24 AC1).
            """
        )
    }

    // MARK: - AC2: RFC1213-MIB is not bundled

    func testRFC1213MIBIsNotBundled() async throws {
        let names = try await StandardMIBBundle.shared.moduleNames()
        XCTAssertFalse(
            names.contains("RFC1213-MIB"),
            """
            RFC1213-MIB is SMIv1 and §5 states the parser will not compile it. \
            Bundling it ships a file the product rejects. Reversing this requires \
            citing a parser change that makes it compile (SNMP-24 AC2).
            """
        )
    }

    // MARK: - AC3: every bundled file is licence-recorded

    func testEveryBundledFileIsListedInNOTICE() async throws {
        let notice = try String(contentsOf: Self.repositoryRoot.appending(path: "NOTICE"), encoding: .utf8)
        // Entries read "- <file>.mib — <source> — <terms>". The source may wrap
        // onto the next line, so only the filename is matched.
        let entry = /(?m)^- ([A-Za-z0-9._-]+)\.mib +—/
        let listed = Set(notice.matches(of: entry).map { String($0.1) })
        let bundled = Set(try await StandardMIBBundle.shared.moduleNames())

        XCTAssertTrue(
            bundled.subtracting(listed).isEmpty,
            """
            Bundled but absent from NOTICE: \(bundled.subtracting(listed).sorted()). \
            C-9 requires each bundled file's licence to be confirmed and recorded \
            before it is bundled.
            """
        )
        XCTAssertTrue(
            listed.subtracting(bundled).isEmpty,
            """
            Listed in NOTICE but not bundled: \(listed.subtracting(bundled).sorted()). \
            A stale NOTICE entry misrepresents what the product ships.
            """
        )
    }

    // MARK: - AC5 (the half that does not need the parser): IMPORTS are closed

    func testImportsResolveEntirelyWithinTheBundle() async throws {
        let bundle = StandardMIBBundle.shared
        let names = Set(try await bundle.moduleNames())
        var unresolved: [String] = []

        for module in names.sorted() {
            let source = try await bundle.source(of: module)
            for imported in Self.importedModules(in: source) where !names.contains(imported) {
                unresolved.append("\(module) imports from \(imported)")
            }
        }

        XCTAssertEqual(
            unresolved, [],
            """
            No bundled module may depend on a module the user has to supply \
            (SNMP-24 AC5).
            """
        )
    }

    // MARK: - AC7: the set is read lazily, not at launch

    func testNoModuleIsReadUntilItIsAskedFor() async throws {
        let bundle = StandardMIBBundle()

        var loaded = await bundle.loadedModuleCount
        XCTAssertEqual(loaded, 0, "Constructing the bundle must not read a module.")

        let names = try await bundle.moduleNames()
        XCTAssertEqual(names.count, Self.expectedModules.count)
        loaded = await bundle.loadedModuleCount
        XCTAssertEqual(
            loaded, 0,
            """
            Enumerating the set must stay a directory listing. Reading every module \
            here would make launch time depend on how many modules are present, \
            which is exactly what NFR-7 forbids.
            """
        )

        _ = try await bundle.source(of: "IF-MIB")
        loaded = await bundle.loadedModuleCount
        XCTAssertEqual(loaded, 1, "Asking for one module must read one module, not the set.")

        _ = try await bundle.source(of: "IF-MIB")
        loaded = await bundle.loadedModuleCount
        XCTAssertEqual(loaded, 1, "A second request for the same module must be served from cache.")
    }

    // MARK: - AC8: the resource is readable from the bundle

    func testEveryBundledModuleIsReadableAndWellFormed() async throws {
        let bundle = StandardMIBBundle.shared
        for module in try await bundle.moduleNames() {
            let source = try await bundle.source(of: module)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

            XCTAssertEqual(
                lines.first.map(String.init), "\(module) DEFINITIONS ::= BEGIN",
                "\(module) does not open with its own DEFINITIONS header."
            )
            XCTAssertEqual(
                lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                    .map { $0.trimmingCharacters(in: .whitespaces) },
                "END",
                "\(module) does not close with END."
            )
            XCTAssertFalse(
                source.contains("\u{0C}"),
                "\(module) contains a form feed — RFC page-break residue."
            )
            XCTAssertNil(
                source.range(of: #"\[Page \d+\]"#, options: .regularExpression),
                "\(module) contains an RFC page footer."
            )
            XCTAssertNil(
                source.range(of: #"(?m)^RFC \d+\s+.*(19|20)\d\d\s*$"#, options: .regularExpression),
                "\(module) contains an RFC running header."
            )
        }
    }

    func testUnknownModuleIsReportedByName() async throws {
        do {
            _ = try await StandardMIBBundle.shared.source(of: "NOT-A-MIB")
            XCTFail("Expected a failure for an unknown module.")
        } catch let failure as StandardMIBBundle.Failure {
            XCTAssertEqual(failure, .unknownModule("NOT-A-MIB"))
        }
    }

    // MARK: - Helpers

    /// Walks up from this source file to the package root. Test-only: the NOTICE
    /// file is a repository artefact, not a bundled resource.
    static let repositoryRoot: URL = {
        URL(filePath: #filePath)  // Tests/MIBKitTests/StandardMIBBundleTests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    /// The module names appearing after `FROM` in a module's `IMPORTS` clause.
    static func importedModules(in source: String) -> [String] {
        guard let importsRange = source.range(of: #"(?m)^\s*IMPORTS\b"#, options: .regularExpression),
            let terminator = source.range(of: ";", range: importsRange.upperBound..<source.endIndex)
        else { return [] }

        let clause = source[importsRange.upperBound..<terminator.lowerBound]
        var modules: [String] = []
        var search = clause.startIndex
        while let from = clause.range(of: #"\bFROM\s+"#, options: .regularExpression, range: search..<clause.endIndex) {
            let rest = clause[from.upperBound...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
            if !name.isEmpty { modules.append(String(name)) }
            search = from.upperBound
        }
        return modules
    }
}
