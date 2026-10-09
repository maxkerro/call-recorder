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
    /// Voice fingerprint (unit length) of every speaker found in the last call, by the label used in the transcript.
    private(set) var lastVoices: [String: [Float]] = [:]

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

        // Known people (named earlier by the user) are recognised by their voice; the rest become "Speaker N".
        var clusters: [String: [Float]] = [:]
        for (id, emb) in result.speakerDatabase ?? [:] where total[id] != nil && (total[id] ?? 0) >= 3 {
            clusters[id] = VoiceBook.normalized(emb)
        }
        let known = VoiceBook.match(clusters, profiles: VoiceBook.load())

        var names: [String: String] = [:]
        var unknown = 0
        lastVoices = [:]
        let turns: [SpeakerTurn] = raw.map { r in
            if names[r.id] == nil {
                if let n = known[r.id] { names[r.id] = n } else { unknown += 1; names[r.id] = "Speaker \(unknown)" }
                if let emb = clusters[r.id] { lastVoices[names[r.id]!] = emb }
            }
            return SpeakerTurn(speaker: names[r.id]!, start: r.start, end: r.end)
        }
        return turns
    }
}
