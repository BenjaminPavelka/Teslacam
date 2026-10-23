import Foundation

/// Minimální čtení MP4: najde video stopu a z tabulek vzorků spočítá, kde v souboru
/// leží každý snímek a kdy se zobrazí. Díky tomu jde telemetrii vytáhnout čtením
/// jen pár set bajtů na snímek, bez načítání celého videa.
public struct MP4VideoTrack: Sendable {
    public struct Sample: Sendable {
        public var offset: UInt64
        public var size: UInt32
        /// Čas dekódování v sekundách od začátku souboru.
        public var time: Double
    }

    public var codec: String
    /// Velikost délkového prefixu NAL jednotek (z `avcC`), obvykle 4.
    public var nalLengthSize: Int
    public var duration: Double
    public var samples: [Sample]
    /// Časy klíčových snímků (z `stss`; bez něj je klíčový každý snímek).
    public var keyframes: [Double]

    /// Nejbližší klíčový snímek v čase `t` nebo před ním.
    public func keyframe(atOrBefore t: Double) -> Double {
        keyframes.last { $0 <= t + 0.0005 } ?? 0
    }
}

public enum MP4Error: Error, Equatable {
    case noMovieBox
    case noVideoTrack
    case malformed(String)
}

public enum MP4 {
    struct Box {
        var type: String
        /// Začátek obsahu (za hlavičkou) a jeho délka.
        var start: Int
        var size: Int
    }

    /// Načte top-level `moov` a z něj popis video stopy.
    public static func videoTrack(_ reader: RandomAccessReader, fileSize: UInt64) throws -> MP4VideoTrack {
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            let header = try reader.read(at: offset, count: 16)
            guard header.count >= 8 else { break }
            var size = UInt64(header.uint32BE(at: 0))
            let type = String(decoding: header[header.startIndex + 4..<header.startIndex + 8], as: UTF8.self)
            var headerSize: UInt64 = 8
            if size == 1 {
                guard header.count >= 16 else { throw MP4Error.malformed("largesize") }
                size = header.uint64BE(at: 8)
                headerSize = 16
            } else if size == 0 {
                size = fileSize - offset
            }
            guard size >= headerSize else { throw MP4Error.malformed("box \(type)") }
            if type == "moov" {
                guard size < 256 << 20 else { throw MP4Error.malformed("moov je příliš velký") }
                let moov = try reader.read(at: offset + headerSize, count: Int(size - headerSize))
                return try parseMovie(Data(moov))
            }
            offset += size
        }
        throw MP4Error.noMovieBox
    }

    static func children(of data: Data, in range: Range<Int>) -> [Box] {
        var boxes: [Box] = []
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            var size = Int(data.uint32BE(at: pos))
            let type = String(decoding: data[data.startIndex + pos + 4..<data.startIndex + pos + 8], as: UTF8.self)
            var header = 8
            if size == 1, pos + 16 <= range.upperBound {
                size = Int(data.uint64BE(at: pos + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - pos
            }
            guard size >= header, pos + size <= range.upperBound else { break }
            boxes.append(Box(type: type, start: pos + header, size: size - header))
            pos += size
        }
        return boxes
    }

    static func child(_ type: String, of data: Data, in box: Box) -> Box? {
        children(of: data, in: box.start..<box.start + box.size).first { $0.type == type }
    }

    static func parseMovie(_ moov: Data) throws -> MP4VideoTrack {
        for trak in children(of: moov, in: 0..<moov.count) where trak.type == "trak" {
            guard let mdia = child("mdia", of: moov, in: trak),
                  let hdlr = child("hdlr", of: moov, in: mdia), hdlr.size >= 12,
                  String(decoding: moov[moov.startIndex + hdlr.start + 8..<moov.startIndex + hdlr.start + 12], as: UTF8.self) == "vide",
                  let mdhd = child("mdhd", of: moov, in: mdia),
                  let minf = child("minf", of: moov, in: mdia),
                  let stbl = child("stbl", of: moov, in: minf)
            else { continue }
            return try parseTrack(moov, mdhd: mdhd, stbl: stbl)
        }
        throw MP4Error.noVideoTrack
    }

    static func parseTrack(_ d: Data, mdhd: Box, stbl: Box) throws -> MP4VideoTrack {
        let version = d[d.startIndex + mdhd.start]
        let timescale: UInt32
        let mediaDuration: UInt64
        if version == 1 {
            timescale = d.uint32BE(at: mdhd.start + 20)
            mediaDuration = d.uint64BE(at: mdhd.start + 24)
        } else {
            timescale = d.uint32BE(at: mdhd.start + 12)
            mediaDuration = UInt64(d.uint32BE(at: mdhd.start + 16))
        }
        guard timescale > 0 else { throw MP4Error.malformed("timescale") }

        func table(_ type: String) -> Box? { child(type, of: d, in: stbl) }
        func u32(_ box: Box, _ i: Int) -> UInt32 { d.uint32BE(at: box.start + i) }

        // Kodek a délka NAL prefixu.
        var codec = "?"
        var nalLengthSize = 4
        if let stsd = table("stsd"), stsd.size >= 16 {
            let entries = children(of: d, in: stsd.start + 8..<stsd.start + stsd.size)
            if let entry = entries.first {
                codec = entry.type
                // Visual sample entry má 78 B pevných polí, za nimi podboxy (avcC…).
                let inner = entry.start + 78
                if inner < entry.start + entry.size,
                   let avcC = children(of: d, in: inner..<entry.start + entry.size).first(where: { $0.type == "avcC" }),
                   avcC.size >= 5 {
                    nalLengthSize = Int(d[d.startIndex + avcC.start + 4] & 0x3) + 1
                }
            }
        }

        // stsz: velikosti vzorků.
        guard let stsz = table("stsz") else { throw MP4Error.malformed("stsz") }
        let fixedSize = u32(stsz, 4)
        let count = Int(u32(stsz, 8))
        guard fixedSize != 0 || stsz.size >= 12 + count * 4 else { throw MP4Error.malformed("stsz") }
        let sizes: [UInt32] = fixedSize != 0
            ? Array(repeating: fixedSize, count: count)
            : (0..<count).map { u32(stsz, 12 + $0 * 4) }

        // stco / co64: začátky chunků.
        var chunkOffsets: [UInt64] = []
        if let stco = table("stco") {
            let n = Int(u32(stco, 4))
            guard stco.size >= 8 + n * 4 else { throw MP4Error.malformed("stco") }
            chunkOffsets = (0..<n).map { UInt64(u32(stco, 8 + $0 * 4)) }
        } else if let co64 = table("co64") {
            let n = Int(u32(co64, 4))
            guard co64.size >= 8 + n * 8 else { throw MP4Error.malformed("co64") }
            chunkOffsets = (0..<n).map { d.uint64BE(at: co64.start + 8 + $0 * 8) }
        } else {
            throw MP4Error.malformed("stco")
        }

        // stsc: kolik vzorků je v kterém chunku.
        guard let stsc = table("stsc") else { throw MP4Error.malformed("stsc") }
        let stscCount = Int(u32(stsc, 4))
        guard stsc.size >= 8 + stscCount * 12 else { throw MP4Error.malformed("stsc") }
        let runs = (0..<stscCount).map { (first: Int(u32(stsc, 8 + $0 * 12)), perChunk: Int(u32(stsc, 12 + $0 * 12))) }

        // stts: délky vzorků.
        guard let stts = table("stts") else { throw MP4Error.malformed("stts") }
        let sttsCount = Int(u32(stts, 4))
        guard stts.size >= 8 + sttsCount * 8 else { throw MP4Error.malformed("stts") }
        var deltas: [UInt32] = []
        deltas.reserveCapacity(count)
        for i in 0..<sttsCount {
            let n = Int(u32(stts, 8 + i * 8))
            deltas.append(contentsOf: repeatElement(u32(stts, 12 + i * 8), count: min(n, count - deltas.count)))
        }

        var samples: [MP4VideoTrack.Sample] = []
        samples.reserveCapacity(count)
        var sampleIndex = 0
        var decodeTime: UInt64 = 0
        for (chunkIndex, chunkOffset) in chunkOffsets.enumerated() {
            let chunkNumber = chunkIndex + 1
            let perChunk = runs.last { $0.first <= chunkNumber }?.perChunk ?? 0
            var offset = chunkOffset
            for _ in 0..<perChunk where sampleIndex < count {
                samples.append(.init(offset: offset, size: sizes[sampleIndex], time: Double(decodeTime) / Double(timescale)))
                offset += UInt64(sizes[sampleIndex])
                decodeTime += UInt64(sampleIndex < deltas.count ? deltas[sampleIndex] : 0)
                sampleIndex += 1
            }
        }

        var keyframes = samples.map(\.time)
        if let stss = table("stss") {
            let n = Int(u32(stss, 4))
            guard stss.size >= 8 + n * 4 else { throw MP4Error.malformed("stss") }
            keyframes = (0..<n).compactMap { k in
                let number = Int(u32(stss, 8 + k * 4))
                return number >= 1 && number <= samples.count ? samples[number - 1].time : nil
            }
        }

        let duration = mediaDuration > 0 ? Double(mediaDuration) / Double(timescale) : Double(decodeTime) / Double(timescale)
        return MP4VideoTrack(codec: codec, nalLengthSize: nalLengthSize, duration: duration, samples: samples, keyframes: keyframes)
    }
}
