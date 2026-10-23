import Foundation
import Testing
@testable import TeslaCamCore

struct ContainerTests {
    let fixtureKey = Data(0..<16)

    /// Vektory spočítané nezávisle Pythonem (převzato z referenční Go implementace).
    @Test func pageIVMatchesReferenceVectors() {
        let root = Container.rootIV(key: fixtureKey)
        #expect(root.hex == "1ac1ef01e96caf1be0d329331a4fc2a8")
        let vectors: [(UInt64, String)] = [
            (0, "cd096e1db464e9b4c91e51419090606b"),
            (1, "41e2d33e4f39f1b90c7b306fc13cb684"),
            (2, "502b4d57690da26dfd03852339ce4733"),
            (9, "ea706b3d1e79a424baa00a982a3eabc4"),
            (10, "5ce066bcdaf9ef30ca01ce592e8d196e"),
            (12345, "4e0ad9f8ed3c8b1c943f3bc6f6a4a6a6"),
        ]
        for (page, want) in vectors {
            #expect(Container.pageIV(rootIV: root, page: page).hex == want, "stránka \(page)")
        }
    }

    @Test func parsesGoldenHeader() throws {
        let header = try Container.readHeader(try Sample.fixture("real_clip.enc"))
        #expect(header.id == "00001388-3c81-b7f5-0000-0002000d0000")
        #expect(header.plaintextSize == 5000)
        #expect(header.vin == "5YJ3E1EA7KF000001")
        #expect(header.keyID == 1)
        #expect(header.timestamp == 1_782_000_000)
        #expect(header.publicKey.count == 65 && header.publicKey.first == 0x04)
        #expect(header.wrappedKey.count == 44)
    }

    /// Vzorek zašifrovaný OpenSSL: ověřuje formát, ne vlastní šifrovací kód.
    @Test func decryptsGoldenClip() throws {
        let encrypted = try Sample.fixture("real_clip.enc")
        let want = try Sample.fixture("real_clip.mp4")
        let header = try Container.readHeader(encrypted)
        var got = Data()
        let n = try Container.decrypt(reader: encrypted, header: header, key: fixtureKey) { got.append($0) }
        #expect(n == UInt64(want.count))
        #expect(got == want)
    }

    @Test func roundTripsAcrossChunkBoundaries() throws {
        // Přes hranici 256 stránek (1 MiB) a s neúplnou poslední stránkou.
        let plain = Sample.mp4(size: 4096 * 300 + 123, seed: 9)
        let key = Sample.key(42)
        let clip = Sample.clip(plain: plain, key: key)
        let header = try Container.readHeader(clip)
        var got = Data()
        try Container.decrypt(reader: clip, header: header, key: key) { got.append($0) }
        #expect(got == plain)
    }

    @Test func wrongKeyIsDetectedByFtypCheck() throws {
        let clip = Sample.clip(plain: Sample.mp4(size: 10_000), key: Sample.key(1))
        let header = try Container.readHeader(clip)
        var written = 0
        #expect(throws: ContainerError.notMP4) {
            try Container.decrypt(reader: clip, header: header, key: Sample.key(2)) { written += $0.count }
        }
        #expect(written == 0, "při špatném klíči se nesmí nic zapsat")
    }

    @Test func ftypCheck() {
        #expect(Container.looksLikeMP4(Sample.mp4(size: 64)))
        #expect(!Container.looksLikeMP4(Data(repeating: 0x55, count: 64)))
        #expect(!Container.looksLikeMP4(Data("ftyp".utf8)))
    }

    @Test func zeroKeyIDMeansIncomplete() {
        #expect(throws: ContainerError.metadataMissing) {
            try Container.readHeader(Sample.zeroMetadataClip(plainSize: 5000))
        }
        var clip = Sample.clip(plain: Sample.mp4(size: 5000), key: Sample.key(1))
        clip.replaceSubrange(0x1000..<0x1004, with: [0, 0, 0, 0])
        #expect(throws: ContainerError.metadataMissing) { try Container.readHeader(clip) }
    }

    @Test func plainMP4IsNotEncrypted() {
        #expect(throws: ContainerError.notEncrypted) { try Container.readHeader(Sample.mp4(size: 10_000)) }
        #expect(!Container.hasSignature(Sample.mp4(size: 10_000)))
    }

    @Test func truncatedFiles() throws {
        let clip = Sample.clip(plain: Sample.mp4(size: 20_000), key: Sample.key(1))
        #expect(throws: ContainerError.truncated) { try Container.readHeader(clip.prefix(2000)) }
        #expect(throws: ContainerError.truncated) { try Container.readHeader(clip.prefix(0x1020)) }

        // Hlavička celá, ale payload useknutý: nesmí projít jako úspěch.
        let cut = clip.prefix(0x2000 + 4096 * 2)
        let header = try Container.readHeader(cut)
        #expect(throws: ContainerError.self) {
            try Container.decrypt(reader: cut, header: header, key: Sample.key(1)) { _ in }
        }
        let midPage = clip.prefix(0x2000 + 4096 + 100)
        #expect(throws: ContainerError.partialPage(1)) {
            try Container.decrypt(reader: midPage, header: header, key: Sample.key(1)) { _ in }
        }
    }

    @Test func idCollidesForSameSize() throws {
        let a = Sample.clip(plain: Sample.mp4(size: 7000, seed: 1), key: Sample.key(1), wrapped: Sample.wrappedKey(1))
        let b = Sample.clip(plain: Sample.mp4(size: 7000, seed: 2), key: Sample.key(2), wrapped: Sample.wrappedKey(2))
        #expect(try Container.readHeader(a).id == Container.readHeader(b).id)
    }

    @Test func badVINAndPublicKey() {
        var clip = Sample.clip(plain: Sample.mp4(size: 5000), key: Sample.key(1))
        clip[0x1004] = 0x02
        #expect(throws: ContainerError.invalidPublicKey) { try Container.readHeader(clip) }
        clip[0x1004] = 0x04
        clip[0x1045 + 5] = 0
        #expect(throws: ContainerError.invalidVIN) { try Container.readHeader(clip) }
    }

    @Test func fileReaderMatchesData() throws {
        let dir = try Sample.tempDir()
        let data = Sample.clip(plain: Sample.mp4(size: 50_000), key: Sample.key(3))
        let url = dir.appendingPathComponent("x.mp4")
        try data.write(to: url)
        let reader = try FileReader(url: url)
        #expect(reader.size == UInt64(data.count))
        #expect(try reader.read(at: 100, count: 5000) == data.subdata(in: 100..<5100))
        #expect(try reader.read(at: UInt64(data.count - 10), count: 100).count == 10)
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
