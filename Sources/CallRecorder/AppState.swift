import Foundation
import SwiftUI
import AppKit
import Speech
import Carbon.HIToolbox

enum Engine: String, CaseIterable, Identifiable {
    case whisper, apple
    var id: String { rawValue }
    var name: String { self == .whisper ? "Whisper (local, best)" : "Apple (built-in)" }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isRecording = false
    @Published var liveMode = false
    @Published var busy = false
    @Published var status = "Ready"
    @Published var elapsed = "00:00"
    @Published var finalLines: [String] = []
    @Published var partials: [String: String] = [:]
    @Published var lastFile: URL?
    @Published var localeID: String {
        didSet { UserDefaults.standard.set(localeID, forKey: "localeID") }
    }
    @Published var checkNote = ""
    @Published var verifyAfterLive: Bool {
        didSet { UserDefaults.standard.set(verifyAfterLive, forKey: "verify") }
    }
    @Published var summaryText = ""
    @Published var summaryNote = ""
    var summaryTranscript = ""
    @Published var summarizeCalls: Bool {
        didSet { UserDefaults.standard.set(summarizeCalls, forKey: "summarize") }
    }
    @Published var offlineMode: Bool {
        didSet {
            UserDefaults.standard.set(offlineMode, forKey: "offline")
            Diarizer.setOffline(offlineMode)
        }
    }
    @Published var speakerLabels: [String] = []
    var lastTranscriptURL: URL?
    @Published var identifySpeakers: Bool {
        didSet { UserDefaults.standard.set(identifySpeakers, forKey: "speakers") }
    }
    @Published var engine: Engine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "engine") }
    }

    static let languages: [(id: String, name: String)] = [
        ("auto", "Auto-detect (Whisper)"),
        ("en-US", "English (US)"), ("en-GB", "English (UK)"),
        ("de-DE", "Deutsch"), ("ru-RU", "Русский"),
    ]

    /// All recordings live in <root>/<yyyy-MM-dd>/. The root is the project folder on Max's Mac
    /// (git-ignored); if it can't be created, ~/Documents/CallRecordings is used instead.
    let rootDir: URL = {
        let fm = FileManager.default
        let preferred = URL(fileURLWithPath: "/Users/mmasliukov/Private/claude/call-recorder/CallRecordings", isDirectory: true)
        if (try? fm.createDirectory(at: preferred, withIntermediateDirectories: true)) != nil {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: preferred.path)   // owner only
            return preferred
        }
        let d = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallRecordings", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Today's folder; refreshed when a recording starts so one call's files stay together.
    private(set) lazy var outDir: URL = Self.dayFolder(in: rootDir)

    private static func dayFolder(in root: URL) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let d = root.appendingPathComponent(f.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)   // owner only
        return d
    }

    private var capture: CaptureSession?
    private var transcribers: [LiveSink] = []
    private struct Line { var t: Double; var label: String; var text: String }
    private var lines: [Line] = []
    private var openLine: [String: Int] = [:]      // label -> index of its current line in `lines`
    private var baseName = ""
    private var startDate = Date()
    private var timer: Timer?

    init() {
        localeID = UserDefaults.standard.string(forKey: "localeID") ?? "en-US"
        verifyAfterLive = UserDefaults.standard.object(forKey: "verify") as? Bool ?? true
        identifySpeakers = UserDefaults.standard.object(forKey: "speakers") as? Bool ?? true
        summarizeCalls = UserDefaults.standard.object(forKey: "summarize") as? Bool ?? true
        offlineMode = UserDefaults.standard.bool(forKey: "offline")
        if let saved = UserDefaults.standard.string(forKey: "engine"), let e = Engine(rawValue: saved) {
            engine = e
        } else {
            engine = WhisperEngine.isReady ? .whisper : .apple
        }
        Diarizer.setOffline(offlineMode)
    }

    /// Whisper is selected but not installed → tell the user how to fix it.
    var whisperHint: String? {
        guard engine == .whisper, !WhisperEngine.isReady else { return nil }
        return "Whisper isn't set up yet: run ./setup-whisper.sh in the project folder, then reopen the app."
    }

    private var appleLocale: String { localeID == "auto" ? "en-US" : localeID }

    func registerHotKeys() {
        let mods = controlKey | optionKey
        HotKeys.shared.register(id: 1, keyCode: kVK_ANSI_R, modifiers: mods) { [weak self] in
            self?.toggle(live: false)
        }
        HotKeys.shared.register(id: 2, keyCode: kVK_ANSI_L, modifiers: mods) { [weak self] in
            self?.toggle(live: true)
        }
    }

    // MARK: Recording

    func toggle(live: Bool) {
        guard !busy else { return }
        if isRecording { Task { await stopRecording() } }
        else { Task { await startRecording(live: live) } }
    }

    private func startRecording(live: Bool) async {
        busy = true
        defer { busy = false }
        finalLines = []
        lines = []
        openLine = [:]
        partials = [:]
        liveMode = live
        outDir = Self.dayFolder(in: rootDir)
        summaryText = ""; summaryNote = ""; summaryTranscript = ""
        checkNote = ""; speakerLabels = []
        if live { LiveLog.reset() }

        var sinks: [LiveSink] = []
        if live {
            switch engine {
            case .whisper:
                guard WhisperEngine.isLiveReady else {
                    status = "Live Whisper needs whisper-server: run ./setup-whisper.sh, then try again."
                    return
                }
                let lang = WhisperEngine.languageCode(from: localeID)
                sinks = [StreamingTranscriber(label: "Them", language: lang),
                         StreamingTranscriber(label: "Me", language: lang)]
            case .apple:
                guard await Transcription.requestAuthorization() else {
                    status = "Speech recognition not allowed (System Settings → Privacy & Security)"
                    return
                }
                let them = LiveTranscriber(label: "Them", localeID: appleLocale)
                let me = LiveTranscriber(label: "Me", localeID: appleLocale)
                guard them.isAvailable else {
                    status = "Apple speech recognizer for \(appleLocale) is unavailable. Try the Whisper engine."
                    return
                }
                sinks = [them, me]
            }
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        baseName = "Call_" + stamp.string(from: Date())
        let session = CaptureSession(tempDir: FileManager.default.temporaryDirectory, baseName: baseName)

        if live {
            for s in sinks {
                s.onEvent = { [weak self] event in
                    Task { @MainActor in self?.handle(event) }
                }
                s.start()
            }
            let them = sinks[0], me = sinks[1]
            session.onSystemBuffer = { them.append($0) }
            session.onMicBuffer = { me.append($0) }
            transcribers = sinks
        }
        session.onError = { [weak self] err in
            Task { @MainActor in self?.status = "Capture error: \(err.localizedDescription)" }
        }

        do {
            try await session.start()
        } catch {
            transcribers = []
            status = "Could not start: \(error.localizedDescription). Allow Screen & System Audio Recording in System Settings → Privacy & Security, then relaunch."
            return
        }

        capture = session
        startDate = Date()
        isRecording = true
        status = live ? (engine == .whisper ? "Starting Whisper…" : "Recording + live transcript (Apple)") : "Recording"
        if live, engine == .whisper {
            Task {
                do {
                    try await WhisperServer.shared.ensureRunning()
                    if isRecording { status = "Recording + live transcript (Whisper)" }
                } catch {
                    status = "Whisper: \(error.localizedDescription)"
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let s = Int(Date().timeIntervalSince(self.startDate))
                self.elapsed = String(format: "%02d:%02d", s / 60, s % 60)
            }
        }
    }

    private func stopRecording() async {
        busy = true
        defer { busy = false }
        timer?.invalidate(); timer = nil
        guard let session = capture else { return }
        status = "Finishing…"
        await session.stop()
        capture = nil
        isRecording = false
        elapsed = "00:00"

        // Let the live engines process their last audio while the MP3 is being made.
        let sinks = transcribers
        transcribers = []
        let finishing = Task { for s in sinks { await s.finish() } }

        let mp3 = outDir.appendingPathComponent(baseName + ".mp3")
        status = "Converting to MP3…"
        do {
            try await Self.mixToMP3(system: session.hasSystemAudio ? session.systemURL : nil,
                                    mic: session.hasMicAudio ? session.micURL : nil,
                                    output: mp3)
            if !(liveMode && verifyAfterLive) {         // the check pass still needs the separate tracks
                try? FileManager.default.removeItem(at: session.systemURL)
                try? FileManager.default.removeItem(at: session.micURL)
            }
            lastFile = mp3
            status = "Saved \(mp3.lastPathComponent)"
        } catch {
            status = "MP3 conversion failed: \(error.localizedDescription) [\(session.diagnostics)]"
        }

        if liveMode {
            if !sinks.isEmpty { status = "Finishing transcript…" }
            await finishing.value
            await WhisperServer.shared.stop()
            for (label, text) in partials where !text.isEmpty {
                handle(LiveEvent(label: label, commit: text, newLine: true))
            }
            partials = [:]
            let txt = outDir.appendingPathComponent(baseName + ".txt")
            try? finalLines.joined(separator: "\n").write(to: txt, atomically: true, encoding: .utf8)
            if lastFile != nil { status = "Saved \(mp3.lastPathComponent) + \(txt.lastPathComponent)" }

            if verifyAfterLive, session.hasSystemAudio || session.hasMicAudio {
                let live = finalLines
                let system = session.hasSystemAudio ? session.systemURL : nil
                let mic = session.hasMicAudio ? session.micURL : nil
                let base = baseName
                let delete = lastFile != nil
                Task {
                    let verified = await self.verify(base: base, system: system, mic: mic, live: live, deleteTracks: delete)
                    await self.summarize(lines: verified, base: base)
                }
            } else {
                let live = finalLines, base = baseName
                Task { await self.summarize(lines: live, base: base) }
            }
        } else if summarizeCalls, let mp3 = lastFile {
            // Plain recording: transcribe it now (the summary follows), so every call gets one.
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)    // let `busy` clear first
                await self.transcribe(mp3)
            }
        }
    }

    // MARK: Live transcript

    /// Confirmed text is appended to the speaker's current line (so the line grows in place); the tentative
    /// tail is shown separately and is rewritten on every update.
    private func handle(_ e: LiveEvent) {
        if let err = e.error {
            status = "Live transcription: \(err)"
            return
        }
        if !e.commit.isEmpty {
            let t = e.time ?? Date().timeIntervalSince(startDate)
            if !e.newLine, let i = openLine[e.label], lines[i].text.count < 300 {
                lines[i].text += " " + e.commit
            } else {
                lines.append(Line(t: t, label: e.label, text: e.commit))
                openLine[e.label] = lines.count - 1
            }
        }
        partials[e.label] = e.tail.isEmpty ? nil : e.tail
        finalLines = lines.sorted { $0.t < $1.t }.map { l in
            let s = Int(max(l.t, 0))
            return String(format: "[%02d:%02d] %@: %@", s / 60, s % 60, l.label, l.text)
        }
    }

    // MARK: Step 2 — transcribe an existing file

    func transcribeFileDialog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav]
        panel.directoryURL = Self.dayFolder(in: rootDir)
        panel.message = "Choose an audio file to transcribe"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await transcribe(url) }
    }

    func transcribe(_ url: URL) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let text: String
            switch engine {
            case .whisper:
                guard WhisperEngine.isReady else {
                    status = whisperHint ?? "Whisper is not ready"
                    return
                }
                let modelName = URL(fileURLWithPath: WhisperEngine.modelPath() ?? "").deletingPathExtension().lastPathComponent
                status = "Transcribing \(url.lastPathComponent) with \(modelName)… (several minutes for long calls)"
                let lang = WhisperEngine.languageCode(from: localeID)
                var turns: [SpeakerTurn] = []
                if identifySpeakers {
                    status = "Finding who speaks when… (the first time this downloads small speaker models)"
                    do { turns = try await Diarizer.shared.diarize(url) }
                    catch { checkNote = "Speaker recognition failed: \(error.localizedDescription)" }
                    status = "Transcribing \(url.lastPathComponent) with \(modelName)… (several minutes for long calls)"
                }
                if turns.isEmpty {
                    text = try await Task.detached(priority: .userInitiated) {
                        try WhisperEngine.transcribeFile(url, language: lang)
                    }.value
                } else {
                    let turns = turns
                    text = try await Task.detached(priority: .userInitiated) {
                        try WhisperEngine.transcribeFileWithSpeakers(url, language: lang, turns: turns)
                            .joined(separator: "\n")
                    }.value
                }
            case .apple:
                guard await Transcription.requestAuthorization() else {
                    status = "Speech recognition not allowed (System Settings → Privacy & Security)"
                    return
                }
                status = "Transcribing \(url.lastPathComponent)…"
                text = try await Transcription.transcribe(file: url, localeID: appleLocale)
            }
            if text.isEmpty {
                status = "No speech recognized in \(url.lastPathComponent)"
                return
            }
            let out = url.deletingPathExtension().appendingPathExtension("txt")
            try text.write(to: out, atomically: true, encoding: .utf8)
            finalLines = text.contains("\n\n") ? text.components(separatedBy: "\n\n") : text.components(separatedBy: "\n")
            lastTranscriptURL = out
            refreshSpeakers()
            status = "Saved \(out.lastPathComponent)"
            let done = finalLines, name = url.deletingPathExtension().lastPathComponent
            let dir = url.deletingLastPathComponent()
            Task { await self.summarize(lines: done, base: name, dir: dir) }
            if !summarizeCalls { NSWorkspace.shared.activateFileViewerSelecting([out]) }
        } catch {
            status = "Transcription failed: \(error.localizedDescription)"
        }
    }

    // MARK: Speaker names

    /// Labels such as "Speaker 1" present in the current transcript (offered in the Rename menu).
    private func refreshSpeakers() {
        var seen: [String] = []
        // Lines look like "[mm:ss] Label: text".
        for l in finalLines {
            guard let close = l.firstIndex(of: "]") else { continue }
            let rest = l[l.index(after: close)...].drop(while: { $0 == " " })
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let label = String(rest[rest.startIndex..<colon])
            if label.hasPrefix("Speaker"), !seen.contains(label) { seen.append(label) }
        }
        speakerLabels = seen
    }

    /// Renames a speaker in the shown transcript and in the saved .txt file.
    func renameSpeaker(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        finalLines = finalLines.map { $0.replacingOccurrences(of: "] \(old): ", with: "] \(name): ") }
        if let url = lastTranscriptURL {
            try? finalLines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        refreshSpeakers()
        status = "Renamed \(old) to \(name)"
    }

    func promptRename(_ old: String) {
        let alert = NSAlert()
        alert.messageText = "Rename \(old)"
        alert.informativeText = "Type the person's name:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { renameSpeaker(old, to: field.stringValue) }
    }

    // MARK: Check pass

    private static func wordCount(_ lines: [String]) -> Int {
        lines.reduce(0) { total, line in
            let body = line.range(of: "]: ").map { String(line[$0.upperBound...]) } ?? line
            return total + body.split(whereSeparator: \.isWhitespace).count
        }
    }

    /// After a live recording: re-transcribe both tracks with the accurate model and replace the transcript.
    /// The live version is kept next to it as ".live.txt".
    @discardableResult
    private func verify(base: String, system: URL?, mic: URL?, live: [String], deleteTracks: Bool) async -> [String] {
        defer {
            if deleteTracks {
                if let system { try? FileManager.default.removeItem(at: system) }
                if let mic { try? FileManager.default.removeItem(at: mic) }
            }
        }
        guard WhisperEngine.isReady else {
            checkNote = "Transcript check skipped: Whisper isn't set up (run ./setup-whisper.sh)."
            return live
        }
        checkNote = "Checking the transcript with the accurate model… (a few minutes for long calls)"
        let lang = WhisperEngine.languageCode(from: localeID)
        var turns: [SpeakerTurn] = []
        var diarizeNote = ""
        if identifySpeakers, let system {
            checkNote = "Finding who speaks when… (the first time this downloads small speaker models)"
            do {
                turns = try await Diarizer.shared.diarize(system)
                let names = Set(turns.map(\.speaker)).sorted()
                diarizeNote = turns.isEmpty
                    ? " Speaker recognition found no distinct voices in the call audio."
                    : " Speakers found: \(names.count) (\(names.joined(separator: ", ")))."
            } catch {
                diarizeNote = " Speaker recognition FAILED: \(error). Labels are Me/Them."
            }
            LiveLog.write("diarization:\(diarizeNote) turns=\(turns.count)")
        } else if identifySpeakers {
            diarizeNote = " Speaker recognition skipped: no call-audio track was captured."
        }
        checkNote = "Checking the transcript with the accurate model… (a few minutes for long calls)"
        do {
            let turns = turns
            let lines = try await Task.detached(priority: .utility) {
                try WhisperEngine.transcribeTracks(system: system, mic: mic, language: lang, turns: turns)
            }.value
            guard !lines.isEmpty else {
                checkNote = "Transcript check heard no speech; the live transcript was kept."
                return live
            }
            try live.joined(separator: "\n").write(to: outDir.appendingPathComponent(base + ".live.txt"),
                                                  atomically: true, encoding: .utf8)
            try lines.joined(separator: "\n").write(to: outDir.appendingPathComponent(base + ".txt"),
                                                   atomically: true, encoding: .utf8)
            if !isRecording {
                finalLines = lines
                lastTranscriptURL = outDir.appendingPathComponent(base + ".txt")
                refreshSpeakers()
            }
            let before = Self.wordCount(live), after = Self.wordCount(lines)
            checkNote = "Checked: \(base).txt now has the verified transcript (\(before) → \(after) words). "
                      + "The live version is saved as \(base).live.txt." + diarizeNote
            return lines
        } catch {
            checkNote = "Transcript check failed: \(error.localizedDescription). The live transcript was kept."
            return live
        }
    }

    // MARK: Summary

    /// Summarizes a finished transcript with the local Ollama model and saves `<base>.summary.md`.
    func summarize(lines: [String], base: String, dir: URL? = nil) async {
        guard summarizeCalls else { return }
        let transcript = lines.joined(separator: "\n")
        guard transcript.split(whereSeparator: \.isWhitespace).count >= 15 else {
            summaryText = ""; summaryNote = "Too little speech for a summary."
            return
        }
        summaryText = ""
        summaryNote = "Summarizing the call with a local model…"
        do {
            let text = try await Summarizer.summarize(transcript: transcript)
            let url = (dir ?? outDir).appendingPathComponent(base + ".summary.md")
            try text.write(to: url, atomically: true, encoding: .utf8)
            summaryText = text
            summaryTranscript = transcript
            summaryNote = "Summary saved as \(url.lastPathComponent)."
        } catch {
            summaryTranscript = transcript
            summaryNote = "No summary: \(error.localizedDescription) You can still use “Copy for Claude”."
        }
    }

    /// Puts the summary prompt + transcript on the clipboard, to paste into claude.ai.
    func copyForClaude() {
        guard !summaryTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Summarizer.pasteText(summaryTranscript), forType: .string)
        summaryNote = "Copied. Paste it into a Claude chat to get the summary."
    }

    func openFolder() { NSWorkspace.shared.open(rootDir) }

    func openVocabulary() { NSWorkspace.shared.open(WhisperEngine.ensureVocabularyFile()) }

    // MARK: ffmpeg

    nonisolated static func ffmpegPath() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static func mixToMP3(system: URL?, mic: URL?, output: URL) async throws {
        guard let ffmpeg = ffmpegPath() else {
            throw NSError(domain: "CallRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "ffmpeg not found — run: brew install ffmpeg"])
        }
        var args = ["-y", "-loglevel", "error"]
        let inputs = [system, mic].compactMap { $0 }
        guard !inputs.isEmpty else {
            throw NSError(domain: "CallRecorder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No audio was captured."])
        }
        for i in inputs { args += ["-i", i.path] }
        if inputs.count == 2 {
            args += ["-filter_complex",
                     "[0:a]aresample=48000,aformat=channel_layouts=stereo[a0];" +
                     "[1:a]aresample=48000,aformat=channel_layouts=stereo[a1];" +
                     "[a0][a1]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95[out]",
                     "-map", "[out]"]
        }
        args += ["-ac", "2", "-codec:a", "libmp3lame", "-b:a", "128k", output.path]

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = args
            let errPipe = Pipe()
            p.standardError = errPipe
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    c.resume()
                } else {
                    let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ffmpeg failed"
                    c.resume(throwing: NSError(domain: "CallRecorder", code: 4,
                                               userInfo: [NSLocalizedDescriptionKey: msg]))
                }
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }
}
