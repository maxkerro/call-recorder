import Foundation

/// Glossary correction. The local model only POINTS at mistakes ("safe" should be "SAFe" in this phrase); this code
/// validates every suggestion and applies it, so the model never rewrites the transcript. Ollama on 127.0.0.1 only.
enum Glossary {
    struct Fix { var wrong: String; var right: String; var context: String }

    static func norm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func body(_ line: String) -> String {
        line.range(of: "]: ").map { String(line[$0.upperBound...]) } ?? line
    }

    private static func wordRegex(_ w: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: w) + "(?![\\p{L}\\p{N}])",
                                 options: [.caseInsensitive])
    }

    private static func replacing(_ w: String, with r: String, in s: String) -> String {
        guard let re = wordRegex(w) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: r))
    }

    static func prompt(terms: [String], chunk: String) -> String {
        """
        You check a speech-recognition transcript against a glossary of correct spellings.
        Glossary (the only allowed corrections): \(terms.joined(separator: "; "))

        Find places where the transcript contains a misheard or misspelled version of a glossary term (for example "safe" for "SAFe" when scaled agile is meant, "Luxsoft" for "Luxoft"). Do NOT touch anything else, do not fix grammar, do not correct a word that is used correctly in its ordinary meaning.
        Answer ONLY with a JSON array. Each item: {"wrong": "<exact wrong word(s)>", "right": "<glossary term>", "context": "<4 to 8 words copied exactly from the transcript that contain the wrong text>"}.
        If nothing needs fixing answer [].

        Transcript:
        \(chunk)
        """
    }

    /// Parses the model answer and keeps only suggestions that pass every check.
    static func parseFixes(_ answer: String, terms: [String], lines: [String]) -> [Fix] {
        guard let a = answer.firstIndex(of: "["), let b = answer.lastIndex(of: "]"), a < b,
              let data = String(answer[a...b]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let byNorm = Dictionary(terms.map { (norm($0), $0) }, uniquingKeysWith: { f, _ in f })
        let bodies = lines.filter { !$0.contains("] [Screen] ") }.map(body)
        var out: [Fix] = []
        for f in arr {
            guard let w = f["wrong"] as? String, let r = f["right"] as? String, let c = f["context"] as? String else { continue }
            let wrong = w.trimmingCharacters(in: .whitespaces), context = c.trimmingCharacters(in: .whitespaces)
            guard let right = byNorm[norm(r)], !wrong.isEmpty, wrong != right else { continue }
            if wrong.split(whereSeparator: \.isWhitespace).count > 4 || context.split(whereSeparator: \.isWhitespace).count > 12 { continue }
            if terms.contains(wrong) { continue }                       // already spelled exactly like a glossary term
            guard let re = wordRegex(wrong), re.firstMatch(in: context, range: NSRange(context.startIndex..., in: context)) != nil
            else { continue }                                            // the context must contain the wrong text
            guard bodies.contains(where: { $0.contains(context) }) else { continue }   // and be verbatim from the transcript
            out.append(Fix(wrong: wrong, right: right, context: context))
        }
        return out
    }

    /// Applies fixes inside their context phrase only.
    static func apply(_ lines: [String], _ fixes: [Fix]) -> (lines: [String], changes: [(wrong: String, right: String)]) {
        var done: [(wrong: String, right: String)] = []
        let out = lines.map { line -> String in
            if line.contains("] [Screen] ") { return line }
            var cur = line
            for f in fixes where cur.contains(f.context) {
                let fixed = replacing(f.wrong, with: f.right, in: f.context)
                if fixed == f.context { continue }
                cur = cur.replacingOccurrences(of: f.context, with: fixed)
                if !done.contains(where: { $0.wrong == f.wrong && $0.right == f.right }) { done.append((f.wrong, f.right)) }
            }
            return cur
        }
        return (out, done)
    }

    static func correct(_ lines: [String], terms: [String]) async throws -> (lines: [String], changes: [(wrong: String, right: String)]) {
        guard !terms.isEmpty, !lines.isEmpty else { return (lines, []) }
        let installed = try await Summarizer.installedModels()
        guard let model = Summarizer.pickModel(installed) else { throw Summarizer.SummaryError.noModel }
        var fixes: [Fix] = []
        for chunk in Summarizer.split(lines.joined(separator: "\n"), limit: 12_000) {
            let answer = try await Summarizer.generate(model: model, prompt: prompt(terms: terms, chunk: chunk))
            fixes += parseFixes(answer, terms: terms, lines: lines)
        }
        return apply(lines, fixes)
    }
}
