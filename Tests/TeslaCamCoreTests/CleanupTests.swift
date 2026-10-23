import Foundation
import Testing
@testable import TeslaCamCore

struct CleanupTests {
    static let ev = "2026-07-02_13-56-12"

    struct Setup {
        let base: URL
        let source: URL
        let destination: URL
        let keys = StubKeys()
    }

    /// Zdroj: jedna úplná událost (3 videa + zamčený event.json + README + ._),
    /// druhá událost s nedopsaným videem, jeden neodemčený průběžný klip.
    func makeUnlocked() async throws -> Setup {
        let base = try Sample.tempDir()
        let setup = Setup(base: base, source: base.appendingPathComponent("TeslaCam"), destination: base.appendingPathComponent("odemcene"))
        let enc = setup.source.appendingPathComponent("EncryptedClips")
        for (i, cam) in ["front", "back", "left_pillar"].enumerated() {
            let seed = UInt8(i + 1)
            try Sample.write(Sample.clip(plain: Sample.validMP4(size: 9000 + i, seed: seed), key: Sample.key(seed), wrapped: Sample.wrappedKey(seed)),
                             to: enc.appendingPathComponent("SavedClips/\(Self.ev)/\(Self.ev)-\(cam).mp4"))
            setup.keys.keysByWrapped[Sample.wrappedKey(seed).base64EncodedString()] = Sample.key(seed)
        }
        try Sample.write(Sample.zeroMetadataClip(plainSize: 200), to: enc.appendingPathComponent("SavedClips/\(Self.ev)/event.json"))
        try Sample.write(Data("x".utf8), to: enc.appendingPathComponent("SavedClips/\(Self.ev)/-README_cs.txt"))
        try Sample.write(Data("x".utf8), to: enc.appendingPathComponent("SavedClips/\(Self.ev)/._event.json"))
        try Sample.write(Sample.zeroMetadataClip(plainSize: 5000), to: enc.appendingPathComponent("SentryClips/2026-07-03_08-00-00/2026-07-03_07-59-00-front.mp4"))

        let options = UnlockOptions(destination: setup.destination)
        let scan = try SourceScanner.scan(root: setup.source)
        #expect(await UnlockEngine.run(plan: UnlockPlan(scan: scan, options: options), options: options, client: setup.keys, emit: { _, _ in }) == .finished)

        // Až po odemčení: průběžný klip, který se neodemykal.
        try Sample.write(Sample.clip(plain: Sample.mp4(size: 7000), key: Sample.key(9), wrapped: Sample.wrappedKey(9)),
                         to: enc.appendingPathComponent("RecentClips/2026-07-02_14-00-00-front.mp4"))
        return setup
    }

    @Test func onlyVerifiedOriginalsAreSelected() async throws {
        let setup = try await makeUnlocked()
        let plan = Cleanup.planSource(scan: try SourceScanner.scan(root: setup.source), destination: setup.destination, includePlain: false)
        let names = plan.items.map { ($0.file.url.lastPathComponent, $0.reason) }
        #expect(names.map(\.0) == ["\(Self.ev)-back.mp4", "\(Self.ev)-front.mp4", "\(Self.ev)-left_pillar.mp4", "event.json"])
        #expect(plan.items.last?.reason == .sidecar)
        let kept = Dictionary(uniqueKeysWithValues: plan.kept.map { ($0.file.url.lastPathComponent, $0.why) })
        #expect(kept["2026-07-03_07-59-00-front.mp4"] == "Nedopsaný klip, necháváme ho.")
        #expect(kept["2026-07-02_14-00-00-front.mp4"] == "Ještě není odemčený.")
    }

    @Test func damagedOutputKeepsOriginalAndItsSidecar() async throws {
        let setup = try await makeUnlocked()
        let output = setup.destination.appendingPathComponent("SavedClips/\(Self.ev)/\(Self.ev)-back.mp4")
        try Data(try Data(contentsOf: output).prefix(100)).write(to: output)
        let plan = Cleanup.planSource(scan: try SourceScanner.scan(root: setup.source), destination: setup.destination, includePlain: false)
        #expect(plan.items.map(\.file.url.lastPathComponent) == ["\(Self.ev)-front.mp4", "\(Self.ev)-left_pillar.mp4"])
        #expect(plan.kept.contains { $0.file.url.lastPathComponent == "\(Self.ev)-back.mp4" && $0.why.contains("poškozený") })
    }

    /// Odemykalo se z kopie na disku, uklízí se flashka: shoda podle otisku hlavičky.
    @Test func matchesOriginalsOnAnotherDriveByFingerprint() async throws {
        let setup = try await makeUnlocked()
        let flash = setup.base.appendingPathComponent("flashka/TeslaCam")
        try FileManager.default.createDirectory(at: flash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: setup.source, to: flash)
        // Jiný klip stejné velikosti a jména: nesmí se smazat.
        let impostor = flash.appendingPathComponent("EncryptedClips/SavedClips/\(Self.ev)/\(Self.ev)-left_pillar.mp4")
        try Sample.clip(plain: Sample.validMP4(size: 9002, seed: 50), key: Sample.key(50), wrapped: Sample.wrappedKey(50)).write(to: impostor)

        let plan = Cleanup.planSource(scan: try SourceScanner.scan(root: flash), destination: setup.destination, includePlain: false)
        #expect(plan.items.map(\.file.url.lastPathComponent) == ["\(Self.ev)-back.mp4", "\(Self.ev)-front.mp4"])
        #expect(plan.kept.contains { $0.file.url == impostor.resolvingSymlinksInPath() && $0.why.contains("Liší se") })
    }

    @Test func executeRemovesFilesAndEmptyEventFolder() async throws {
        let setup = try await makeUnlocked()
        let plan = Cleanup.planSource(scan: try SourceScanner.scan(root: setup.source), destination: setup.destination, includePlain: false)
        let result = Cleanup.executeSource(plan, method: .permanent)
        #expect(result.removed == 4 && result.failures.isEmpty)
        let fm = FileManager.default
        let saved = setup.source.appendingPathComponent("EncryptedClips/SavedClips")
        #expect(!fm.fileExists(atPath: saved.appendingPathComponent(Self.ev).path), "prázdná složka události i s README a ._ zmizí")
        #expect(fm.fileExists(atPath: saved.path), "složka kategorie zůstává")
        #expect(fm.fileExists(atPath: setup.source.appendingPathComponent("EncryptedClips/SentryClips/2026-07-03_08-00-00/2026-07-03_07-59-00-front.mp4").path))
        // Odemčená videa zůstala.
        #expect(Cleanup.verifyOutput(setup.destination.appendingPathComponent("SavedClips/\(Self.ev)/\(Self.ev)-front.mp4")) == nil)
    }

    @Test func executeSkipsFilesChangedAfterPlanning() async throws {
        let setup = try await makeUnlocked()
        let plan = Cleanup.planSource(scan: try SourceScanner.scan(root: setup.source), destination: setup.destination, includePlain: false)
        try Data("jiný obsah".utf8).write(to: plan.items[0].file.url)
        let result = Cleanup.executeSource(plan, method: .permanent)
        #expect(result.failures.map(\.path) == [plan.items[0].file.relativePath])
        #expect(FileManager.default.fileExists(atPath: plan.items[0].file.url.path))
    }

    @Test func deletedEventsAreRememberedAndFreeTheirOriginals() async throws {
        let setup = try await makeUnlocked()
        var notes = LibraryAnnotations()
        notes["SavedClips/\(Self.ev)"].decision = .delete
        notes["SavedClips/\(Self.ev)"].tags = ["x"]
        try notes.save(to: setup.destination)

        let events = LibraryScanner.scan(root: setup.destination)
        let items = Cleanup.planEventTrash(events, annotations: LibraryAnnotations.load(from: setup.destination))
        #expect(items.map(\.id) == ["SavedClips/\(Self.ev)"])
        #expect(items[0].files.count == 3 && items[0].bytes == 9000 + 9001 + 9002)
        #expect(Cleanup.verifyOutput(items[0].files[0]) == nil)

        let result = Cleanup.trashEvents(items, root: setup.destination, method: .permanent)
        #expect(result.removed == 1 && result.failures.isEmpty)
        #expect(LibraryScanner.scan(root: setup.destination).isEmpty)
        #expect(LibraryAnnotations.load(from: setup.destination).events.isEmpty)

        // Další odemykání je neobnoví…
        let scan = try SourceScanner.scan(root: setup.source)
        let plan = UnlockPlan(scan: scan, options: UnlockOptions(destination: setup.destination))
        #expect(plan.deletedByUser.count == 3)
        #expect(!plan.toUnlock.contains { $0.file.relativePath.hasPrefix("SavedClips/\(Self.ev)") })
        // …a úklid zdroje smí smazat jejich originály.
        let source = Cleanup.planSource(scan: scan, destination: setup.destination, includePlain: false)
        #expect(source.items.filter { $0.reason == .deletedByUser }.count == 3)
    }
}

/// `TP_DEMO_DIR=/cesta swift test --filter CleanupDemo`: připraví ukázková data pro UI úklidu.
struct CleanupDemo {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TP_DEMO_DIR"] != nil))
    func makeDemo() async throws {
        let setup = try await CleanupTests().makeUnlocked()
        let target = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TP_DEMO_DIR"]!)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: setup.base, to: target)
        var notes = LibraryAnnotations()
        notes["SavedClips/\(CleanupTests.ev)"].decision = .delete
        try notes.save(to: target.appendingPathComponent("odemcene"))
    }
}
