import Foundation
import FluidAudio

struct SpeakerTurn {
    var speaker: String      // "Speaker 1", "Speaker 2", … in order of first appearance
    var start: Double
    var end: Double
}

/// Works out who spoke when, locally, with FluidAudio's offline diarizer (models are downloaded on first use).
actor Diarizer {
    static let shared = Diarizer()
    private var manager: OfflineDiarizerManager?

    /// Offline mode: FluidAudio refuses every network fetch (it only downloads its models, on first use).
    nonisolated static func setOffline(_ on: Bool) { ModelHub.offlineMode = on }

    func diarize(_ url: URL) async throws -> [SpeakerTurn] {
        if manager == nil {
            let m = OfflineDiarizerManager(config: OfflineDiarizerConfig())
            try await m.prepareModels()
            manager = m
        }
        guard let manager else { return [] }
        let samples = try AudioConverter().resampleAudioFile(path: url.path)
        let result = try await manager.process(audio: samples)

        var raw = result.segments.map {
            (id: "\($0.speakerId)", start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        // Ignore "speakers" with under 3 s in total: usually noise or a cough, not a person.
        var total: [String: Double] = [:]
        for r in raw { total[r.id, default: 0] += r.end - r.start }
        raw = raw.filter { (total[$0.id] ?? 0) >= 3 }
        raw.sort { $0.start < $1.start }

        var names: [String: String] = [:]
        return raw.map { r in
            if names[r.id] == nil { names[r.id] = "Speaker \(names.count + 1)" }
            return SpeakerTurn(speaker: names[r.id]!, start: r.start, end: r.end)
        }
    }
}
