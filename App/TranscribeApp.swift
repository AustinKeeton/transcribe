import SwiftUI
import UniformTypeIdentifiers

@main
struct TranscribeApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            ListView()
                .environment(library)
                // transcribe://open?id=<uuid>, sent by the share sheet after adding a recording.
                .onOpenURL { url in
                    library.reload()
                    if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "id" })?.value.flatMap(UUID.init) {
                        library.path = [id]
                    }
                }
        }
    }
}

/// Recordings and the work done on them. Nothing runs on its own: processing starts
/// only when the person taps Transcribe on a recording.
@MainActor @Observable
final class Library {
    enum ModelState: Equatable {
        case idle
        case loading(Double)
        case ready
        case failed(String)
    }

    struct Stage: Equatable {
        var label: String
        var value: Double?
    }

    var items: [Transcript] = []
    var path: [UUID] = []
    var working: Set<UUID> = []
    var progress: [UUID: Stage] = [:]
    var speakerModel = ModelState.idle
    var parakeetModel = ModelState.idle
    /// Transcription engine. Choosing Parakeet downloads it (once).
    var engine: Transcript.Engine {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: "engine")
            if engine == .parakeet { Task { await loadParakeet() } }
        }
    }

    init() {
        engine = UserDefaults.standard.string(forKey: "engine").flatMap(Transcript.Engine.init) ?? .apple
        reload()
    }

    func reload() {
        items = Store.all()
    }

    func loadSpeakerModel(_ report: TranscriptionProgress? = nil) async {
        await load(.speakers, report) { try await SpeakerModel.shared.prepare(progress: $0) }
    }

    func loadParakeet(_ report: TranscriptionProgress? = nil) async {
        await load(.parakeet, report) { try await Parakeet.shared.prepare(progress: $0) }
    }

    func removeParakeet() async {
        engine = .apple
        await Parakeet.shared.remove()
        parakeetModel = .idle
    }

    private enum Model: Sendable { case speakers, parakeet }

    private subscript(model: Model) -> ModelState {
        get { model == .speakers ? speakerModel : parakeetModel }
        set { if model == .speakers { speakerModel = newValue } else { parakeetModel = newValue } }
    }

    private func load(_ model: Model, _ report: TranscriptionProgress?,
                      _ prepare: (@escaping @Sendable (Double) -> Void) async throws -> Void) async {
        if case .ready = self[model] { return }
        if case .loading = self[model] {
            // Already loading (another recording, or Settings): wait for it.
            while case .loading = self[model] { try? await Task.sleep(for: .milliseconds(200)) }
            return
        }
        self[model] = .loading(0)
        do {
            try await prepare { p in
                report?(p)
                Task { @MainActor in if case .loading = self[model] { self[model] = .loading(p) } }
            }
            self[model] = .ready
        } catch {
            self[model] = .failed(error.localizedDescription)
        }
    }

    /// Text (Apple, or Parakeet if chosen), title, speakers, then names.
    func process(_ t: Transcript) async {
        let id = t.id
        guard !working.contains(id) else { return }
        working.insert(id)
        defer {
            working.remove(id)
            progress[id] = nil
            reload()
        }
        func report(_ label: String) -> TranscriptionProgress {
            progress[id] = Stage(label: label, value: nil)
            return { p in
                Task { @MainActor in if self.working.contains(id) { self.progress[id] = Stage(label: label, value: p) } }
            }
        }

        var t = Store.load(id) ?? t
        t.upgradeError = nil
        _ = report("Preparing…")
        guard let (media, stop) = await Store.openMedia(t) else {
            t.status = .failed
            t.error = "Couldn't open the recording."
            try? Store.save(t)
            return
        }
        defer { stop() }

        // 1. Text.
        if engine == .parakeet { await loadParakeet(report("Getting Parakeet ready…")) }
        if engine == .parakeet, parakeetModel == .ready {
            do {
                let r = try await Parakeet.shared.transcribe(media, progress: report("Transcribing with Parakeet…"))
                t.text = r.text
                t.words = r.words
                t.segments = r.segments
                t.duration = r.duration
                t.engine = .parakeet
                t.status = .done
                t.error = nil
            } catch {
                t.status = .failed
                t.error = error.localizedDescription
            }
        } else {
            t = await Store.process(t, progress: report("Transcribing…"))
        }
        guard t.status == .done else { try? Store.save(t); return }
        t.speakersDone = nil
        t.namesSuggested = nil
        try? Store.save(t)
        if t.title == nil {
            _ = report("Writing a title…")
            t.title = await Titler.title(for: t.text)
            try? Store.save(t)
        }

        // 2. Speakers (the model downloads the first time).
        if !(t.words ?? []).isEmpty {
            await loadSpeakerModel(report("Getting speaker model ready…"))
            if speakerModel == .ready {
                do {
                    t = try await SpeakerModel.shared.label(t, media: media, progress: report("Finding speakers…"))
                } catch {
                    t.upgradeError = error.localizedDescription
                }
            } else if case .failed(let message) = speakerModel {
                t.upgradeError = message
            }
        }

        // 3. Names, from how people talk to each other.
        if t.speakersDone == true { t = await SpeakerNamer.suggest(for: t) }

        // 4. Drop the app's own copy (never a linked original) once everything worked.
        if t.mediaFile != nil, t.speakersDone == true || (t.words ?? []).isEmpty {
            try? FileManager.default.removeItem(at: media)
            t.mediaFile = nil
        }
        try? Store.save(t)
    }

    func importFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Link to the original when possible; copy only if a link can't be made.
        _ = (try? Store.importReference(to: url)) ?? (try? Store.importMedia(from: url))
        reload()
    }

    func rename(_ t: Transcript, speaker: Int, to name: String) {
        var t = Store.load(t.id) ?? t
        t.rename(speaker: speaker, to: name)
        try? Store.save(t)
        reload()
    }

    func delete(_ t: Transcript) {
        Store.delete(t)
        reload()
    }
}
