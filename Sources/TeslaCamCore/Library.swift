import Foundation

public enum Camera: String, CaseIterable, Codable, Sendable, Identifiable {
    case front, back
    case leftPillar = "left_pillar"
    case rightPillar = "right_pillar"
    case leftRepeater = "left_repeater"
    case rightRepeater = "right_repeater"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .front: "Přední"
        case .back: "Zadní"
        case .leftPillar: "Levý sloupek"
        case .rightPillar: "Pravý sloupek"
        case .leftRepeater: "Levá boční"
        case .rightRepeater: "Pravá boční"
        }
    }
}

/// Jeden minutový úsek se soubory jednotlivých kamer.
public struct ClipMinute: Sendable, Hashable {
    public var start: Date
    public var name: String
    public var cameras: [Camera: URL]
}

/// Obsah `event.json` (jen u nešifrovaných událostí).
public struct EventMetadata: Codable, Sendable, Hashable {
    public var timestamp: String?
    public var city: String?
    public var street: String?
    public var estLat: String?
    public var estLon: String?
    public var reason: String?
    public var camera: String?

    enum CodingKeys: String, CodingKey {
        case timestamp, city, street, reason, camera
        case estLat = "est_lat"
        case estLon = "est_lon"
    }

    public var coordinate: (lat: Double, lon: Double)? {
        guard let lat = estLat.flatMap(Double.init), let lon = estLon.flatMap(Double.init), lat != 0 || lon != 0 else { return nil }
        return (lat, lon)
    }

    public var place: String? {
        let parts = [street, city].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Lidsky čitelný důvod uložení.
    public var reasonText: String? {
        guard let reason, !reason.isEmpty else { return nil }
        return Self.reasonText(reason)
    }

    public static func reasonText(_ reason: String) -> String {
        let known: [String: String] = [
            "user_interaction_dashcam_icon_tapped": "Uloženo ikonou dashcamu",
            "user_interaction_dashcam_launcher_action_tapped": "Uloženo z aplikace Dashcam",
            "user_interaction_dashcam_panel_save": "Uloženo z panelu dashcamu",
            "user_interaction_honk": "Uloženo troubením",
            "user_interaction_voice_command": "Uloženo hlasovým příkazem",
            "sentry_aware_object_detection": "Sentry: objekt v blízkosti auta",
            "sentry_aware_accel": "Sentry: otřes auta",
            "sentry_locked_handle_pulls": "Sentry: zatažení za kliku",
            "sentry_panic_alarm": "Sentry: alarm",
            "vehicle_auto_emergency_braking": "Nouzové brzdění",
            "vehicle_collision": "Náraz",
        ]
        if let text = known[reason] { return text }
        if let match = known.first(where: { reason.hasPrefix($0.key) }) { return match.value }
        if reason.hasPrefix("sentry") { return "Sentry: " + humanize(String(reason.dropFirst(6))) }
        return humanize(reason)
    }

    static func humanize(_ code: String) -> String {
        let words = code.split(separator: "_").map(String.init).filter { !$0.isEmpty }
        guard let first = words.first else { return code }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }
}

public struct LibraryEvent: Identifiable, Sendable, Hashable {
    /// Např. `SavedClips/2026-06-21_18-57-38` nebo `RecentClips/2026-07-02_14-00-00`.
    public var id: String
    public var category: ClipCategory
    /// Složka události (u průběžných klipů `nil`).
    public var folder: URL?
    /// Okamžik uložení (u průběžných klipů začátek úseku).
    public var savedAt: Date
    public var minutes: [ClipMinute]
    public var metadata: EventMetadata?

    public var start: Date { minutes.first?.start ?? savedAt }
    public var cameras: [Camera] { Camera.allCases.filter { cam in minutes.contains { $0.cameras[cam] != nil } } }
    /// Soubory s telemetrií a náhledem: přední kamera, jinak první dostupná.
    public var primaryCamera: Camera { cameras.first ?? .front }

    /// Klíč použitelný jako název souboru v mezipaměti.
    public var cacheKey: String { id.replacingOccurrences(of: "/", with: "__") }

    public var allFiles: [URL] { minutes.flatMap { $0.cameras.values } }
}

extension LibraryEvent {
    /// Skutečný čas na hodinách pro pozici `t` v události.
    public func clockTime(at t: Double, index: EventIndex) -> Date {
        let offsets = index.offsets
        let i = max(0, min(offsets.lastIndex { $0 <= t } ?? 0, minutes.count - 1))
        return minutes[i].start.addingTimeInterval(t - offsets[i])
    }
}

public enum LibraryScanner {
    public static func formatTimestamp(_ date: Date) -> String { timestampFormat.string(from: date) }

    static let timestampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    public static func parseTimestamp(_ text: some StringProtocol) -> Date? {
        guard text.count >= 19 else { return nil }
        return timestampFormat.date(from: String(text.prefix(19)))
    }

    /// Najde v názvu klipu kameru: `2026-06-21_18-55-52-left_pillar.mp4`.
    static func parseClipName(_ name: String) -> (start: Date, minute: String, camera: Camera)? {
        guard name.lowercased().hasSuffix(".mp4"), !name.hasPrefix("."), name.count > 24,
              let start = parseTimestamp(name)
        else { return nil }
        let rest = name.dropFirst(20).dropLast(4)
        guard let camera = Camera(rawValue: String(rest)) else { return nil }
        return (start, String(name.prefix(19)), camera)
    }

    static func group(_ urls: [URL]) -> [ClipMinute] {
        var byMinute: [String: ClipMinute] = [:]
        for url in urls {
            guard let (start, minute, camera) = parseClipName(url.lastPathComponent) else { continue }
            byMinute[minute, default: ClipMinute(start: start, name: minute, cameras: [:])].cameras[camera] = url
        }
        return byMinute.values.sorted { $0.start < $1.start }
    }

    /// Průběžné klipy rozdělí na souvislé jízdy (mezera > 2 min = nová).
    static let recentGap: TimeInterval = 120

    /// Projde výstupní složku odemykání a vrátí události od nejnovější.
    public static func scan(root: URL) -> [LibraryEvent] {
        let fm = FileManager.default
        var events: [LibraryEvent] = []

        for category in [ClipCategory.saved, .sentry] {
            let dir = root.appendingPathComponent(category.rawValue)
            guard let folders = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            else { continue }
            for folder in folders {
                guard let savedAt = parseTimestamp(folder.lastPathComponent),
                      let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                else { continue }
                let minutes = group(files)
                guard !minutes.isEmpty else { continue }
                events.append(LibraryEvent(
                    id: "\(category.rawValue)/\(folder.lastPathComponent)", category: category, folder: folder,
                    savedAt: savedAt, minutes: minutes, metadata: readMetadata(folder)
                ))
            }
        }

        let recentDir = root.appendingPathComponent(ClipCategory.recent.rawValue)
        if let files = try? fm.contentsOfDirectory(at: recentDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            var session: [ClipMinute] = []
            func flush() {
                guard let first = session.first else { return }
                events.append(LibraryEvent(
                    id: "\(ClipCategory.recent.rawValue)/\(first.name)", category: .recent, folder: nil,
                    savedAt: first.start, minutes: session, metadata: nil
                ))
                session = []
            }
            for minute in group(files) {
                if let last = session.last, minute.start.timeIntervalSince(last.start) > recentGap { flush() }
                session.append(minute)
            }
            flush()
        }

        return events.sorted { $0.savedAt > $1.savedAt }
    }

    static func readMetadata(_ folder: URL) -> EventMetadata? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("event.json")),
              !Container.hasSignature(data)
        else { return nil }
        return try? JSONDecoder().decode(EventMetadata.self, from: data)
    }
}

// MARK: - Třídění

public enum Decision: String, Codable, Sendable, CaseIterable {
    case undecided, keep, delete

    public var title: String {
        switch self {
        case .undecided: "Nerozhodnuto"
        case .keep: "Ponechat"
        case .delete: "Smazat"
        }
    }
}

/// Vybraný úsek události v sekundách od jejího začátku.
public struct TrimRange: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public var duration: Double { end - start }
}

public struct EventAnnotation: Codable, Sendable, Equatable {
    public var decision: Decision = .undecided
    public var note = ""
    public var tags: [String] = []
    public var range: TrimRange?

    public init() {}

    public var isEmpty: Bool { decision == .undecided && note.isEmpty && tags.isEmpty && range == nil }

    enum CodingKeys: String, CodingKey { case decision, note, tags, range }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decision = try c.decodeIfPresent(Decision.self, forKey: .decision) ?? .undecided
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        range = try c.decodeIfPresent(TrimRange.self, forKey: .range)
    }
}

/// Označení, poznámky a štítky, uložené v `.tesla-preview/library.json` ve složce odemčených videí.
public struct LibraryAnnotations: Codable, Sendable {
    public var version = 1
    public var events: [String: EventAnnotation] = [:]

    public init() {}

    public static func url(in root: URL) -> URL { root.appendingPathComponent(".tesla-preview/library.json") }

    public static func load(from root: URL) -> LibraryAnnotations {
        guard let data = try? Data(contentsOf: url(in: root)) else { return LibraryAnnotations() }
        return (try? JSONDecoder().decode(LibraryAnnotations.self, from: data)) ?? LibraryAnnotations()
    }

    public func save(to root: URL) throws {
        let target = Self.url(in: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: target, options: .atomic)
    }

    public subscript(id: String) -> EventAnnotation {
        get { events[id] ?? EventAnnotation() }
        set { events[id] = newValue.isEmpty ? nil : newValue }
    }

    public var allTags: [String] {
        Array(Set(events.values.flatMap(\.tags))).sorted { $0.localizedCompare($1) == .orderedAscending }
    }
}
