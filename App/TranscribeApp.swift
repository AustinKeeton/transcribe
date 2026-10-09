import BackgroundTasks
import Network
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
        case missing
        case downloaded
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
    var models: ModelState = Engine.isDownloaded ? .downloaded : .missing
    /// True on cellular or another metered connection; model downloads wait for Wi-Fi.
    var expensiveNetwork = false

    private let network = NWPathMonitor()
    private var backgroundTask: BGContinuedProcessingTask?
    static let jobTaskID = "org.trioaudie.transcribe.job"

    init() {
        reload()
        Self.removeRetiredModels()
        network.pathUpdateHandler = { path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in self.expensiveNetwork = expensive }
        }
        network.start(queue: .global(qos: .utility))
        // Lets a running job continue, with the system's progress UI, if the app is left.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.jobTaskID, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
            MainActor.assumeIsolated { self.attach(task) }
        }
    }

    func reload() {
        items = Store.all()
    }

    var modelsDownloaded: Bool {
        switch models {
        case .missing, .failed: Engine.isDownloaded
        default: true
        }
    }

    /// Downloads (first time) and loads all models. On a metered network it refuses unless allowed.
    func loadModels(allowExpensive: Bool = false, _ report: TranscriptionProgress? = nil) async {
        if case .ready = models { return }
        if case .loading = models {
            while case .loading = models { try? await Task.sleep(for: .milliseconds(200)) }
            return
        }
        if !Engine.isDownloaded, expensiveNetwork, !allowExpensive {
            models = .failed("Connect to Wi-Fi to download the models (about 650 MB).")
            return
        }
        models = .loading(0)
        do {
            try await Engine.shared.prepare { p in
                report?(p)
                Task { @MainActor in if case .loading = self.models { self.models = .loading(p) } }
            }
            models = .ready
        } catch {
            models = .failed(error.localizedDescription)
        }
    }

    /// VAD → Parakeet v2 (with vocabulary) → two-speaker diarization (coaching) → title → names.
    func process(_ t: Transcript, mode: Engine.Mode, vocabulary: [String]) async {
        let id = t.id
        guard !working.contains(id) else { return }
        working.insert(id)
        UIApplication.shared.isIdleTimerDisabled = true
        startBackgroundTask(for: t)
        var succeeded = false
        defer {
            working.remove(id)
            progress[id] = nil
            UIApplication.shared.isIdleTimerDisabled = !working.isEmpty
            finishBackgroundTask(success: succeeded)
            reload()
        }
        func report(_ label: String) -> TranscriptionProgress {
            progress[id] = Stage(label: label, value: nil)
            return { p in
                Task { @MainActor in
                    guard self.working.contains(id) else { return }
                    self.progress[id] = Stage(label: label, value: p)
                    self.backgroundTask?.progress.completedUnitCount = Int64((p ?? 0) * 100)
                }
            }
        }

        var t = Store.load(id) ?? t
        t.mode = mode.rawValue
        t.vocabulary = vocabulary
        t.upgradeError = nil
        Self.remember(vocabulary)

        await loadModels(report("Getting models ready…"))
        guard models == .ready else {
            if case .failed(let message) = models { t.upgradeError = message }
            try? Store.save(t)
            return
        }
        guard let (media, stop) = await Store.openMedia(t) else {
            t.status = .failed
            t.error = "Couldn't open the recording."
            try? Store.save(t)
            return
        }
        defer { stop() }

        do {
            let label = mode == .coaching ? "Transcribing and finding speakers…" : "Transcribing…"
            let r = try await Engine.shared.transcribe(media, mode: mode, vocabulary: vocabulary, progress: report(label))
            t.text = r.text
            t.words = r.words
            t.segments = r.segments
            t.duration = r.duration
            t.engine = .parakeet
            t.status = .done
            t.error = nil
            t.speakersDone = mode == .coaching
            t.namesSuggested = nil
        } catch {
            t.status = .failed
            t.error = error.localizedDescription
            try? Store.save(t)
            return
        }
        try? Store.save(t)
        if t.title == nil {
            _ = report("Writing a title…")
            t.title = await Titler.title(for: t.text)
        }
        if mode == .coaching { t = await SpeakerNamer.suggest(for: t) }

        // Drop the app's own copy (never a linked original) once done.
        if t.mediaFile != nil {
            try? FileManager.default.removeItem(at: media)
            t.mediaFile = nil
        }
        try? Store.save(t)
        succeeded = true
    }

    /// Earlier versions downloaded Parakeet Ultra and Sortformer (~730 MB); only the current
    /// models' folders are kept.
    private static func removeRetiredModels() {
        let keep: Set<String> = ["parakeet-tdt-0.6b-v2", "speaker-diarization"]
        let items = (try? FileManager.default.contentsOfDirectory(at: Store.models, includingPropertiesForKeys: nil)) ?? []
        for item in items where !keep.contains(item.lastPathComponent) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: Background continuation

    private func startBackgroundTask(for t: Transcript) {
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.jobTaskID, title: "Transcribing", subtitle: t.displayTitle)
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        guard !working.isEmpty else { return task.setTaskCompleted(success: true) }
        task.progress.totalUnitCount = 100
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.backgroundTask = nil }
        }
        backgroundTask = task
    }

    private func finishBackgroundTask(success: Bool) {
        backgroundTask?.setTaskCompleted(success: success)
        backgroundTask = nil
    }

    // MARK: Vocabulary

    /// Terms used before, newest first, offered as suggestions.
    static var recentVocabulary: [String] {
        UserDefaults.standard.stringArray(forKey: "vocabulary") ?? []
    }

    private static func remember(_ terms: [String]) {
        var all = terms + recentVocabulary.filter { old in !terms.contains { $0.caseInsensitiveCompare(old) == .orderedSame } }
        all = Array(all.prefix(60))
        UserDefaults.standard.set(all, forKey: "vocabulary")
    }

    // MARK: Import and editing

    func importFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Link to the original when possible; copy only if a link can't be made.
        _ = (try? Store.importReference(to: url)) ?? (try? Store.importMedia(from: url))
        reload()
    }

    /// A video or audio file from Photos arrives as a temporary copy; keep our own.
    func importCopy(_ url: URL, name: String?) {
        _ = try? Store.importMedia(from: url, name: name)
        try? FileManager.default.removeItem(at: url)
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
