import Foundation
import FoundationModels
import NaturalLanguage

/// Titles have two parts. The template ("Coaching with Isabel · 38 min") is built from facts and
/// always right. The topic line ("Overwhelm and time management") comes from Apple's on-device
/// model with tight guidance and no randomness, and falls back to the transcript's keywords.
enum Titler {
    @Generable struct CoachingTopic {
        @Guide(description: "3 to 7 words naming what the client wanted to work on, as a short noun phrase like a chapter title. No names, no quotes, never 'coaching session' or 'conversation'.")
        var topic: String
    }

    @Generable struct MemoTopic {
        @Guide(description: "3 to 7 words naming the main subject, as a short noun phrase like a chapter title. No quotes, never 'voice memo' or 'recording'.")
        var topic: String
    }

    // MARK: Topic

    /// Topic line for a finished transcript, or nil when the model is unavailable or its answer
    /// fails the checks (the keywords are shown instead).
    static func topic(text: String, coaching: Bool, minutes: Int, keywords: [String], names: [String]) async -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, SystemLanguageModel.default.isAvailable else { return nil }

        var prompt = coaching
            ? "A coaching session, \(minutes) minutes. These are the client's own words only (the coach's lines are left out).\n"
            : "A voice memo, \(minutes) minutes.\n"
        prompt += "Frequent words: \(keywords.joined(separator: ", ")).\n\n"
        prompt += "Beginning:\n\(excerpt(text, at: 0, length: 2400))\n\n"
        prompt += "Middle:\n\(excerpt(text, at: 0.5, length: 1400))\n\n"
        prompt += "End:\n\(excerpt(text, at: 0.93, length: 1200))"

        let instructions = coaching ? """
            You name coaching sessions. From the client's own words in a session, state what the client \
            wanted to work on, in 3 to 7 words. Focus on the client's own concern or goal, not the coach's \
            techniques. The frequent words show what the client talked about most; prefer a title that \
            reflects them, in the client's own terms. Write it like a chapter title. Good: "Overwhelm and \
            learning to delegate", "Preparing for a hard promotion talk", "Rebuilding confidence after a \
            layoff". Bad: "Coaching session with Isabel", "A conversation about feelings", "Breathing exercise".
            """ : """
            You title voice memos. From excerpts of a memo, state its main subject in 3 to 7 words, like a \
            chapter title. If it covers several things, name the first two. Good: "Wall display parts and \
            weekend groceries", "Ideas for logging meals faster". Bad: "Voice memo", "Some thoughts".
            """
        let session = LanguageModelSession(instructions: instructions)
        // Greedy decoding: the same transcript always gets the same topic.
        let options = GenerationOptions(samplingMode: .greedy)
        let answer: String
        do {
            answer = coaching
                ? try await session.respond(to: prompt, generating: CoachingTopic.self, options: options).content.topic
                : try await session.respond(to: prompt, generating: MemoTopic.self, options: options).content.topic
        } catch {
            return nil
        }
        return accepted(answer, names: names)
    }

    /// Rejects answers that are too short or long, generic, or name a person.
    static func accepted(_ answer: String, names: [String]) -> String? {
        let topic = answer.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”.")))
        let words = topic.split(separator: " ")
        let lower = topic.lowercased()
        guard (2...8).contains(words.count),
              !["session", "conversation", "voice memo", "recording", "transcript"].contains(where: lower.contains),
              !names.contains(where: { !$0.isEmpty && lower.contains($0.lowercased()) })
        else { return nil }
        return topic.prefix(1).uppercased() + topic.dropFirst()
    }

    private static func excerpt(_ text: String, at fraction: Double, length: Int) -> String {
        let chars = Array(text)
        guard chars.count > length else { return text }
        let start = min(max(0, Int(Double(chars.count) * fraction) - length / 2), chars.count - length)
        return String(chars[start..<(start + length)])
    }

    // MARK: Keywords

    private static let ignored: Set<String> = [
        "uh", "um", "yeah", "okay", "right", "like", "know", "think", "really", "just", "thing", "lot", "bit",
        "way", "time", "something", "kind", "sort", "yes", "mean", "well",
        // nouns that say nothing about the topic
        "day", "life", "part", "people", "person", "everyone", "everything", "anything", "nothing", "one",
        "today", "tomorrow", "moment", "minute", "hour", "week", "year", "end", "start", "side", "point",
        "question", "answer", "word", "fact", "case", "place", "stuff", "guy", "folk", "session", "conversation",
    ]

    /// Most frequent nouns (by lemma), leaving out fillers, generic words and the given names.
    static func keywords(_ text: String, excluding names: [String], count: Int = 8) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        let skip = Set(names.map { $0.lowercased() })
        var frequency: [String: Int] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            guard tag == .noun else { return true }
            let lemma = (tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
                ?? String(text[range])).lowercased()
            if lemma.count > 2, !ignored.contains(lemma), !skip.contains(lemma) {
                frequency[lemma, default: 0] += 1
            }
            return true
        }
        return frequency.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(count).map(\.key)
    }
}
