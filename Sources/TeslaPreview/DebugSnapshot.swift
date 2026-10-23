#if DEBUG
import AppKit

/// Jen pro vývoj: `TP_SNAPSHOT=/cesta.png` uloží po chvíli snímek hlavního okna
/// (bez oprávnění k nahrávání obrazovky). `TP_SOURCE` předvyplní zdroj.
import AVFoundation
import SwiftUI

/// Snímek okna nezachytí AVPlayerLayer; pro screenshoty se místo videa vykreslí obrázek.
struct StaticFrameView: View {
    let asset: AVAsset
    let time: Double
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.black
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
        }
        .task(id: Int(time * 4)) {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        }
    }
}

enum DebugSnapshot {
    static let staticFrames = ProcessInfo.processInfo.environment["TP_STATIC_FRAMES"] != nil

    @MainActor static func dumpPlayers(label: String) {
        guard let player = activePlayer else { print(label, "žádný přehrávač"); return }
        if let error = player.loadError { print("chyba:", error) }
        for (camera, p) in player.players.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let item = p.currentItem
            print(label, camera.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0),
                  String(format: "%.3f", p.currentTime().seconds), "rate", p.rate,
                  "status", item?.status.rawValue ?? -1, "size", item?.presentationSize ?? .zero)
        }
        fflush(stdout)
    }

    static var model: AppModel?
    static weak var activePlayer: MultiCamPlayer?

    @MainActor static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let source = env["TP_SOURCE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model?.setSource(URL(fileURLWithPath: source)) }
        }
        if let dest = env["TP_DEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                model?.destination = URL(fileURLWithPath: dest)
                model?.refreshPlan()
            }
        }
        if env["TP_FAKE_TOKEN"] != nil {
            // Neplatný token jen pro screenshot (platnost +2 h, podpis smyšlený).
            let exp = Int(Date().timeIntervalSince1970) + 7200
            let payload = Data("{\"exp\":\(exp)}".utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model?.acceptToken("eyJhbGciOiJub25lIn0.\(payload).c2ln") }
        }
        if env["TP_SCREEN"] == "cleanup" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { model?.screen = .cleanup }
        }
        if env["TP_SCREEN"] == "library" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { model?.screen = .library }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { model?.library.selection = model?.library.events.first?.id }
        }
        if let seek = env["TP_SEEK"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { activePlayer?.seek(to: seek) }
        }
        if env["TP_PLAY"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { activePlayer?.play() }
            for delay in [7.5, 9.0, 11.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { dumpPlayers(label: "t+\(delay)") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.windows.first { $0.isVisible }?.setContentSize(NSSize(width: 1440, height: 1000))
        }
        guard let path = env["TP_SNAPSHOT"] else { return }
        let delay = env["TP_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
