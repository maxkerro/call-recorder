import Foundation

/// Live translation of transcript lines with the local Ollama model (127.0.0.1 only).
enum Translator {
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("de", "German"), ("ru", "Russian"), ("fr", "French"), ("es", "Spanish"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("pl", "Polish"), ("uk", "Ukrainian"),
        ("tr", "Turkish"), ("ar", "Arabic"), ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"),
    ]

    static func name(of code: String) -> String { languages.first { $0.code == code }?.name ?? code }

    /// The spoken text of a line "[mm:ss] Label: text" (the line without its time if it has no such shape).
    static func lineBody(_ line: String) -> String {
        var rest = Substring(line)
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            rest = rest[rest.index(after: close)...].drop(while: { $0 == " " })
            if let colon = rest.firstIndex(of: ":") {
                let label = rest[rest.startIndex..<colon]
                if label.count <= 40, !label.contains("[") {
                    return rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func prompt(_ text: String, target: String, context: String) -> String {
        var p = "You are a live interpreter. Translate the transcript line below into \(name(of: target)). "
            + "Keep names, product names, abbreviations and numbers. Do not explain, do not add anything. "
            + "Answer with the translation only.\n"
        if !context.isEmpty { p += "\nPrevious line, for context only (do not translate it): \(context)\n" }
        return p + "\nLine to translate:\n" + text
    }

    static func translate(_ text: String, target: String, context: String) async throws -> String {
        let installed = try await Summarizer.installedModels()
        guard let model = Summarizer.pickModel(installed) else { throw Summarizer.SummaryError.noModel }
        return try await Summarizer.generate(model: model, prompt: prompt(text, target: target, context: context),
                                             options: ["num_ctx": 4096, "temperature": 0.1])
    }
}
