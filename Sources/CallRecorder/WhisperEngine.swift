import Foundation
import AVFoundation

/// Local, offline speech recognition with whisper.cpp (`brew install whisper-cpp`).
/// Much better than Apple's recognizer for Russian, German and mixed-language calls.
enum WhisperEngine {
    struct Segment {
        var start: Double   // seconds from the start of the audio that was transcribed
        var text: String
    }

    enum WhisperError: LocalizedError {
        case notInstalled
        case noModel
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "whisper-cli not found. Run ./setup-whisper.sh (or: brew install whisper-cpp)."
            case .noModel: return "No Whisper model found. Run ./setup-whisper.sh to download one."
            case .failed(let m): return m
            }
        }
    }

    // MARK: Locating the tools

    static func cliPath() -> String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        let names = ["whisper-cli", "whisper-cpp"]
        for d in dirs { for n in names {
            let p = "\(d)/\(n)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        } }
        return nil
    }

    static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallRecorder/models", isDirectory: true)
    }

    /// Best model that is installed, preferring accuracy-per-speed.
    static func modelPath() -> String? {
        let preferred = ["ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3-turbo.bin",
                         "ggml-large-v3-q5_0.bin", "ggml-large-v3.bin",
                         "ggml-medium-q5_0.bin", "ggml-medium.bin",
                         "ggml-small.bin", "ggml-base.bin"]
        for name in preferred {
            let p = modelsDir.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    static var isReady: Bool { cliPath() != nil && modelPath() != nil }

    /// whisper-server keeps the model loaded, which live transcription needs. Homebrew's package may include it;
    /// otherwise setup-whisper.sh builds it into Application Support/CallRecorder/bin.
    static func serverPath() -> String? {
        let candidates = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server",
                          FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                              .appendingPathComponent("CallRecorder/bin/whisper-server").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isLiveReady: Bool { serverPath() != nil && modelPath() != nil }

    /// "en-GB" -> "en"; "auto" stays "auto".
    static func languageCode(from localeID: String) -> String {
        localeID == "auto" ? "auto" : String(localeID.split(separator: "-").first ?? "en")
    }

    // MARK: Running whisper-cli (blocking; call off the main thread)

    static func run(wav: URL, language: String) throws -> [Segment] {
        guard let cli = cliPath() else { throw WhisperError.notInstalled }
        guard let model = modelPath() else { throw WhisperError.noModel }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["-m", model, "-f", wav.path, "-l", language, "-np",
                       "-t", String(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))]
        let out = Pipe()
        p.standardOutput = out
        // whisper-cli is chatty on stderr; a file avoids pipe-buffer deadlocks.
        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errURL)
        p.standardError = errHandle
        defer { try? errHandle.close(); try? FileManager.default.removeItem(at: errURL) }

        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let log = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            throw WhisperError.failed("whisper-cli failed (\(p.terminationStatus)): \(log.suffix(300))")
        }
        return parse(String(data: data, encoding: .utf8) ?? "")
    }

    /// Lines look like: [00:00:03.000 --> 00:00:07.500]   Hello there
    static func parse(_ output: String) -> [Segment] {
        guard let re = try? NSRegularExpression(
            pattern: #"^\[(\d+):(\d+):(\d+)[.,](\d+)\s*-->\s*[^\]]*\]\s*(.*)$"#) else { return [] }
        var segs: [Segment] = []
        for line in output.components(separatedBy: .newlines) {
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let h = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let mi = Double(ns.substring(with: m.range(at: 2))) ?? 0
            let s = Double(ns.substring(with: m.range(at: 3))) ?? 0
            let text = ns.substring(with: m.range(at: 5)).trimmingCharacters(in: .whitespaces)
            if isNoise(text) { continue }
            segs.append(Segment(start: h * 3600 + mi * 60 + s, text: text))
        }
        return segs
    }

    /// Drops markers such as [BLANK_AUDIO], (music), [Music] that Whisper emits for non-speech.
    static func isNoise(_ t: String) -> Bool {
        if t.isEmpty { return true }
        let trimmed = t.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) ||
               (trimmed.hasPrefix("(") && trimmed.hasSuffix(")")) ||
               (trimmed.hasPrefix("♪") && trimmed.hasSuffix("♪"))
    }

    // MARK: Whole-file transcription (step 2)

    /// Converts any audio file to 16 kHz mono WAV with ffmpeg, runs Whisper, returns text with [mm:ss] markers.
    static func transcribeFile(_ input: URL, language: String) throws -> String {
        guard let ffmpeg = AppState.ffmpegPath() else {
            throw WhisperError.failed("ffmpeg not found — run: brew install ffmpeg")
        }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-in-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-loglevel", "error", "-i", input.path, "-ar", "16000", "-ac", "1",
                       "-c:a", "pcm_s16le", wav.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw WhisperError.failed("ffmpeg could not read \(input.lastPathComponent)") }

        let segs = try run(wav: wav, language: language)
        return format(segs)
    }

    /// New paragraph with a [mm:ss] marker roughly every 30 seconds.
    static func format(_ segs: [Segment]) -> String {
        var out = ""
        var lastMark = -100.0
        for seg in segs {
            if seg.start - lastMark >= 30 {
                let s = Int(seg.start)
                out += (out.isEmpty ? "" : "\n\n") + String(format: "[%02d:%02d] ", s / 60, s % 60)
                lastMark = seg.start
            } else {
                out += " "
            }
            out += seg.text
        }
        return out
    }
}
