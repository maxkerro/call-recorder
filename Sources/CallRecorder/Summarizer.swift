import Foundation

/// Summarizes a transcript with a local model served by Ollama (https://ollama.com), so the call never leaves the Mac.
enum Summarizer {
    static let base = URL(string: "http://127.0.0.1:11434")!
    private static let preferred = ["qwen2.5:14b", "qwen2.5:7b", "llama3.1:8b", "gemma2:9b", "mistral:7b", "llama3.2:3b"]

    enum SummaryError: LocalizedError {
        case notRunning, noModel, failed(String)
        var errorDescription: String? {
            switch self {
            case .notRunning: return "Ollama isn't running. Install it from ollama.com (or: brew install ollama && ollama serve)."
            case .noModel: return "No Ollama model installed. Run: ollama pull qwen2.5:7b"
            case .failed(let m): return m
            }
        }
    }

    static let prompt = """
    You are given the transcript of a work call (lines look like "[mm:ss] Speaker: text"). It may contain recognition \
    errors. Write a concise summary in the language the call was mostly held in, in Markdown, with these sections:
    ## Summary (3-6 sentences)
    ## Key points (bullets)
    ## Decisions (bullets, or "None")
    ## Action items (bullets: who - what - when if mentioned, or "None")
    ## Open questions (bullets, or "None")
    Lines marked [Screen] describe screenshots of what was shown on screen at that moment (slides, documents, \
    diagrams); use them as context and mention them where relevant.
    Use only what is in the transcript; do not invent names, numbers or decisions.
    """

    /// The topic is typed by the user before the call; it steers the summary. One line, bounded length.
    static func topicLine(_ topic: String) -> String {
        let t = topic.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(300)
        if t.isEmpty { return "" }
        return "Topic of this call, set in advance by the user: \"\(t)\". Organize the summary around this topic: what was said, decided and left open about it; mention anything important but off-topic briefly. If the transcript says nothing about the topic, say so.\n\n"
    }

    /// Prompt + transcript, for pasting into any chat (e.g. claude.ai).
    static func pasteText(_ transcript: String, topic: String = "") -> String {
        prompt + "\n\n" + topicLine(topic) + "Transcript:\n" + transcript
    }

    static func installedModels() async throws -> [String] {
        var req = URLRequest(url: base.appendingPathComponent("api/tags"))
        req.timeoutInterval = 3
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (obj?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        } catch {
            throw SummaryError.notRunning
        }
    }

    static func pickModel(_ installed: [String]) -> String? {
        for p in preferred { if let m = installed.first(where: { $0 == p || $0.hasPrefix(p + "-") }) { return m } }
        return installed.first(where: { !$0.contains("embed") })
    }

    static func summarize(transcript: String, topic: String = "") async throws -> String {
        let installed = try await installedModels()
        guard let model = pickModel(installed) else { throw SummaryError.noModel }

        // Long calls: summarize chunks first, then summarize the summaries.
        let chunks = split(transcript, limit: 20_000)
        if chunks.count == 1 { return try await generate(model: model, prompt: pasteText(chunks[0], topic: topic)) }
        var parts: [String] = []
        for (i, c) in chunks.enumerated() {
            parts.append(try await generate(model: model,
                prompt: "Summarize part \(i + 1) of \(chunks.count) of a call transcript in detail (key points, decisions, action items with owners, open questions). Same language as the transcript.\n\n" + c))
        }
        return try await generate(model: model,
            prompt: prompt + "\n\n" + topicLine(topic) + "Instead of a transcript you get notes on consecutive parts of the call:\n\n" + parts.joined(separator: "\n\n---\n\n"))
    }

    private static let visionPreferred = ["qwen2.5vl", "qwen3-vl", "llama3.2-vision", "gemma3", "minicpm-v", "llava"]

    static func pickVisionModel(_ installed: [String]) -> String? {
        for p in visionPreferred { if let m = installed.first(where: { $0.lowercased().hasPrefix(p) }) { return m } }
        return installed.first { $0.range(of: "vision|-vl|llava|moondream", options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Describes one screenshot with a local vision model (the image goes to 127.0.0.1 only).
    static func describeImage(_ png: Data, model: String, topic: String) async throws -> String {
        var ask = "This is a screenshot from a work call (a shared presentation, document, chart or picture). "
            + "Transcribe the visible titles and the key text exactly, then describe any diagram, chart or picture in a sentence. "
        if !topic.isEmpty { ask += "The call is about: \(topic.prefix(200)). " }
        ask += "Answer in at most 120 words, plain text, no preamble."
        var req = URLRequest(url: base.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model, "prompt": ask, "stream": false,
                                   "images": [png.base64EncodedString()],
                                   "options": ["num_ctx": 8192, "temperature": 0.1]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let err = obj?["error"] as? String { throw SummaryError.failed("Ollama: \(err)") }
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let text = obj?["response"] as? String else {
            throw SummaryError.failed("Ollama returned an unexpected answer for a screenshot.")
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var out: [String] = [], cur = ""
        for line in text.components(separatedBy: "\n") {
            if cur.count + line.count > limit, !cur.isEmpty { out.append(cur); cur = "" }
            cur += line + "\n"
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func generate(model: String, prompt: String) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model, "prompt": prompt, "stream": false,
                                   "options": ["num_ctx": 16384, "temperature": 0.2]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let err = obj?["error"] as? String { throw SummaryError.failed("Ollama: \(err)") }
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let text = obj?["response"] as? String else {
            throw SummaryError.failed("Ollama returned an unexpected answer.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
