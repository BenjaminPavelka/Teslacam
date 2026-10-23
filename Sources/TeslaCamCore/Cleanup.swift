import Foundation

/// Úklid: smazání označených událostí z odemčené složky a ověřených originálů ze zdroje.
/// Nic se nemaže samo; vždy jde nejdřív o plán, který uživatel vidí a potvrdí.
public enum Cleanup {
    public enum Method: Sendable {
        case trash
        case permanent
    }

    public struct Failure: Sendable, Identifiable {
        public var id: String { path }
        public var path: String
        public var message: String
    }

    public struct Result: Sendable {
        public var removed = 0
        public var bytes: UInt64 = 0
        public var failures: [Failure] = []
    }

    static func remove(_ url: URL, method: Method) throws {
        switch method {
        case .trash: try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        case .permanent: try FileManager.default.removeItem(at: url)
        }
    }

    static func fileSize(_ url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0)
    }

    static func relativePath(_ url: URL, root: URL) -> String? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }

    // MARK: - Označené události

    public struct EventItem: Sendable, Identifiable {
        public var id: String { event.id }
        public var event: LibraryEvent
        /// Co se přesune do Koše: složka události, u průběžných klipů jednotlivé soubory.
        public var targets: [URL]
        /// Všechny soubory, které tím zmizí.
        public var files: [URL]
        public var bytes: UInt64
    }

    public static func planEventTrash(_ events: [LibraryEvent], annotations: LibraryAnnotations) -> [EventItem] {
        events.filter { annotations[$0.id].decision == .delete }.map { event in
            var files: [URL]
            let targets: [URL]
            if let folder = event.folder {
                let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
                files = (walker?.allObjects as? [URL] ?? []).filter {
                    (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }
                targets = [folder]
            } else {
                files = event.allFiles
                targets = files
            }
            files.sort { $0.path < $1.path }
            return EventItem(event: event, targets: targets, files: files, bytes: files.reduce(0) { $0 + fileSize($1) })
        }
    }

    /// Přesune události do Koše, zapíše je do `deleted.json` (aby je odemykání neobnovilo),
    /// smaže jejich mezipaměť a označení.
    public static func trashEvents(_ items: [EventItem], root: URL, method: Method = .trash) -> Result {
        var result = Result()
        var deleted = DeletedLog.load(from: root)
        var annotations = LibraryAnnotations.load(from: root)
        let cache = EventCache(root: root)

        for item in items {
            let relative = item.files.compactMap { relativePath($0, root: root) }
            do {
                for target in item.targets where FileManager.default.fileExists(atPath: target.path) {
                    try remove(target, method: method)
                }
            } catch {
                result.failures.append(Failure(path: item.event.id, message: error.localizedDescription))
                continue
            }
            let now = Date()
            for path in relative { deleted.paths[path] = now }
            for url in [cache.indexURL(item.event), cache.telemetryURL(item.event), cache.thumbnailURL(item.event)] {
                try? FileManager.default.removeItem(at: url)
            }
            annotations.events[item.event.id] = nil
            result.removed += 1
            result.bytes += item.bytes
        }

        do {
            try deleted.save(to: root)
            try annotations.save(to: root)
        } catch {
            result.failures.append(Failure(path: ".tesla-preview", message: "Záznam o smazání se nepodařilo uložit: \(error.localizedDescription)"))
        }
        return result
    }

    // MARK: - Zdroj

    public struct SourceItem: Sendable, Identifiable {
        public enum Reason: Sendable {
            /// Odemčeno a výsledek ověřen.
            case verified
            /// Odemčeno a uživatel výsledek sám smazal.
            case deletedByUser
            /// Nešifrovaný soubor, zkopírovaná kopie ověřena.
            case copied
            /// Zamčený doplněk (event.json, thumb.png) události, jejíž videa se všechna mažou.
            case sidecar

            public var title: String {
                switch self {
                case .verified: "Odemčeno a ověřeno"
                case .deletedByUser: "Smazáno v knihovně"
                case .copied: "Zkopírováno a ověřeno"
                case .sidecar: "Zamčený doplněk události"
                }
            }
        }

        public var id: String { file.relativePath }
        public var file: SourceFile
        public var reason: Reason
    }

    public struct KeptItem: Sendable, Identifiable {
        public var id: String { file.relativePath }
        public var file: SourceFile
        public var why: String
    }

    public struct SourcePlan: Sendable {
        public var root: URL
        public var items: [SourceItem] = []
        public var kept: [KeptItem] = []
        public var bytes: UInt64 { items.reduce(0) { $0 + $1.file.size } }
    }

    /// Projde zdroj a rozhodne, co se smí smazat. Originál se smaže, jen když manifest
    /// odemykání vede stejný soubor (velikost a otisk hlavičky) jako úspěšně odemčený
    /// a odemčený výsledek je platné video, nebo ho uživatel v knihovně sám smazal.
    public static func planSource(
        scan: ScanResult, destination: URL, includePlain: Bool, isCancelled: () -> Bool = { false }
    ) -> SourcePlan {
        let manifest = Manifest.load(from: destination)
        let deleted = DeletedLog.load(from: destination)
        var plan = SourcePlan(root: scan.root)
        var sidecars: [SourceFile] = []

        for file in scan.files {
            if isCancelled() { break }
            let entry = manifest.entries[file.relativePath]
            let sameFile = entry.map { e in
                e.sourceSize == file.size
                    && (e.fingerprint.map { $0 == file.fingerprint } ?? (e.sourcePath == file.url.path))
            } ?? false
            let output = destination.appendingPathComponent(file.relativePath)
            let userDeleted = deleted.paths[file.relativePath] != nil

            func keep(_ why: String) { plan.kept.append(KeptItem(file: file, why: why)) }
            func take(_ reason: SourceItem.Reason) { plan.items.append(SourceItem(file: file, reason: reason)) }

            switch file.kind {
            case .encryptedVideo:
                guard let entry else { keep("Ještě není odemčený."); continue }
                guard sameFile else { keep("Liší se od souboru, který se odemykal."); continue }
                switch entry.status {
                case .unlocked:
                    if userDeleted { take(.deletedByUser) }
                    else if let problem = verifyOutput(output) { keep(problem) }
                    else { take(.verified) }
                case .failed: keep("Odemčení selhalo: \(entry.reason ?? "neznámý důvod").")
                default: keep("Není odemčený.")
                }
            case .plain:
                guard includePlain else { continue }
                guard let entry, entry.status == .copied, sameFile else { keep("Nešifrovaný soubor ještě není zkopírovaný."); continue }
                if userDeleted { take(.deletedByUser) }
                else if fileSize(output) == file.size { take(.copied) }
                else { keep("Zkopírovaný soubor chybí nebo má jinou velikost.") }
            case .incompleteVideo:
                keep("Nedopsaný klip, necháváme ho.")
            case .damaged(let error):
                keep(Messages.text(for: error))
            case .lockedSidecar:
                sidecars.append(file)
            }
        }

        // Doplňky se mažou jen se všemi videi své události.
        let taken = Set(plan.items.map(\.file.relativePath))
        let videosByFolder = Dictionary(grouping: scan.files.filter(\.isVideo)) { $0.url.deletingLastPathComponent().path }
        for sidecar in sidecars {
            let folder = sidecar.url.deletingLastPathComponent()
            let videos = videosByFolder[folder.path] ?? []
            if SourceScanner.isEventName(folder.lastPathComponent), !videos.isEmpty, videos.allSatisfy({ taken.contains($0.relativePath) }) {
                plan.items.append(SourceItem(file: sidecar, reason: .sidecar))
            }
        }
        plan.items.sort { $0.file.relativePath < $1.file.relativePath }
        plan.kept.sort { $0.file.relativePath < $1.file.relativePath }
        return plan
    }

    /// Ověří, že odemčený soubor existuje a je celé, čitelné video. Vrací důvod, proč ne.
    public static func verifyOutput(_ url: URL) -> String? {
        guard let reader = try? FileReader(url: url), reader.size > 0 else { return "Odemčený soubor chybí." }
        guard let head = try? reader.read(at: 0, count: 8), Container.looksLikeMP4(head) else {
            return "Odemčený soubor není platné video."
        }
        guard let track = try? MP4.videoTrack(reader, fileSize: reader.size), track.duration > 0,
              let last = track.samples.last, last.offset + UInt64(last.size) <= reader.size
        else { return "Odemčený soubor je poškozený nebo neúplný." }
        return nil
    }

    /// Smaže položky plánu. Prázdné složky událostí uklidí (i se soubory `._*` a README).
    public static func executeSource(
        _ plan: SourcePlan, method: Method, progress: (Int) -> Void = { _ in }
    ) -> Result {
        var result = Result()
        var folders = Set<URL>()
        for (i, item) in plan.items.enumerated() {
            // Pojistka: mažeme jen uvnitř zdroje a jen soubory, které se od plánu nezměnily.
            guard relativePath(item.file.url, root: plan.root) != nil, fileSize(item.file.url) == item.file.size else {
                result.failures.append(Failure(path: item.file.relativePath, message: "Soubor se mezitím změnil, nechali jsme ho být."))
                continue
            }
            do {
                try remove(item.file.url, method: method)
                result.removed += 1
                result.bytes += item.file.size
                folders.insert(item.file.url.deletingLastPathComponent())
            } catch {
                result.failures.append(Failure(path: item.file.relativePath, message: error.localizedDescription))
            }
            progress(i + 1)
        }

        let fm = FileManager.default
        for folder in folders where SourceScanner.isEventName(folder.lastPathComponent) {
            guard let rest = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
                  rest.allSatisfy({ isLeftover($0.lastPathComponent) })
            else { continue }
            for leftover in rest { try? remove(leftover, method: method) }
            try? remove(folder, method: method)
        }
        return result
    }

    static func isLeftover(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store" || name.localizedCaseInsensitiveContains("README")
    }
}
