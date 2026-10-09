import Foundation
import UniformTypeIdentifiers

struct Segment: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
    var text: String
    /// 0-based speaker number, nil when speakers weren't identified.
    var speaker: Int?
}

struct Transcript: Codable, Identifiable, Hashable, Sendable {
    enum Status: String, Codable, Sendable { case pending, done, failed }
    /// Which speech-to-text model produced the text.
    enum Engine: String, Codable, Sendable { case apple, parakeet }

    var id: UUID
    var sourceName: String
    var title: String?
    var created: Date
    var status: Status
    /// The app's own copy in inbox/ (shared items); deleted once fully processed.
    var mediaFile: String?
    /// Security-scoped link to the original (files added with +); the original is never deleted.
    var bookmark: Data?
    var duration: Double?
    var text: String = ""
    var segments: [Segment] = []
    var words: [Word]?
    /// True once the speaker model has labelled this transcript.
    var speakersDone: Bool?
    /// Names given to speakers, by speaker number; empty strings mean unnamed.
    var speakerNames: [String]?
    /// True once automatic naming has run, so it runs only once.
    var namesSuggested: Bool?
    var error: String?
    var engine: Engine?
    /// "coaching" (two speakers) or "single", as chosen when transcribing.
    var mode: String?
    /// Custom vocabulary used for this transcription.
    var vocabulary: [String]?
    /// Set when adding speakers or the Parakeet redo failed, so it isn't retried on every launch.
    var upgradeError: String?

    /// AI topic line ("Overwhelm and time management"); nil when the model declined or failed.
    var topic: String?
    /// Frequent nouns, shown when there's no topic.
    var keywords: [String]?

    /// "Coaching with Isabel · 38 min" / "Voice note · 4 min" for transcripts made with a mode;
    /// older ones keep their AI title.
    var displayTitle: String { template ?? title ?? sourceName }

    /// Second line under the title: the topic, else the top keywords.
    var subtitle: String? {
        if let topic { return topic }
        guard let keywords, !keywords.isEmpty else { return nil }
        return keywords.prefix(4).joined(separator: " · ")
    }

    var template: String? {
        guard status == .done, let mode else { return nil }
        let base: String
        if mode == "coaching" {
            let name = clientSpeaker.map(speakerName)
            base = name.map { $0.hasPrefix("Speaker ") ? "Coaching session" : "Coaching with \($0)" } ?? "Coaching session"
        } else {
            base = "Voice note"
        }
        return [base, duration.map(Self.length)].compactMap { $0 }.joined(separator: " · ")
    }

    /// In coaching the client usually does most of the talking.
    var clientSpeaker: Int? {
        var words: [Int: Int] = [:]
        for s in segments { if let sp = s.speaker { words[sp, default: 0] += s.text.split(separator: " ").count } }
        return words.max { $0.value < $1.value }?.key
    }

    /// The client's lines only (coaching), or everything.
    var clientText: String {
        guard mode == "coaching", let client = clientSpeaker else { return text }
        return segments.filter { $0.speaker == client }.map(\.text).joined(separator: " ")
    }

    static func length(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let minutes = Int((Double(s) / 60).rounded())
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
    var hasMedia: Bool { mediaFile != nil || bookmark != nil }

    func speakerName(_ speaker: Int) -> String {
        let name = speakerNames.flatMap { $0.indices.contains(speaker) ? $0[speaker] : nil } ?? ""
        return name.isEmpty ? "Speaker \(speaker + 1)" : name
    }

    mutating func rename(speaker: Int, to name: String) {
        var names = speakerNames ?? []
        while names.count <= speaker { names.append("") }
        names[speaker] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        speakerNames = names
    }

    /// Text for Copy and Share: formatted with pauses marked, or the raw engine text. With
    /// speakers, the name starts each change of speaker; further paragraphs follow on their own.
    func exportText(raw: Bool) -> String {
        let paragraphs = TranscriptBody.paragraphs(segments, pauses: !raw)
        let tidy = { (s: String) in raw ? s : Readable.format(s) }
        guard paragraphs.contains(where: { $0.speaker != nil }) else {
            return paragraphs.isEmpty ? tidy(text) : paragraphs.map { tidy($0.text) }.joined(separator: "\n\n")
        }
        var previous: Int?
        return paragraphs.map { p in
            defer { previous = p.speaker }
            guard let speaker = p.speaker, speaker != previous else { return tidy(p.text) }
            return "\(speakerName(speaker)): \(tidy(p.text))"
        }.joined(separator: "\n\n")
    }
}

/// Shared App Group storage: inbox/ holds media waiting to be transcribed,
/// transcripts/ holds one JSON file per transcript.
enum Store {
    static let groupID = "group.org.trioaudie.transcribe"

    static var root: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var inbox: URL { folder("inbox") }
    static var transcripts: URL { folder("transcripts") }
    static var models: URL { folder("Models") }

    private static func folder(_ name: String) -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies media into the inbox and records a pending transcript.
    static func importMedia(from source: URL, name: String? = nil) throws -> Transcript {
        let id = UUID()
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let file = "\(id.uuidString).\(ext)"
        try FileManager.default.copyItem(at: source, to: inbox.appending(path: file))
        let t = Transcript(id: id, sourceName: name ?? source.lastPathComponent,
                           created: .now, status: .pending, mediaFile: file)
        try save(t)
        return t
    }

    /// Records a pending transcript that links to the original file instead of copying it.
    static func importReference(to url: URL) throws -> Transcript {
        let bookmark = try url.bookmarkData()
        let t = Transcript(id: UUID(), sourceName: url.lastPathComponent, created: .now,
                           status: .pending, bookmark: bookmark)
        try save(t)
        return t
    }

    /// Opens the media for reading: the inbox copy, or the linked original (downloading it
    /// from iCloud first if needed). Call `stop` when done.
    static func openMedia(_ t: Transcript) async -> (url: URL, stop: @Sendable () -> Void)? {
        if let file = t.mediaFile { return (inbox.appending(path: file), {}) }
        guard let bookmark = t.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        let stop: @Sendable () -> Void = { if scoped { url.stopAccessingSecurityScopedResource() } }
        // A coordinated read makes the file provider download an iCloud file that isn't local yet.
        let readable = await Task.detached {
            var error: NSError?
            var ok = false
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { _ in ok = true }
            return ok
        }.value
        guard readable else { stop(); return nil }
        return (url, stop)
    }

    static func save(_ t: Transcript) throws {
        let data = try JSONEncoder().encode(t)
        try data.write(to: transcripts.appending(path: "\(t.id.uuidString).json"), options: .atomic)
    }

    static func load(_ id: UUID) -> Transcript? {
        let url = transcripts.appending(path: "\(id.uuidString).json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) }
    }

    static func all() -> [Transcript] {
        let files = (try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) }
        }
        .sorted { $0.created > $1.created }
    }

    static func delete(_ t: Transcript) {
        // Only the app's own copy; a linked original stays where it is.
        if let file = t.mediaFile { try? FileManager.default.removeItem(at: inbox.appending(path: file)) }
        try? FileManager.default.removeItem(at: transcripts.appending(path: "\(t.id.uuidString).json"))
    }

    /// On-device pass with Apple's transcriber. Keeps the media so the app can add
    /// speaker labels (and redo it with Parakeet if that's chosen).
    static func process(_ t: Transcript, progress: @escaping TranscriptionProgress = { _ in }) async -> Transcript {
        var t = t
        guard let (media, stop) = await openMedia(t) else {
            t.status = .failed
            t.error = "Couldn't open the recording."
            try? save(t)
            return t
        }
        defer { stop() }
        do {
            let result = try await Transcriber.transcribe(media, progress: progress)
            t.text = result.text
            t.segments = result.segments
            t.words = result.words
            t.duration = result.duration
            progress(1)
            t.status = .done
            t.engine = .apple
            t.error = nil
        } catch {
            t.status = .failed
            t.error = error.localizedDescription
        }
        try? save(t)
        return t
    }
}
