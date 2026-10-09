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
            + "Answer with the translation only, written only in \(name(of: target)).\n"
        if !context.isEmpty { p += "\nPrevious line, for context only (do not translate it): \(context)\n" }
        return p + "\nLine to translate:\n" + text
    }

    static func translate(_ text: String, target: String, context: String) async throws -> String {
        let installed = try await Summarizer.installedModels()
        guard let model = Summarizer.pickFastModel(installed) else { throw Summarizer.SummaryError.noModel }
        // Some models slip into Chinese. Unless Chinese/Japanese/Korean was asked for, such an answer is rejected and retried.
        for attempt in 0..<3 {
            var p = prompt(text, target: target, context: context)
            if attempt > 0 { p += "\n\nIMPORTANT: write only in \(name(of: target)). No Chinese characters." }
            let out = try await Summarizer.generate(model: model, prompt: p,
                                                    options: ["num_ctx": 4096, "temperature": attempt == 0 ? 0.1 : 0.4], timeout: 60)
            if !strayScript(out, target: target) { return out }
        }
        throw Summarizer.SummaryError.failed("The model answered in the wrong script; line skipped.")
    }

    /// True if the answer contains CJK characters although the target language is not Chinese, Japanese or Korean.
    static func strayScript(_ s: String, target: String) -> Bool {
        if ["zh", "ja", "ko"].contains(target) { return false }
        return s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
            || (0xAC00...0xD7AF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }
}
