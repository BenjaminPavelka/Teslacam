import AVFoundation
import Foundation
import Observation
import TeslaCamCore

/// Šest přehrávačů na společných hodinách. Každá kamera má vlastní kompozici, ve které
/// minutové soubory navazují bez mezer; chybějící minuty jsou prázdné úseky.
@Observable @MainActor
final class MultiCamPlayer {
    private(set) var players: [Camera: AVPlayer] = [:]
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var isReady = false
    private(set) var loadError: String?
    var rate: Float = 1 {
        didSet { if isPlaying { startAll() } }
    }

    /// Zastavit přehrávání v tomto čase (přehrání výřezu).
    private var stopAt: Double?
    private var master: AVPlayer?
    private var timeObserver: Any?
    private var seekGeneration = 0
    private var lastResync = Date.distantPast

    func load(_ event: LibraryEvent, index: EventIndex) async {
        duration = index.totalDuration
        var built: [Camera: AVPlayer] = [:]
        var failed: [String] = []
        defer {
            if !failed.isEmpty { loadError = "Nepodařilo se načíst: \(failed.joined(separator: ", ")). Soubory mohou být poškozené." }
        }
        for camera in event.cameras {
            do {
                let item = AVPlayerItem(asset: try await Self.composition(event, index: index, camera: camera))
                let player = AVPlayer(playerItem: item)
                player.automaticallyWaitsToMinimizeStalling = false
                player.isMuted = true
                player.preventsDisplaySleepDuringVideoPlayback = true
                built[camera] = player
            } catch {
                failed.append(camera.title)
            }
        }
        players = built
        master = built[event.primaryCamera] ?? built.values.first
        guard let master else { return }

        timeObserver = master.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }

        // Počkat, až budou všechny položky připravené (max. ~3 s).
        for _ in 0..<60 where !built.values.allSatisfy({ $0.currentItem?.status == .readyToPlay }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        isReady = true
    }

    static func composition(_ event: LibraryEvent, index: EventIndex, camera: Camera) async throws -> AVComposition {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.featureUnsupported)
        }
        var cursor = CMTime.zero
        for (i, minute) in event.minutes.enumerated() {
            let length = CMTime(seconds: index.durations[i], preferredTimescale: 600)
            var inserted = CMTime.zero
            // Asset musí žít až do vložení, jinak vložení stopy selže (-12780).
            let asset = minute.cameras[camera].map { AVURLAsset(url: $0) }
            if let asset,
               let source = try? await asset.loadTracks(withMediaType: .video).first,
               let range = try? await source.load(.timeRange) {
                let take = CMTimeMinimum(range.duration, length)
                try track.insertTimeRange(CMTimeRange(start: range.start, duration: take), of: source, at: cursor)
                inserted = take
                if i == 0, let transform = try? await source.load(.preferredTransform) { track.preferredTransform = transform }
            }
            if inserted < length {
                track.insertEmptyTimeRange(CMTimeRange(start: cursor + inserted, duration: length - inserted))
            }
            withExtendedLifetime(asset) {}
            cursor = cursor + length
        }
        return composition
    }

    func tear() {
        if let timeObserver, let master { master.removeTimeObserver(timeObserver) }
        timeObserver = nil
        players.values.forEach { $0.pause(); $0.replaceCurrentItem(with: nil) }
        players = [:]
        master = nil
    }

    // MARK: Ovládání

    func togglePlay() { isPlaying ? pause() : play() }

    /// Přehraje jen úsek a na jeho konci zastaví.
    func play(range: TrimRange) {
        guard isReady else { return }
        // Po dokončení posunu se přehrávání spustí samo (seek pokračuje, když isPlaying).
        stopAt = range.end
        isPlaying = true
        seek(to: range.start)
    }

    func play() {
        guard isReady else { return }
        if currentTime >= duration - 0.1 { seek(to: 0) }
        isPlaying = true
        startAll()
    }

    func pause() {
        isPlaying = false
        stopAt = nil
        players.values.forEach { $0.rate = 0 }
        if let master { currentTime = master.currentTime().seconds }
    }

    /// Spustí všechny přehrávače ve stejný okamžik hostitelských hodin.
    private func startAll() {
        guard let master else { return }
        let lead = 0.1
        let host = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: lead, preferredTimescale: 1_000_000)
        let start = master.currentTime() + CMTime(seconds: lead * Double(rate), preferredTimescale: 600)
        for player in players.values where player.currentItem?.status == .readyToPlay {
            player.setRate(rate, time: start, atHostTime: host)
        }
        lastResync = Date()
    }

    func seek(to seconds: Double, exact: Bool = true) {
        let target = CMTime(seconds: min(max(0, seconds), duration), preferredTimescale: 600)
        currentTime = target.seconds
        seekGeneration += 1
        let generation = seekGeneration
        let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.25, preferredTimescale: 600)
        let resume = isPlaying
        players.values.forEach { $0.rate = 0 }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for player in players.values {
                    group.addTask { _ = await player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) }
                }
            }
            if generation == seekGeneration, resume, isPlaying { startAll() }
        }
    }

    func skip(_ delta: Double) { seek(to: currentTime + delta) }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if isPlaying, seconds >= (stopAt ?? duration) - 0.05 {
            pause()
            return
        }
        // Korekce rozjetí kamer (nejvýš jednou za 2 s).
        guard isPlaying, Date().timeIntervalSince(lastResync) > 2, let master else { return }
        let reference = master.currentTime().seconds
        let drift = players.values.map { abs($0.currentTime().seconds - reference) }.max() ?? 0
        if drift > 0.12 { startAll() }
    }
}
