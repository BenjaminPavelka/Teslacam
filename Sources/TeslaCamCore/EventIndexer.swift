import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Předpočítané údaje o události, uložené v `.tesla-preview/index/`.
public struct EventIndex: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = currentVersion
    /// Názvy a velikosti souborů, ze kterých index vznikl (pro zneplatnění).
    public var signature: [String: UInt64]
    /// Skutečná délka každého minutového úseku v sekundách.
    public var durations: [Double]
    public var telemetryCount: Int
    public var summary: TelemetrySummary

    public var totalDuration: Double { durations.reduce(0, +) }

    /// Kde v časové ose události začíná který úsek.
    public var offsets: [Double] {
        var acc = 0.0
        return durations.map { d in defer { acc += d }; return acc }
    }
}

public struct EventCache: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    var base: URL { root.appendingPathComponent(".tesla-preview") }
    public func indexURL(_ event: LibraryEvent) -> URL { base.appendingPathComponent("index/\(event.cacheKey).json") }
    public func telemetryURL(_ event: LibraryEvent) -> URL { base.appendingPathComponent("telemetry/\(event.cacheKey).json") }
    public func thumbnailURL(_ event: LibraryEvent) -> URL { base.appendingPathComponent("thumbs/\(event.cacheKey).jpg") }

    public func loadIndex(_ event: LibraryEvent) -> EventIndex? {
        guard let data = try? Data(contentsOf: indexURL(event)),
              let index = try? JSONDecoder().decode(EventIndex.self, from: data),
              index.version == EventIndex.currentVersion,
              index.signature == EventIndexer.signature(event)
        else { return nil }
        return index
    }

    public func loadTelemetry(_ event: LibraryEvent) -> [TelemetrySample] {
        guard let data = try? Data(contentsOf: telemetryURL(event)) else { return [] }
        return (try? JSONDecoder().decode([TelemetrySample].self, from: data)) ?? []
    }

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

public enum EventIndexer {
    static func signature(_ event: LibraryEvent) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for minute in event.minutes {
            guard let url = minute.cameras[event.primaryCamera] else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            result[url.lastPathComponent] = UInt64(size)
        }
        return result
    }

    /// Spočítá délky úseků, telemetrii a náhled. Výsledky uloží do mezipaměti.
    public static func index(_ event: LibraryEvent, cache: EventCache) async throws -> EventIndex {
        let camera = event.primaryCamera
        var durations: [Double] = []
        var telemetry: [TelemetrySample] = []
        var offset = 0.0

        for minute in event.minutes {
            try Task.checkCancellation()
            guard let url = minute.cameras[camera] else {
                durations.append(60)
                offset += 60
                continue
            }
            var duration = 60.0
            if let reader = try? FileReader(url: url), let track = try? MP4.videoTrack(reader, fileSize: reader.size) {
                duration = track.duration
                if track.codec.hasPrefix("avc"), let samples = try? Telemetry.extract(track: track, reader: reader) {
                    telemetry += Telemetry.thin(samples).map { var s = $0; s.t += offset; return s }
                }
            }
            durations.append(duration)
            offset += duration
        }

        let index = EventIndex(
            signature: signature(event), durations: durations,
            telemetryCount: telemetry.count, summary: TelemetrySummary(telemetry)
        )
        try cache.write(telemetry, to: cache.telemetryURL(event))
        try await makeThumbnail(event, index: index, cache: cache)
        try cache.write(index, to: cache.indexURL(event))
        return index
    }

    /// Kde v časové ose události nastalo uložení.
    public static func savedOffset(_ event: LibraryEvent, index: EventIndex) -> Double? {
        guard event.category != .recent else { return nil }
        let offsets = index.offsets
        guard let i = event.minutes.lastIndex(where: { $0.start <= event.savedAt }) else { return nil }
        let within = event.savedAt.timeIntervalSince(event.minutes[i].start)
        return min(offsets[i] + min(within, index.durations[i]), index.totalDuration)
    }

    /// Snímek z přední kamery chvíli před uložením. Do složky události zapíše `thumb.png`,
    /// pokud tam žádný není (u šifrovaných událostí zůstal originál zamčený).
    static func makeThumbnail(_ event: LibraryEvent, index: EventIndex, cache: EventCache) async throws {
        let target = savedOffset(event, index: index).map { max(0, $0 - 1) } ?? min(5, index.totalDuration / 2)
        let offsets = index.offsets
        let i = max(0, (offsets.lastIndex { $0 <= target }) ?? 0)
        guard i < event.minutes.count, let url = event.minutes[i].cameras[event.primaryCamera] else { return }
        let within = min(max(0, target - offsets[i]), max(0, index.durations[i] - 0.5))

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let image = try? await generator.image(at: CMTime(seconds: within, preferredTimescale: 600)).image else { return }

        try writeImage(image, to: cache.thumbnailURL(event), type: .jpeg)
        if let folder = event.folder {
            let thumb = folder.appendingPathComponent("thumb.png")
            if !FileManager.default.fileExists(atPath: thumb.path) { try? writeImage(image, to: thumb, type: .png) }
        }
    }

    static func writeImage(_ image: CGImage, to url: URL, type: UTType) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".tp-\(UUID().uuidString).part")
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
    }
}
