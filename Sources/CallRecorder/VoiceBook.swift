import Foundation

/// Voice profiles: a name and a voice "fingerprint" (speaker embedding) for people the user has named.
/// Stored only on this Mac, in Application Support/CallRecorder/voices.json (owner-only file). Never sent anywhere.
struct VoiceProfile: Codable {
    var name: String
    var embedding: [Float]      // unit length
    var count: Int              // how many calls it has learned from (capped, so it can still adapt)
}

enum VoiceBook {
    /// Minimum cosine similarity to call a voice "the same person", and the lead it needs over the runner-up.
    static let threshold: Float = 0.55
    static let margin: Float = 0.04

    static var url: URL { WhisperEngine.supportDir.appendingPathComponent("voices.json") }

    static func load() -> [VoiceProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([VoiceProfile].self, from: data)) ?? []
    }

    static func save(_ profiles: [VoiceProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static var names: [String] { load().map(\.name).sorted() }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot          // both are unit length
    }

    /// Which cluster is which known person. Each person is given to at most one cluster (the best match first),
    /// and only when the match is clear: above the threshold and ahead of the next-best person by the margin.
    static func match(_ clusters: [String: [Float]], profiles: [VoiceProfile]) -> [String: String] {
        var scored: [(cluster: String, name: String, score: Float, runnerUp: Float)] = []
        for (id, emb) in clusters {
            let s = profiles.map { (name: $0.name, score: cosine(emb, $0.embedding)) }.sorted { $0.score > $1.score }
            if let best = s.first { scored.append((id, best.name, best.score, s.count > 1 ? s[1].score : -1)) }
        }
        var out: [String: String] = [:], used = Set<String>()
        for c in scored.sorted(by: { $0.score > $1.score }) {
            guard c.score >= threshold, c.score - c.runnerUp >= margin, !used.contains(c.name) else { continue }
            out[c.cluster] = c.name
            used.insert(c.name)
        }
        return out
    }

    /// Remembers (or refines) a person's voice.
    static func learn(name: String, embedding: [Float]) {
        let e = normalized(embedding)
        guard !e.isEmpty else { return }
        var profiles = load()
        if let i = profiles.firstIndex(where: { $0.name == name }), profiles[i].embedding.count == e.count {
            let n = Float(profiles[i].count)
            let mixed = zip(profiles[i].embedding, e).map { $0 * n + $1 }
            profiles[i].embedding = normalized(mixed)
            profiles[i].count = min(profiles[i].count + 1, 20)
        } else {
            profiles.removeAll { $0.name == name }
            profiles.append(VoiceProfile(name: name, embedding: e, count: 1))
        }
        save(profiles)
    }

    static func forget(_ name: String) { save(load().filter { $0.name != name }) }
    static func forgetAll() { try? FileManager.default.removeItem(at: url) }
}
