import Foundation
import Testing
@testable import TeslaCamCore

/// Ruční kontrola na skutečném klipu: `TP_REAL_CLIP=/cesta/front.mp4 swift test --filter RealClip`
struct RealClipTests {
    static let path = ProcessInfo.processInfo.environment["TP_REAL_CLIP"]

    @Test(.enabled(if: path != nil))
    func extractsTelemetryFromRealClip() throws {
        let url = URL(fileURLWithPath: Self.path!)
        let start = Date()
        let reader = try FileReader(url: url)
        let track = try MP4.videoTrack(reader, fileSize: reader.size)
        let samples = try Telemetry.extract(from: url)
        let summary = TelemetrySummary(samples)
        print("""
        kodek \(track.codec), délka \(track.duration) s, snímků \(track.samples.count), telemetrie \(samples.count) \
        za \(String(format: "%.2f", Date().timeIntervalSince(start))) s
        max \(Int(summary.maxSpeedKmh)) km/h, \(String(format: "%.2f", summary.distanceKm)) km, \
        režimy \(summary.autopilotSeconds), brzdění \(summary.brakeEvents), GPS \(summary.hasPosition)
        první \(samples.first.map { "\($0.t) s \(Int($0.speedKmh)) km/h \($0.gear.letter)" } ?? "-"), \
        poslední \(samples.last.map { "\($0.t) s \(Int($0.speedKmh)) km/h" } ?? "-")
        """)
        #expect(!samples.isEmpty)
    }
}

/// `TP_REAL_LIBRARY=/cesta/k/knihovne swift test --filter RealLibrary`: uloží výřez první události.
struct RealLibraryTests {
    static let path = ProcessInfo.processInfo.environment["TP_REAL_LIBRARY"]

    @Test(.enabled(if: path != nil && FFmpeg.locate() != nil))
    func savesRealCut() async throws {
        let root = URL(fileURLWithPath: Self.path!)
        let event = try #require(LibraryScanner.scan(root: root).last)
        let cache = EventCache(root: root)
        let index = try await EventIndexer.index(event, cache: cache)
        let range = TrimRange(start: 48, end: 72)
        let start = Date()
        let id = try await Exporter.saveToLibrary(event, index: index, range: range, root: root, ffmpeg: FFmpeg.locate()!)
        let cut = try #require(LibraryScanner.scan(root: root).first { $0.id == id })
        let cutIndex = try await EventIndexer.index(cut, cache: cache)
        let telemetry = cache.loadTelemetry(cut)
        print("výřez \(id) za \(String(format: "%.1f", Date().timeIntervalSince(start))) s: kamer \(cut.cameras.count), délka \(cutIndex.totalDuration) s, telemetrie \(telemetry.count), max \(Int(cutIndex.summary.maxSpeedKmh)) km/h")
        for minute in cut.minutes {
            for (camera, url) in minute.cameras.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let reader = try FileReader(url: url)
                let track = try MP4.videoTrack(reader, fileSize: reader.size)
                print("  \(camera.rawValue): \(String(format: "%.2f", track.duration)) s, \(url.lastPathComponent)")
            }
        }
        #expect(abs(cutIndex.totalDuration - 24) < 0.7)
        #expect(telemetry.count > 200)
    }
}
