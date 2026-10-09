import FluidAudio
import Foundation

/// Optional Parakeet Ultra transcription (~630 MB download) via FluidAudio.
actor Parakeet {
    static let shared = Parakeet()

    private var asr: AsrManager?
    private static var dir: URL { Store.models.appending(path: "parakeet-ultra-coreml", directoryHint: .isDirectory) }

    var isReady: Bool { asr != nil }

    nonisolated static var isDownloaded: Bool {
        AsrModels.modelsExist(at: dir, version: .ultra)
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if asr != nil { return }
        let models = try await AsrModels.downloadAndLoad(
            to: Self.dir, version: .ultra,
            progressHandler: { progress($0.fractionCompleted) })
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
    }

    func remove() {
        asr = nil
        try? FileManager.default.removeItem(at: Self.dir)
    }

    func transcribe(_ media: URL, progress: @escaping TranscriptionProgress) async throws -> TranscriptionResult {
        guard let asr else { throw CocoaError(.featureUnsupported) }
        progress(nil)
        let (audioURL, cleanup) = try await Transcriber.audioFile(for: media)
        defer { if cleanup { try? FileManager.default.removeItem(at: audioURL) } }

        progress(0)
        let stream = await asr.transcriptionProgressStream
        let watcher = Task { for try await p in stream { progress(p) } }
        defer { watcher.cancel() }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(audioURL, decoderState: &state)

        let words = buildWordTimings(from: result.tokenTimings ?? []).enumerated().map { i, w in
            Word(text: (i == 0 ? "" : " ") + w.word, start: w.startTime, end: w.endTime)
        }
        return TranscriptionResult(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                   words: words, segments: Segments.build(words: words),
                                   duration: result.duration)
    }
}
