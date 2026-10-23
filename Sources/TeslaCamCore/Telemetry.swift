import Foundation

/// Stav asistence řízení podle `dashcam.proto` (github.com/teslamotors/dashcam).
public enum AutopilotState: UInt8, Codable, Sendable, CaseIterable {
    case none = 0
    case selfDriving = 1
    case autosteer = 2
    case tacc = 3

    public var title: String {
        switch self {
        case .none: "Ručně"
        case .selfDriving: "FSD"
        case .autosteer: "Autosteer"
        case .tacc: "TACC"
        }
    }
}

public enum Gear: UInt8, Codable, Sendable {
    case park = 0, drive = 1, reverse = 2, neutral = 3

    public var letter: String {
        switch self {
        case .park: "P"
        case .drive: "D"
        case .reverse: "R"
        case .neutral: "N"
        }
    }
}

/// Jeden snímek telemetrie (zpráva `SeiMetadata` vložená v H.264 SEI).
/// Krátké klíče kvůli velikosti mezipaměti na disku.
public struct TelemetrySample: Codable, Sendable, Equatable {
    /// Čas v sekundách od začátku události (po zařazení do časové osy).
    public var t: Double
    public var speed: Float = 0
    public var gear: Gear = .park
    public var autopilot: AutopilotState = .none
    public var brake = false
    /// Plyn 0–100 %.
    public var accelerator: Float = 0
    /// Natočení volantu ve stupních.
    public var steering: Float = 0
    public var blinkLeft = false
    public var blinkRight = false
    public var lat: Double = 0
    public var lon: Double = 0
    public var heading: Double = 0
    public var accelX: Double = 0
    public var accelY: Double = 0
    public var frame: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case t, speed = "v", gear = "g", autopilot = "ap", brake = "b", accelerator = "a", steering = "s",
             blinkLeft = "bl", blinkRight = "br", lat, lon, heading = "h", accelX = "ax", accelY = "ay", frame = "f"
    }

    public var speedKmh: Double { Double(speed) * 3.6 }
    public var hasPosition: Bool { lat != 0 || lon != 0 }
}

public enum Telemetry {
    /// Vytáhne telemetrii ze všech snímků video souboru. Čte jen začátky snímků.
    public static func extract(from url: URL) throws -> [TelemetrySample] {
        let reader = try FileReader(url: url)
        let track = try MP4.videoTrack(reader, fileSize: reader.size)
        guard track.codec == "avc1" || track.codec == "avc3" else { return [] }
        return try extract(track: track, reader: reader)
    }

    static func extract(track: MP4VideoTrack, reader: RandomAccessReader) throws -> [TelemetrySample] {
        var result: [TelemetrySample] = []
        let lengthSize = track.nalLengthSize
        for sample in track.samples {
            let headSize = min(Int(sample.size), 512)
            var head = try reader.read(at: sample.offset, count: headSize)
            var pos = 0
            while pos + lengthSize <= head.count {
                var length = 0
                for i in 0..<lengthSize { length = length << 8 | Int(head[head.startIndex + pos + i]) }
                let nalStart = pos + lengthSize
                guard length > 0, nalStart < head.count else { break }
                let type = head[head.startIndex + nalStart] & 0x1F
                if type == 1 || type == 5 { break } // řez snímku; SEI je vždy před ním
                if type == 6 {
                    if nalStart + length > head.count {
                        guard nalStart + length <= Int(sample.size) else { break }
                        head = try reader.read(at: sample.offset, count: nalStart + length)
                    }
                    let nal = head[head.startIndex + nalStart..<head.startIndex + nalStart + length]
                    if var decoded = decodeSEI(Data(nal)) {
                        decoded.t = sample.time
                        result.append(decoded)
                        break
                    }
                }
                pos = nalStart + length
            }
        }
        return result
    }

    /// SEI NAL Tesly: `06 05 <délka> 42 42 … 69 <protobuf> 80`.
    public static func decodeSEI(_ nal: Data) -> TelemetrySample? {
        let bytes = [UInt8](nal)
        guard bytes.count >= 4, bytes[0] & 0x1F == 6, bytes[1] == 5 else { return nil }
        var i = 3
        while i < bytes.count, bytes[i] == 0x42 { i += 1 }
        guard i > 3, i + 1 < bytes.count, bytes[i] == 0x69 else { return nil }
        return decodeProtobuf(stripEmulationPrevention(Array(bytes[(i + 1)..<(bytes.count - 1)])))
    }

    static func stripEmulationPrevention(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var zeros = 0
        for byte in data {
            if zeros >= 2, byte == 0x03 { zeros = 0; continue }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// Dekóduje `SeiMetadata` bez knihovny protobufu.
    static func decodeProtobuf(_ b: [UInt8]) -> TelemetrySample? {
        var s = TelemetrySample(t: 0)
        var i = 0
        var sawField = false

        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let byte = b[i]; i += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        func fixed32() -> UInt32? {
            guard i + 4 <= b.count else { return nil }
            defer { i += 4 }
            return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
        }
        func fixed64() -> UInt64? {
            guard i + 8 <= b.count else { return nil }
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
            i += 8
            return v
        }

        while i < b.count {
            guard let key = varint() else { return nil }
            let field = key >> 3
            switch key & 7 {
            case 0:
                guard let v = varint() else { return nil }
                switch field {
                case 2: s.gear = Gear(rawValue: UInt8(truncatingIfNeeded: v)) ?? .park
                case 3: s.frame = v
                case 7: s.blinkLeft = v != 0
                case 8: s.blinkRight = v != 0
                case 9: s.brake = v != 0
                case 10: s.autopilot = AutopilotState(rawValue: UInt8(truncatingIfNeeded: v)) ?? .none
                default: break
                }
            case 1:
                guard let raw = fixed64() else { return nil }
                let v = Double(bitPattern: raw)
                switch field {
                case 11: s.lat = v
                case 12: s.lon = v
                case 13: s.heading = v
                case 14: s.accelX = v
                case 15: s.accelY = v
                default: break
                }
            case 5:
                guard let raw = fixed32() else { return nil }
                let v = Float(bitPattern: raw)
                switch field {
                case 4: s.speed = v
                case 5: s.accelerator = v
                case 6: s.steering = v
                default: break
                }
            case 2:
                guard let len = varint(), i + Int(len) <= b.count else { return nil }
                i += Int(len)
            default:
                return nil
            }
            sawField = true
        }
        return sawField ? s : nil
    }

    /// Zředí vzorky na nejvýš `hz` za sekundu (pro mezipaměť a graf).
    public static func thin(_ samples: [TelemetrySample], hz: Double = 10) -> [TelemetrySample] {
        var out: [TelemetrySample] = []
        var last = -Double.infinity
        for sample in samples where sample.t - last >= 1 / hz - 0.0001 {
            out.append(sample)
            last = sample.t
        }
        return out
    }
}

/// Souhrn pro seznam událostí.
public struct TelemetrySummary: Codable, Sendable, Equatable {
    public var maxSpeedKmh: Double = 0
    public var distanceKm: Double = 0
    /// Sekundy v jednotlivých režimech (klíč = `AutopilotState.rawValue`).
    public var autopilotSeconds: [UInt8: Double] = [:]
    public var brakeEvents = 0
    public var hasPosition = false

    public init() {}

    public init(_ samples: [TelemetrySample]) {
        var previous: TelemetrySample?
        for s in samples {
            maxSpeedKmh = max(maxSpeedKmh, s.speedKmh)
            hasPosition = hasPosition || s.hasPosition
            if let p = previous {
                let dt = max(0, min(s.t - p.t, 1))
                distanceKm += Double(p.speed) * dt / 1000
                autopilotSeconds[p.autopilot.rawValue, default: 0] += dt
                if s.brake && !p.brake { brakeEvents += 1 }
            }
            previous = s
        }
    }

    public func seconds(_ state: AutopilotState) -> Double { autopilotSeconds[state.rawValue] ?? 0 }
}
