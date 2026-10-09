import Foundation

/// Turns verbatim speech into readable text: drops fillers and stutters, fixes "i" and
/// sentence capitals, and removes Parakeet's <unk> marker. The stored words are untouched;
/// this only changes what's shown and copied.
enum Readable {
    private static let rules: [(NSRegularExpression, String)] = [
        // Parakeet writes <unk> for characters it can't spell, e.g. "Q<unk>A" for "Q&A".
        (#"(?<=\w)<unk>(?=\w)"#, "&"),
        (#"\s*<unk>\s*"#, " "),
        // Fillers, with a trailing comma if any.
        (#"(?i)\b(?:uh+|um+|uhm+|erm+|hmm+|mm+|mhm)\b[,.]?\s*"#, ""),
        // Stutters: "I I I" -> "I", then "in the in the" -> "in the". Repeats split by commas
        // ("no, no, no") are emphasis and stay; so do "had had" and "bye bye".
        (#"(?i)\b(?!(?:had|bye)\b)(\w+(?:'\w+)?)(?:\s+\1\b)+"#, "$1"),
        (#"(?i)\b(\w+(?:'\w+)?\s+\w+(?:'\w+)?)(?:\s+\1\b)+"#, "$1"),
        // Lone "i" and its contractions.
        (#"\bi\b(?='(?:m|ve|ll|d)\b|\s|[,.?!]|$)"#, "I"),
        // Tidy spacing and leftover punctuation.
        (#"\s+([,.?!])"#, "$1"),
        (#",\s*([.?!])"#, "$1"),
        (#"([,.?!])\s*,"#, "$1"),
        (#"\s{2,}"#, " "),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func clean(_ text: String) -> String {
        var s = text
        for (regex, template) in rules {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        s = s.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",")))
        return capitalizingSentences(s)
    }

    /// Capital letter at the start and after each . ? !
    private static func capitalizingSentences(_ text: String) -> String {
        var out = ""
        var capitalizeNext = true
        for ch in text {
            if capitalizeNext, ch.isLetter {
                out += ch.uppercased()
                capitalizeNext = false
            } else {
                out.append(ch)
                if ".?!".contains(ch) { capitalizeNext = true }
                else if !ch.isWhitespace { capitalizeNext = false }
            }
        }
        return out
    }
}
