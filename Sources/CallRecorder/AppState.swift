import Foundation
import SwiftUI
import AppKit
import Speech
import Carbon.HIToolbox

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

    static let languages: [(id: String, name: String)] = [
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
    private var transcribers: [LiveTranscriber] = []
    private var baseName = ""
    private var startDate = Date()
    private var timer: Timer?

    init() {
        localeID = UserDefaults.standard.string(forKey: "localeID") ?? "en-US"
    }

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
        partials = [:]
        liveMode = live

        if live {
            guard await Transcription.requestAuthorization() else {
                status = "Speech recognition not allowed (System Settings → Privacy & Security)"
                return
            }
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        baseName = "Call_" + stamp.string(from: Date())
        let session = CaptureSession(tempDir: FileManager.default.temporaryDirectory, baseName: baseName)

        if live {
            let them = LiveTranscriber(label: "Them", localeID: localeID)
            let me = LiveTranscriber(label: "Me", localeID: localeID)
            guard them.isAvailable else {
                status = "Speech recognizer for \(localeID) is unavailable"
                return
            }
            for t in [them, me] {
                t.onUpdate = { [weak self] label, text, isFinal in
                    Task { @MainActor in self?.handleLive(label: label, text: text, isFinal: isFinal) }
                }
                t.start()
            }
            session.onSystemBuffer = { them.append($0) }
            session.onMicBuffer = { me.append($0) }
            transcribers = [them, me]
        }
        session.onError = { [weak self] err in
            Task { @MainActor in self?.status = "Capture error: \(err.localizedDescription)" }
        }

        do {
            try await session.start()
        } catch {
            transcribers.forEach { $0.stop() }
            transcribers = []
            status = "Could not start: \(error.localizedDescription). Allow Screen & System Audio Recording in System Settings → Privacy & Security, then relaunch."
            return
        }

        capture = session
        startDate = Date()
        isRecording = true
        status = live ? "Recording + live transcript" : "Recording"
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
        transcribers.forEach { $0.stop() }
        transcribers = []
        capture = nil
        isRecording = false
        elapsed = "00:00"

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
            status = "MP3 conversion failed: \(error.localizedDescription). Raw audio kept in temp folder."
        }

        if liveMode {
            for (label, text) in partials where !text.isEmpty { finalLines.append(line(label, text)) }
            partials = [:]
            let txt = outDir.appendingPathComponent(baseName + ".txt")
            try? finalLines.joined(separator: "\n").write(to: txt, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Live transcript

    private func line(_ label: String, _ text: String) -> String {
        let s = Int(Date().timeIntervalSince(startDate))
        return String(format: "[%02d:%02d] %@: %@", s / 60, s % 60, label, text)
    }

    private func handleLive(label: String, text: String, isFinal: Bool) {
        if isFinal {
            finalLines.append(line(label, text))
            partials[label] = nil
        } else {
            partials[label] = text
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
        guard await Transcription.requestAuthorization() else {
            status = "Speech recognition not allowed (System Settings → Privacy & Security)"
            return
        }
        status = "Transcribing \(url.lastPathComponent)…"
        do {
            let text = try await Transcription.transcribe(file: url, localeID: localeID)
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
