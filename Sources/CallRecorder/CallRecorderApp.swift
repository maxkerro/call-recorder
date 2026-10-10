import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.make()
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in AppState.shared.registerHotKeys() }
    }

    // Closing the window keeps the app (and its hotkeys) running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Red rounded square with white sound bars, drawn in code so no asset files are needed.
enum AppIcon {
    static func make() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let bg = NSBezierPath(roundedRect: rect.insetBy(dx: 20, dy: 20), xRadius: 110, yRadius: 110)
            NSColor(red: 0.86, green: 0.12, blue: 0.18, alpha: 1).setFill()
            bg.fill()
            NSColor.white.setFill()
            let heights: [CGFloat] = [110, 210, 310, 210, 110]
            let barWidth: CGFloat = 40, gap: CGFloat = 30
            let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            var x = (rect.width - total) / 2
            for h in heights {
                let bar = NSRect(x: x, y: (rect.height - h) / 2, width: barWidth, height: h)
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                x += barWidth + gap
            }
            return true
        }
    }
}

@main
struct CallRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        // Main window: opens on launch and when you click the Dock icon.
        Window("CallRecorder", id: "main") {
            MenuView(state: state)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuView(state: state)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: state.isRecording ? "record.circle.fill" : "waveform.circle.fill")
                Text(state.isRecording ? state.elapsed : "Rec")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case recorder = "Recorder", settings = "Settings", about = "About"
    var id: String { rawValue }
}

struct MenuView: View {
    @ObservedObject var state: AppState
    @State private var tab: AppTab = .recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Call Recorder").font(.headline)
                Spacer()
                if state.isRecording {
                    Label(state.elapsed, systemImage: "circle.fill")
                        .foregroundStyle(.red)
                        .monospacedDigit()
                }
            }

            Picker("", selection: $tab) {
                ForEach(AppTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .recorder: recorderTab
            case .settings: settingsTab
            case .about: aboutTab
            }

            Divider()
            if let p = state.progress {
                HStack(spacing: 10) {
                    if p < 0 { ProgressView().controlSize(.small) } else { ProgressView(value: p).frame(maxWidth: .infinity) }
                    Text(p < 0 ? "\(state.progressLabel)…" : "\(state.progressLabel): \(Int((p * 100).rounded())) %")
                        .font(.callout.monospacedDigit())
                    if p < 0 { Spacer() }
                }
            }
            Text(state.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !state.checkNote.isEmpty {
                Text(state.checkNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.large)
        .padding(14)
        .frame(width: state.translationOpen ? 1060 : 600)
        .onAppear { DispatchQueue.main.async { state.applyOpacity() } }
    }

    // MARK: Recorder

    private var recorderTab: some View {
        VStack(alignment: .leading, spacing: 12) {
        Group {
        HStack(spacing: 8) {
            Button {
                state.toggle(live: false)
            } label: {
                VStack(spacing: 2) {
                    Label(state.isRecording && !state.liveMode ? "Stop" : "Record",
                          systemImage: state.isRecording && !state.liveMode ? "stop.fill" : "record.circle")
                    Text("⇧⌥R").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(state.busy || (state.isRecording && state.liveMode))

            Button {
                state.toggle(live: true)
            } label: {
                VStack(spacing: 2) {
                    Label(state.isRecording && state.liveMode ? "Stop" : "Record + transcript",
                          systemImage: state.isRecording && state.liveMode ? "stop.fill" : "text.bubble")
                    Text("⇧⌥T").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(state.busy || (state.isRecording && !state.liveMode))

            Button {
                Task { await state.takeScreenshot() }
            } label: {
                VStack(spacing: 2) {
                    Label(state.shotCount > 0 ? "Screenshot (\(state.shotCount))" : "Screenshot",
                          systemImage: "camera.viewfinder")
                    Text("⇧⌥S").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!state.isRecording)
        }
        .controlSize(.large)

        TextField("Topic of this call (optional, guides the summary)", text: $state.topic)
            .textFieldStyle(.roundedBorder)
        }

        Group {

        if !state.speakerLabels.isEmpty && !state.isRecording {
            Menu("Rename speaker") {
                ForEach(state.speakerLabels, id: \.self) { name in
                    Button(name) { state.promptRename(name) }
                }
            }
        }

        if !state.confirmable.isEmpty && !state.isRecording {
            Menu("Confirm speaker") {
                ForEach(state.confirmable, id: \.self) { name in
                    Button("\(name) is correct") { state.confirmVoice(name) }
                }
            }
            .help("The app recognised this person correctly: refine their saved voice")
        }

        if let hint = state.whisperHint {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 8) {
            Text("Transcript").font(.subheadline.bold())
            Spacer()
            if state.translationOpen {
                HStack(spacing: 4) {
                    Button { state.translationControl(.pause) } label: { Image(systemName: "pause.fill") }
                        .help("Pause: finish the current line, then wait")
                        .disabled(state.translationState != .running)
                    Button { state.translationControl(.resume) } label: { Image(systemName: "play.fill") }
                        .help("Continue translating")
                        .disabled(state.translationState == .running)
                    Button { state.translationControl(.stop) } label: { Image(systemName: "stop.fill") }
                        .help("Stop: cancel the current line and skip what is waiting")
                        .disabled(state.translationState == .stopped)
                    Button { state.translationControl(.restart) } label: { Image(systemName: "arrow.counterclockwise") }
                        .help("Restart: translate everything again from the start")
                }
                .controlSize(.small)
                Picker("", selection: $state.translateTo) {
                    ForEach(Translator.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            Button(state.translationOpen ? "Translation ▸" : "Translation ◂") { state.translationOpen.toggle() }
        }

        if !state.translateNote.isEmpty {
            Text(state.translateNote).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !state.finalLines.isEmpty || !state.partials.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(state.finalLines.enumerated()), id: \.offset) { _, l in
                            HStack(alignment: .top, spacing: 14) {
                                Text(l).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if state.translationOpen {
                                    let t = state.translation(for: l)
                                    Text(t ?? "…").textSelection(.enabled)
                                        .foregroundStyle(t == nil ? .secondary : .primary)
                                        .padding(.leading, 10)
                                        .overlay(alignment: .leading) { Rectangle().fill(.tint).frame(width: 2).opacity(t == nil ? 0 : 1) }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        ForEach(state.partials.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                            HStack(alignment: .top, spacing: 14) {
                                Text("\(k): \(v)").foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if state.translationOpen { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 260)
                .onChange(of: state.finalLines) { _, _ in proxy.scrollTo("end") }
                .onChange(of: state.partials) { _, _ in proxy.scrollTo("end") }
            }
        }

        if !state.summaryText.isEmpty || !state.summaryNote.isEmpty {
            Divider()
            Text("Summary").font(.subheadline.bold())
            if !state.summaryText.isEmpty {
                ScrollView {
                    Text(state.summaryText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            Text(state.summaryNote).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !state.summaryText.isEmpty {
                    Button("Copy summary") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.summaryText, forType: .string)
                    }
                }
                Button("Copy for Claude") { state.copyForClaude() }
            }
            .fixedSize()
        }

        }

        Divider()

        // One row. Every button has the same (large) height.
        HStack(spacing: 8) {
            Button("Transcribe file") { state.transcribeFileDialog() }
                .disabled(state.busy || state.isRecording)
            Button("Open folder") { state.openFolder() }
            Button("Vocabulary") { state.openVocabulary() }
            Button("Analyze words") { state.analyzeWords() }
                .help("Most frequent words and words that are not in your Vocabulary list")
            Spacer()
        }
        .buttonStyle(.bordered)
        .fixedSize(horizontal: false, vertical: true)

        if let r = state.wordReport {
            VStack(alignment: .leading, spacing: 6) {
                Text("Words (\(r.source))").font(.subheadline.bold())
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("10 most frequent").font(.caption.bold())
                        ForEach(Array(r.frequent.enumerated()), id: \.offset) { i, w in
                            Text("\(i + 1). \(w.word) × \(w.count)").font(.callout)
                        }
                        if r.frequent.isEmpty { Text("—") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("10 unknown").font(.caption.bold())
                            if !r.unknown.isEmpty {
                                Button("Add all") { state.addVocabulary(r.unknown.map(\.word)) }
                                    .controlSize(.mini)
                                    .help("Add all to the Vocabulary list")
                            }
                        }
                        ForEach(Array(r.unknown.enumerated()), id: \.offset) { i, w in
                            HStack(spacing: 6) {
                                Text("\(i + 1). \(w.word) × \(w.count)").font(.callout)
                                Button("+ Vocabulary") { state.addVocabulary([w.word]) }.controlSize(.mini)
                            }
                        }
                        if r.unknown.isEmpty { Text("—") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Unknown = names, abbreviations and terms that are not in your Vocabulary list. Add the ones Whisper should spell right.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }

        HStack(spacing: 10) {
            Text("Window transparency")
            Slider(value: $state.windowOpacity, in: 0.3...1)
            Text("\(Int((state.windowOpacity * 100).rounded())) %")
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        }
    }

    // MARK: Settings

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
            Text("Save to:")
            Text(state.outputRoot.isEmpty ? state.rootDir.path : state.outputRoot)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose…") { state.chooseFolder() }.fixedSize()
            Button("Default") { state.setOutputRoot("") }.fixedSize()
                .disabled(state.outputRoot.isEmpty)
        }
        .disabled(state.isRecording)

        Picker("Language", selection: $state.localeID) {
            ForEach(AppState.languages, id: \.id) { Text($0.name).tag($0.id) }
        }
        .disabled(state.isRecording)

        Picker("Engine", selection: $state.engine) {
            ForEach(Engine.allCases) { Text($0.name).tag($0) }
        }
        .disabled(state.isRecording)

        Toggle("Check transcript after live recording", isOn: $state.verifyAfterLive)
            .disabled(state.isRecording)

        Toggle("Recognize speakers (Speaker 1, 2…)", isOn: $state.identifySpeakers)
            .disabled(state.isRecording)

        VStack(alignment: .leading, spacing: 4) {
            Text("Known voices").font(.subheadline.bold())
            Text("Rename a speaker after a call (Rename speaker) and the app remembers the voice; next calls use the name. "
                 + "Voice data stays on this Mac (voices.json in Application Support/CallRecorder).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if state.knownVoices.isEmpty {
                Text("None yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(state.knownVoices, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button("Forget") { state.forgetVoice(name) }.controlSize(.small)
                    }
                }
                Button("Forget all voices") { state.forgetAllVoices() }.controlSize(.small)
            }
        }

        Toggle("Fix glossary terms in transcript (Vocabulary list, local Ollama)", isOn: $state.glossaryCorrect)
            .disabled(state.isRecording)

        Toggle("Summarize each call (local Ollama)", isOn: $state.summarizeCalls)
            .disabled(state.isRecording)

        Toggle("Offline mode (never download anything)", isOn: $state.offlineMode)
            .disabled(state.isRecording)
        }
    }

    // MARK: About

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(AppInfo.name) \(AppInfo.version)").font(.title3.bold())
            Text(AppInfo.summary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Version").foregroundStyle(.secondary); Text("\(AppInfo.version) (build \(AppInfo.build))") }
                GridRow { Text("Released").foregroundStyle(.secondary); Text(AppInfo.releaseDate) }
                GridRow { Text("Author").foregroundStyle(.secondary); Text(AppInfo.author) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
