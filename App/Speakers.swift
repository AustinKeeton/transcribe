import FluidAudio
import Foundation

/// Speaker labels with FluidAudio's Sortformer model (~100 MB download).
actor SpeakerModel {
    static let shared = SpeakerModel()

    private var diarizer: SortformerDiarizer?

    var isReady: Bool { diarizer != nil }

    private static var config: SortformerConfig {
        var config = SortformerConfig.highContextV2_1
        config.precision = .palettized
        return config
    }

    /// Written by the app once the model has downloaded and loaded, so the share
    /// extension only ever loads it from disk and never starts a download.
    private static var readyFlag: URL { Store.models.appending(path: "speakers-ready") }
    nonisolated static var isDownloaded: Bool { FileManager.default.fileExists(atPath: readyFlag.path) }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if diarizer != nil { return }
        let models = try await SortformerModels.loadFromHuggingFace(
            config: Self.config, cacheDirectory: Store.models,
            progressHandler: { progress($0.fractionCompleted) })
        let diarizer = SortformerDiarizer(config: Self.config)
        diarizer.initialize(models: models)
        self.diarizer = diarizer
        try? Data().write(to: Self.readyFlag)
    }

    /// Adds speaker labels to a transcribed item.
    func label(_ t: Transcript, media: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        var t = t
        guard let words = t.words, !words.isEmpty else { return t }
        let turns = try await turns(for: media, progress: progress)
        t.segments = Segments.build(words: words, speakers: Segments.assignSpeakers(words: words, turns: turns))
        t.speakersDone = true
        return t
    }

    /// Who spoke when, for the whole recording.
    func turns(for media: URL, progress: @escaping TranscriptionProgress) async throws -> [SpeakerTurn] {
        guard let diarizer else { throw CocoaError(.featureUnsupported) }
        progress(nil)
        let (audioURL, cleanup) = try await Transcriber.audioFile(for: media)
        defer { if cleanup { try? FileManager.default.removeItem(at: audioURL) } }

        diarizer.reset()
        let timeline = try diarizer.processComplete(audioFileURL: audioURL) { done, total, _ in
            progress(Double(done) / Double(max(total, 1)))
        }
        return timeline.speakers.values
            .flatMap(\.finalizedSegments)
            .map { SpeakerTurn(start: Double($0.startTime), end: Double($0.endTime), speaker: $0.speakerIndex) }
            .sorted { $0.start < $1.start }
    }
}
