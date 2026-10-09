import Foundation

/// One word (or word piece) with its time range. `text` keeps any leading space,
/// so joining pieces by plain concatenation rebuilds the sentence.
struct Word: Codable, Hashable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// A stretch of speech attributed to one speaker by the diarizer.
struct SpeakerTurn: Sendable {
    var start: Double
    var end: Double
    var speaker: Int
}

enum Segments {
    /// Groups words into phrases that break on a speaker change, a pause, or a sentence end.
    static func build(words: [Word], speakers: [Int?]? = nil) -> [Segment] {
        var out: [Segment] = []
        for (i, w) in words.enumerated() {
            let speaker = speakers?[i] ?? nil
            if var last = out.last, last.speaker == speaker, w.start - last.end < 0.8,
               !(last.text.last.map { ".?!".contains($0) } ?? false) {
                last.text += w.text
                last.end = w.end
                out[out.count - 1] = last
            } else {
                let text = w.text.trimmingCharacters(in: .whitespaces)
                out.append(Segment(start: w.start, end: w.end, text: text, speaker: speaker))
            }
        }
        return out.filter { !$0.text.isEmpty }
    }

    /// Labels each word with the speaker talking at its midpoint (or within a second of it),
    /// numbered by first appearance. A single voice gets no labels.
    static func assignSpeakers(words: [Word], turns: [SpeakerTurn]) -> [Int?] {
        func distance(_ turn: SpeakerTurn, _ t: Double) -> Double {
            t < turn.start ? turn.start - t : max(0, t - turn.end)
        }
        var labels: [Int?] = []
        var previous: Int?
        for w in words {
            let mid = (w.start + w.end) / 2
            let nearest = turns.min { distance($0, mid) < distance($1, mid) }
            let speaker = nearest.flatMap { distance($0, mid) < 1 ? $0.speaker : nil } ?? previous
            labels.append(speaker)
            previous = speaker
        }
        var order: [Int: Int] = [:]
        for case let s? in labels where order[s] == nil { order[s] = order.count }
        guard order.count > 1 else { return labels.map { _ in nil } }
        return labels.map { $0.flatMap { order[$0] } }
    }
}
