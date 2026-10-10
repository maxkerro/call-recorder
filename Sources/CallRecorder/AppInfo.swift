import AppKit

/// Facts shown in the About box. Keep `version` in step with Info.plist and windows/package.json.
enum AppInfo {
    static let name = "Call Recorder"
    static let version = "1.24.29"
    static let build = "54"                       // number of commits at release
    static let releaseDate = "8 October 2026"
    static let author = "Maksim Masliukov"
    static let summary = """
    Records any call you hear (Teams, Skype, a browser…) plus your microphone, transcribes it \
    locally with Whisper, labels the speakers, and writes a summary with a local Ollama model. \
    Nothing leaves your computer.
    """

    @MainActor static func show() {
        let alert = NSAlert()
        alert.messageText = "\(name) \(version)"
        alert.informativeText = """
        \(summary)

        Version: \(version) (build \(build))
        Released: \(releaseDate)
        Author: \(author)
        """
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
