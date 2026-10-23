import AppKit
import Foundation
import Observation
import TeslaCamCore

@Observable @MainActor
final class AppModel {
    var screen: Screen? = .unlock

    // MARK: Zdroj a cíl

    var sourceURL: URL?
    var scan: ScanResult?
    var isScanning = false
    var scanError: String?

    var destination = AppModel.defaultDestination {
        didSet { library.setRoot(destination) }
    }
    static let defaultDestination = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/tesla dočasné/odemčené")
    let library = LibraryModel(root: AppModel.defaultDestination)
    var categories = Set(ClipCategory.allCases) { didSet { refreshPlan() } }
    var plan: UnlockPlan?
    var availableBytes: Int64?

    let ffmpeg = FFmpeg.locate()
    var remux = true
    var workers = 4

    // MARK: Token (jen v paměti)

    var token: BearerToken?
    var tokenMessage: String?

    // MARK: Běh

    enum Phase: Equatable {
        case idle, running, finished(RunEnd)
    }

    var phase = Phase.idle
    var outcomes: [String: FileOutcome] = [:]
    var filesByPath: [String: SourceFile] = [:]
    var runTotalFiles = 0
    var runTotalBytes: UInt64 = 0
    var runDoneFiles = 0
    var runDoneBytes: UInt64 = 0
    var startedAt: Date?
    private var runTask: Task<Void, Never>?

    static let flashDrive = URL(fileURLWithPath: "/Volumes/TESLADRIVE/TeslaCam")
    var flashDriveAvailable: Bool { FileManager.default.fileExists(atPath: Self.flashDrive.path) }

    // MARK: Akce

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Vyber složku se zkopírovanými klipy (TeslaCam, EncryptedClips, SavedClips…)"
        panel.prompt = "Vybrat"
        if panel.runModal() == .OK, let url = panel.url { setSource(url) }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Kam uložit odemčená videa"
        panel.prompt = "Vybrat"
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
            refreshPlan()
        }
    }

    func setSource(_ url: URL) {
        sourceURL = url
        rescan()
    }

    func rescan() {
        guard let sourceURL else { return }
        isScanning = true
        scanError = nil
        scan = nil
        plan = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try SourceScanner.scan(root: sourceURL)
                }.value
                scan = result
                if result.files.isEmpty {
                    scanError = "Ve složce nejsou žádné klipy (hledáme podsložky RecentClips, SavedClips a SentryClips)."
                }
            } catch {
                scanError = "Složku se nepodařilo projít: \(error.localizedDescription)"
            }
            isScanning = false
            refreshPlan()
        }
    }

    func refreshPlan(only: Set<String>? = nil) {
        availableBytes = UnlockEngine.availableCapacity(at: destination)
        guard let scan else { plan = nil; return }
        plan = UnlockPlan(scan: scan, options: options(only: only))
    }

    func options(only: Set<String>? = nil) -> UnlockOptions {
        UnlockOptions(
            destination: destination, categories: categories,
            ffmpeg: remux ? ffmpeg : nil, workers: workers, only: only
        )
    }

    /// Cíl nesmí ležet ve zdroji, jinak by se odemčená videa příště načetla jako zdroj.
    /// Opačně to nevadí: výstup jde jen do podsložek RecentClips/SavedClips/SentryClips.
    var overlapProblem: String? {
        guard let src = sourceURL?.standardizedFileURL.resolvingSymlinksInPath().path else { return nil }
        let dst = destination.standardizedFileURL.resolvingSymlinksInPath().path
        if dst == src || dst.hasPrefix(src + "/") { return "Cílová složka nesmí být uvnitř zdrojové." }
        if ClipCategory.allCases.contains(where: { src.hasPrefix(dst + "/" + $0.rawValue + "/") || src == dst + "/" + $0.rawValue }) {
            return "Zdroj leží ve výstupní složce odemčených videí. Přesuň ho jinam, nebo vyber jiný cíl."
        }
        return nil
    }

    var spaceProblem: String? {
        guard let plan, let availableBytes else { return nil }
        // Rezerva na dočasné soubory, dokud se dešifrovaná verze nenahradí remuxovanou.
        let reserve: UInt64 = remux ? UInt64(workers) * 200_000_000 : 0
        if plan.requiredBytes + reserve > UInt64(max(0, availableBytes)) {
            return "Nevejde se: potřeba \(Format.bytes(plan.requiredBytes + reserve)), volno jen \(Format.bytes(availableBytes)). Vyber méně kategorií, nebo jiný cíl."
        }
        return nil
    }

    var needsToken: Bool { !(plan?.toUnlock.isEmpty ?? true) }

    var startBlocker: String? {
        if phase == .running { return "Běží." }
        guard let plan else { return "Nejdřív vyber zdrojovou složku." }
        if let overlapProblem { return overlapProblem }
        if plan.workCount == 0 { return "Není co odemykat, všechno už je hotové." }
        if let spaceProblem { return spaceProblem }
        if needsToken {
            guard let token else { return "Chybí token. Vlož ho ze schránky, nebo se přihlas." }
            if token.isExpired() { return "Token vypršel. Vlož nový." }
        }
        return nil
    }

    // MARK: Token

    func pasteToken() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            tokenMessage = "Ve schránce není žádný text."
            return
        }
        acceptToken(text, fromClipboard: true)
    }

    func acceptToken(_ raw: String, fromClipboard: Bool = false) {
        do {
            let parsed = try BearerToken(parsing: raw)
            if parsed.isExpired() {
                tokenMessage = "Tenhle token už vypršel. Načti stránku dashcam.tesla.com znovu a zkopíruj nový."
                return
            }
            token = parsed
            tokenMessage = nil
            // Token ve schránce by viděl každý správce schránky; necháváme ho jen v paměti.
            if fromClipboard { NSPasteboard.general.clearContents() }
        } catch BearerToken.ParseError.empty {
            tokenMessage = "Schránka je prázdná."
        } catch {
            tokenMessage = "Ve schránce není token. Má začínat „eyJ“ a mít zhruba 1 000 znaků (hodnota za „Authorization: Bearer“)."
        }
    }

    func forgetToken() {
        token = nil
        tokenMessage = nil
    }

    // MARK: Odemykání

    func start(only: Set<String>? = nil) {
        refreshPlan(only: only)
        guard startBlocker == nil, let plan else { return }
        let client: KeyFetching = token.map { TeslaKeyClient(token: $0) } ?? NoTokenClient()
        let options = options(only: only)

        if only == nil { outcomes = [:] } else { for path in only! { outcomes[path] = nil } }
        for file in scan?.files ?? [] { filesByPath[file.relativePath] = file }
        runTotalFiles = plan.workCount
        runTotalBytes = plan.requiredBytes
        runDoneFiles = 0
        runDoneBytes = 0
        startedAt = Date()
        phase = .running

        runTask = Task {
            let end = await UnlockEngine.run(plan: plan, options: options, client: client) { file, outcome in
                Task { @MainActor in self.apply(file, outcome) }
            }
            // Doručit zbylé události, než ukážeme souhrn.
            await Task.yield()
            phase = .finished(end)
            runTask = nil
            refreshPlan()
            library.reload()
        }
    }

    func stop() { runTask?.cancel() }

    private func apply(_ file: SourceFile, _ outcome: FileOutcome) {
        outcomes[file.relativePath] = outcome
        switch outcome {
        case .unlocked, .copied, .failed, .waitingForToken:
            runDoneFiles += 1
            runDoneBytes += file.outputSize
        case .alreadyDone, .incomplete, .locked:
            break
        }
    }

    func retryFailed() { start(only: Set(retryablePaths)) }

    // MARK: Souhrn

    struct Summary {
        var unlocked = 0, copied = 0, alreadyDone = 0, incomplete = 0, locked = 0, failed = 0, waiting = 0
        var remuxFallback = 0
    }

    var summary: Summary {
        var s = Summary()
        for outcome in outcomes.values {
            switch outcome {
            case .unlocked(_, _, let note):
                s.unlocked += 1
                if note != nil { s.remuxFallback += 1 }
            case .copied: s.copied += 1
            case .alreadyDone: s.alreadyDone += 1
            case .incomplete: s.incomplete += 1
            case .locked: s.locked += 1
            case .failed: s.failed += 1
            case .waitingForToken: s.waiting += 1
            }
        }
        return s
    }

    var retryablePaths: [String] {
        outcomes.compactMap { path, outcome in
            switch outcome {
            case .failed, .waitingForToken: path
            default: nil
            }
        }.sorted()
    }

    /// Soubory, které stojí za zmínku (bez zamčených doplňků, těch je hodně a jsou očekávané).
    var problems: [(path: String, message: String)] {
        outcomes.compactMap { path, outcome in
            switch outcome {
            case .failed, .incomplete, .waitingForToken, .unlocked(_, _, .some):
                Messages.text(for: outcome).map { (path, $0) }
            default: nil
            }
        }.sorted { $0.path < $1.path }
    }

    var eta: TimeInterval? {
        guard let startedAt, runDoneBytes > 0, runTotalBytes > runDoneBytes else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 3 else { return nil }
        return elapsed / Double(runDoneBytes) * Double(runTotalBytes - runDoneBytes)
    }

    var throughput: Double? {
        guard let startedAt else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        return elapsed > 1 ? Double(runDoneBytes) / elapsed : nil
    }
}

/// Když se nic nedešifruje (jen kopírování), token nepotřebujeme.
struct NoTokenClient: KeyFetching {
    func fetchKeys(_ items: [KeyRequestItem]) async throws -> KeySet { throw KeyServiceError.unauthorized }
}

enum Format {
    static func bytes<T: BinaryInteger>(_ value: T) -> String {
        if value == 0 { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "cs_CZ")
        f.calendar = calendar
        return f.string(from: seconds) ?? ""
    }

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "cs_CZ")))
    }
}
