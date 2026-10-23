import Foundation
import Testing
@testable import TeslaCamCore

/// Celá cesta se skutečným H.264 videem: zašifrovat → odemknout → remux.
/// Hlavně ověřuje, že remux (`-c copy`) zachová SEI zprávy, ve kterých Tesla
/// ukládá telemetrii (rychlost, brzda, FSD…).
struct RemuxTests {
    static let ffmpeg = FFmpeg.locate()
    static let marker = "TESLA-SEI-TELEMETRIE-TEST"

    @Test(.enabled(if: ffmpeg != nil, "ffmpeg není nainstalovaný"))
    func remuxKeepsSEIUserData() async throws {
        let ffmpeg = try #require(Self.ffmpeg)
        let base = try Sample.tempDir()
        let raw = base.appendingPathComponent("raw.mp4")
        try await FFmpeg.run(ffmpeg, [
            "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10:duration=2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-bsf:v", "h264_metadata=sei_user_data=086f3693-b7b3-4f2c-9653-21492feee5b8+\(Self.marker)",
            raw.path,
        ])
        let plain = try Data(contentsOf: raw)
        #expect(Container.looksLikeMP4(plain))
        #expect(plain.range(of: Data(Self.marker.utf8)) != nil)

        let rel = "SentryClips/ev/ev-front.mp4"
        let source = base.appendingPathComponent("TeslaCam/EncryptedClips")
        try Sample.write(Sample.clip(plain: plain, key: Sample.key(5), wrapped: Sample.wrappedKey(5)),
                         to: source.appendingPathComponent(rel))
        let keys = StubKeys()
        keys.keysByWrapped[Sample.wrappedKey(5).base64EncodedString()] = Sample.key(5)

        let dest = base.appendingPathComponent("out")
        let options = UnlockOptions(destination: dest, ffmpeg: ffmpeg)
        let log = OutcomeLog()
        let plan = UnlockPlan(scan: try SourceScanner.scan(root: source), options: options)
        #expect(await UnlockEngine.run(plan: plan, options: options, client: keys, emit: log.add) == .finished)
        #expect(log.all[rel] == .unlocked(bytes: UInt64(plain.count), remuxed: true, note: nil))

        let output = try Data(contentsOf: dest.appendingPathComponent(rel))
        #expect(Container.looksLikeMP4(output))
        #expect(output.range(of: Data(Self.marker.utf8)) != nil, "remux zahodil SEI telemetrii")
        // faststart: index (moov) je před daty (mdat).
        let moov = try #require(output.range(of: Data("moov".utf8)))
        let mdat = try #require(output.range(of: Data("mdat".utf8)))
        #expect(moov.lowerBound < mdat.lowerBound)
    }
}
