import Foundation
import NaturalLanguage

/// Names speakers from how people talk: introducing themselves ("this is Dana") or calling
/// someone by name ("Hi Dana", "thanks, Alex", "Jordan, did you…"). Names that are only
/// talked about ("ask Mike") are ignored. Never overwrites a name the person set.
enum SpeakerNamer {
    static func suggest(for t: Transcript) async -> Transcript {
        var t = t
        t.namesSuggested = true
        let paragraphs = TranscriptBody.paragraphs(t.segments).filter { $0.speaker != nil }
        let speakers = Set(paragraphs.compactMap(\.speaker))
        guard speakers.count > 1 else { return t }

        // Votes for each speaker's name.
        var votes: [Int: [String: Int]] = [:]
        for (i, p) in paragraphs.enumerated() {
            guard let speaker = p.speaker else { continue }
            for (name, kind) in mentions(in: p.text) {
                let target: Int?
                switch kind {
                case .own:
                    target = speaker
                case .addressee:
                    // The person they're talking with: who spoke just before, else just after.
                    let previous = paragraphs[..<i].last { $0.speaker != speaker }?.speaker
                    let next = paragraphs[(i + 1)...].first { $0.speaker != speaker }?.speaker
                    target = previous ?? next
                }
                if let target { votes[target, default: [:]][name, default: 0] += 1 }
            }
        }

        // Strongest evidence first; one name per speaker, one speaker per name.
        let ranked = votes.flatMap { speaker, names in names.map { (speaker, $0.key, $0.value) } }
            .sorted { $0.2 > $1.2 }
        var used = Set((t.speakerNames ?? []).filter { !$0.isEmpty }.map { $0.lowercased() })
        for (speaker, name, _) in ranked
        where t.speakerName(speaker).hasPrefix("Speaker ") && !used.contains(name.lowercased()) {
            t.rename(speaker: speaker, to: name)
            used.insert(name.lowercased())
        }
        return t
    }

    enum Kind { case own, addressee }

    private static let ownCues = ["this is", "i'm", "i am", "my name is", "my name's", "name's", "it's", "call me"]
    private static let greetings = ["hi", "hey", "hello", "thanks", "thank you", "bye", "morning", "good morning",
                                    "evening", "night", "yes", "no", "okay", "ok", "sorry", "right", "well", "oh",
                                    "see you", "love you"]
    private static let notNames: Set<String> = [
        "i", "okay", "ok", "yes", "yeah", "yep", "no", "nope", "well", "so", "oh", "hi", "hey", "hello", "thanks",
        "sure", "right", "great", "good", "morning", "sorry", "please", "anyway", "actually", "god", "man", "dude",
        "guys", "everyone", "mom", "dad", "honey", "babe", "sir", "madam", "doctor",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december",
    ]

    /// Capitalised words in a cue position. The cues carry the signal; the tagger only
    /// rules out common words (it often misses or mislabels first names on their own).
    static func mentions(in text: String) -> [(String, Kind)] {
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass])
        tagger.string = text
        let nameLike: Set<NLTag> = [.personalName, .placeName, .organizationName, .noun]
        var out: [(String, Kind)] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameTypeOrLexicalClass,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            let name = String(text[range])
            guard let first = name.first, first.isUppercase, let tag, nameLike.contains(tag),
                  !notNames.contains(name.lowercased()) else { return true }
            let before = text[..<range.lowerBound].lowercased().trimmingCharacters(in: .whitespaces)
            let after = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let lastWords = before.trimmingCharacters(in: CharacterSet(charactersIn: ",!. "))
            let startsSentence = before.isEmpty || before.hasSuffix(".") || before.hasSuffix("!") || before.hasSuffix("?")
            let endsSentence = after.first.map { ".?!".contains($0) } ?? true
            func follows(_ cue: String) -> Bool {
                lastWords == cue || lastWords.hasSuffix(" " + cue) || lastWords.hasSuffix("." + cue)
            }
            if ownCues.contains(where: follows) {
                out.append((name, .own))
            } else if (greetings.contains(where: follows) && !startsSentence)
                        || (startsSentence && after.hasPrefix(","))
                        || (before.hasSuffix(",") && endsSentence) {
                out.append((name, .addressee))
            }
            return true
        }
        return out
    }
}
