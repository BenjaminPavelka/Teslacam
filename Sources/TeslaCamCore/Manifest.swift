import Foundation

/// Záznam o každém zpracovaném souboru, uložený v cílové složce
/// (`.tesla-preview/manifest.json`). Podle něj se později rozhoduje, co je
/// bezpečně odemčené a smí se smazat ze zdroje.
public struct Manifest: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case unlocked, copied, incomplete, locked, failed
    }

    public struct Entry: Codable, Sendable {
        public var status: Status
        public var sourcePath: String
        public var sourceSize: UInt64
        public var outputSize: UInt64?
        public var remuxed: Bool?
        public var reason: String?
        public var updated: Date
        /// Otisk šifrované hlavičky (unikátní wrapped key). Podle něj se pozná stejný
        /// originál i v jiné složce, třeba na flashce, ze které se kopírovalo.
        public var fingerprint: String?
    }

    public var version = 1
    /// Klíčem je relativní cesta ve výstupu.
    public var entries: [String: Entry] = [:]

    public static func url(in destination: URL) -> URL {
        destination.appendingPathComponent(".tesla-preview/manifest.json")
    }

    public static func load(from destination: URL) -> Manifest {
        guard let data = try? Data(contentsOf: url(in: destination)) else { return Manifest() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Manifest.self, from: data)) ?? Manifest()
    }

    public func save(to destination: URL) throws {
        let target = Self.url(in: destination)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: target, options: .atomic)
    }
}

/// Soubory, které uživatel z odemčené složky smazal (relativní cesty). Další odemykání
/// je neobnoví a úklid zdroje smí smazat i jejich originály.
public struct DeletedLog: Codable, Sendable {
    public var version = 1
    public var paths: [String: Date] = [:]

    public init() {}

    public static func url(in destination: URL) -> URL {
        destination.appendingPathComponent(".tesla-preview/deleted.json")
    }

    public static func load(from destination: URL) -> DeletedLog {
        guard let data = try? Data(contentsOf: url(in: destination)) else { return DeletedLog() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(DeletedLog.self, from: data)) ?? DeletedLog()
    }

    public func save(to destination: URL) throws {
        let target = Self.url(in: destination)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: target, options: .atomic)
    }
}

/// Souběžně zapisovaný manifest; na disk se ukládá průběžně po dávkách.
actor ManifestStore {
    private var manifest: Manifest
    private let destination: URL
    private var unsaved = 0

    init(destination: URL) {
        self.destination = destination
        manifest = Manifest.load(from: destination)
    }

    func record(_ path: String, _ entry: Manifest.Entry) {
        manifest.entries[path] = entry
        unsaved += 1
        if unsaved >= 25 { flush() }
    }

    func flush() {
        guard unsaved > 0 else { return }
        try? manifest.save(to: destination)
        unsaved = 0
    }
}
