import Foundation

public struct UnlockOptions: Sendable {
    public var destination: URL
    public var categories: Set<ClipCategory>
    /// `nil` = bez remuxu.
    public var ffmpeg: URL?
    public var workers: Int
    public var batchSize: Int
    /// Zpracovat jen tyto relativní cesty (tlačítko „Zkusit znovu jen chybné“).
    public var only: Set<String>?

    public init(
        destination: URL, categories: Set<ClipCategory> = Set(ClipCategory.allCases),
        ffmpeg: URL? = nil, workers: Int = 4, batchSize: Int = 20, only: Set<String>? = nil
    ) {
        self.destination = destination
        self.categories = categories
        self.ffmpeg = ffmpeg
        self.workers = workers
        self.batchSize = batchSize
        self.only = only
    }
}

public enum FailureReason: Error, Sendable, Equatable {
    case container(ContainerError)
    /// API odmítlo vydat klíč pro tento soubor (kód z odpovědi).
    case keyRejected(String)
    case keyService(KeyServiceError)
    case io(String)
}

public enum FileOutcome: Sendable, Equatable {
    case unlocked(bytes: UInt64, remuxed: Bool, note: String?)
    case copied(bytes: UInt64)
    case alreadyDone(bytes: UInt64)
    case incomplete
    case locked
    case failed(FailureReason)
    case waitingForToken
}

public enum RunEnd: Sendable, Equatable {
    case finished
    case cancelled
    case tokenExpired
    case gaveUp(KeyServiceError)
}

/// Co se bude dít s každým souborem, ještě než začne práce.
public struct UnlockPlan: Sendable {
    public var toUnlock: [(file: SourceFile, header: ContainerHeader)] = []
    public var toCopy: [SourceFile] = []
    public var alreadyDone: [SourceFile] = []
    public var incomplete: [SourceFile] = []
    public var locked: [SourceFile] = []
    public var damaged: [(file: SourceFile, error: ContainerError)] = []

    /// Místo, které výsledek zabere, plus rezerva na dočasné soubory remuxu.
    public var requiredBytes: UInt64 {
        let unlock = toUnlock.reduce(0) { $0 + $1.header.plaintextSize }
        let copy = toCopy.reduce(0) { $0 + $1.size }
        return unlock + copy
    }

    public var workCount: Int { toUnlock.count + toCopy.count }

    public init(scan: ScanResult, options: UnlockOptions) {
        let fm = FileManager.default
        for file in scan.files where options.categories.contains(file.category) {
            if let only = options.only, !only.contains(file.relativePath) { continue }
            let target = options.destination.appendingPathComponent(file.relativePath)
            switch file.kind {
            case .incompleteVideo: incomplete.append(file)
            case .lockedSidecar: locked.append(file)
            case .damaged(let error): damaged.append((file, error))
            case .encryptedVideo(let header):
                if fm.fileExists(atPath: target.path) { alreadyDone.append(file) } else { toUnlock.append((file, header)) }
            case .plain:
                if fm.fileExists(atPath: target.path) { alreadyDone.append(file) } else { toCopy.append(file) }
            }
        }
    }
}

public enum UnlockEngine {
    public typealias Emit = @Sendable (SourceFile, FileOutcome) -> Void

    /// Rozdělí soubory do dávek tak, aby v žádné nebyla dvě stejná id.
    /// API páruje výsledky podle id a klipy stejné velikosti id sdílí.
    public static func makeBatches<T>(_ items: [T], size: Int, id: (T) -> String) -> [[T]] {
        let size = max(1, size)
        var remaining = items
        var batches: [[T]] = []
        while !remaining.isEmpty {
            var seen = Set<String>()
            var batch: [T] = []
            var rest: [T] = []
            for item in remaining {
                if batch.count < size, seen.insert(id(item)).inserted {
                    batch.append(item)
                } else {
                    rest.append(item)
                }
            }
            batches.append(batch)
            remaining = rest
        }
        return batches
    }

    /// Volné místo na svazku, kam míří `url` (i když složka ještě neexistuje).
    public static func availableCapacity(at url: URL) -> Int64? {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static let tempPrefix = ".tp-"
    static let maxConsecutiveBatchFailures = 3

    /// Provede plán. Výsledek každého souboru hlásí přes `emit` (souběžně, v libovolném pořadí).
    /// Při vypršení tokenu doběhne rozpracované a zbytek nahlásí jako `waitingForToken`.
    public static func run(
        plan: UnlockPlan, options: UnlockOptions, client: KeyFetching, emit: @escaping Emit
    ) async -> RunEnd {
        let manifest = ManifestStore(destination: options.destination)
        removeStaleTemporaries(in: options.destination)

        let report: @Sendable (SourceFile, FileOutcome) async -> Void = { file, outcome in
            if let entry = manifestEntry(file, outcome) { await manifest.record(file.relativePath, entry) }
            emit(file, outcome)
        }

        for file in plan.alreadyDone { await report(file, .alreadyDone(bytes: file.outputSize)) }
        for file in plan.incomplete { await report(file, .incomplete) }
        for file in plan.locked { await report(file, .locked) }
        for (file, error) in plan.damaged { await report(file, .failed(.container(error))) }

        let workers = max(1, options.workers)
        let batches = makeBatches(plan.toUnlock, size: options.batchSize) { $0.header.id }

        let end: RunEnd = await withTaskGroup(of: Void.self) { group in
            var running = 0
            var end = RunEnd.finished

            for file in plan.toCopy {
                if Task.isCancelled { break }
                if running >= workers { await group.next(); running -= 1 }
                running += 1
                group.addTask {
                    do {
                        let bytes = try copyOne(file, options: options)
                        await report(file, .copied(bytes: bytes))
                    } catch is CancellationError {
                    } catch {
                        await report(file, .failed(.io(error.localizedDescription)))
                    }
                }
            }

            var failures = 0
            for (index, batch) in batches.enumerated() {
                if Task.isCancelled { end = .cancelled; break }

                let keys: KeySet
                do {
                    // Klíče pro další dávku se stahují, zatímco předchozí se ještě dešifruje.
                    keys = try await client.fetchKeys(batch.map { KeyRequestItem(header: $0.header) })
                    failures = 0
                } catch is CancellationError {
                    end = .cancelled; break
                } catch KeyServiceError.unauthorized {
                    end = .tokenExpired
                    for pending in batches[index...].joined() { await report(pending.file, .waitingForToken) }
                    break
                } catch {
                    let reason = (error as? KeyServiceError) ?? .network(error.localizedDescription)
                    failures += 1
                    if failures >= maxConsecutiveBatchFailures {
                        end = .gaveUp(reason)
                        for pending in batches[index...].joined() { await report(pending.file, .failed(.keyService(reason))) }
                        break
                    }
                    for pending in batch { await report(pending.file, .failed(.keyService(reason))) }
                    continue
                }

                for (file, header) in batch {
                    guard let key = keys.keys[header.id] else {
                        await report(file, .failed(.keyRejected(keys.errors[header.id] ?? "no_key")))
                        continue
                    }
                    if Task.isCancelled { break }
                    if running >= workers { await group.next(); running -= 1 }
                    running += 1
                    group.addTask {
                        do {
                            let outcome = try await unlockOne(file, header: header, key: key, options: options)
                            await report(file, outcome)
                        } catch is CancellationError {
                        } catch let reason as FailureReason {
                            await report(file, .failed(reason))
                        } catch {
                            await report(file, .failed(.io(error.localizedDescription)))
                        }
                    }
                }
            }

            await group.waitForAll()
            if Task.isCancelled { end = .cancelled }
            return end
        }

        await manifest.flush()
        return end
    }

    static func manifestEntry(_ file: SourceFile, _ outcome: FileOutcome) -> Manifest.Entry? {
        func entry(_ status: Manifest.Status, size: UInt64? = nil, remuxed: Bool? = nil, reason: String? = nil) -> Manifest.Entry {
            Manifest.Entry(status: status, sourcePath: file.url.path, sourceSize: file.size,
                           outputSize: size, remuxed: remuxed, reason: reason, updated: Date())
        }
        switch outcome {
        case .unlocked(let bytes, let remuxed, let note): return entry(.unlocked, size: bytes, remuxed: remuxed, reason: note)
        case .copied(let bytes): return entry(.copied, size: bytes)
        case .incomplete: return entry(.incomplete)
        case .locked: return entry(.locked)
        case .failed(let reason): return entry(.failed, reason: Messages.text(for: reason))
        case .alreadyDone, .waitingForToken: return nil
        }
    }

    static func prepareDirectory(for file: SourceFile, options: UnlockOptions) throws -> (dir: URL, target: URL) {
        let target = options.destination.appendingPathComponent(file.relativePath)
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (dir, target)
    }

    static func temporaryURL(in dir: URL) -> URL {
        dir.appendingPathComponent("\(tempPrefix)\(UUID().uuidString).part")
    }

    static func copyOne(_ file: SourceFile, options: UnlockOptions) throws -> UInt64 {
        let (dir, target) = try prepareDirectory(for: file, options: options)
        let temp = temporaryURL(in: dir)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.copyItem(at: file.url, to: temp)
        try FileManager.default.moveItem(at: temp, to: target)
        return file.size
    }

    /// Dešifruje do dočasného souboru, volitelně remuxuje a teprve hotový výsledek
    /// přejmenuje na `.mp4`. Napůl zapsané video tak nikdy nevznikne.
    static func unlockOne(_ file: SourceFile, header: ContainerHeader, key: Data, options: UnlockOptions) async throws -> FileOutcome {
        let (dir, target) = try prepareDirectory(for: file, options: options)
        let decrypted = temporaryURL(in: dir)
        defer { try? FileManager.default.removeItem(at: decrypted) }

        let written: UInt64
        do {
            let reader = try FileReader(url: file.url)
            guard FileManager.default.createFile(atPath: decrypted.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw FailureReason.io("Nelze vytvořit dočasný soubor v \(dir.path)")
            }
            let out = try FileHandle(forWritingTo: decrypted)
            defer { try? out.close() }
            written = try Container.decrypt(
                reader: reader, header: header, key: key,
                checkCancelled: { try Task.checkCancellation() },
                write: { try out.write(contentsOf: $0) }
            )
            try out.synchronize()
        } catch let error as ContainerError {
            throw FailureReason.container(error)
        }

        var final = decrypted
        var remuxed = false
        var note: String?
        if let ffmpeg = options.ffmpeg {
            let remuxTemp = temporaryURL(in: dir)
            defer { try? FileManager.default.removeItem(at: remuxTemp) }
            do {
                try await FFmpeg.remux(ffmpeg: ffmpeg, input: decrypted, output: remuxTemp)
                let head = try FileReader(url: remuxTemp).read(at: 0, count: 8)
                guard Container.looksLikeMP4(head) else { throw FFmpeg.Failure(status: 0, detail: "výstup není MP4") }
                try FileManager.default.moveItem(at: remuxTemp, to: target)
                remuxed = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                note = Messages.remuxFailed(error)
            }
            if remuxed { return .unlocked(bytes: written, remuxed: true, note: nil) }
            final = decrypted
        }

        try FileManager.default.moveItem(at: final, to: target)
        return .unlocked(bytes: written, remuxed: remuxed, note: note)
    }

    /// Smaže pozůstatky přerušeného běhu (`.tp-*.part`).
    static func removeStaleTemporaries(in destination: URL) {
        guard let walker = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker where url.lastPathComponent.hasPrefix(tempPrefix) && url.pathExtension == "part" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
