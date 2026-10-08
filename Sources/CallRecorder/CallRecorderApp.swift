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

struct MenuView: View {
    @ObservedObject var state: AppState

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
                Button("About") { AppInfo.show() }
            }

            Button {
                state.toggle(live: false)
            } label: {
                Label(state.isRecording && !state.liveMode ? "Stop recording" : "Record to MP3",
                      systemImage: state.isRecording && !state.liveMode ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
                Text("⇧⌥R").foregroundStyle(.secondary)
            }
            .controlSize(.large)
            .disabled(state.busy || (state.isRecording && state.liveMode))

            Button {
                state.toggle(live: true)
            } label: {
                Label(state.isRecording && state.liveMode ? "Stop" : "Record + live transcript",
                      systemImage: state.isRecording && state.liveMode ? "stop.fill" : "text.bubble")
                    .frame(maxWidth: .infinity)
                Text("⇧⌥T").foregroundStyle(.secondary)
            }
            .controlSize(.large)
            .disabled(state.busy || (state.isRecording && !state.liveMode))

            Button {
                Task { await state.takeScreenshot() }
            } label: {
                Label(state.shotCount > 0 ? "Screenshot into summary (\(state.shotCount))" : "Screenshot into summary",
                      systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("⇧⌥S").foregroundStyle(.secondary)
            }
            .controlSize(.large)
            .disabled(!state.isRecording)

            TextField("Topic of this call (optional, guides the summary)", text: $state.topic)
                .textFieldStyle(.roundedBorder)

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

            Toggle("Fix glossary terms in transcript (Vocabulary list, local Ollama)", isOn: $state.glossaryCorrect)
                .disabled(state.isRecording)

            Toggle("Summarize each call (local Ollama)", isOn: $state.summarizeCalls)
                .disabled(state.isRecording)

            Toggle("Offline mode (never download anything)", isOn: $state.offlineMode)
                .disabled(state.isRecording)

            if !state.speakerLabels.isEmpty && !state.isRecording {
                Menu("Rename speaker") {
                    ForEach(state.speakerLabels, id: \.self) { name in
                        Button(name) { state.promptRename(name) }
                    }
                }
            }

            if let hint = state.whisperHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !state.finalLines.isEmpty || !state.partials.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(state.finalLines.enumerated()), id: \.offset) { _, l in
                                Text(l).textSelection(.enabled)
                            }
                            ForEach(state.partials.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                                Text("\(k): \(v)").foregroundStyle(.secondary)
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

            Divider()

            // One row. Every button has the same (large) height.
            HStack(spacing: 8) {
                Button("Transcribe file") { state.transcribeFileDialog() }
                    .disabled(state.busy || state.isRecording)
                Button("Open folder") { state.openFolder() }
                Button("Vocabulary") { state.openVocabulary() }
                Spacer()
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: false, vertical: true)

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
        .frame(width: 600)
    }
}
