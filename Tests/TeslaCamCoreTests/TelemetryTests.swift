import Foundation
import Testing
@testable import TeslaCamCore

struct TelemetryTests {
    /// Skutečná SEI zpráva z klipu (D1, 2026-06-21), včetně emulation prevention bajtu `00 00 03`.
    static let realNAL = Data(hex:
        "060552424242690801100118c8a810259ff409422dcdccec4135cdccccbd5936620ea0bfdb484061bcafe1583d01324069"
        + "0e846401135e41407100000300e051b8dcbf79000003002085ebe3bf8101000003008014aedbbf80")

    @Test func decodesRealTeslaSEI() throws {
        let s = try #require(Telemetry.decodeSEI(Self.realNAL))
        #expect(s.gear == .drive)
        #expect(abs(s.speedKmh - 124.2) < 0.5)
        #expect(abs(s.accelerator - 29.6) < 0.1)
        #expect(abs(s.steering - -0.1) < 0.01)
        #expect(abs(s.lat - 49.7) < 0.2)
        #expect(abs(s.lon - 18.0) < 0.2)
        #expect(s.autopilot == .none)
    }

    @Test func emulationPreventionIsStripped() {
        #expect(Telemetry.stripEmulationPrevention([0, 0, 3, 1, 0, 0, 3, 0]) == [0, 0, 1, 0, 0, 0])
        #expect(Telemetry.stripEmulationPrevention([0, 3, 0]) == [0, 3, 0])
    }

    @Test func decodesAllFields() throws {
        var pb: [UInt8] = [0x08, 1, 0x10, 1, 0x18, 7]
        pb += [0x25] + le(Float(20).bitPattern)
        pb += [0x2d] + le(Float(55).bitPattern)
        pb += [0x35] + le(Float(-12.5).bitPattern)
        pb += [0x38, 1, 0x48, 1, 0x50, 1]
        pb += [0x59] + le(Double(50.1).bitPattern)
        pb += [0x61] + le(Double(14.4).bitPattern)
        pb += [0x69] + le(Double(270).bitPattern)
        let nal = Data([0x06, 0x05, UInt8(pb.count + 5), 0x42, 0x42, 0x42, 0x69] + pb + [0x80])
        let s = try #require(Telemetry.decodeSEI(nal))
        #expect(s.frame == 7 && s.speed == 20 && s.accelerator == 55 && s.steering == -12.5)
        #expect(s.blinkLeft && !s.blinkRight && s.brake)
        #expect(s.autopilot == .selfDriving)
        #expect(s.lat == 50.1 && s.lon == 14.4 && s.heading == 270)
    }

    @Test func rejectsForeignSEI() {
        #expect(Telemetry.decodeSEI(Data([0x06, 0x05, 0x10] + Array("x264 encoder".utf8) + [0x80])) == nil)
        #expect(Telemetry.decodeSEI(Data([0x06, 0x04, 0x03, 0x42, 0x42, 0x69, 0x08, 0x01, 0x80])) == nil)
    }

    @Test func summaryAndThinning() {
        let samples = (0..<100).map { i -> TelemetrySample in
            var s = TelemetrySample(t: Double(i) * 0.05)
            s.speed = Float(i)
            s.autopilot = i < 50 ? .selfDriving : .none
            s.brake = i == 80
            return s
        }
        let summary = TelemetrySummary(samples)
        #expect(abs(summary.maxSpeedKmh - 99 * 3.6) < 0.01)
        #expect(abs(summary.seconds(.selfDriving) - 2.5) < 0.01)
        #expect(summary.brakeEvents == 1)
        #expect(Telemetry.thin(samples, hz: 10).count == 50)
    }

    /// Skutečné H.264 MP4: tabulky vzorků sedí s ffprobe a SEI se najde v každém snímku.
    @Test(.enabled(if: FFmpeg.locate() != nil))
    func parsesSampleTablesOfRealMP4() async throws {
        let ffmpeg = try #require(FFmpeg.locate())
        let url = try Sample.tempDir().appendingPathComponent("a.mp4")
        try await FFmpeg.run(ffmpeg, [
            "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10:duration=3",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-bf", "0", "-g", "10",
            "-bsf:v", "h264_metadata=sei_user_data=42424242-4242-4242-4242-424242424242+i",
            url.path,
        ])
        let reader = try FileReader(url: url)
        let track = try MP4.videoTrack(reader, fileSize: reader.size)
        #expect(track.codec == "avc1")
        #expect(track.nalLengthSize == 4)
        #expect(track.samples.count == 30)
        #expect(abs(track.duration - 3) < 0.01)
        #expect(abs(track.samples[10].time - 1) < 0.001)
        // Každý vzorek začíná platnou NAL jednotkou.
        for sample in track.samples {
            let head = try reader.read(at: sample.offset, count: 5)
            let length = head.uint32BE(at: 0)
            #expect(length > 0 && length <= sample.size)
        }
    }
}

private func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var it = hex.makeIterator()
        while let a = it.next(), let b = it.next() { bytes.append(UInt8(String([a, b]), radix: 16)!) }
        self.init(bytes)
    }
}
