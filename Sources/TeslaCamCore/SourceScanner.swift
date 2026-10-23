import Foundation

public enum ClipCategory: String, CaseIterable, Codable, Sendable, Comparable {
    case saved = "SavedClips"
    case sentry = "SentryClips"
    case recent = "RecentClips"

    public var title: String {
        switch self {
        case .saved: "Uložené"
        case .sentry: "Sentry"
        case .recent: "Průběžné"
        }
    }

    public static func < (a: ClipCategory, b: ClipCategory) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

public struct SourceFile: Sendable, Identifiable {
    public enum Kind: Sendable {
        /// Šifrované video, které jde odemknout přes API.
        case encryptedVideo(ContainerHeader)
        /// Šifrované video bez metadat: auto ho nedopsalo (vytažená flashka).
        case incompleteVideo
        /// Šifrovaný `event.json` / `thumb.png`: Tesla k nim klíč nevydá.
        case lockedSidecar
        /// Nešifrovaný soubor, stačí zkopírovat.
        case plain
        /// Šifrovaný soubor s poškozenou hlavičkou.
        case damaged(ContainerError)
    }

    public var id: String { relativePath }
    public let url: URL
    /// Cesta ve výstupu, např. `SavedClips/2026-07-02_13-56-12/2026-07-02_13-56-12-front.mp4`.
    public let relativePath: String
    public let category: ClipCategory
    public let size: UInt64
    public let kind: Kind

    /// Kolik místa výsledek zabere.
    public var outputSize: UInt64 {
        if case .encryptedVideo(let h) = kind { return h.plaintextSize }
        return size
    }

    public var isVideo: Bool { url.pathExtension.lowercased() == "mp4" }
}

public struct ScanResult: Sendable {
    public let root: URL
    public let files: [SourceFile]
}

public enum SourceScanner {
    /// Soubory, které nikdy nezpracováváme.
    static func isIgnored(_ name: String) -> Bool {
        name.hasPrefix("._") || name.hasPrefix(".") || name.localizedCaseInsensitiveContains("README")
    }

    /// Projde `root` (TeslaCam, EncryptedClips, SavedClips, nebo i jedna událost)
    /// a zařadí každý soubor. Symlinky a jiné neobvyklé soubory přeskočí.
    public static func scan(root: URL, isCancelled: () -> Bool = { false }) throws -> ScanResult {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw CocoaError(.fileReadNoSuchFile) }

        let rootComponents = root.pathComponents
        var eventCategories: [String: ClipCategory] = [:]
        var files: [SourceFile] = []
        for case let url as URL in walker {
            if isCancelled() { throw CancellationError() }
            let name = url.lastPathComponent
            guard !isIgnored(name),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            // Enumerátor může vrátit /var místo /private/var; počty složek musí sedět s kořenem.
            let url = url.resolvingSymlinksInPath()
            guard let (category, rel) = outputPath(for: url.pathComponents, rootDepth: rootComponents.count)
                ?? looseOutputPath(for: url, rootDepth: rootComponents.count, cache: &eventCategories)
            else { continue }

            files.append(SourceFile(
                url: url, relativePath: rel, category: category,
                size: UInt64(values.fileSize ?? 0), kind: classify(url)
            ))
        }
        files.sort { $0.relativePath < $1.relativePath }
        return ScanResult(root: root, files: files)
    }

    /// Najde v cestě poslední `RecentClips/SavedClips/SentryClips` (smí to být i
    /// samotný kořen) a vrátí cestu od něj. `EncryptedClips` tak ve výstupu zmizí.
    static func outputPath(for components: [String], rootDepth: Int) -> (ClipCategory, String)? {
        let earliest = max(0, rootDepth - 1)
        for i in stride(from: components.count - 2, through: earliest, by: -1) {
            if let category = ClipCategory(rawValue: components[i]) {
                return (category, components[i...].joined(separator: "/"))
            }
        }
        return nil
    }

    /// Pro soubory mimo `SavedClips/SentryClips/RecentClips`, např. když je vybraná
    /// přímo složka události. Kategorii odhadne z `event.json` (Sentry podle důvodu
    /// uložení, jinak Uložené); samostatné minutové klipy bere jako Průběžné.
    static func looseOutputPath(for url: URL, rootDepth: Int, cache: inout [String: ClipCategory]) -> (ClipCategory, String)? {
        let components = url.pathComponents
        let name = components.last!
        let parentIndex = components.count - 2
        if parentIndex >= rootDepth - 1, isEventName(components[parentIndex]) {
            let folder = url.deletingLastPathComponent()
            let category = cache[folder.path] ?? eventCategory(folder)
            cache[folder.path] = category
            return (category, "\(category.rawValue)/\(components[parentIndex])/\(name)")
        }
        if parentIndex == rootDepth - 1, name.lowercased().hasSuffix(".mp4"), isEventName(String(name.prefix(19))) {
            return (.recent, "\(ClipCategory.recent.rawValue)/\(name)")
        }
        return nil
    }

    static func isEventName(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    static func eventCategory(_ folder: URL) -> ClipCategory {
        let url = folder.appendingPathComponent("event.json")
        guard let data = try? Data(contentsOf: url), !Container.hasSignature(data),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = json["reason"] as? String
        else { return .saved }
        return reason.lowercased().hasPrefix("sentry") ? .sentry : .saved
    }

    static func classify(_ url: URL) -> SourceFile.Kind {
        guard let reader = try? FileReader(url: url) else { return .damaged(.truncated) }
        guard Container.hasSignature(reader) else { return .plain }
        let isVideo = url.pathExtension.lowercased() == "mp4"
        do {
            return .encryptedVideo(try Container.readHeader(reader))
        } catch ContainerError.metadataMissing {
            return isVideo ? .incompleteVideo : .lockedSidecar
        } catch let error as ContainerError {
            return isVideo ? .damaged(error) : .lockedSidecar
        } catch {
            return .damaged(.truncated)
        }
    }
}
