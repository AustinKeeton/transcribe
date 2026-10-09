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
    /// Set when adding speakers or the Parakeet redo failed, so it isn't retried on every launch.
    var upgradeError: String?

    var displayTitle: String { title ?? sourceName }
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

    /// Text for Copy and Share, readable unless verbatim. With speakers, the name starts
    /// each change of speaker ("Name: paragraph"); further paragraphs follow on their own.
    func exportText(verbatim: Bool) -> String {
        let paragraphs = TranscriptBody.paragraphs(segments)
        let tidy = { (s: String) in verbatim ? s : Readable.clean(s) }
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
            t.title = await Titler.title(for: result.text)
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
