import Foundation

/// Word statistics of a transcript: the most frequent words and the words the app does not know yet
/// (names, abbreviations and terms that are not in the Vocabulary list). Local text processing only.
enum WordStats {
    struct Item: Identifiable { var word: String; var count: Int; var id: String { word } }

    static let stop: Set<String> = Set((
        // English
        "the and for are but not you your all any can had her was one our out has have him his how its let may new now old see two way who did get got "
        + "she too use that this with from they will would there their what when which about been were then them than these those just like also into over only some such "
        + "more most much very here where while after before because could should still really going yeah yes okay well know think want need make made said say says "
        + "dont doesnt didnt isnt wasnt thats ive weve youre theyre hes shes lets cant wont "
        // German
        + "der die das den dem des ein eine einen einem einer und oder aber nicht ist sind war waren wird werden wurde bin hat haben hatte auch noch schon nur mit von für auf aus bei nach zum zur über "
        + "wir ihr sie ich du er es mir mich dir dich uns euch wie was wer wo wann warum dass wenn dann also ja nein ganz mal sehr kann können muss müssen soll gibt "
        // Russian
        + "это что как так вот или для при его она они мне вас нас уже если есть был была были будет надо тоже ещё еще очень только можно нужно просто да нет ну там тут когда потом "
        + "который которая которые этот эта эти этого себя меня тебя свой своё"
    ).split(separator: " ").map(String.init))

    static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    struct Token { var word: String; var sentenceStart: Bool }

    /// Every word of the spoken text (the "[mm:ss] Label:" part of a line is skipped).
    static func tokens(_ transcript: String) -> [Token] {
        var out: [Token] = []
        for line in transcript.components(separatedBy: .newlines) {
            let body = Translator.lineBody(line)
            if body.isEmpty { continue }
            var cur = ""
            var start = true
            func flush() {
                while let l = cur.last, l == "-" || l == "'" || l == "’" { cur.removeLast() }
                if !cur.isEmpty { out.append(Token(word: cur, sentenceStart: start)); start = false }
                cur = ""
            }
            for ch in body {
                if ch.isLetter || ch.isNumber || ((ch == "'" || ch == "’" || ch == "-") && !cur.isEmpty) {
                    cur.append(ch)
                } else {
                    flush()
                    if ".!?…".contains(ch) { start = true }
                }
            }
            flush()
        }
        return out
    }

    private static func tally(_ words: [String]) -> [Item] {
        var counts: [String: (count: Int, forms: [String: Int])] = [:]
        for w in words {
            let k = norm(w)
            if k.isEmpty { continue }
            var e = counts[k] ?? (0, [:])
            e.count += 1
            e.forms[w, default: 0] += 1
            counts[k] = e
        }
        return counts.values
            .map { Item(word: $0.forms.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key, count: $0.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.word.localizedCompare($1.word) == .orderedAscending }
    }

    /// The n most frequent words (not counting filler words like "the", "und", "это").
    static func topWords(_ transcript: String, n: Int = 10) -> [Item] {
        let list = tokens(transcript).map(\.word).filter {
            norm($0).count >= 3 && !stop.contains(norm($0)) && Int($0) == nil
        }
        return Array(tally(list).prefix(n))
    }

    /// Looks like a name, abbreviation or technical term (rather than an ordinary word).
    static func looksSpecial(_ t: Token) -> Bool {
        let w = t.word
        if w.count < 2 || Int(w) != nil { return false }
        if w.contains(where: \.isLetter) && w.contains(where: \.isNumber) { return true }          // ID3, 5G
        if w == w.uppercased() && w != w.lowercased() { return true }                            // HMI
        let chars = Array(w)
        for i in 1..<chars.count where chars[i].isUppercase && chars[i - 1].isLowercase { return true }   // SAFe, camelCase
        if !t.sentenceStart, let f = chars.first, f.isUppercase { return true }                  // names, products
        return false
    }

    /// The n words that are not in the vocabulary and look like names/abbreviations/terms (most frequent first).
    static func unknownWords(_ transcript: String, vocabulary: [String], n: Int = 10) -> [Item] {
        let known = Set(vocabulary.flatMap { $0.split(whereSeparator: \.isWhitespace) }.map { norm(String($0)) }.filter { !$0.isEmpty })
        let all = tokens(transcript)
        // Special if it looks like a name/abbreviation/term anywhere; then every occurrence counts
        // (at the start of a sentence a name looks like any other word).
        let special = Set(all.filter { looksSpecial($0) && !stop.contains(norm($0.word)) && !known.contains(norm($0.word)) }
                             .map { norm($0.word) })
        return Array(tally(all.map(\.word).filter { special.contains(norm($0)) }).prefix(n))
    }
}
