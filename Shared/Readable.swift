import Foundation

/// Formats verbatim speech for reading without dropping anything that was said: fillers,
/// stutters and repeats all stay. It adds sentence capitals, "I", commas around fillers in
/// unpunctuated stretches, and turns Parakeet's <unk> marker into "&". Display only; the
/// stored words are untouched.
enum Readable {
    private static let filler = #"(?:uh+|um+|uhm+|erm+|hmm+|mm+|mhm)"#

    private static let rules: [(NSRegularExpression, String)] = [
        // Parakeet writes <unk> for characters it can't spell, e.g. "Q<unk>A" for "Q&A".
        (#"(?<=\w)<unk>(?=\w)"#, "&"),
        (#"\s*<unk>\s*"#, " "),
        // Commas around fillers: "right uh um and" -> "right, uh, um, and".
        (#"(?i)(?<=[\w'])\s+(?=\#(filler)\b)"#, ", "),
        (#"(?i)\b(\#(filler))\b(?=\s+[\w'])"#, "$1,"),
        // Lone "i" and its contractions.
        (#"\bi\b(?='(?:m|ve|ll|d)\b|\s|[,.?!…]|$)"#, "I"),
        // Tidy spacing and doubled punctuation.
        (#"\s+([,.?!])"#, "$1"),
        (#",\s*,"#, ","),
        (#",(?=[.?!])"#, ""),
        (#"\s{2,}"#, " "),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func format(_ text: String) -> String {
        var s = text
        for (regex, template) in rules {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return capitalizingSentences(s.trimmingCharacters(in: .whitespaces))
    }

    /// Marker for a silence of `seconds` within one person's speech, or nil if too short to show.
    static func pause(_ seconds: Double, afterSentenceEnd: Bool) -> String? {
        if seconds >= 3 { return "[pause, \(Int(seconds.rounded())) s]" }
        if seconds >= 1, !afterSentenceEnd { return "…" }
        return nil
    }

    /// Capital letter at the start and after each . ? !
    private static func capitalizingSentences(_ text: String) -> String {
        var out = ""
        var capitalizeNext = true
        var inMarker = false
        for ch in text {
            if inMarker || ch == "[" {
                // Leave "[pause, 5 s]" markers as they are.
                out.append(ch)
                inMarker = ch != "]"
            } else if capitalizeNext, ch.isLetter {
                out += ch.uppercased()
                capitalizeNext = false
            } else {
                out.append(ch)
                if ".?!".contains(ch) { capitalizeNext = true }
                else if !ch.isWhitespace, ch != "…" { capitalizeNext = false }
            }
        }
        return out
    }
}
