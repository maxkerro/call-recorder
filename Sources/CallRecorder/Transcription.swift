import Foundation
import Speech
import AVFoundation

enum Transcription {
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    /// Step 2: transcribe an existing audio file (mp3, m4a, wav ...) with Apple's Speech framework.
    /// Uses on-device recognition when the language supports it.
    static func transcribe(file url: URL, localeID: String) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)), recognizer.isAvailable else {
            throw NSError(domain: "CallRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognizer for \(localeID) is not available."])
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        // The task is held in this local until the continuation resumes, which keeps it alive.
        var task: SFSpeechRecognitionTask?
        let text: String = try await withCheckedThrowingContinuation { cont in
            var finished = false
            task = recognizer.recognitionTask(with: request) { result, error in
                if finished { return }
                if let error {
                    finished = true
                    cont.resume(throwing: error)
                } else if let result, result.isFinal {
                    finished = true
                    cont.resume(returning: format(result.bestTranscription))
                }
            }
        }
        withExtendedLifetime(task) {}
        return text
    }

    /// Paragraph every ~30 s with a [mm:ss] marker.
    static func format(_ t: SFTranscription) -> String {
        var out = ""
        var lastMark = -100.0
        for seg in t.segments {
            if seg.timestamp - lastMark >= 30 {
                let s = Int(seg.timestamp)
                out += (out.isEmpty ? "" : "\n\n") + String(format: "[%02d:%02d] ", s / 60, s % 60)
                lastMark = seg.timestamp
            } else {
                out += " "
            }
            out += seg.substring
        }
        return out
    }
}

/// Step 3: live transcription of one audio source. Restarts its recognition task
/// whenever Apple ends it (silence timeouts, ~1 min limits), so it can run for a whole call.
final class LiveTranscriber: LiveSink {
    let label: String
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var stopped = false

    /// (label, text, isFinal, offset) — called on an arbitrary thread; offset is nil = "now".
    var onUpdate: ((String, String, Bool, Double?) -> Void)?

    init(label: String, localeID: String) {
        self.label = label
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
    }

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    func start() { startTask() }

    private func startTask() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, let recognizer else { return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { r.requiresOnDeviceRecognition = true }
        request = r
        task = recognizer.recognitionTask(with: r) { [weak self] result, error in
            guard let self else { return }
            var ended = error != nil
            if let result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty { self.onUpdate?(self.label, text, result.isFinal, nil) }
                if result.isFinal { ended = true }
            }
            if ended {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.startTask()
                }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        request?.append(buffer)
    }

    func stop() {
        lock.lock()
        stopped = true
        request?.endAudio()
        lock.unlock()
    }

    func finish() async { stop() }
}
