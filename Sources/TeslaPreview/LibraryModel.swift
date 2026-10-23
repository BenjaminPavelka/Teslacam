import AppKit
import Foundation
import Observation
import TeslaCamCore

@Observable @MainActor
final class LibraryModel {
    private(set) var root: URL
    private(set) var events: [LibraryEvent] = []
    private(set) var indexes: [String: EventIndex] = [:]
    private(set) var annotations = LibraryAnnotations()
    private(set) var isLoading = false
    private(set) var indexing: (done: Int, total: Int)?
    var saveError: String?

    var selection: String?

    // Filtry
    var categoryFilter: ClipCategory?
    var decisionFilter: Decision?
    var tagFilter: String?
    var onlyAssisted = false
    var searchText = ""

    private var indexTask: Task<Void, Never>?

    init(root: URL) { self.root = root }

    var cache: EventCache { EventCache(root: root) }

    private var loaded = false

    func loadIfNeeded() {
        guard !loaded else { return }
        reload()
    }

    func setRoot(_ url: URL) {
        guard url.standardizedFileURL != root.standardizedFileURL else { return }
        root = url
        selection = nil
        reload()
    }

    func reload(select: String? = nil) {
        loaded = true
        indexTask?.cancel()
        isLoading = true
        let root = root
        Task {
            let (events, indexes) = await Task.detached(priority: .userInitiated) {
                let events = LibraryScanner.scan(root: root)
                let cache = EventCache(root: root)
                var indexes: [String: EventIndex] = [:]
                for event in events { indexes[event.id] = cache.loadIndex(event) }
                return (events, indexes)
            }.value
            guard root == self.root else { return }
            self.events = events
            self.indexes = indexes
            annotations = LibraryAnnotations.load(from: root)
            isLoading = false
            if let select, events.contains(where: { $0.id == select }) {
                selection = select
            } else if let selection, !events.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
            startIndexing()
        }
    }

    /// Dopočítá chybějící náhledy, délky a telemetrii (dvě události souběžně).
    private func startIndexing() {
        let missing = events.filter { indexes[$0.id] == nil }
        guard !missing.isEmpty else { indexing = nil; return }
        indexing = (0, missing.count)
        let cache = cache
        indexTask = Task {
            await withTaskGroup(of: (String, EventIndex?).self) { group in
                var queue = missing[...]
                func next() {
                    guard let event = queue.popFirst() else { return }
                    group.addTask { (event.id, try? await EventIndexer.index(event, cache: cache)) }
                }
                next(); next()
                for await (id, index) in group {
                    if Task.isCancelled { break }
                    indexes[id] = index
                    indexing = indexing.map { ($0.done + 1, $0.total) }
                    next()
                }
            }
            if !Task.isCancelled { indexing = nil }
        }
    }

    /// Náhled z mezipaměti; volat mimo vykreslování (z `.task`).
    nonisolated static func loadThumbnail(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
    }

    // MARK: Třídění

    func annotation(_ id: String) -> EventAnnotation { annotations[id] }

    func update(_ id: String, _ change: (inout EventAnnotation) -> Void) {
        var value = annotations[id]
        change(&value)
        annotations[id] = value
        do {
            try annotations.save(to: root)
            saveError = nil
        } catch {
            saveError = "Označení se nepodařilo uložit: \(error.localizedDescription)"
        }
    }

    var filteredEvents: [LibraryEvent] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return events.filter { event in
            if let categoryFilter, event.category != categoryFilter { return false }
            let note = annotations[event.id]
            if let decisionFilter, note.decision != decisionFilter { return false }
            if let tagFilter, !note.tags.contains(tagFilter) { return false }
            if onlyAssisted {
                guard let summary = indexes[event.id]?.summary,
                      AutopilotState.allCases.dropFirst().contains(where: { summary.seconds($0) > 0 })
                else { return false }
            }
            if !query.isEmpty {
                let haystack = [event.id, event.metadata?.place, event.metadata?.reasonText, note.note, note.tags.joined(separator: " ")]
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                if !haystack.contains(query) { return false }
            }
            return true
        }
    }

    /// Události seskupené podle dne (od nejnovějšího).
    var groupedByDay: [(day: Date, events: [LibraryEvent])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filteredEvents) { calendar.startOfDay(for: $0.savedAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    var counts: (keep: Int, delete: Int, undecided: Int) {
        var keep = 0, delete = 0
        for event in events {
            switch annotations[event.id].decision {
            case .keep: keep += 1
            case .delete: delete += 1
            case .undecided: break
            }
        }
        return (keep, delete, events.count - keep - delete)
    }

    var selectedEvent: LibraryEvent? { events.first { $0.id == selection } }
}

extension Format {
    static let czech = Locale(identifier: "cs_CZ")

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(czech))
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(czech))
    }

    static func timeOfDay(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(czech))
    }

    /// Cesta pro zobrazení, domovská složka jako `~`.
    static func path(_ url: URL) -> String {
        var text = (url.path as NSString).abbreviatingWithTildeInPath
        #if DEBUG
        // Pro screenshoty: TP_PATH_ALIAS="/dlouha/cesta=>~/Kratsi"
        if let alias = ProcessInfo.processInfo.environment["TP_PATH_ALIAS"]?.components(separatedBy: "=>"), alias.count == 2 {
            text = text.replacingOccurrences(of: alias[0], with: alias[1])
        }
        #endif
        return text
    }

    /// České skloňování podle počtu: 1 soubor, 2–4 soubory, 5+ souborů.
    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(n) " + (n == 1 ? one : (2...4).contains(n) ? few : many)
    }

    static func files(_ n: Int) -> String { count(n, "soubor", "soubory", "souborů") }
    static func events(_ n: Int) -> String { count(n, "událost", "události", "událostí") }

    static func minutes(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds.rounded())) s" : "\(Int((seconds / 60).rounded())) min"
    }
}
