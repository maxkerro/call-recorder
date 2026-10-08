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
    @Published var engine: Engine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "engine") }
    }

    static let languages: [(id: String, name: String)] = [
        ("auto", "Auto-detect (Whisper)"),
        ("en-US", "English (US)"), ("en-GB", "English (UK)"),
        ("de-DE", "Deutsch"), ("ru-RU", "Русский"),
    ]

    let outDir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

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
        if let saved = UserDefaults.standard.string(forKey: "engine"), let e = Engine(rawValue: saved) {
            engine = e
        } else {
            engine = WhisperEngine.isReady ? .whisper : .apple
        }
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
            try? FileManager.default.removeItem(at: session.systemURL)
            try? FileManager.default.removeItem(at: session.micURL)
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
        panel.directoryURL = outDir
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
                status = "Transcribing \(url.lastPathComponent) with Whisper… (a few minutes for long calls)"
                let lang = WhisperEngine.languageCode(from: localeID)
                text = try await Task.detached(priority: .userInitiated) {
                    try WhisperEngine.transcribeFile(url, language: lang)
                }.value
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
            finalLines = text.components(separatedBy: "\n\n")
            status = "Saved \(out.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([out])
        } catch {
            status = "Transcription failed: \(error.localizedDescription)"
        }
    }

    func openFolder() { NSWorkspace.shared.open(outDir) }

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
