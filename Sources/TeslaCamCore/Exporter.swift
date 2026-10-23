import Foundation

/// Export události (celé nebo jen vybraného úseku) přes ffmpeg.
public enum Exporter {
    public enum Kind: Sendable, Equatable {
        /// Jen hlavní kamera do jednoho souboru, bez překódování (telemetrie zůstává).
        case front
        /// Všechny kamery jako samostatné soubory do složky, bez překódování.
        case cameras
        /// Mozaika 3×2 ze všech kamer, překódovaná hardwarově.
        case mosaic
    }

    /// Rozložení mozaiky jako v autě: sloupky a přední nahoře, boční a zadní dole.
    static let mosaicOrder: [Camera] = [.leftPillar, .front, .rightPillar, .leftRepeater, .back, .rightRepeater]
    static let tile = (w: 960, h: 620)

    /// Úsek jednoho souboru v seznamu pro ffmpeg concat.
    struct Piece: Equatable {
        var url: URL
        var inpoint: Double?
        var outpoint: Double?
    }

    /// Které soubory dané kamery a jaké jejich části pokrývají úsek. `nil`, když kamera
    /// v některé potřebné minutě chybí. Bez překódování musí začátek ležet na klíčovém
    /// snímku, proto se posune na nejbližší předchozí (Tesla je má každých 0,5 s).
    static func pieces(_ event: LibraryEvent, index: EventIndex, camera: Camera, range: TrimRange?, snapToKeyframe: Bool) -> [Piece]? {
        let offsets = index.offsets
        var result: [Piece] = []
        for (i, minute) in event.minutes.enumerated() {
            let segStart = offsets[i], segEnd = offsets[i] + index.durations[i]
            if let range, range.end <= segStart || range.start >= segEnd { continue }
            guard let url = minute.cameras[camera] else { return nil }
            var piece = Piece(url: url)
            if let range, range.start > segStart + 0.001 {
                var local = range.start - segStart
                if snapToKeyframe, let reader = try? FileReader(url: url),
                   let track = try? MP4.videoTrack(reader, fileSize: reader.size) {
                    local = track.keyframe(atOrBefore: local)
                }
                piece.inpoint = local > 0.001 ? local : nil
            }
            if let range, range.end < segEnd - 0.001 { piece.outpoint = range.end - segStart }
            result.append(piece)
        }
        return result.isEmpty ? nil : result
    }

    /// Název souborů ve stylu Tesly podle skutečného času začátku úseku.
    public static func clipPrefix(_ event: LibraryEvent, index: EventIndex, range: TrimRange?) -> String {
        LibraryScanner.formatTimestamp(event.clockTime(at: range?.start ?? 0, index: index))
    }

    /// Exportuje do `output`: u `.cameras` je to složka (vytvoří se), jinak soubor.
    public static func export(
        _ event: LibraryEvent, index: EventIndex, kind: Kind, range: TrimRange? = nil, to output: URL, ffmpeg: URL
    ) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("tp-export-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let temp = output.deletingLastPathComponent().appendingPathComponent(".tp-\(UUID().uuidString).part")
        defer { try? fm.removeItem(at: temp) }
        let length = range?.duration ?? index.totalDuration

        switch kind {
        case .front:
            guard let pieces = pieces(event, index: index, camera: event.primaryCamera, range: range, snapToKeyframe: true) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try await FFmpeg.run(ffmpeg, base() + concatInput(pieces, list: work.appendingPathComponent("front.txt")) + copyOutput(temp))

        case .cameras:
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            let prefix = clipPrefix(event, index: index, range: range)
            for camera in event.cameras {
                // Kamera, která v úseku chybí, se přeskočí.
                guard let pieces = pieces(event, index: index, camera: camera, range: range, snapToKeyframe: true) else { continue }
                let file = temp.appendingPathComponent("\(prefix)-\(camera.rawValue).mp4")
                try await FFmpeg.run(ffmpeg, base() + concatInput(pieces, list: work.appendingPathComponent("\(camera.rawValue).txt")) + copyOutput(file))
            }

        case .mosaic:
            var args = base()
            var filters: [String] = []
            for (i, camera) in mosaicOrder.enumerated() {
                if let pieces = pieces(event, index: index, camera: camera, range: range, snapToKeyframe: false) {
                    args += concatInput(pieces, list: work.appendingPathComponent("\(camera.rawValue).txt"))
                } else {
                    // Kamera chybí: místo ní černá plocha.
                    args += ["-f", "lavfi", "-i", "color=c=black:s=\(tile.w)x\(tile.h):r=30:d=\(length)"]
                }
                filters.append("[\(i):v]setpts=PTS-STARTPTS,scale=\(tile.w):\(tile.h):force_original_aspect_ratio=decrease,"
                    + "pad=\(tile.w):\(tile.h):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30[v\(i)]")
            }
            let layout = "0_0|\(tile.w)_0|\(tile.w * 2)_0|0_\(tile.h)|\(tile.w)_\(tile.h)|\(tile.w * 2)_\(tile.h)"
            filters.append("[v0][v1][v2][v3][v4][v5]xstack=inputs=6:layout=\(layout),format=yuv420p[out]")
            args += [
                "-filter_complex", filters.joined(separator: ";"), "-map", "[out]",
                "-t", String(length),
                "-c:v", "h264_videotoolbox", "-b:v", "20M",
                "-movflags", "faststart", "-f", "mp4", temp.path,
            ]
            try await FFmpeg.run(ffmpeg, args)
        }

        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        try fm.moveItem(at: temp, to: output)
    }

    /// Uloží úsek (všechny kamery, bez ztráty) jako novou událost do knihovny.
    /// Složka dostane jméno podle času konce úseku, `event.json` se převezme.
    @discardableResult
    public static func saveToLibrary(
        _ event: LibraryEvent, index: EventIndex, range: TrimRange, root: URL, ffmpeg: URL
    ) async throws -> String {
        let category = event.category == .recent ? ClipCategory.saved : event.category
        var end = event.clockTime(at: range.end, index: index)
        let parent = root.appendingPathComponent(category.rawValue)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Stejný název (sekunda) by přepsal jinou událost.
        while FileManager.default.fileExists(atPath: parent.appendingPathComponent(LibraryScanner.formatTimestamp(end)).path) {
            end.addTimeInterval(1)
        }
        let name = LibraryScanner.formatTimestamp(end)
        let target = parent.appendingPathComponent(name)
        try await export(event, index: index, kind: .cameras, range: range, to: target, ffmpeg: ffmpeg)
        if let folder = event.folder {
            try? FileManager.default.copyItem(at: folder.appendingPathComponent("event.json"), to: target.appendingPathComponent("event.json"))
        }
        return "\(category.rawValue)/\(name)"
    }

    static func base() -> [String] { ["-y", "-nostdin", "-loglevel", "error"] }

    static func copyOutput(_ url: URL) -> [String] {
        ["-map", "0:v", "-c", "copy", "-avoid_negative_ts", "make_zero", "-movflags", "faststart", "-f", "mp4", url.path]
    }

    static func concatInput(_ pieces: [Piece], list: URL) -> [String] {
        var lines: [String] = []
        for piece in pieces {
            lines.append("file '\(piece.url.path.replacingOccurrences(of: "'", with: "'\\''"))'")
            if let inpoint = piece.inpoint { lines.append("inpoint \(String(format: "%.6f", inpoint))") }
            if let outpoint = piece.outpoint { lines.append("outpoint \(String(format: "%.6f", outpoint))") }
        }
        try? lines.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        return ["-f", "concat", "-safe", "0", "-protocol_whitelist", "file", "-i", list.path]
    }
}
