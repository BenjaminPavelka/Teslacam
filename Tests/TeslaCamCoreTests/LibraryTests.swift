import Foundation
import Testing
@testable import TeslaCamCore

struct LibraryTests {
    @Test func parsesClipNames() throws {
        let parsed = try #require(LibraryScanner.parseClipName("2026-06-21_18-55-52-left_pillar.mp4"))
        #expect(parsed.camera == .leftPillar)
        #expect(parsed.minute == "2026-06-21_18-55-52")
        #expect(LibraryScanner.parseClipName("2026-06-21_18-55-52-unknown.mp4") == nil)
        #expect(LibraryScanner.parseClipName("._2026-06-21_18-55-52-front.mp4") == nil)
        #expect(LibraryScanner.parseClipName("event.json") == nil)
    }

    @Test func scansEventsAndRecentSessions() throws {
        let root = try Sample.tempDir()
        let ev = "SavedClips/2026-06-21_18-57-38"
        for minute in ["2026-06-21_18-55-52", "2026-06-21_18-56-52"] {
            for cam in Camera.allCases { try Sample.write(Data(), to: root.appendingPathComponent("\(ev)/\(minute)-\(cam.rawValue).mp4")) }
        }
        try Sample.write(Data(#"{"city":"Velké Albrechtice","street":"D1","est_lat":"49.739","est_lon":"18.0447","reason":"user_interaction_honk"}"#.utf8),
                         to: root.appendingPathComponent("\(ev)/event.json"))
        try Sample.write(Sample.zeroMetadataClip(plainSize: 200), to: root.appendingPathComponent("SentryClips/2026-06-22_10-00-00/event.json"))
        try Sample.write(Data(), to: root.appendingPathComponent("SentryClips/2026-06-22_10-00-00/2026-06-22_09-59-00-back.mp4"))
        for name in ["2026-07-02_14-00-00", "2026-07-02_14-01-00", "2026-07-02_14-02-01", "2026-07-02_15-30-00"] {
            try Sample.write(Data(), to: root.appendingPathComponent("RecentClips/\(name)-front.mp4"))
        }
        try Sample.write(Data(), to: root.appendingPathComponent("SentryClips/neni-udalost/x.mp4"))

        let events = LibraryScanner.scan(root: root)
        #expect(events.map(\.id) == [
            "RecentClips/2026-07-02_15-30-00", "RecentClips/2026-07-02_14-00-00",
            "SentryClips/2026-06-22_10-00-00", ev,
        ])
        let saved = events[3]
        #expect(saved.minutes.count == 2)
        #expect(saved.cameras == Camera.allCases)
        #expect(saved.metadata?.place == "D1, Velké Albrechtice")
        #expect(saved.metadata?.reasonText == "Uloženo troubením")
        #expect(saved.metadata?.coordinate?.lat == 49.739)
        #expect(events[2].metadata == nil, "zamčený event.json se nečte")
        #expect(events[2].primaryCamera == .back)
        #expect(events[1].minutes.count == 3)
    }

    @Test func reasonTexts() {
        #expect(EventMetadata.reasonText("sentry_aware_object_detection") == "Sentry: objekt v blízkosti auta")
        #expect(EventMetadata.reasonText("sentry_aware_accel_0.53") == "Sentry: otřes auta")
        #expect(EventMetadata.reasonText("user_interaction_something_new") == "User interaction something new")
    }

    @Test func annotationsRoundTrip() throws {
        let root = try Sample.tempDir()
        var notes = LibraryAnnotations()
        notes["SavedClips/a"].decision = .keep
        notes["SavedClips/a"].tags = ["dálnice", "FSD"]
        notes["SavedClips/b"].note = "srnka"
        notes["SavedClips/c"] = EventAnnotation()
        try notes.save(to: root)
        let loaded = LibraryAnnotations.load(from: root)
        #expect(loaded["SavedClips/a"].decision == .keep)
        #expect(loaded["SavedClips/b"].note == "srnka")
        #expect(loaded.events["SavedClips/c"] == nil)
        #expect(loaded.allTags == ["dálnice", "FSD"])
    }

    @Test func savedOffsetLandsInRightMinute() throws {
        let start = try #require(LibraryScanner.parseTimestamp("2026-06-21_18-55-52"))
        let event = LibraryEvent(
            id: "SavedClips/x", category: .saved, folder: nil,
            savedAt: start.addingTimeInterval(60 + 46),
            minutes: [ClipMinute(start: start, name: "a", cameras: [:]), ClipMinute(start: start.addingTimeInterval(60), name: "b", cameras: [:])],
            metadata: nil
        )
        let index = EventIndex(signature: [:], durations: [59.5, 40], telemetryCount: 0, summary: .init())
        #expect(EventIndexer.savedOffset(event, index: index) == 59.5 + 40)
        var early = event
        early.savedAt = start.addingTimeInterval(30)
        #expect(EventIndexer.savedOffset(early, index: index) == 30)
    }
}

/// Indexace a export na skutečných (vygenerovaných) H.264 videích.
@Suite(.enabled(if: FFmpeg.locate() != nil))
struct IndexAndExportTests {
    static let marker = "TELEMETRIE-ZNACKA"

    func makeEvent() async throws -> (root: URL, event: LibraryEvent) {
        let ffmpeg = try #require(FFmpeg.locate())
        let root = try Sample.tempDir()
        let folder = root.appendingPathComponent("SavedClips/2026-06-21_18-56-58")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for minute in ["2026-06-21_18-55-52", "2026-06-21_18-56-52"] {
            for cam in [Camera.front, .back] {
                try await FFmpeg.run(ffmpeg, [
                    "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=4",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "5", "-bf", "0",
                    "-bsf:v", "h264_metadata=sei_user_data=42424242-4242-4242-4242-424242424242+\(Self.marker)",
                    folder.appendingPathComponent("\(minute)-\(cam.rawValue).mp4").path,
                ])
            }
        }
        return (root, try #require(LibraryScanner.scan(root: root).first))
    }

    @Test func indexesDurationsAndThumbnail() async throws {
        let (root, event) = try await makeEvent()
        let cache = EventCache(root: root)
        let index = try await EventIndexer.index(event, cache: cache)
        #expect(index.durations.count == 2)
        #expect(abs(index.totalDuration - 8) < 0.1)
        #expect(index.offsets == [0, index.durations[0]])
        #expect(index.telemetryCount == 0)
        #expect(FileManager.default.fileExists(atPath: cache.thumbnailURL(event).path))
        #expect(FileManager.default.fileExists(atPath: event.folder!.appendingPathComponent("thumb.png").path))
        #expect(cache.loadIndex(event) == index)
    }

    @Test func exportsFrontAndMosaic() async throws {
        let ffmpeg = try #require(FFmpeg.locate())
        let (root, event) = try await makeEvent()
        let index = try await EventIndexer.index(event, cache: EventCache(root: root))
        for (kind, name) in [(Exporter.Kind.front, "front.mp4"), (.mosaic, "mozaika.mp4")] {
            let out = root.appendingPathComponent(name)
            try await Exporter.export(event, index: index, kind: kind, to: out, ffmpeg: ffmpeg)
            let reader = try FileReader(url: out)
            let track = try MP4.videoTrack(reader, fileSize: reader.size)
            #expect(abs(track.duration - 8) < 0.5, "\(name): \(track.duration)")
        }
    }

    func duration(_ url: URL) throws -> Double {
        let reader = try FileReader(url: url)
        return try MP4.videoTrack(reader, fileSize: reader.size).duration
    }

    @Test func keyframesAreParsed() async throws {
        let (_, event) = try await makeEvent()
        let reader = try FileReader(url: event.minutes[0].cameras[.front]!)
        let track = try MP4.videoTrack(reader, fileSize: reader.size)
        #expect(track.keyframes.count == 8)
        #expect(track.keyframe(atOrBefore: 2.2) == 2.0)
        #expect(track.keyframe(atOrBefore: 0.3) == 0)
    }

    @Test func piecesSpanMinutesAndSnapToKeyframes() async throws {
        let (root, event) = try await makeEvent()
        let index = try await EventIndexer.index(event, cache: EventCache(root: root))
        let pieces = try #require(Exporter.pieces(event, index: index, camera: .back, range: TrimRange(start: 2.2, end: 6), snapToKeyframe: true))
        #expect(pieces.count == 2)
        #expect(pieces[0].inpoint == 2.0 && pieces[0].outpoint == nil)
        #expect(pieces[1].inpoint == nil && abs(pieces[1].outpoint! - (6 - index.durations[0])) < 0.001)
        let late = try #require(Exporter.pieces(event, index: index, camera: .front, range: TrimRange(start: 5, end: 7), snapToKeyframe: false))
        #expect(late.count == 1 && late[0].url.lastPathComponent.hasPrefix("2026-06-21_18-56-52"))
        #expect(Exporter.pieces(event, index: index, camera: .leftPillar, range: nil, snapToKeyframe: true) == nil)
    }

    @Test func cutsAllCamerasLosslesslyAndKeepsTelemetry() async throws {
        let ffmpeg = try #require(FFmpeg.locate())
        let (root, event) = try await makeEvent()
        let index = try await EventIndexer.index(event, cache: EventCache(root: root))
        let range = TrimRange(start: 2.2, end: 6)

        let folder = root.appendingPathComponent("vyrez")
        try await Exporter.export(event, index: index, kind: .cameras, range: range, to: folder, ffmpeg: ffmpeg)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == ["2026-06-21_18-55-54-back.mp4", "2026-06-21_18-55-54-front.mp4"])
        for file in files {
            let url = folder.appendingPathComponent(file)
            // Začátek na klíčovém snímku 2,0 s → délka 4,0 s.
            #expect(abs(try duration(url) - 4.0) < 0.15, "\(file)")
            #expect(try Data(contentsOf: url).range(of: Data(Self.marker.utf8)) != nil, "střih zahodil telemetrii")
        }

        let mosaic = root.appendingPathComponent("mozaika.mp4")
        try await Exporter.export(event, index: index, kind: .mosaic, range: range, to: mosaic, ffmpeg: ffmpeg)
        #expect(abs(try duration(mosaic) - 3.8) < 0.15)
    }

    @Test func savesCutAsNewLibraryEvent() async throws {
        let ffmpeg = try #require(FFmpeg.locate())
        let (root, event) = try await makeEvent()
        try Data(#"{"city":"Praha","reason":"user_interaction_honk"}"#.utf8).write(to: event.folder!.appendingPathComponent("event.json"))
        let index = try await EventIndexer.index(event, cache: EventCache(root: root))
        let id = try await Exporter.saveToLibrary(event, index: index, range: TrimRange(start: 1, end: 3), root: root, ffmpeg: ffmpeg)
        #expect(id == "SavedClips/2026-06-21_18-55-55")
        let saved = try #require(LibraryScanner.scan(root: root).first { $0.id == id })
        #expect(saved.cameras == [.front, .back])
        #expect(saved.metadata?.city == "Praha")
        // Druhé uložení téhož úseku nepřepíše první.
        let again = try await Exporter.saveToLibrary(event, index: index, range: TrimRange(start: 1, end: 3), root: root, ffmpeg: ffmpeg)
        #expect(again == "SavedClips/2026-06-21_18-55-56")
    }
}
