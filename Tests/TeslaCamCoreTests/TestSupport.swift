import CommonCrypto
import Foundation
@testable import TeslaCamCore

/// Vyrábí šifrované kontejnery pro testy, nezávisle na čtecím kódu.
enum Sample {
    static let vin = "5YJ3E1EA7KF000001"
    static let timestamp: UInt64 = 1_782_000_000

    static func key(_ seed: UInt8) -> Data { Data((0..<16).map { seed &+ UInt8($0) }) }
    static func wrappedKey(_ seed: UInt8) -> Data { Data((0..<44).map { seed ^ UInt8($0) }) }

    /// Deterministický „MP4“ začínající `ftyp` boxem.
    static func mp4(size: Int, seed: UInt8 = 1) -> Data {
        var out = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) ^ seed })
        if size >= 12 {
            out.replaceSubrange(0..<12, with: [0, 0, 0, 12] + Array("ftypisom".utf8))
        }
        return out
    }

    /// Minimální platné MP4: ftyp, mdat se `samples` snímky a moov s tabulkami vzorků.
    /// Celková velikost = `size` (doplní se do mdat), aby šlo vyrobit soubory různých velikostí.
    static func validMP4(size: Int, seed: UInt8 = 1, samples: Int = 10) -> Data {
        func box(_ type: String, _ body: Data) -> Data {
            var d = Data(); d.putBE32(UInt32(8 + body.count)); d.append(Data(type.utf8)); d.append(body); return d
        }
        func full(_ type: String, _ body: Data) -> Data { box(type, Data(count: 4) + body) }
        func be(_ values: [UInt32]) -> Data { var d = Data(); values.forEach { d.putBE32($0) }; return d }

        let ftyp = box("ftyp", Data("isom".utf8) + be([0x200]) + Data("isomavc1".utf8))
        func moov(mdatStart: Int, sampleSize: Int) -> Data {
            let mdhd = full("mdhd", be([0, 0, 1000, UInt32(samples * 100), 0]))
            let hdlr = full("hdlr", be([0]) + Data("vide".utf8) + be([0, 0, 0]) + Data([0]))
            let stts = full("stts", be([1, UInt32(samples), 100]))
            let stsc = full("stsc", be([1, 1, UInt32(samples), 1]))
            let stsz = full("stsz", be([UInt32(sampleSize), UInt32(samples)]))
            let stco = full("stco", be([1, UInt32(mdatStart)]))
            let stss = full("stss", be([1, 1]))
            let stbl = box("stbl", stts + stsc + stsz + stco + stss)
            return box("moov", box("trak", box("mdia", mdhd + hdlr + box("minf", stbl))))
        }
        let overhead = ftyp.count + 8 + moov(mdatStart: 0, sampleSize: 0).count
        let payload = max(samples, size - overhead)
        let sampleSize = payload / samples
        let body = Data((0..<payload).map { UInt8(truncatingIfNeeded: $0 &* 13) ^ seed })
        return ftyp + box("mdat", body) + moov(mdatStart: ftyp.count + 8, sampleSize: sampleSize)
    }

    static func clip(plain: Data, key: Data, wrapped: Data = wrappedKey(1), keyID: UInt32 = 1) -> Data {
        var header = Data(count: 4096)
        header.putBE(UInt64(plain.count), at: 0)
        header.replaceSubrange(8..<16, with: [0x3c, 0x81, 0xb7, 0xf5, 0, 0, 0, 2])
        header.putBE(UInt32(0x0d0000), at: 16)
        header.putBE(UInt32(0x1000), at: 0x14)

        var meta = Data(count: 4096)
        meta.putBE(keyID, at: 0)
        meta[4] = 0x04
        for i in 0..<64 { meta[5 + i] = UInt8(i) }
        meta.replaceSubrange(69..<86, with: Data(vin.utf8))
        meta.putBE(timestamp, at: 86)
        meta.replaceSubrange(94..<138, with: wrapped)

        return header + meta + encrypt(plain, key: key)
    }

    /// Šifrovaný doplněk/nedopsaný klip: podpis kontejneru, ale metadata samé nuly.
    static func zeroMetadataClip(plainSize: Int) -> Data {
        var header = Data(count: 4096)
        header.putBE(UInt64(plainSize), at: 0)
        header.putBE(UInt32(0x1000), at: 0x14)
        return header + Data(count: 4096) + Data(repeating: 0xAB, count: 4096)
    }

    static func encrypt(_ plain: Data, key: Data) -> Data {
        var padded = plain
        if padded.count % 4096 != 0 { padded.append(Data(count: 4096 - padded.count % 4096)) }
        let root = Container.rootIV(key: key)
        var out = Data(count: padded.count)
        for page in 0..<(padded.count / 4096) {
            let iv = independentIV(root: root, page: page)
            let range = page * 4096..<(page + 1) * 4096
            let input = padded.subdata(in: range)
            var moved = 0
            var block = Data(count: 4096)
            _ = block.withUnsafeMutableBytes { o in
                input.withUnsafeBytes { i in
                    key.withUnsafeBytes { k in
                        iv.withUnsafeBytes { v in
                            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                    k.baseAddress, key.count, v.baseAddress,
                                    i.baseAddress, 4096, o.baseAddress, 4096, &moved)
                        }
                    }
                }
            }
            out.replaceSubrange(range, with: block)
        }
        return out
    }

    /// Vlastní odvození IV, aby test nekontroloval kód sám sebou.
    static func independentIV(root: Data, page: Int) -> Data {
        var material = Data(count: 32)
        material.replaceSubrange(0..<16, with: root)
        let digits = Data(String(page).utf8)
        material.replaceSubrange(16..<16 + digits.count, with: digits)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        material.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(material.count), &digest) }
        return Data(digest)
    }

    static func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
        return try Data(contentsOf: url)
    }

    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

extension Data {
    mutating func putBE32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }

    mutating func putBE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        let bytes = Swift.withUnsafeBytes(of: value.bigEndian) { Array($0) }
        replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }
}

/// Podvržený klíčový server: zná klíče podle wrapped_key.
final class StubKeys: KeyFetching, @unchecked Sendable {
    var keysByWrapped: [String: Data] = [:]
    var failWith: KeyServiceError?
    var rejected: [String: String] = [:]
    private(set) var requests: [[KeyRequestItem]] = []
    private let lock = NSLock()

    func fetchKeys(_ items: [KeyRequestItem]) async throws -> KeySet {
        try lock.withLock {
        requests.append(items)
        if let failWith { throw failWith }
        var set = KeySet()
        for item in items {
            if let code = rejected[item.wrappedKey] { set.errors[item.id] = code }
            else if let key = keysByWrapped[item.wrappedKey] { set.keys[item.id] = key }
        }
        return set
        }
    }
}

final class OutcomeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: FileOutcome] = [:]
    func add(_ file: SourceFile, _ outcome: FileOutcome) { lock.lock(); storage[file.relativePath] = outcome; lock.unlock() }
    var all: [String: FileOutcome] { lock.lock(); defer { lock.unlock() }; return storage }
}
