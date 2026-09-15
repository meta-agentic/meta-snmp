import Foundation

/// The standard MIB modules that ship inside the app bundle.
///
/// C-6 requires the app to work with no internet connectivity, so the standard
/// modules cannot be fetched on demand — they are a SwiftPM resource of this
/// target. `docs/bundled-mibs.md` records which modules ship and why; `NOTICE`
/// records each file's licence, as C-9 requires.
///
/// NFR-7 requires launch time to be independent of how many modules are present,
/// so nothing here reads a module until it is asked for. Enumerating the set is
/// a directory listing; `source(of:)` is the only thing that touches a file, and
/// it caches what it read. `loadedModuleCount` exposes how many modules have
/// actually been read, so the laziness is a property a test can assert rather
/// than a claim in a comment.
public actor StandardMIBBundle {
    /// The process-wide bundle. Creating it reads nothing.
    public static let shared = StandardMIBBundle()

    /// Subdirectory of the resource bundle holding the modules.
    static let resourceSubdirectory = "StandardMIBs"

    /// Filename extension of a bundled module.
    static let moduleExtension = "mib"

    /// Filename of the bundled copyright notice.
    static let noticeResource = "NOTICE"

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case resourceDirectoryMissing
        case unknownModule(String)
        case unreadable(module: String, reason: String)
        case noticeMissing

        public var description: String {
            switch self {
            case .resourceDirectoryMissing:
                return """
                    The bundled MIB resource directory is missing from the app bundle. \
                    This is a packaging fault, not a user error.
                    """
            case .unknownModule(let name):
                return "No bundled MIB module named '\(name)'."
            case .unreadable(let module, let reason):
                return "Bundled MIB module '\(module)' could not be read: \(reason)"
            case .noticeMissing:
                return """
                    The copyright notice is missing from the app bundle. This is a \
                    packaging fault: the bundled MIB modules may only be redistributed \
                    with their notice, so the product must not ship without it.
                    """
            }
        }
    }

    private let bundle: Bundle
    private var cache: [String: String] = [:]
    private var noticeCache: String?

    init(bundle: Bundle = .module) {
        self.bundle = bundle
    }

    /// Names of the bundled modules, without the file extension, sorted.
    ///
    /// This is a directory listing. It does not open any module.
    public func moduleNames() throws -> [String] {
        try moduleURLs().keys.sorted()
    }

    /// The MIB source text of one bundled module, read on first request.
    public func source(of module: String) throws -> String {
        if let cached = cache[module] { return cached }
        guard let url = try moduleURLs()[module] else {
            throw Failure.unknownModule(module)
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw Failure.unreadable(module: module, reason: error.localizedDescription)
        }
        cache[module] = text
        return text
    }

    /// The copyright notice covering every bundled module, read from the app
    /// bundle rather than from the repository.
    ///
    /// Most of the bundled modules carry no copyright line of their own, so the
    /// only grant they travel under is the RFC Full Copyright Statement, whose
    /// single condition is that the notice is included on all copies. That makes
    /// this file part of the product, not a repository artefact: a build that
    /// cannot find it here is one that must not ship.
    ///
    /// Read lazily and cached, like a module. Nothing reads it until the
    /// acknowledgements surface asks for it.
    public func notice() throws -> String {
        if let cached = noticeCache { return cached }
        guard let url = bundle.url(forResource: Self.noticeResource, withExtension: nil) else {
            throw Failure.noticeMissing
        }
        // Presence of the entry is not enough — it must have readable content.
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            throw Failure.noticeMissing
        }
        noticeCache = text
        return text
    }

    /// How many modules have had their source read so far.
    ///
    /// Zero until something asks for one. This is the observable form of NFR-7:
    /// a bundle that compiled its modules at launch could not report zero here.
    public var loadedModuleCount: Int { cache.count }

    private func moduleURLs() throws -> [String: URL] {
        guard
            let urls = bundle.urls(
                forResourcesWithExtension: Self.moduleExtension,
                subdirectory: Self.resourceSubdirectory
            ), !urls.isEmpty
        else {
            throw Failure.resourceDirectoryMissing
        }
        return Dictionary(
            uniqueKeysWithValues: urls.map { ($0.deletingPathExtension().lastPathComponent, $0) }
        )
    }
}
