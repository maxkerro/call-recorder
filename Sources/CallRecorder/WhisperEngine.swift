import Foundation
import AVFoundation

/// Local, offline speech recognition with whisper.cpp (`brew install whisper-cpp`).
/// Much better than Apple's recognizer for Russian, German and mixed-language calls.
enum WhisperEngine {
    struct Segment {
        var start: Double   // seconds from the start of the audio that was transcribed
        var text: String
        var end: Double = 0
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

    /// Best installed model. Files favour accuracy (large-v3); live favours speed (large-v3-turbo).
    static func modelPath(live: Bool = false) -> String? {
        let accurate = ["ggml-large-v3.bin", "ggml-large-v3-q5_0.bin",
                        "ggml-large-v3-turbo.bin", "ggml-large-v3-turbo-q5_0.bin",
                        "ggml-medium.bin", "ggml-small.bin", "ggml-base.bin"]
        let fast = ["ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3-turbo.bin",
                    "ggml-large-v3-q5_0.bin", "ggml-large-v3.bin",
                    "ggml-medium.bin", "ggml-small.bin", "ggml-base.bin"]
        for name in (live ? fast : accurate) {
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

    static var isLiveReady: Bool { serverPath() != nil && modelPath(live: true) != nil }

    // MARK: Accuracy helpers

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallRecorder", isDirectory: true)
    }

    static var vocabularyURL: URL { supportDir.appendingPathComponent("vocabulary.txt") }

    /// Names and terms (one per line, "#" starts a comment) handed to Whisper as context, so it spells them right.
    private static func vocabularyLines() -> [String] {
        guard let raw = try? String(contentsOf: vocabularyURL, encoding: .utf8) else { return [] }
        return raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func vocabularyTerms() -> [String] { vocabularyLines().filter { !$0.hasPrefix("!") } }

    static func vocabularyPrompt() -> String { String(vocabularyTerms().joined(separator: ", ").prefix(600)) }

    /// Phrases that must never appear in a transcript: lines starting with "!" in the vocabulary file.
    static func userBlocklist() -> [String] {
        vocabularyLines().filter { $0.hasPrefix("!") }
            .map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: Hallucination filters

    /// Lower-case letters and digits only ("SAFe," -> "safe").
    static func norm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Phrases Whisper makes up on silence, breath or noise: subtitle credits and sign-offs from its training data.
    private static let hallucinationPatterns: [NSRegularExpression] = [
        #"субтитры\s+(?:создавал|создал|сделал|делал|подогнал|предоставил)\p{L}*(?:\s+[\p{L}\d._\-]+)?"#,
        #"редактор\s+субтитров(?:\s+\p{L}\.[\p{L}\-]+)?"#,
        #"корректор\s+\p{L}\.[\p{L}\-]+"#,
        #"dimatorzok"#,
        #"untertitel\w*\s+(?:der|des|von|im\s+auftrag)\s+[\w.\-]+(?:\s+[\w.\-]+){0,2}"#,
        #"amara\.org\S*"#,
        #"(?:thanks?|thank\s+you)\s+for\s+watching\W*"#,
        #"subtitles?\s+(?:by|made\s+by|created\s+by)\s+[\w.\-]+(?:\s+[\w.\-]+)?"#,
        #"продолжение\s+следует\W*"#,
        #"vielen\s+dank\s+f(?:ü|u)rs\s+zuschauen\W*"#,
        #"подписывайтесь\s+на\s+(?:наш\s+)?канал\W*"#,
        #"спасибо\s+за\s+просмотр\W*"#,
    ].compactMap { try? NSRegularExpression(pattern: "(?i)" + $0) }

    /// Removes made-up phrases (built-in list plus the user's "!" lines). Returns the text unchanged if nothing matched.
    static func scrub(_ text: String, blocklist: [String] = []) -> String {
        let extra = blocklist.compactMap {
            try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: $0), options: [.caseInsensitive])
        }
        var t = text
        for re in hallucinationPatterns + extra {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        guard t != text else { return text }
        return t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:-–—")))
    }

    /// The vocabulary as a flat word sequence, used to recognise Whisper reading its own hint back.
    static func vocabularySequence() -> [String] {
        vocabularyTerms().flatMap { $0.split(whereSeparator: \.isWhitespace) }
            .map { norm(String($0)) }.filter { !$0.isEmpty }
    }

    /// Indices of words that merely echo the vocabulary hint: a run of 3+ words that follows the vocabulary order,
    /// or a run of 2+ at the very end of the text (the typical "…, HMI, SAFe, Scrum" tail after a breath).
    static func echoIndices(_ norms: [String], seq: [String]) -> Set<Int> {
        guard seq.count >= 2, norms.count >= 2 else { return [] }
        var drop = Set<Int>()
        var i = 0
        while i < norms.count {
            var best = 0
            if !norms[i].isEmpty {
                for start in seq.indices where seq[start] == norms[i] {
                    var k = 0
                    while i + k < norms.count, start + k < seq.count, norms[i + k] == seq[start + k] { k += 1 }
                    best = max(best, k)
                }
            }
            if best >= 3 || (best >= 2 && i + best == norms.count) {
                for j in i..<(i + best) { drop.insert(j) }
            }
            i += max(best, 1)
        }
        return drop
    }

    static func stripPromptEcho(_ text: String, seq: [String]) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let drop = echoIndices(words.map(norm), seq: seq)
        guard !drop.isEmpty else { return text }
        return words.enumerated().filter { !drop.contains($0.offset) }.map(\.element).joined(separator: " ")
    }

    /// Creates the vocabulary file with a starter template if it doesn't exist, and returns its URL.
    @discardableResult
    static func ensureVocabularyFile() -> URL {
        let url = vocabularyURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let template = """
            # Words Whisper should spell correctly: names, products, jargon, abbreviations. One per line.
            # Lines starting with # are ignored. Keep it short (a few dozen terms) for best results.
            # A line starting with ! is a phrase that must never appear in a transcript, for example:
            # ! Subtitles by the Amara.org community
            Mercedes-Benz
            Luxoft
            infotainment
            HMI
            SAFe
            Scrum
            Telemost
            """
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Voice-activity-detection model; makes Whisper skip silence and music instead of inventing text.
    static func vadModelPath() -> String? {
        let p = modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin").path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// "en-GB" -> "en"; "auto" stays "auto".
    static func languageCode(from localeID: String) -> String {
        localeID == "auto" ? "auto" : String(localeID.split(separator: "-").first ?? "en")
    }

    // MARK: Running whisper-cli (blocking; call off the main thread)

    static func run(wav: URL, language: String, quality: Bool = false) throws -> [Segment] {
        guard let cli = cliPath() else { throw WhisperError.notInstalled }
        guard let model = modelPath() else { throw WhisperError.noModel }

        let threads = String(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        let base = ["-m", model, "-f", wav.path, "-l", language, "-np", "-t", threads]
        var extra: [String] = []
        if quality {
            extra += ["-bs", "5", "-bo", "5", "-sns"]            // beam search, suppress music/noise tokens
            let prompt = vocabularyPrompt()
            if !prompt.isEmpty { extra += ["--prompt", prompt, "--carry-initial-prompt"] }
            if let vad = vadModelPath() { extra += ["--vad", "-vm", vad] }
        }
        do {
            return try execute(cli: cli, args: base + extra)
        } catch where !extra.isEmpty {
            // An older whisper-cli may not know some option: retry with the basics rather than failing.
            return try execute(cli: cli, args: base)
        }
    }

    private static func execute(cli: String, args: [String]) throws -> [Segment] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
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
            pattern: #"^\[(\d+):(\d+):(\d+)[.,](\d+)\s*-->\s*(\d+):(\d+):(\d+)[.,](\d+)\s*\]\s*(.*)$"#) else { return [] }
        var segs: [Segment] = []
        let seq = vocabularySequence()
        let blocked = userBlocklist()
        for line in output.components(separatedBy: .newlines) {
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let h = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let mi = Double(ns.substring(with: m.range(at: 2))) ?? 0
            let s = (Double(ns.substring(with: m.range(at: 3))) ?? 0)
                  + (Double("0." + ns.substring(with: m.range(at: 4))) ?? 0)
            let eh = Double(ns.substring(with: m.range(at: 5))) ?? 0
            let em = Double(ns.substring(with: m.range(at: 6))) ?? 0
            let es = (Double(ns.substring(with: m.range(at: 7))) ?? 0)
                   + (Double("0." + ns.substring(with: m.range(at: 8))) ?? 0)
            let raw = ns.substring(with: m.range(at: 9)).trimmingCharacters(in: .whitespaces)
            let text = stripPromptEcho(scrub(raw, blocklist: blocked), seq: seq)
            if isNoise(text) { continue }
            let start = h * 3600 + mi * 60 + s
            segs.append(Segment(start: start, text: text, end: max(start, eh * 3600 + em * 60 + es)))
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

    /// Converts any audio file to 16 kHz mono WAV with ffmpeg (levelling the volume), then runs Whisper.
    static func segments(of input: URL, language: String) throws -> [Segment] {
        guard let ffmpeg = AppState.ffmpegPath() else {
            throw WhisperError.failed("ffmpeg not found — run: brew install ffmpeg")
        }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-in-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        // loudnorm brings quiet recordings (a faint mic or call) to a level Whisper handles well.
        p.arguments = ["-y", "-loglevel", "error", "-i", input.path,
                       "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "16000", "-ac", "1",
                       "-c:a", "pcm_s16le", wav.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw WhisperError.failed("ffmpeg could not read \(input.lastPathComponent)") }

        return try run(wav: wav, language: language, quality: true)
    }

    /// Whole file as text with [mm:ss] markers (step 2).
    static func transcribeFile(_ input: URL, language: String) throws -> String {
        format(try segments(of: input, language: language))
    }

    /// True when the track is (nearly) digital silence, e.g. the other side never spoke or nothing played.
    /// Whisper invents text for silence, so such tracks are skipped.
    static func isSilent(_ url: URL) -> Bool {
        guard let ffmpeg = AppState.ffmpegPath() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-nostats", "-i", url.path, "-af", "volumedetect", "-f", "null", "-"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let r = text.range(of: "max_volume: "),
              let end = text[r.upperBound...].range(of: " dB"),
              let v = Double(text[r.upperBound..<end.lowerBound]) else { return false }
        return v < -50
    }

    /// The accurate "check" pass: transcribes the call-audio track ("Them") and the microphone track ("Me")
    /// separately, so overlapping speech doesn't confuse Whisper, and returns speaker-labelled lines.
    static func transcribeTracks(system: URL?, mic: URL?, language: String,
                                 turns: [SpeakerTurn] = []) throws -> [String] {
        var all: [(t: Double, label: String, text: String)] = []
        for (url, label) in [(system, "Them"), (mic, "Me")] {
            guard let url, !isSilent(url) else { continue }
            for seg in try segments(of: url, language: language) {
                if label == "Them" && !turns.isEmpty {
                    all += split(seg, by: turns, fallback: label)
                } else {
                    all.append((seg.start, label, seg.text))
                }
            }
        }
        return lines(from: all)
    }

    /// Whole file with speaker labels: diarization of the (mixed) file decides who says each segment.
    static func transcribeFileWithSpeakers(_ input: URL, language: String, turns: [SpeakerTurn]) throws -> [String] {
        var all: [(t: Double, label: String, text: String)] = []
        for seg in try segments(of: input, language: language) {
            all += split(seg, by: turns, fallback: "Speaker ?")
        }
        return lines(from: all)
    }

    /// Word-level speaker assignment: a segment may hold several voices, so each word gets an estimated time
    /// (spread over the segment in proportion to its length) and the speaker talking at that moment.
    /// Consecutive words of one speaker are joined again.
    static func split(_ seg: Segment, by turns: [SpeakerTurn], fallback: String)
        -> [(t: Double, label: String, text: String)] {
        let words = seg.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1, seg.end > seg.start else {
            return [(seg.start, speaker(for: seg, in: turns) ?? fallback, seg.text)]
        }
        let weights = words.map { Double(max($0.count, 2)) }
        let total = weights.reduce(0, +)
        var t = seg.start
        var out: [(t: Double, label: String, text: String)] = []
        for (w, wt) in zip(words, weights) {
            let dur = (seg.end - seg.start) * wt / total
            let mid = t + dur / 2
            let who = speaker(at: mid, in: turns) ?? out.last?.label ?? fallback
            if let i = out.indices.last, out[i].label == who {
                out[i].text += " " + w
            } else {
                out.append((t, who, w))
            }
            t += dur
        }
        return out
    }

    /// Speaker at a moment; in a gap between turns, the nearest turn within 1.5 s.
    static func speaker(at time: Double, in turns: [SpeakerTurn]) -> String? {
        if let t = turns.first(where: { $0.start <= time && time <= $0.end }) { return t.speaker }
        let near = turns.min { abs(($0.start + $0.end) / 2 - time) - ($0.end - $0.start) / 2
                             < abs(($1.start + $1.end) / 2 - time) - ($1.end - $1.start) / 2 }
        guard let n = near else { return nil }
        let gap = time < n.start ? n.start - time : time - n.end
        return gap <= 1.5 ? n.speaker : nil
    }

    /// The speaker whose turns overlap the segment the most (nil when nobody was detected there).
    static func speaker(for seg: Segment, in turns: [SpeakerTurn]) -> String? {
        let end = max(seg.end, seg.start + 0.5)
        var overlap: [String: Double] = [:]
        for t in turns {
            let o = min(end, t.end) - max(seg.start, t.start)
            if o > 0 { overlap[t.speaker, default: 0] += o }
        }
        return overlap.max { $0.value < $1.value }?.key
    }

    static func lines(from entries: [(t: Double, label: String, text: String)]) -> [String] {
        let all = entries.sorted { $0.t < $1.t }

        // Join consecutive segments of the same speaker into one line.
        var lines: [(t: Double, label: String, text: String, last: Double)] = []
        for e in all {
            if let i = lines.indices.last, lines[i].label == e.label,
               e.t - lines[i].last < 6, lines[i].text.count < 300 {
                lines[i].text += " " + e.text
                lines[i].last = e.t
            } else {
                lines.append((e.t, e.label, e.text, e.t))
            }
        }
        return lines.map { l in
            let s = Int(max(l.t, 0))
            return String(format: "[%02d:%02d] %@: %@", s / 60, s % 60, l.label, l.text)
        }
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
