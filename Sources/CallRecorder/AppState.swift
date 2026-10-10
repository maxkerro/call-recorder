import Foundation
import SwiftUI
import AppKit
import Speech
import Carbon.HIToolbox
import ScreenCaptureKit

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
    @Published var finalLines: [String] = [] { didSet { scheduleTranslation() } }
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
    /// 0.3 … 1.0; applied to every window of the app (the main window and the menu-bar popover).
    @Published var windowOpacity: Double {
        didSet {
            UserDefaults.standard.set(windowOpacity, forKey: "opacity")
            applyOpacity()
        }
    }
    func applyOpacity() {
        for w in NSApp.windows { w.alphaValue = CGFloat(windowOpacity) }
    }
    // MARK: Live translation (only while the translation pane is open)

    enum TranslationState { case running, paused, stopped }
    enum TranslationControl { case pause, resume, stop, restart }

    @Published var translationOpen = false {
        didSet {
            adjustWindowForTranslation(open: translationOpen)
            if translationOpen { scheduleTranslation() } else { cancelTranslation() }
        }
    }
    @Published var translateTo: String {
        didSet { UserDefaults.standard.set(translateTo, forKey: "translateTo"); scheduleTranslation() }
    }
    @Published var translations: [String: String] = [:]      // "<lang>\u{1}<text>" -> translation
    @Published var translateNote = ""
    @Published var translationState: TranslationState = .running
    private var translating = false
    private var translationGen = 0                           // bumped whenever the running worker must give up
    private var translationTask: Task<Void, Never>?
    private var failedAt: [String: Date] = [:]
    private var skipped: Set<String> = []                    // lines left behind by Stop
    private var staleTranslations: [String: String] = [:]    // "<lang>\u{1}<line header>" -> last translation of a growing line

    private func lineHeader(_ line: String, body: String) -> String {
        guard !body.isEmpty, let r = line.range(of: body, options: .backwards), r.lowerBound > line.startIndex else { return line }
        return String(line[line.startIndex..<r.lowerBound])
    }

    private func translationKey(_ body: String) -> String { "\(translateTo)\u{1}\(body)" }

    /// The translation of a transcript line in the selected language, if it is ready.
    /// A line that is still growing has no exact translation yet: the one for its earlier text is shown meanwhile.
    func translation(for line: String) -> String? {
        let body = Translator.lineBody(line)
        return translations[translationKey(body)] ?? staleTranslations["\(translateTo)\u{1}\(lineHeader(line, body: body))"]
    }

    private func pendingTranslations() -> [(body: String, context: String, header: String)] {
        var out: [(body: String, context: String, header: String)] = []
        for (i, l) in finalLines.enumerated() {
            let body = Translator.lineBody(l)
            let key = translationKey(body)
            if body.count < 2 || translations[key] != nil || skipped.contains(key) { continue }
            if let t = failedAt[key], Date().timeIntervalSince(t) < 15 { continue }
            out.append((body, i > 0 ? Translator.lineBody(finalLines[i - 1]) : "", lineHeader(l, body: body)))
        }
        return out
    }

    private func scheduleTranslation() {
        guard translationOpen else { return }
        if translationState == .stopped {                    // Continue picks up from now: what arrives while stopped is skipped
            for p in pendingTranslations() { skipped.insert(translationKey(p.body)) }
            return
        }
        guard translationState == .running, !translating, !pendingTranslations().isEmpty else { return }
        translating = true
        let gen = translationGen
        translationTask = Task { await runTranslation(gen) }
    }

    /// Gives up the running worker (and the request in flight, if any).
    private func cancelTranslation() {
        translationGen += 1
        translationTask?.cancel()
        translationTask = nil
        translating = false
    }

    /// Pause / Continue / Stop / Restart. Pause lets the current line finish; Stop cancels it and skips the backlog.
    func translationControl(_ action: TranslationControl) {
        switch action {
        case .pause:
            if translationState == .running { translationState = .paused }
        case .resume:
            translationState = .running
            scheduleTranslation()
        case .stop:
            translationState = .stopped
            for p in pendingTranslations() { skipped.insert(translationKey(p.body)) }
            cancelTranslation()
        case .restart:
            cancelTranslation()
            translations = [:]; staleTranslations = [:]; failedAt = [:]; skipped = []
            translateNote = ""
            translationState = .running
            scheduleTranslation()
        }
    }

    /// One worker translates the lines that are missing, newest first (the live end stays current).
    /// New lines are picked up by the same loop, so a stream of new text never restarts or starves it.
    private func runTranslation(_ gen: Int) async {
        try? await Task.sleep(nanoseconds: 900_000_000)          // let a growing line settle
        while gen == translationGen, !Task.isCancelled, translationOpen, translationState == .running,
              let next = pendingTranslations().last {
            let key = translationKey(next.body)
            let target = translateTo
            do {
                let out = try await Translator.translate(next.body, target: target, context: next.context)
                if gen != translationGen || Task.isCancelled { break }       // stopped or restarted meanwhile: drop the answer
                if out.isEmpty { failedAt[key] = Date() } else {
                    translations["\(target)\u{1}\(next.body)"] = out
                    staleTranslations["\(target)\u{1}\(next.header)"] = out
                }
                translateNote = ""
            } catch {
                if gen != translationGen || Task.isCancelled { break }       // a cancelled request is not an error
                failedAt[key] = Date()
                translateNote = "Translation: \(error.localizedDescription)"
            }
            if translations.count > 5000 { translations = [:] }
        }
        if gen == translationGen { translating = false }
    }

    @Published var glossaryCorrect: Bool {
        didSet { UserDefaults.standard.set(glossaryCorrect, forKey: "glossary") }
    }
    @Published var summarizeCalls: Bool {
        didSet { UserDefaults.standard.set(summarizeCalls, forKey: "summarize") }
    }
    @Published var offlineMode: Bool {
        didSet {
            UserDefaults.standard.set(offlineMode, forKey: "offline")
            Diarizer.setOffline(offlineMode)
        }
    }
    @Published var topic = ""                 // set in advance; steers the summary
    @Published var shotCount = 0
    struct Shot { var t: Double; var file: URL }
    private var shots: [Shot] = []
    private var shotsByCall: [String: [Shot]] = [:]      // kept until that call's summary is made
    private var topicByCall: [String: String] = [:]
    private var transcriptFiles: Set<URL> = []              // every transcript file of the shown call (rename updates all)
    var summaryTopic = ""
    @Published var speakerLabels: [String] = []
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

    /// All recordings live in <root>/<yyyy-MM-dd>/. By default the root is the project folder on Max's Mac
    /// (git-ignored; ~/Documents/CallRecordings if that can't be created). A folder chosen in the app wins.
    @Published var outputRoot: String {
        didSet { UserDefaults.standard.set(outputRoot, forKey: "outputRoot") }
    }

    static func defaultRoot() -> URL {
        let fm = FileManager.default
        let preferred = URL(fileURLWithPath: "/Users/mmasliukov/Private/claude/call-recorder/recordings", isDirectory: true)
        if (try? fm.createDirectory(at: preferred, withIntermediateDirectories: true)) != nil {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: preferred.path)   // owner only
            return preferred
        }
        let d = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallRecordings", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    var rootDir: URL {
        let fm = FileManager.default
        if outputRoot.hasPrefix("/") {
            let u = URL(fileURLWithPath: outputRoot, isDirectory: true)
            if (try? fm.createDirectory(at: u, withIntermediateDirectories: true)) != nil, fm.isWritableFile(atPath: u.path) {
                return u
            }
        }
        return Self.defaultRoot()
    }

    /// Opens a folder picker; the choice is remembered. Cloud-synced folders get a warning (the audio would leave the Mac).
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = rootDir
        panel.message = "Folder for recordings (a subfolder per day is created inside it)"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setOutputRoot(url.path)
    }

    func setOutputRoot(_ path: String) {
        outputRoot = path
        if !isRecording { outDir = Self.dayFolder(in: rootDir) }
        if path.isEmpty { status = "Recordings go to the default folder again"; return }
        let lower = path.lowercased()
        let synced = ["mobile documents", "icloud", "dropbox", "onedrive", "google drive", "googledrive", "box sync"]
            .contains { lower.contains($0) }
        status = synced
            ? "Recordings will be saved in \(path). Warning: this looks like a cloud-synced folder, so your calls would be uploaded."
            : "Recordings will be saved in \(path)"
    }

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
    private var tempName = ""                // names the temporary audio tracks
    private var files = CallFiles(dir: FileManager.default.temporaryDirectory)
    private var startDate = Date()
    private var timer: Timer?

    init() {
        localeID = UserDefaults.standard.string(forKey: "localeID") ?? "en-US"
        outputRoot = UserDefaults.standard.string(forKey: "outputRoot") ?? ""
        verifyAfterLive = UserDefaults.standard.object(forKey: "verify") as? Bool ?? true
        identifySpeakers = UserDefaults.standard.object(forKey: "speakers") as? Bool ?? true
        summarizeCalls = UserDefaults.standard.object(forKey: "summarize") as? Bool ?? true
        glossaryCorrect = UserDefaults.standard.object(forKey: "glossary") as? Bool ?? true
        translateTo = UserDefaults.standard.string(forKey: "translateTo") ?? "ru"
        let savedOpacity = UserDefaults.standard.object(forKey: "opacity") as? Double ?? 1
        windowOpacity = min(1, max(0.3, savedOpacity))
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
        let mods = shiftKey | optionKey
        HotKeys.shared.register(id: 1, keyCode: kVK_ANSI_R, modifiers: mods) { [weak self] in
            self?.toggle(live: false)
        }
        HotKeys.shared.register(id: 2, keyCode: kVK_ANSI_T, modifiers: mods) { [weak self] in
            self?.toggle(live: true)
        }
        HotKeys.shared.register(id: 3, keyCode: kVK_ANSI_S, modifiers: mods) { [weak self] in
            Task { @MainActor in await self?.takeScreenshot() }
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
        callVoices = [:]
        confirmed = []
        lines = []
        openLine = [:]
        partials = [:]
        liveMode = live
        outDir = Self.dayFolder(in: rootDir)
        transcriptFiles = []
        summaryText = ""; summaryNote = ""; summaryTranscript = ""
        checkNote = ""; speakerLabels = []
        shots = []; shotCount = 0
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
        tempName = "Call_" + stamp.string(from: Date())
        let session = CaptureSession(tempDir: FileManager.default.temporaryDirectory, baseName: tempName)

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

        files = CallFiles.newCall(in: rootDir)          // created only once recording really started
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

        let call = files
        if !shots.isEmpty { shotsByCall[call.key] = shots }
        topicByCall[call.key] = topic
        let mp3 = call.audio()
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
            try? finalLines.joined(separator: "\n").write(to: call.live, atomically: true, encoding: .utf8)
            writeTranscript(finalLines, to: call.raw)
            if lastFile != nil { status = "Saved \(mp3.lastPathComponent) + \(call.raw.lastPathComponent)" }

            if verifyAfterLive, session.hasSystemAudio || session.hasMicAudio {
                let live = finalLines
                let system = session.hasSystemAudio ? session.systemURL : nil
                let mic = session.hasMicAudio ? session.micURL : nil
                let delete = lastFile != nil
                Task {
                    let verified = await self.verify(call, system: system, mic: mic, live: live, deleteTracks: delete)
                    await self.finishCall(lines: verified, call)
                }
            } else {
                let live = finalLines
                Task { await self.finishCall(lines: live, call) }
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
        defer { busy = false; endProgress() }
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
                    busyProgress("Finding who speaks when")
                    do { turns = try await Diarizer.shared.diarize(url); callVoices = await Diarizer.shared.lastVoices; confirmed = [] }
                    catch { checkNote = "Speaker recognition failed: \(error.localizedDescription)" }
                    status = "Transcribing \(url.lastPathComponent) with \(modelName)… (several minutes for long calls)"
                }
                let sink = startProgress("Transcribing \(url.lastPathComponent)")
                if turns.isEmpty {
                    text = try await Task.detached(priority: .userInitiated) {
                        try WhisperEngine.transcribeFile(url, language: lang, progress: sink)
                    }.value
                } else {
                    let turns = turns
                    text = try await Task.detached(priority: .userInitiated) {
                        try WhisperEngine.transcribeFileWithSpeakers(url, language: lang, turns: turns, progress: sink)
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
            let call = CallFiles.forAudio(url)
            let out = call.raw
            finalLines = text.contains("\n\n") ? text.components(separatedBy: "\n\n") : text.components(separatedBy: "\n")
            transcriptFiles = []
            writeTranscript(finalLines, to: out)
            refreshSpeakers()
            status = "Saved \(out.lastPathComponent)"
            let done = finalLines
            Task { await self.finishCall(lines: done, call) }
        } catch {
            status = "Transcription failed: \(error.localizedDescription)"
        }
    }

    // MARK: Speaker names

    /// Voice fingerprints of the speakers in the current transcript, by label (kept in memory only).
    private var callVoices: [String: [Float]] = [:]
    @Published var knownVoices: [String] = VoiceBook.names
    /// Recognised people in this call whose voice has not been confirmed yet (the "Confirm" button).
    @Published var confirmable: [String] = []
    private var confirmed: Set<String> = []

    /// The app recognised this person correctly: their saved voice is refined with this call.
    func confirmVoice(_ name: String) {
        guard let voice = callVoices[name], !confirmed.contains(name) else { return }
        VoiceBook.learn(name: name, embedding: voice)
        confirmed.insert(name)
        refreshSpeakers()
        status = "Confirmed \(name): the voice profile was refined"
    }

    func forgetVoice(_ name: String) { VoiceBook.forget(name); knownVoices = VoiceBook.names }
    func forgetAllVoices() { VoiceBook.forgetAll(); knownVoices = [] }

    /// Labels such as "Speaker 1" present in the current transcript (offered in the Rename menu).
    private func refreshSpeakers() {
        knownVoices = VoiceBook.names
        confirmable = []   // recomputed below once the labels are known
        var seen: [String] = []
        // Lines look like "[mm:ss] Label: text".
        for l in finalLines {
            guard let close = l.firstIndex(of: "]") else { continue }
            let rest = l[l.index(after: close)...].drop(while: { $0 == " " })
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let label = String(rest[rest.startIndex..<colon])
            if label.hasPrefix("Speaker") || callVoices[label] != nil, !seen.contains(label) { seen.append(label) }
        }
        speakerLabels = seen
        confirmable = seen.filter { knownVoices.contains($0) && callVoices[$0] != nil && !confirmed.contains($0) }
    }

    /// Renames a speaker in the shown transcript and in the saved transcript files.
    func renameSpeaker(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        var remembered = false
        if let voice = callVoices[old] {           // teach the app this voice: later calls name this person automatically
            VoiceBook.learn(name: name, embedding: voice)
            callVoices[name] = voice
            callVoices[old] = nil
            remembered = true
        }
        finalLines = finalLines.map { $0.replacingOccurrences(of: "] \(old): ", with: "] \(name): ") }
        for url in transcriptFiles {          // raw and fixed copies both get the name
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            try? content.replacingOccurrences(of: "] \(old): ", with: "] \(name): ")
                .write(to: url, atomically: true, encoding: .utf8)
        }
        refreshSpeakers()
        status = "Renamed \(old) to \(name)" + (remembered ? " — voice remembered for the next calls" : "")
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
    /// The live version is kept next to it as "live_transcript.txt".
    @discardableResult
    private func verify(_ call: CallFiles, system: URL?, mic: URL?, live: [String], deleteTracks: Bool) async -> [String] {
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
            busyProgress("Finding who speaks when")
            do {
                turns = try await Diarizer.shared.diarize(system)
                callVoices = await Diarizer.shared.lastVoices
                confirmed = []
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
        defer { endProgress() }
        do {
            let turns = turns
            let sink = startProgress("Checking the transcript")
            let lines = try await Task.detached(priority: .utility) {
                try WhisperEngine.transcribeTracks(system: system, mic: mic, language: lang, turns: turns, progress: sink)
            }.value
            guard !lines.isEmpty else {
                checkNote = "Transcript check heard no speech; the live transcript was kept."
                return live
            }
            try live.joined(separator: "\n").write(to: call.live, atomically: true, encoding: .utf8)
            writeTranscript(lines, to: call.raw)
            if !isRecording {
                finalLines = lines
                refreshSpeakers()
            }
            let before = Self.wordCount(live), after = Self.wordCount(lines)
            checkNote = "Checked: \(call.raw.lastPathComponent) now has the verified transcript (\(before) → \(after) words). "
                      + "The live version is saved as \(call.live.lastPathComponent)." + diarizeNote
            return lines
        } catch {
            checkNote = "Transcript check failed: \(error.localizedDescription). The live transcript was kept."
            return live
        }
    }

    // MARK: Glossary + summary

    /// After the transcript is final: glossary correction, then the summary.
    func finishCall(lines: [String], _ call: CallFiles) async {
        let fixed = await glossaryFix(lines, call)
        writeTranscript(fixed, to: call.fixed)          // always written: equals the raw one when nothing was fixed
        if !isRecording { finalLines = fixed; refreshSpeakers() }
        await summarize(lines: fixed, call)
    }

    /// Writes a transcript file and remembers it, so renaming a speaker updates every copy.
    private func writeTranscript(_ lines: [String], to url: URL) {
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        transcriptFiles.insert(url)
    }

    /// Fixes misheard glossary terms (the Vocabulary… file) with the local model. The uncorrected text is kept.
    private func glossaryFix(_ lines: [String], _ call: CallFiles) async -> [String] {
        guard glossaryCorrect else { return lines }
        _ = WhisperEngine.ensureVocabularyFile()
        let terms = WhisperEngine.vocabularyTerms()
        guard !terms.isEmpty else { return lines }
        let before = checkNote
        func note(_ msg: String) { checkNote = [before, msg].filter { !$0.isEmpty }.joined(separator: " ") }
        note("Checking spelling of your glossary terms…")
        do {
            let r = try await Glossary.correct(lines, terms: terms)
            guard !r.changes.isEmpty else { note("Glossary check: no corrections needed."); return lines }
            note("Glossary: \(r.changes.count) correction(s): "
                 + r.changes.map { "\($0.wrong) → \($0.right)" }.joined(separator: ", ")
                 + ". Original kept as \(call.raw.lastPathComponent).")
            return r.lines
        } catch {
            note("Glossary check skipped: \(error.localizedDescription)")
            return lines
        }
    }

    /// Summarizes a finished transcript with the local Ollama model and saves summary.md.
    func summarize(lines: [String], _ call: CallFiles) async {
        let callShots = shotsByCall.removeValue(forKey: call.key) ?? []
        let callTopic = topicByCall.removeValue(forKey: call.key) ?? topic
        guard summarizeCalls else { return }

        var all = lines
        var shotNote = ""
        if !callShots.isEmpty {
            summaryText = ""
            summaryNote = "Describing the screenshots with a local vision model…"
            let (described, note) = await describeShots(callShots, topic: callTopic)
            shotNote = note
            if !described.isEmpty {
                try? FileManager.default.createDirectory(at: call.shotsText.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? described.joined(separator: "\n").write(to: call.shotsText, atomically: true, encoding: .utf8)
                all = Self.mergeByTime(lines, described)
            }
        }
        let transcript = all.joined(separator: "\n")
        guard transcript.split(whereSeparator: \.isWhitespace).count >= 15 else {
            summaryText = ""
            summaryNote = (["Too little speech for a summary.", shotNote]).filter { !$0.isEmpty }.joined(separator: " ")
            return
        }
        summaryText = ""
        summaryNote = "Summarizing the call with a local model…"
        summaryTranscript = transcript
        summaryTopic = callTopic
        do {
            var text = try await Summarizer.summarize(transcript: transcript, topic: callTopic)
            let t = callTopic.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !t.isEmpty { text = "**Topic:** \(t)\n\n" + text }
            let url = call.summary
            try text.write(to: url, atomically: true, encoding: .utf8)
            summaryText = text
            summaryNote = (["Summary saved as \(url.lastPathComponent).", shotNote]).filter { !$0.isEmpty }.joined(separator: " ")
        } catch {
            summaryNote = "No summary: \(error.localizedDescription) You can still use “Copy for Claude”."
        }
    }

    private static func timeText(_ t: Double) -> String {
        let s = Int(max(t, 0)); return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Screenshot descriptions as transcript lines ("[mm:ss] [Screen] …"), made by a local vision model.
    private func describeShots(_ shots: [Shot], topic: String) async -> ([String], String) {
        let models: [String]
        do { models = try await Summarizer.installedModels() }
        catch { return ([], "\(shots.count) screenshot(s) saved but not described: \(error.localizedDescription)") }
        guard let model = Summarizer.pickVisionModel(models) else {
            return ([], "\(shots.count) screenshot(s) saved but not described: no vision model in Ollama (run: ollama pull qwen2.5vl:7b).")
        }
        var out: [String] = []
        var failed = 0
        for (i, shot) in shots.enumerated() {
            summaryNote = "Describing screenshot \(i + 1) of \(shots.count) with \(model)…"
            do {
                let png = try Data(contentsOf: shot.file)
                let d = try await Summarizer.describeImage(png, model: model, topic: topic)
                out.append("[\(Self.timeText(shot.t))] [Screen] \(d)")
            } catch { failed += 1 }
        }
        return (out, failed > 0 ? "\(failed) screenshot(s) could not be described." : "")
    }

    /// Inserts the extra lines among the transcript lines by their [mm:ss] time; lines without a time stay put.
    static func mergeByTime(_ lines: [String], _ extra: [String]) -> [String] {
        func tOf(_ l: String) -> Int? {
            guard l.hasPrefix("["), let close = l.firstIndex(of: "]") else { return nil }
            let p = l[l.index(after: l.startIndex)..<close].split(separator: ":")
            guard p.count == 2, let m = Int(p[0]), let s = Int(p[1]) else { return nil }
            return m * 60 + s
        }
        let all = lines.enumerated().map { (t: tOf($0.element) ?? -1, i: $0.offset, l: $0.element) }
                + extra.enumerated().map { (t: tOf($0.element) ?? -1, i: 1_000_000 + $0.offset, l: $0.element) }
        return all.sorted { $0.t != $1.t ? $0.t < $1.t : $0.i < $1.i }.map(\.l)
    }

    // MARK: Screenshots

    /// Saves a screenshot of a part of the screen that you select with the mouse (a shared slide, a picture…).
    /// After the call a local vision model describes it and the description joins the transcript for the summary.
    /// Uses macOS's own selection tool (crosshair; Esc cancels). The image stays on this Mac.
    func takeScreenshot() async {
        guard isRecording else { status = "Screenshots can be taken while a recording is running."; return }
        let t = Date().timeIntervalSince(startDate)
        let dir = files.shotsDir
        let name = String(format: "%02d_", shots.count + 1) + Self.timeText(t).replacingOccurrences(of: ":", with: "-") + ".png"
        let file = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            status = "Screenshot failed: \(error.localizedDescription)"
            return
        }
        status = "Drag to select the area… (Esc cancels)"
        let ok = await Task.detached { Self.runSelectionCapture(to: file) }.value
        if ok, FileManager.default.fileExists(atPath: file.path) {
            shots.append(Shot(t: t, file: file))
            shotCount = shots.count
            status = "Screenshot \(shots.count) saved at \(Self.timeText(t))"
        } else {
            if let left = try? FileManager.default.contentsOfDirectory(atPath: dir.path), left.isEmpty {
                try? FileManager.default.removeItem(at: dir)         // don't leave an empty folder behind
            }
            status = "Screenshot cancelled."
        }
    }

    /// `screencapture -i -s -x`: interactive area selection, no sound. Exits non-zero or writes no file when cancelled.
    private nonisolated static func runSelectionCapture(to file: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-s", "-x", "-t", "png", file.path]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Puts the summary prompt + transcript on the clipboard, to paste into claude.ai.
    func copyForClaude() {
        guard !summaryTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Summarizer.pasteText(summaryTranscript, topic: summaryTopic), forType: .string)
        summaryNote = "Copied. Paste it into a Claude chat to get the summary."
    }

    func openFolder() { NSWorkspace.shared.open(rootDir) }

    func openVocabulary() { NSWorkspace.shared.open(WhisperEngine.ensureVocabularyFile()) }

    // MARK: Window layout

    @Published var transcriptHeight: CGFloat = 260        // the big text areas can be resized by dragging their grip
    @Published var summaryHeight: CGFloat = 180
    @Published var wordsExpanded = true
    @Published var wordsHeight: CGFloat = 130

    /// Changes whenever the transcript grows, so the transcript area follows its end.
    var transcriptScrollKey: Int { finalLines.count &* 31 &+ partials.values.reduce(0) { $0 &+ $1.count } }

    private var mainWindow: NSWindow? { NSApp.windows.first { $0.title == "CallRecorder" && !($0 is NSPanel) } }

    /// Never bigger than the screen: shrinks and moves the window to fit the visible area.
    func fitWindowToScreen() {
        guard let w = mainWindow, let area = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = w.frame
        f.size.width = min(f.width, area.width)
        f.size.height = min(f.height, area.height)
        f.origin.x = min(max(f.origin.x, area.minX), area.maxX - f.width)
        f.origin.y = min(max(f.origin.y, area.minY), area.maxY - f.height)
        if f != w.frame { w.setFrame(f, display: true, animate: false) }
    }

    /// The line under the transcript: the window grows or shrinks by `dy` (the top edge stays, the bottom stays on screen).
    func resizeWindow(byHeight dy: CGFloat) {
        guard dy != 0, let w = mainWindow, let area = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = w.frame
        let top = f.maxY
        let height = min(max(f.height + dy, w.minSize.height), top - area.minY)
        guard height != f.height else { return }
        f.size.height = height
        f.origin.y = top - height
        w.setFrame(f, display: true, animate: false)
    }

    private var translateGrow: CGFloat = 0

    /// The translation pane needs room: the window grows by up to 460 pt (never past the screen) and gives it back.
    private func adjustWindowForTranslation(open: Bool) {
        guard let w = mainWindow, let area = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = w.frame
        if open && translateGrow == 0 {
            let width = min(f.width + 460, area.width)
            translateGrow = width - f.width
            f.size.width = width
            f.origin.x = min(max(f.origin.x, area.minX), area.maxX - width)
        } else if !open && translateGrow > 0 {
            f.size.width = max(min(520, area.width), f.width - translateGrow)
            translateGrow = 0
        } else { return }
        w.setFrame(f, display: true, animate: true)
    }

    // MARK: Progress of the Whisper pass

    /// 0...1 while a transcription runs; negative = busy with unknown length (finding speakers); nil = nothing running.
    @Published var progress: Double?
    @Published var progressLabel = ""
    @Published var progressStart = Date()

    /// Starts a progress display and returns the callback for the (background) Whisper pass.
    private func startProgress(_ label: String) -> @Sendable (Double) -> Void {
        progress = 0
        progressLabel = label
        progressStart = Date()
        return { [weak self] f in
            Task { @MainActor in
                guard let self, self.progress != nil else { return }
                let v = (f * 100).rounded() / 100
                if v != self.progress { self.progress = v }
            }
        }
    }

    private func busyProgress(_ label: String) { progress = -1; progressLabel = label; progressStart = Date() }
    private func endProgress() { progress = nil; progressLabel = "" }

    // MARK: Word statistics

    struct WordReport {
        var source: String
        var frequent: [WordStats.Item]
        var unknown: [WordStats.Item]
    }
    @Published var wordReport: WordReport?

    /// The 10 most frequent words and 10 unknown words (not in the Vocabulary list) of the transcript on screen,
    /// or of a transcript file if there is none.
    func analyzeWords() {
        var transcript = finalLines.joined(separator: "\n")
        var source = "current transcript"
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.plainText]
            panel.directoryURL = Self.dayFolder(in: rootDir)
            panel.message = "Choose a transcript file to analyze"
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                status = "Could not read \(url.lastPathComponent)"
                return
            }
            transcript = content
            source = url.lastPathComponent
        }
        wordReport = WordReport(source: source,
                                frequent: WordStats.topWords(transcript, n: 10),
                                unknown: WordStats.unknownWords(transcript, vocabulary: WhisperEngine.vocabularyTerms(), n: 10))
    }

    /// Adds words to the Vocabulary list (skipping ones already there).
    func addVocabulary(_ words: [String]) {
        let url = WhisperEngine.ensureVocabularyFile()
        var have = Set(WhisperEngine.vocabularyTerms().map(WordStats.norm))
        var add: [String] = []
        for w in words.map({ $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }) where !w.isEmpty {
            if have.contains(WordStats.norm(w)) { continue }
            have.insert(WordStats.norm(w))
            add.append(String(w.prefix(60)))
        }
        if !add.isEmpty {
            var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if !content.hasSuffix("\n") { content += "\n" }
            content += add.joined(separator: "\n") + "\n"
            try? content.write(to: url, atomically: true, encoding: .utf8)
            if var r = wordReport {
                let gone = Set(add.map(WordStats.norm))
                r.unknown.removeAll { gone.contains(WordStats.norm($0.word)) }
                wordReport = r
            }
            status = "Added to the Vocabulary list: \(add.joined(separator: ", "))"
        } else {
            status = "Those words are already in the Vocabulary list."
        }
    }

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
