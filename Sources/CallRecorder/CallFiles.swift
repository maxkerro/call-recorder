import Foundation

/// Where the files of one call live:
///   <root>/<yyyy-MM-dd>/<HH-mm-ss>/audio.mp3, raw_transcript.txt, fixed_transcript.txt, summary.md, screenshots/
/// (plus live_transcript.txt: the live version, kept when the accurate check pass replaced it).
/// An audio file from elsewhere (not named audio.*) gets the same names next to it, prefixed with its own name.
struct CallFiles {
    var dir: URL
    var prefix = ""

    var raw: URL { dir.appendingPathComponent(prefix + "raw_transcript.txt") }
    var fixed: URL { dir.appendingPathComponent(prefix + "fixed_transcript.txt") }
    var live: URL { dir.appendingPathComponent(prefix + "live_transcript.txt") }
    var summary: URL { dir.appendingPathComponent(prefix + "summary.md") }
    func audio(_ ext: String = "mp3") -> URL { dir.appendingPathComponent("audio." + ext) }
    var shotsDir: URL { dir.appendingPathComponent(prefix.isEmpty ? "screenshots" : prefix + "screenshots", isDirectory: true) }
    var shotsText: URL {
        prefix.isEmpty ? shotsDir.appendingPathComponent("descriptions.txt") : dir.appendingPathComponent(prefix + "screenshots.txt")
    }
    var key: String { raw.path }

    static func forAudio(_ file: URL) -> CallFiles {
        let dir = file.deletingLastPathComponent()
        if file.deletingPathExtension().lastPathComponent.lowercased() == "audio" { return CallFiles(dir: dir) }
        return CallFiles(dir: dir, prefix: file.deletingPathExtension().lastPathComponent + ".")
    }

    /// Creates <root>/<date>/<time>/ (adds -2, -3… if that second is taken). Owner-only permissions.
    static func newCall(in root: URL, date: Date = Date()) -> CallFiles {
        let fm = FileManager.default
        let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd"
        let t = DateFormatter(); t.dateFormat = "HH-mm-ss"
        let day = root.appendingPathComponent(d.string(from: date), isDirectory: true)
        try? fm.createDirectory(at: day, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: day.path)
        let stamp = t.string(from: date)
        var i = 1
        while true {
            let dir = day.appendingPathComponent(i == 1 ? stamp : "\(stamp)-\(i)", isDirectory: true)
            if (try? fm.createDirectory(at: dir, withIntermediateDirectories: false)) != nil {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
                return CallFiles(dir: dir)
            }
            i += 1
            if i > 99 { return CallFiles(dir: day) }
        }
    }
}
