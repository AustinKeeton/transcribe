import Foundation
import FoundationModels

/// Short descriptive title from the on-device Apple Intelligence model,
/// falling back to the transcript's opening words.
enum Titler {
    static func title(for text: String) async -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "No speech" }
        if SystemLanguageModel.default.isAvailable,
           let title = try? await modelTitle(for: text), !title.isEmpty {
            return title
        }
        return fallback(text)
    }

    private static func modelTitle(for text: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You write titles for transcripts of voice memos and videos. \
            Reply with only a short descriptive title of 3 to 8 words that says what the recording is about. \
            No quotes, no trailing punctuation.
            """)
        // Keep well inside the model's context window.
        let excerpt = String(text.prefix(6000))
        let response = try await session.respond(to: "Transcript:\n\(excerpt)")
        return response.content
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”.")))
            .components(separatedBy: .newlines).first ?? ""
    }

    private static func fallback(_ text: String) -> String {
        let words = text.split(separator: " ").prefix(8).joined(separator: " ")
        return words.count < text.count ? words + "…" : words
    }
}
