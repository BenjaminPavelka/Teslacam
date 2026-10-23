import Foundation
import Testing
@testable import TeslaCamCore

struct TokenTests {
    // {"alg":"none"}.{"exp":2000000000}.sig
    let jwt = "eyJhbGciOiJub25lIn0.eyJleHAiOjIwMDAwMDAwMDB9.c2ln"

    @Test func acceptsClipboardVariants() throws {
        for raw in [jwt, "Bearer \(jwt)", "  bearer \(jwt)\n", "Authorization: Bearer \(jwt)", "\"\(jwt)\""] {
            #expect(try BearerToken(parsing: raw).value == jwt, "\(raw)")
        }
        // Zalomené řádky z DevTools.
        let wrapped = String(jwt.prefix(20)) + "\n" + String(jwt.dropFirst(20))
        #expect(try BearerToken(parsing: wrapped).value == jwt)
    }

    @Test func rejectsGarbage() {
        #expect(throws: BearerToken.ParseError.empty) { try BearerToken(parsing: "  Bearer  ") }
        #expect(throws: BearerToken.ParseError.notJWT) { try BearerToken(parsing: "hello world") }
        #expect(throws: BearerToken.ParseError.notJWT) { try BearerToken(parsing: "eyJabc.def") }
    }

    @Test func readsExpiryAndNeverPrintsValue() throws {
        let token = try BearerToken(parsing: jwt)
        #expect(token.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(!token.isExpired(now: Date(timeIntervalSince1970: 1_900_000_000)))
        #expect(token.isExpired(now: Date(timeIntervalSince1970: 2_100_000_000)))
        #expect(!"\(token)".contains("eyJ"))
        #expect(!String(reflecting: token).contains("eyJ"))
    }
}

struct BatchingTests {
    @Test func collidingIDsNeverShareABatch() {
        let ids = ["a", "b", "a", "c", "a", "b", "d"]
        let batches = UnlockEngine.makeBatches(Array(ids.enumerated()), size: 3) { $0.element }
        #expect(batches.joined().count == ids.count)
        for batch in batches {
            #expect(Set(batch.map(\.element)).count == batch.count)
            #expect(batch.count <= 3)
        }
    }
}

struct ScannerTests {
    @Test func classifiesAndMapsTeslaCamLayout() throws {
        let root = try Sample.tempDir().appendingPathComponent("TeslaCam")
        let ev = "2026-07-02_13-56-12"
        let enc = root.appendingPathComponent("EncryptedClips")
        try Sample.write(Sample.clip(plain: Sample.mp4(size: 9000), key: Sample.key(1)),
                         to: enc.appendingPathComponent("SavedClips/\(ev)/\(ev)-front.mp4"))
        try Sample.write(Sample.zeroMetadataClip(plainSize: 9000),
                         to: enc.appendingPathComponent("SavedClips/\(ev)/\(ev)-back.mp4"))
        try Sample.write(Sample.zeroMetadataClip(plainSize: 200), to: enc.appendingPathComponent("SavedClips/\(ev)/event.json"))
        try Sample.write(Data("x".utf8), to: enc.appendingPathComponent("SavedClips/\(ev)/._event.json"))
        try Sample.write(Data("x".utf8), to: enc.appendingPathComponent("SavedClips/-README_cs.txt"))
        try Sample.write(Sample.clip(plain: Sample.mp4(size: 9000), key: Sample.key(2)),
                         to: enc.appendingPathComponent("RecentClips/2026-07-02_14-00-00-front.mp4"))
        try Sample.write(Sample.mp4(size: 3000), to: root.appendingPathComponent("SentryClips/2025-01-01_10-00-00/2025-01-01_10-00-00-front.mp4"))
        try Sample.write(Data("{}".utf8), to: root.appendingPathComponent("SentryClips/2025-01-01_10-00-00/event.json"))
        try Sample.write(Data("x".utf8), to: root.appendingPathComponent("TeslaTrackMode/x.mp4"))

        let scan = try SourceScanner.scan(root: root)
        let byPath = Dictionary(uniqueKeysWithValues: scan.files.map { ($0.relativePath, $0) })
        #expect(Set(byPath.keys) == [
            "SavedClips/\(ev)/\(ev)-front.mp4",
            "SavedClips/\(ev)/\(ev)-back.mp4",
            "SavedClips/\(ev)/event.json",
            "RecentClips/2026-07-02_14-00-00-front.mp4",
            "SentryClips/2025-01-01_10-00-00/2025-01-01_10-00-00-front.mp4",
            "SentryClips/2025-01-01_10-00-00/event.json",
        ])
        if case .encryptedVideo = byPath["SavedClips/\(ev)/\(ev)-front.mp4"]!.kind {} else { Issue.record("front") }
        if case .incompleteVideo = byPath["SavedClips/\(ev)/\(ev)-back.mp4"]!.kind {} else { Issue.record("back") }
        if case .lockedSidecar = byPath["SavedClips/\(ev)/event.json"]!.kind {} else { Issue.record("sidecar") }
        if case .plain = byPath["SentryClips/2025-01-01_10-00-00/event.json"]!.kind {} else { Issue.record("plain") }
        #expect(byPath["RecentClips/2026-07-02_14-00-00-front.mp4"]!.category == .recent)
    }

    @Test func rootCanBeASingleEventFolder() throws {
        let base = try Sample.tempDir().appendingPathComponent("Test apky")
        let saved = base.appendingPathComponent("2026-06-21_18-57-38")
        try Sample.write(Sample.mp4(size: 100), to: saved.appendingPathComponent("2026-06-21_18-55-52-front.mp4"))
        try Sample.write(Data(#"{"reason":"user_interaction_dashcam_launcher_action_tapped"}"#.utf8), to: saved.appendingPathComponent("event.json"))
        let sentry = base.appendingPathComponent("2026-06-22_10-00-00")
        try Sample.write(Sample.mp4(size: 100), to: sentry.appendingPathComponent("2026-06-22_09-59-00-back.mp4"))
        try Sample.write(Data(#"{"reason":"sentry_aware_object_detection"}"#.utf8), to: sentry.appendingPathComponent("event.json"))

        // Vybraná přímo událost i složka nad událostmi.
        #expect(try SourceScanner.scan(root: saved).files.map(\.relativePath) == [
            "SavedClips/2026-06-21_18-57-38/2026-06-21_18-55-52-front.mp4",
            "SavedClips/2026-06-21_18-57-38/event.json",
        ])
        let all = try SourceScanner.scan(root: base).files
        #expect(all.map(\.relativePath).contains("SentryClips/2026-06-22_10-00-00/2026-06-22_09-59-00-back.mp4"))
        #expect(all.filter { $0.category == .sentry }.count == 2)

        // Samostatné minutové klipy bez události = Průběžné.
        let loose = try Sample.tempDir()
        try Sample.write(Sample.mp4(size: 100), to: loose.appendingPathComponent("2026-07-02_14-00-00-front.mp4"))
        #expect(try SourceScanner.scan(root: loose).files.map(\.relativePath) == ["RecentClips/2026-07-02_14-00-00-front.mp4"])
    }

    @Test func rootCanBeACategoryFolder() throws {
        let saved = try Sample.tempDir().appendingPathComponent("SavedClips")
        try Sample.write(Sample.mp4(size: 100), to: saved.appendingPathComponent("ev/a.mp4"))
        let scan = try SourceScanner.scan(root: saved)
        #expect(scan.files.map(\.relativePath) == ["SavedClips/ev/a.mp4"])
    }
}

struct EngineTests {
    struct Setup {
        let source: URL
        let destination: URL
        let keys = StubKeys()
        var plains: [String: Data] = [:]
    }

    func makeSetup(count: Int = 5) throws -> Setup {
        let base = try Sample.tempDir()
        var setup = Setup(source: base.appendingPathComponent("TeslaCam"), destination: base.appendingPathComponent("odemčené"))
        for i in 0..<count {
            let seed = UInt8(i + 1)
            // Polovina se stejnou velikostí, aby kolidovala id.
            let plain = Sample.mp4(size: i % 2 == 0 ? 20_000 : 20_000 + i, seed: seed)
            let rel = "SavedClips/ev/clip\(i)-front.mp4"
            try Sample.write(Sample.clip(plain: plain, key: Sample.key(seed), wrapped: Sample.wrappedKey(seed)),
                             to: setup.source.appendingPathComponent("EncryptedClips/\(rel)"))
            setup.keys.keysByWrapped[Sample.wrappedKey(seed).base64EncodedString()] = Sample.key(seed)
            setup.plains[rel] = plain
        }
        try Sample.write(Sample.zeroMetadataClip(plainSize: 1000),
                         to: setup.source.appendingPathComponent("EncryptedClips/SavedClips/ev/broken-back.mp4"))
        return setup
    }

    @Test func unlocksSkipsDoneAndReportsIncomplete() async throws {
        let setup = try makeSetup()
        let options = UnlockOptions(destination: setup.destination, workers: 3, batchSize: 4)
        let scan = try SourceScanner.scan(root: setup.source)

        let log = OutcomeLog()
        let end = await UnlockEngine.run(plan: UnlockPlan(scan: scan, options: options), options: options, client: setup.keys, emit: log.add)
        #expect(end == .finished)
        for (rel, plain) in setup.plains {
            #expect(try Data(contentsOf: setup.destination.appendingPathComponent(rel)) == plain, "\(rel)")
        }
        #expect(log.all["SavedClips/ev/broken-back.mp4"] == .incomplete)
        #expect(!FileManager.default.fileExists(atPath: setup.destination.appendingPathComponent("SavedClips/ev/broken-back.mp4").path))
        for batch in setup.keys.requests { #expect(Set(batch.map(\.id)).count == batch.count) }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: setup.destination.appendingPathComponent("SavedClips/ev").path)
        #expect(leftovers.allSatisfy { !$0.hasSuffix(".part") })

        let manifest = Manifest.load(from: setup.destination)
        #expect(manifest.entries.values.filter { $0.status == .unlocked }.count == 5)
        #expect(manifest.entries["SavedClips/ev/broken-back.mp4"]?.status == .incomplete)

        // Druhý běh navazuje: nic nového se nestahuje.
        let again = UnlockPlan(scan: scan, options: options)
        #expect(again.toUnlock.isEmpty)
        #expect(again.alreadyDone.count == 5)
    }

    @Test func expiredTokenStopsAndKeepsRestPending() async throws {
        let setup = try makeSetup()
        setup.keys.failWith = .unauthorized
        let options = UnlockOptions(destination: setup.destination, batchSize: 2)
        let scan = try SourceScanner.scan(root: setup.source)
        let log = OutcomeLog()
        let end = await UnlockEngine.run(plan: UnlockPlan(scan: scan, options: options), options: options, client: setup.keys, emit: log.add)
        #expect(end == .tokenExpired)
        #expect(log.all.values.filter { $0 == .waitingForToken }.count == 5)
        #expect(setup.keys.requests.count == 1)
    }

    @Test func wrongKeyAndRejectedKeyAreNotSaved() async throws {
        let setup = try makeSetup(count: 2)
        setup.keys.keysByWrapped[Sample.wrappedKey(1).base64EncodedString()] = Sample.key(99)
        setup.keys.rejected[Sample.wrappedKey(2).base64EncodedString()] = "error.unable_to_verify_ownership"
        let options = UnlockOptions(destination: setup.destination)
        let scan = try SourceScanner.scan(root: setup.source)
        let log = OutcomeLog()
        _ = await UnlockEngine.run(plan: UnlockPlan(scan: scan, options: options), options: options, client: setup.keys, emit: log.add)

        #expect(log.all["SavedClips/ev/clip0-front.mp4"] == .failed(.container(.notMP4)))
        #expect(log.all["SavedClips/ev/clip1-front.mp4"] == .failed(.keyRejected("error.unable_to_verify_ownership")))
        let dir = setup.destination.appendingPathComponent("SavedClips/ev")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)

        // „Zkusit znovu jen chybné“
        setup.keys.keysByWrapped[Sample.wrappedKey(1).base64EncodedString()] = Sample.key(1)
        setup.keys.rejected = [:]
        var retry = options
        retry.only = ["SavedClips/ev/clip0-front.mp4", "SavedClips/ev/clip1-front.mp4"]
        let plan = UnlockPlan(scan: scan, options: retry)
        #expect(plan.toUnlock.count == 2 && plan.incomplete.isEmpty)
        let end = await UnlockEngine.run(plan: plan, options: retry, client: setup.keys, emit: log.add)
        #expect(end == .finished)
        #expect(log.all["SavedClips/ev/clip1-front.mp4"] == .unlocked(bytes: 20_001, remuxed: false, note: nil))
    }

    @Test func networkFailuresGiveUpAfterThreeBatches() async throws {
        let setup = try makeSetup()
        setup.keys.failWith = .httpStatus(503, "")
        let options = UnlockOptions(destination: setup.destination, batchSize: 1)
        let scan = try SourceScanner.scan(root: setup.source)
        let log = OutcomeLog()
        let end = await UnlockEngine.run(plan: UnlockPlan(scan: scan, options: options), options: options, client: setup.keys, emit: log.add)
        #expect(end == .gaveUp(.httpStatus(503, "")))
        #expect(setup.keys.requests.count == 3)
    }
}
