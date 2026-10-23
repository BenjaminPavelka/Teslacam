// Šifrovaný kontejner, který Tesla používá od firmwaru 2026.20 pro dashcam a Sentry.
//
// Soubor tvoří dvě hlavičkové stránky po 4096 B a za nimi payload:
//
//   0x0000   8   velikost plaintextu MP4 (uint64 BE)
//   0x0004  16   correlation id (překrývá se s velikostí, NENÍ unikátní)
//   0x0014   4   offset metadat = 0x1000 (podpis kontejneru)
//   0x1000   4   key_id (uint32 BE)
//   0x1004  65   public_key (nekomprimovaný EC bod, začíná 0x04)
//   0x1045  17   VIN (ASCII)
//   0x1056   8   timestamp (uint64 BE)
//   0x105e  44   wrapped_key
//   0x2000+      AES-CBC payload po 4096B stránkách
//
// Logika převzata z github.com/crstian19/tesla-dashcam-decrypt-go (MIT), commit ed2b751.

import CommonCrypto
import CryptoKit
import Foundation

public struct ContainerHeader: Sendable, Equatable {
    /// Correlation id ve tvaru UUID. Dva klipy stejné velikosti mají stejné id.
    public var id: String
    public var plaintextSize: UInt64
    public var vin: String
    public var keyID: UInt32
    public var timestamp: UInt64
    public var wrappedKey: Data
    public var publicKey: Data
}

public enum ContainerError: Error, Equatable, Sendable {
    /// Soubor není šifrovaný kontejner Tesly (běžné MP4, README…).
    case notEncrypted
    /// Kontejner je useknutý, nemá ani celou hlavičku.
    case truncated
    /// key_id je samé nuly: metadata se nikdy nezapsala, auto soubor nedopsalo.
    case metadataMissing
    case invalidVIN
    case invalidPublicKey
    case invalidSize
    case invalidKeyLength(Int)
    /// Payload skončil uprostřed stránky.
    case partialPage(UInt64)
    /// Payload je kratší, než hlavička slibuje.
    case shortPayload(got: UInt64, want: UInt64)
    /// Po dešifrování chybí `ftyp`: klíč nepatří k souboru (CBC nemá kontrolu integrity).
    case notMP4
    case cryptoFailure(Int32)
}

/// Čtení na libovolném offsetu. Vrací méně bajtů jen na konci zdroje.
public protocol RandomAccessReader {
    func read(at offset: UInt64, count: Int) throws -> Data
}

extension Data: RandomAccessReader {
    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset < UInt64(self.count) else { return Data() }
        let start = startIndex + Int(offset)
        let end = Swift.min(start + count, endIndex)
        return self[start..<end]
    }
}

/// Čte přes `pread`, takže nesdílí pozici a je bezpečné z více vláken.
public final class FileReader: RandomAccessReader {
    private let handle: FileHandle
    public let size: UInt64

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    public func read(at offset: UInt64, count: Int) throws -> Data {
        var buffer = Data(count: count)
        let fd = handle.fileDescriptor
        var total = 0
        while total < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + total, count - total, off_t(offset) + off_t(total))
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if n == 0 { break }
            total += n
        }
        buffer.count = total
        return buffer
    }
}

public enum Container {
    public static let pageSize = 4096
    static let metadataOffset = 0x1000
    static let payloadOffset: UInt64 = 0x2000
    static let metadataOffsetField = 0x14
    static let idRange = 4..<20
    static let keyIDSize = 4
    static let publicKeySize = 65
    static let vinSize = 17
    static let timestampSize = 8
    static let wrappedKeySize = 44
    static let metadataLength = keyIDSize + publicKeySize + vinSize + timestampSize + wrappedKeySize

    /// Rychlá kontrola podpisu bez dalšího ověřování.
    public static func hasSignature(_ reader: RandomAccessReader) -> Bool {
        guard let field = try? reader.read(at: UInt64(metadataOffsetField), count: 4), field.count == 4 else {
            return false
        }
        return field.uint32BE(at: 0) == UInt32(metadataOffset)
    }

    public static func readHeader(_ reader: RandomAccessReader) throws -> ContainerHeader {
        let probe = try reader.read(at: 0, count: metadataOffset + keyIDSize)

        // Podpis kontejneru je offset metadat. Bez něj soubor nikdy šifrovaný nebyl.
        guard probe.count >= metadataOffsetField + 4,
              probe.uint32BE(at: metadataOffsetField) == UInt32(metadataOffset)
        else { throw ContainerError.notEncrypted }
        // Podpis sedí, takže cokoli dalšího chybějícího je poškození.
        guard probe.count == metadataOffset + keyIDSize else { throw ContainerError.truncated }
        if probe.uint32BE(at: metadataOffset) == 0 { throw ContainerError.metadataMissing }

        let size = probe.uint64BE(at: 0)
        guard size > 0 else { throw ContainerError.invalidSize }

        let meta = try reader.read(at: UInt64(metadataOffset), count: metadataLength)
        guard meta.count == metadataLength else { throw ContainerError.truncated }

        var cursor = 0
        func take(_ n: Int) -> Data {
            defer { cursor += n }
            return Data(meta[meta.startIndex + cursor..<meta.startIndex + cursor + n])
        }
        let keyID = take(keyIDSize).uint32BE(at: 0)
        let publicKey = take(publicKeySize)
        let vinBytes = take(vinSize)
        let timestamp = take(timestampSize).uint64BE(at: 0)
        let wrappedKey = take(wrappedKeySize)

        guard publicKey.first == 0x04 else { throw ContainerError.invalidPublicKey }
        let trimmed = vinBytes.prefix { $0 != 0 }
        guard trimmed.count == vinSize, trimmed.allSatisfy({ $0 < 0x80 }),
              let vin = String(data: trimmed, encoding: .ascii)
        else { throw ContainerError.invalidVIN }

        let rawID = probe[probe.startIndex + idRange.lowerBound..<probe.startIndex + idRange.upperBound]
        return ContainerHeader(
            id: formatUUID(rawID),
            plaintextSize: size,
            vin: vin,
            keyID: keyID,
            timestamp: timestamp,
            wrappedKey: wrappedKey,
            publicKey: publicKey
        )
    }

    /// IV stránky = MD5(MD5(klíč) + ascii(číslo stránky)), vstup doplněný nulami na 32 B.
    public static func pageIV(rootIV: Data, page: UInt64) -> Data {
        let digits = Array(String(page).utf8)
        var material = [UInt8](repeating: 0, count: max(32, rootIV.count + digits.count))
        material.replaceSubrange(0..<rootIV.count, with: rootIV)
        material.replaceSubrange(rootIV.count..<rootIV.count + digits.count, with: digits)
        return Data(Insecure.MD5.hash(data: material))
    }

    public static func rootIV(key: Data) -> Data {
        Data(Insecure.MD5.hash(data: key))
    }

    /// Ověří, že dešifrovaná první stránka začíná `ftyp` boxem na offsetu 4.
    public static func looksLikeMP4(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        return data[data.startIndex + 4..<data.startIndex + 8] == Data("ftyp".utf8)
    }

    /// Stránek dešifrovaných v jednom kroku (1 MiB).
    static let pagesPerChunk = 256

    /// Dešifruje payload a průběžně ho předává do `write`. Vrací počet zapsaných bajtů.
    /// První stránka se ověří na `ftyp` dřív, než se cokoli zapíše.
    @discardableResult
    public static func decrypt(
        reader: RandomAccessReader,
        header: ContainerHeader,
        key: Data,
        checkCancelled: () throws -> Void = {},
        write: (Data) throws -> Void
    ) throws -> UInt64 {
        guard [16, 24, 32].contains(key.count) else { throw ContainerError.invalidKeyLength(key.count) }
        let root = rootIV(key: key)
        let want = header.plaintextSize
        var written: UInt64 = 0
        var page: UInt64 = 0

        while written < want {
            try checkCancelled()
            let remainingPages = Int((want - written + UInt64(pageSize) - 1) / UInt64(pageSize))
            let pages = min(pagesPerChunk, remainingPages)
            let offset = payloadOffset + page * UInt64(pageSize)
            let chunk = try reader.read(at: offset, count: pages * pageSize)

            if chunk.isEmpty { throw ContainerError.shortPayload(got: written, want: want) }
            let fullPages = chunk.count / pageSize
            if fullPages == 0 { throw ContainerError.partialPage(page) }

            var plain = Data(count: fullPages * pageSize)
            try chunk.withUnsafeBytes { input in
                try plain.withUnsafeMutableBytes { output in
                    for i in 0..<fullPages {
                        let iv = pageIV(rootIV: root, page: page + UInt64(i))
                        try aesCBCDecrypt(
                            key: key, iv: iv,
                            input: UnsafeRawBufferPointer(rebasing: input[i * pageSize..<(i + 1) * pageSize]),
                            output: UnsafeMutableRawBufferPointer(rebasing: output[i * pageSize..<(i + 1) * pageSize])
                        )
                    }
                }
            }

            if page == 0, !looksLikeMP4(plain) { throw ContainerError.notMP4 }

            let usable = min(UInt64(plain.count), want - written)
            try write(plain.prefix(Int(usable)))
            written += usable
            page += UInt64(fullPages)

            if fullPages < pages {
                // Zdroj skončil dřív, než bylo potřeba.
                if chunk.count % pageSize != 0 { throw ContainerError.partialPage(page) }
                if written < want { throw ContainerError.shortPayload(got: written, want: want) }
            }
        }
        return written
    }

    static func aesCBCDecrypt(
        key: Data, iv: Data,
        input: UnsafeRawBufferPointer, output: UnsafeMutableRawBufferPointer
    ) throws {
        var moved = 0
        let status = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                CCCrypt(
                    CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                    k.baseAddress, key.count, v.baseAddress,
                    input.baseAddress, input.count,
                    output.baseAddress, output.count, &moved
                )
            }
        }
        guard status == kCCSuccess else { throw ContainerError.cryptoFailure(status) }
    }

    static func formatUUID(_ bytes: Data) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let c = Array(hex)
        return [c[0..<8], c[8..<12], c[12..<16], c[16..<20], c[20..<32]].map { String($0) }.joined(separator: "-")
    }
}

extension Data {
    func uint32BE(at offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(self[startIndex + offset + i]) }
        return v
    }

    func uint64BE(at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(self[startIndex + offset + i]) }
        return v
    }
}
