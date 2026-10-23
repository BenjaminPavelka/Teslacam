import Foundation

public enum FFmpeg {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    public static func locate(_ tool: String = "ffmpeg") -> URL? {
        searchPaths
            .map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static let installHint = "ffmpeg nebyl nalezen. Nainstaluj ho v Terminálu příkazem: brew install ffmpeg"

    public struct Failure: Error, Sendable {
        public let status: Int32
        public let detail: String
    }

    /// Spustí nástroj a počká na konec. Zrušení úlohy proces ukončí.
    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        // Čtení musí běžet souběžně, jinak se plná roura zasekne.
        async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
        async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in cont.resume() }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        let (output, errors) = await (out, err)
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let lines = String(decoding: errors, as: UTF8.self)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            throw Failure(status: process.terminationStatus, detail: lines.last ?? "")
        }
        return output
    }

    /// Bezztrátově přebalí MP4 a přesune index na začátek (`-c copy -movflags faststart`).
    /// Video ani SEI telemetrie se nepřekódovávají.
    public static func remux(ffmpeg: URL, input: URL, output: URL) async throws {
        try await run(ffmpeg, [
            "-y", "-nostdin", "-loglevel", "error",
            // Vstup pevně jako MP4 a jen ze souboru: obsah je z cizího zdroje.
            "-f", "mp4", "-protocol_whitelist", "file",
            "-i", input.standardizedFileURL.path,
            "-c", "copy",
            "-movflags", "faststart",
            "-f", "mp4", output.standardizedFileURL.path,
        ])
    }
}
