import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppState.shared.registerHotKeys() }
    }
}

@main
struct CallRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            Image(systemName: state.isRecording ? "record.circle.fill" : "waveform.circle")
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
            }

            Button {
                state.toggle(live: false)
            } label: {
                Label(state.isRecording && !state.liveMode ? "Stop recording" : "Record to MP3",
                      systemImage: state.isRecording && !state.liveMode ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
                Text("⌃⌥R").foregroundStyle(.secondary)
            }
            .controlSize(.large)
            .disabled(state.busy || (state.isRecording && state.liveMode))

            Button {
                state.toggle(live: true)
            } label: {
                Label(state.isRecording && state.liveMode ? "Stop" : "Record + live transcript",
                      systemImage: state.isRecording && state.liveMode ? "stop.fill" : "text.bubble")
                    .frame(maxWidth: .infinity)
                Text("⌃⌥L").foregroundStyle(.secondary)
            }
            .controlSize(.large)
            .disabled(state.busy || (state.isRecording && !state.liveMode))

            Picker("Language", selection: $state.localeID) {
                ForEach(AppState.languages, id: \.id) { Text($0.name).tag($0.id) }
            }
            .disabled(state.isRecording)

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
                    .frame(height: 180)
                    .onChange(of: state.finalLines.count) { _, _ in proxy.scrollTo("end") }
                }
            }

            Divider()

            HStack {
                Button("Transcribe file…") { state.transcribeFileDialog() }
                    .disabled(state.busy || state.isRecording)
                Button("Open folder") { state.openFolder() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }

            Text(state.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 340)
    }
}
