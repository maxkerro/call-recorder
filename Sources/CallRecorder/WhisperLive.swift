import Foundation
import AVFoundation

// MARK: - Shared live-transcription types

/// One update from a live engine.
struct LiveEvent {
    var label: String
    var commit: String = ""      // newly confirmed text; appended to the current line
    var tail: String = ""        // tentative text; replaced on every update
    var time: Double? = nil      // seconds since recording start for `commit` (nil = now)
    var newLine: Bool = false    // start a new transcript line for `commit`
    var error: String? = nil
}

protocol LiveSink: AnyObject {
    var onEvent: ((LiveEvent) -> Void)? { get set }
    func start()
    func append(_ buffer: AVAudioPCMBuffer)
    /// Flush what is pending and wait until all results were delivered.
    func finish() async
}

/// Converts arbitrary PCM buffers to 16 kHz mono Float32 (Whisper's input format).
final class Resampler {
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                          channels: 1, interleaved: false)!

    func convert(_ buf: AVAudioPCMBuffer) -> [Float] {
        if converter == nil || inFormat != buf.format {
            converter = AVAudioConverter(from: buf.format, to: outFormat)
            inFormat = buf.format
        }
        guard let conv = converter else { return [] }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return [] }
        var supplied = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buf
        }
        guard error == nil, let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}

enum WAV {
    /// 16 kHz mono 16-bit PCM WAV.
    static func data(from floats: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(44 + floats.count * 2)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(floats.count * 2)
        data.append("RIFF".data(using: .ascii)!); u32(36 + byteCount)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        data.append("data".data(using: .ascii)!); u32(byteCount)
        for f in floats {
            u16(UInt16(bitPattern: Int16(max(-1, min(1, f)) * 32767)))
        }
        return data
    }
}

// MARK: - Debug log (<project folder>/live-debug.log, rewritten for every live session)

enum LiveLog {
    private static let queue = DispatchQueue(label: "CallRecorder.livelog")
    private static var t0 = Date()
    static let url: URL = {
        let fm = FileManager.default
        let project = URL(fileURLWithPath: "/Users/mmasliukov/Private/claude/call-recorder", isDirectory: true)
        if fm.fileExists(atPath: project.path) { return project.appendingPathComponent("live-debug.log") }
        let d = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CallRecordings")
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("live-debug.log")
    }()

    static func reset() {
        queue.async {
            t0 = Date()
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func write(_ line: String) {
        queue.async {
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            let stamp = String(format: "%7.1f", Date().timeIntervalSince(t0))
            try? h.write(contentsOf: Data("\(stamp)s \(line)\n".utf8))
        }
    }
}

// MARK: - whisper-server (model stays loaded between requests)

actor WhisperServer {
    static let shared = WhisperServer()

    struct Word { var text: String; var start: Double; var end: Double }
    struct Seg {
        var start: Double; var end: Double; var text: String
        var noSpeech: Double; var avgLogprob: Double; var words: [Word]
    }
    struct Result {
        var segs: [Seg]
        var probs: [String: Double]     // language code -> probability (only when the language was auto-detected)
        var language: String            // language Whisper used/detected, as a code ("en", "ru", …)
    }
    private static let languageCodes = ["english": "en", "german": "de", "russian": "ru"]

    private var process: Process?
    private var port = 0
    private var startTask: Task<Void, Error>?
    private var prompt = ""
    private var blocklist: [String] = []
    private var level = 0           // 0 = full features, 1 = no hotter retries
    private var generation = 0      // bumped each time the server is replaced after a crash
    private var lastLog = ""
    private let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-server.log")

    func ensureRunning() async throws {
        if let t = startTask { return try await t.value }
        let t = Task { try await self.launch() }
        startTask = t
        do { try await t.value } catch { startTask = nil; process?.terminate(); process = nil; throw error }
    }

    func stop() {
        process?.terminate()
        process = nil
        startTask = nil
        let log = logURL                                    // the log may contain recognised text
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { try? FileManager.default.removeItem(at: log) }
    }

    private func launch() async throws {
        guard let exe = WhisperEngine.serverPath() else {
            throw WhisperEngine.WhisperError.failed("whisper-server not found. Run ./setup-whisper.sh")
        }
        guard let model = WhisperEngine.modelPath(live: true) else { throw WhisperEngine.WhisperError.noModel }
        prompt = WhisperEngine.vocabularyPrompt()
        blocklist = WhisperEngine.userBlocklist()

        port = Int.random(in: 20000...40000)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        // No server-side silence detector here: it crashed or stalled the server on some audio, and the volume
        // gate in StreamingTranscriber already keeps silence away from Whisper.
        p.arguments = ["-m", model, "--host", "127.0.0.1", "--port", String(port), "-l", "auto", "-t", "4"]
        p.standardOutput = log
        p.standardError = log
        try p.run()
        process = p

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if !p.isRunning {
                let tail = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").suffix(300)
                throw WhisperEngine.WhisperError.failed("whisper-server exited: \(tail)")
            }
            if await healthOK() { return }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw WhisperEngine.WhisperError.failed("whisper-server did not become ready in 90 s")
    }

    private func healthOK() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// If the server dies (crash, killed), restart it with fewer features and try again. That way one
    /// misbehaving option never leaves live transcription dead; the log tail explains what went wrong.
    func transcribe(samples: [Float], language: String) async throws -> Result {
        for _ in 0..<3 {
            try await ensureRunning()
            let gen = generation
            do {
                return try await request(samples: samples, language: language)
            } catch let e as URLError where isServerDown(e) {
                if gen == generation {                      // first request to notice: replace the server
                    generation += 1
                    lastLog = String(((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").suffix(400))
                    process?.terminate()
                    process = nil
                    startTask = nil
                    level += 1
                }
                if level > 1 { break }
            }
        }
        throw WhisperEngine.WhisperError.failed("whisper-server keeps stopping. Its log ends with: \(lastLog)")
    }

    private func isServerDown(_ e: URLError) -> Bool {
        [.networkConnectionLost, .cannotConnectToHost, .cannotParseResponse, .badServerResponse, .timedOut].contains(e.code)
            || !(process?.isRunning ?? false)
    }

    private func request(samples: [Float], language: String) async throws -> Result {
        let boundary = "----CallRecorder\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "verbose_json")
        field("language", language)
        field("temperature", "0.0")
        field("temperature_inc", level >= 1 ? "0.0" : "0.2")   // retry hotter when decoding degenerates
        field("suppress_nst", "true")
        if language != "auto" { field("no_language_probabilities", "true") }
        if !prompt.isEmpty {
            field("prompt", prompt)
            field("carry_initial_prompt", "true")
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(WAV.data(from: samples))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 25

        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw WhisperEngine.WhisperError.failed("whisper-server: " + (String(data: data, encoding: .utf8) ?? "request failed"))
        }
        return Self.parse(data, blocklist: blocklist)
    }

    // MARK: JSON

    static func parse(_ data: Data, blocklist: [String] = []) -> Result {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Result(segs: [], probs: [:], language: "")
        }
        var probs: [String: Double] = [:]
        if let lp = root["language_probabilities"] as? [String: Any] {
            for (k, v) in lp {
                if let d = v as? Double { probs[languageCodes[k.lowercased()] ?? k.lowercased()] = d }
            }
        }
        var code = probs.max(by: { $0.value < $1.value })?.key ?? ""
        if code.isEmpty, let name = (root["language"] as? String)?.lowercased() {
            code = languageCodes[name] ?? name
        }

        var out: [Seg] = []
        for s in (root["segments"] as? [[String: Any]]) ?? [] {
            let rawText = (s["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = WhisperEngine.scrub(rawText, blocklist: blocklist)
            if text.isEmpty { continue }
            let start = (s["start"] as? Double) ?? 0
            let end = (s["end"] as? Double) ?? start
            let noSpeech = (s["no_speech_prob"] as? Double) ?? 0
            let avgLogprob = (s["avg_logprob"] as? Double) ?? 0
            let tokens = (s["words"] as? [[String: Any]]) ?? []
            var words = text == rawText ? mergeTokens(tokens) : []   // text was cleaned: re-space the words
            // Fall back to even spacing inside the segment when word timestamps are missing/unusable.
            if words.isEmpty || words.contains(where: { $0.start < 0 || $0.end < $0.start }) {
                words = interpolate(text: text, start: start, end: end)
            }
            out.append(Seg(start: start, end: end, text: text, noSpeech: noSpeech,
                           avgLogprob: avgLogprob, words: words))
        }
        return Result(segs: out, probs: probs, language: code)
    }

    /// The server reports sub-word tokens; a token that begins with a space starts a new word.
    private static func mergeTokens(_ tokens: [[String: Any]]) -> [Word] {
        var out: [Word] = []
        for t in tokens {
            guard let piece = t["word"] as? String else { continue }
            if piece.hasPrefix("[_") || piece.hasPrefix("<|") { continue }      // special tokens
            let s = (t["start"] as? Double) ?? -1
            let e = (t["end"] as? Double) ?? -1
            if piece.first == " " || out.isEmpty {
                out.append(Word(text: piece.trimmingCharacters(in: .whitespaces), start: s, end: e))
            } else {
                out[out.count - 1].text += piece
                out[out.count - 1].end = e
            }
        }
        return out.filter { !$0.text.isEmpty }
    }

    private static func interpolate(text: String, start: Double, end: Double) -> [Word] {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return [] }
        let total = Double(parts.reduce(0) { $0 + $1.count })
        let dur = max(end - start, 0.01)
        var t = start
        return parts.map { p in
            let d = dur * Double(p.count) / total
            defer { t += d }
            return Word(text: p, start: t, end: t + d)
        }
    }
}

// MARK: - Streaming transcriber (sliding window + agreement)

/// Every second the not-yet-confirmed audio is transcribed again. A word is only confirmed once two
/// consecutive passes agree on it, and the last word of a pass is never confirmed early. A word that is cut
/// in half by the end of the audio is therefore re-read with its second half, instead of staying wrong.
/// A pause (1.2 s of silence) ends an utterance and confirms everything in it.
final class StreamingTranscriber: LiveSink, @unchecked Sendable {
    let label: String
    private let language: String
    var onEvent: ((LiveEvent) -> Void)?

    private let resampler = Resampler()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var bufferStart = 0                 // absolute index (16 kHz) of samples[0]
    private var stopped = false
    private var loop: Task<Void, Never>?

    private struct HWord { var text: String; var start: Double; var end: Double; var norm: String }
    private var committedEnd = 0.0              // absolute seconds up to which text is confirmed
    private var committedMid = 0.0              // midpoint of the last confirmed word
    private var lastCommitEnd = -100.0
    private var recentNorms: [String] = []
    private var prevTail: [HWord] = []
    private var lastSentCount = -1
    private var reportedError = false
    private let allowedLanguages = ["en", "de", "ru"]     // what "Auto-detect" chooses between
    private var lockedLanguage: String?                   // language fixed for the current utterance
    private var lastLanguage: String?
    private let vocabSeq = WhisperEngine.vocabularySequence()

    private let sr = 16000.0
    private let silenceRMS: Float = 0.003

    init(label: String, language: String) {
        self.label = label
        self.language = language
    }

    // MARK: LiveSink

    func start() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                guard let self else { return }
                await self.tick(final: false)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let new = resampler.convert(buffer)
        guard !new.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if !stopped { samples.append(contentsOf: new) }
    }

    func finish() async {
        loop?.cancel()
        await loop?.value
        await tick(final: true)
    }

    // MARK: Buffer access (synchronous: NSLock must not be used from async code)

    private func snapshot() -> (samples: [Float], start: Int) {
        lock.lock(); defer { lock.unlock() }
        return (samples, bufferStart)
    }

    private func trim(toAbsoluteSample abs: Int) {
        lock.lock(); defer { lock.unlock() }
        let drop = min(max(abs - bufferStart, 0), samples.count)
        samples.removeFirst(drop)
        bufferStart += drop
    }

    // MARK: One pass

    private func tick(final: Bool) async {
        let (buf, start) = snapshot()
        guard buf.count >= (final ? 4000 : Int(0.8 * sr)) else { return }
        let startSec = Double(start) / sr
        let endAbs = start + buf.count
        let endSec = Double(endAbs) / sr

        // Nothing but silence: drop it (keep half a second so the next word's onset isn't clipped).
        guard Self.hasSpeech(buf, win: Int(0.25 * sr), thr: silenceRMS) else {
            let hadTail = !prevTail.isEmpty
            LiveLog.write("\(label) no speech in buffer (\(buf.count / 16000) s), tail=\(prevTail.count)")
            if final, hadTail { emit(commit: prevTail, tail: []) }
            else if hadTail { onEvent?(LiveEvent(label: label)) }
            prevTail = []
            lockedLanguage = nil
            trim(toAbsoluteSample: max(start, endAbs - Int(0.5 * sr)))
            return
        }

        let trailingSilent = Self.rms(buf.suffix(Int(1.2 * sr))) < silenceRMS
        let forceFlush = !final && !trailingSilent && Double(buf.count) / sr > 20
        let flush = final || trailingSilent || forceFlush
        if !flush && buf.count == lastSentCount { return }       // no new audio since the last pass
        lastSentCount = buf.count

        let segs: [WhisperServer.Seg]
        let t0 = Date()
        do {
            // "Auto": decide the language once per utterance among English/German/Russian instead of letting
            // Whisper re-guess every second (that is how a short phrase turned into Icelandic).
            var r = try await WhisperServer.shared.transcribe(
                samples: buf, language: language == "auto" ? (lockedLanguage ?? "auto") : language)
            if language == "auto", lockedLanguage == nil {
                let chosen = pickLanguage(r)
                lockedLanguage = chosen
                if chosen != r.language {
                    r = try await WhisperServer.shared.transcribe(samples: buf, language: chosen)
                }
            }
            segs = r.segs
            LiveLog.write("\(label) pass buf=\(String(format: "%.1f", Double(buf.count) / sr))s start=\(String(format: "%.1f", startSec)) lang=\(lockedLanguage ?? language) req=\(Int(Date().timeIntervalSince(t0) * 1000))ms segs=\(r.segs.count) words=\(r.segs.reduce(0) { $0 + $1.words.count }) flush=\(flush) trailSilent=\(trailingSilent) committedMid=\(String(format: "%.1f", committedMid))")
        } catch {
            LiveLog.write("\(label) ERROR \(error.localizedDescription)")
            if !reportedError {
                reportedError = true
                onEvent?(LiveEvent(label: label, error: error.localizedDescription))
            }
            return
        }

        // Hypothesis for this window, with absolute times.
        var hyp: [HWord] = []
        var segEnds: [Double] = []
        for s in segs {
            // Short segments (1-3 words) are where made-up "Thank you" lives: demand more certainty from them.
            let short = s.text.split(whereSeparator: \.isWhitespace).count <= 3
            guard s.noSpeech < (short ? 0.4 : 0.6), Self.plausible(s),
                  !WhisperEngine.isNoise(s.text), !Self.isRepetitive(s.text) else { continue }
            // "Thank you" over typing or room noise: a generic sign-off on audio that is only faintly above silence.
            if Self.isGenericFiller(s.text), Self.spanRMS(buf, s.start, s.end, sr: sr) < Self.fillerRMS {
                LiveLog.write("\(label) dropped quiet filler \"\(s.text)\"")
                continue
            }
            for w in s.words {
                hyp.append(HWord(text: w.text, start: startSec + w.start, end: startSec + w.end,
                                 norm: Self.norm(w.text)))
            }
            segEnds.append(startSec + s.end)
        }

        // Drop words that only echo the vocabulary hint (Whisper reads it back after a breath).
        let echo = WhisperEngine.echoIndices(hyp.map(\.norm), seq: vocabSeq)
        if !echo.isEmpty { hyp = hyp.enumerated().filter { !echo.contains($0.offset) }.map(\.element) }
        hyp = Self.collapseRepeats(hyp)

        // Only words after what is already confirmed (a word counts as new when its midpoint is later).
        var fresh = hyp.filter { ($0.start + $0.end) / 2 > committedMid }

        // Drop an n-gram that repeats the end of the confirmed text (the window overlaps it).
        if let first = fresh.first, first.start - committedEnd < 1.0 {
            for n in stride(from: min(5, recentNorms.count, fresh.count), through: 1, by: -1)
            where Array(recentNorms.suffix(n)) == fresh.prefix(n).map(\.norm) {
                fresh.removeFirst(n)
                break
            }
        }

        let commitWords: [HWord]
        let tail: [HWord]
        if flush {
            commitWords = fresh
            tail = []
        } else {
            var n = 0
            while n < fresh.count, n < prevTail.count,
                  !fresh[n].norm.isEmpty, fresh[n].norm == prevTail[n].norm { n += 1 }
            n = min(n, max(fresh.count - 1, 0))       // the last word may be cut off: never confirm it yet
            commitWords = Array(fresh.prefix(n))
            tail = Array(fresh.dropFirst(n))
        }
        emit(commit: commitWords, tail: tail)
        prevTail = tail
        LiveLog.write("\(label)   hyp=\(hyp.count) fresh=\(fresh.count) commit=\(commitWords.count) tail=\(tail.count) | \(commitWords.map(\.text).joined(separator: " ")) ‖ \(tail.map(\.text).joined(separator: " "))")

        if flush {
            committedEnd = max(committedEnd, endSec)
            committedMid = max(committedMid, endSec)
            trim(toAbsoluteSample: endAbs)
            prevTail = []
            lastSentCount = -1
            if let l = lockedLanguage { lastLanguage = l }
            lockedLanguage = nil
        } else if Double(buf.count) / sr > 10,
                  let e = segEnds.last(where: { $0 > startSec + 1 && $0 <= committedEnd + 0.05 }) {
            // Window is getting long: cut at the end of a fully confirmed segment.
            trim(toAbsoluteSample: Int(e * sr))
        }
    }

    private func emit(commit: [HWord], tail: [HWord]) {
        var ev = LiveEvent(label: label)
        ev.tail = tail.map(\.text).joined(separator: " ")
        if let first = commit.first, let last = commit.last {
            ev.commit = commit.map(\.text).joined(separator: " ")
            ev.time = first.start
            ev.newLine = first.start - lastCommitEnd > 1.5
            committedEnd = max(committedEnd, last.end)
            committedMid = max(committedMid, (last.start + last.end) / 2)
            lastCommitEnd = last.end
            recentNorms = Array((recentNorms + commit.map(\.norm)).suffix(8))
        }
        onEvent?(ev)
    }

    // MARK: Helpers

    private func pickLanguage(_ r: WhisperServer.Result) -> String {
        let scores = allowedLanguages.map { ($0, r.probs[$0] ?? 0) }
        let total = scores.reduce(0) { $0 + $1.1 }
        if total > 0, let best = scores.max(by: { $0.1 < $1.1 }) {
            if best.1 / total >= 0.6 || lastLanguage == nil { return best.0 }
            return lastLanguage ?? best.0           // unsure: stay with the previous utterance's language
        }
        if allowedLanguages.contains(r.language) { return r.language }
        return lastLanguage ?? "en"
    }

    /// Low average confidence marks garbage in longer segments; one- or two-word segments (often the last word
    /// of a sentence) are exempt, otherwise the end of a phrase gets dropped.
    private static func plausible(_ s: WhisperServer.Seg) -> Bool {
        s.text.split(whereSeparator: \.isWhitespace).count < 3 || s.avgLogprob > -1.3
    }

    /// Whisper sometimes loops ("a little bit of a little bit of …"). Such text is never real speech.
    private static func isRepetitive(_ text: String) -> Bool {
        let w = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard w.count >= 8 else { return false }
        return Double(Set(w).count) / Double(w.count) < 0.35
    }

    /// Keeps one copy of any 1–4 word phrase that repeats three or more times in a row.
    private static func collapseRepeats(_ words: [HWord]) -> [HWord] {
        var out = words
        for n in 1...4 {
            var i = 0
            while i + 3 * n <= out.count {
                let group = out[i..<(i + n)].map(\.norm)
                var reps = 1
                while i + (reps + 1) * n <= out.count,
                      out[(i + reps * n)..<(i + (reps + 1) * n)].map(\.norm) == group { reps += 1 }
                if reps >= 3 { out.removeSubrange((i + n)..<(i + reps * n)) }
                i += 1
            }
        }
        return out
    }

    private static func norm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static let fillerRMS: Float = 0.015     // real speech is well above this; typing and room noise below
    private static let fillers: Set<String> = ["thankyou", "thanks", "thankyouverymuch", "thankyousomuch",
        "thankyouforwatching", "bye", "byebye", "goodbye", "you", "danke", "dankeschön", "dankeschoen", "vielendank",
        "спасибо", "пока", "благодарюзавнимание"]

    private static func isGenericFiller(_ t: String) -> Bool { fillers.contains(norm(t)) }

    private static func spanRMS(_ x: [Float], _ start: Double, _ end: Double, sr: Double) -> Float {
        let a = max(0, Int(start * sr)), b = min(x.count, max(a + 1, Int((end * sr).rounded(.up))))
        guard a < b else { return 0 }
        return rms(x[a..<b])
    }

    private static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        var s: Float = 0
        for v in x { s += v * v }
        return (s / Float(x.count)).squareRoot()
    }

    private static func hasSpeech(_ x: [Float], win: Int, thr: Float) -> Bool {
        var i = 0
        while i < x.count {
            if rms(x[i..<min(i + win, x.count)]) >= thr { return true }
            i += win
        }
        return false
    }
}
