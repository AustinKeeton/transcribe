import CoreML
import FluidAudio
import Foundation

/// The on-device transcription pipeline, all through FluidAudio on the Neural Engine:
/// Silero VAD → Parakeet TDT 0.6B v2 (English) per speech segment → optional custom-vocabulary
/// rescoring → offline diarization with exactly two speakers (coaching mode only).
actor Engine {
    static let shared = Engine()

    enum Mode: String, Codable, Sendable {
        case coaching   // two speakers, diarization on
        case single     // one speaker, diarization off
    }

    private var asr: AsrManager?
    private var vad: VadManager?
    private var ctc: CtcModels?
    /// The diarizer isn't Sendable, so each job makes its own from the cached models.
    private var diarizerReady = false

    private static let sampleRate = 16_000.0
    private static var asrDir: URL { Store.models.appending(path: "parakeet-tdt-0.6b-v2", directoryHint: .isDirectory) }

    private static var neuralEngine: MLModelConfiguration {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        return config
    }

    var isReady: Bool { asr != nil && vad != nil && ctc != nil && diarizerReady }

    /// True when the speech model is on disk, so loading won't start a large download.
    nonisolated static var isDownloaded: Bool { AsrModels.modelsExist(at: asrDir, version: .v2) }

    /// Downloads (first time, ~650 MB) and loads every model.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isReady { return }
        if asr == nil {
            let models = try await AsrModels.downloadAndLoad(
                to: Self.asrDir, configuration: Self.neuralEngine, version: .v2,
                progressHandler: { progress($0.fractionCompleted * 0.75) })
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asr = manager
        }
        if ctc == nil {
            // The vocabulary rescorer reads the CTC model from FluidAudio's default location.
            ctc = try await CtcModels.downloadAndLoad()
            progress(0.88)
        }
        if !diarizerReady {
            _ = try await Self.makeDiarizer()
            diarizerReady = true
            progress(0.96)
        }
        if vad == nil {
            vad = try await VadManager(config: VadConfig(computeUnits: .cpuAndNeuralEngine))
        }
        progress(1)
    }

    func transcribe(_ media: URL, mode: Mode, vocabulary: [String],
                    progress: @escaping TranscriptionProgress) async throws -> TranscriptionResult {
        guard let asr, let vad, let ctc, diarizerReady else { throw CocoaError(.featureUnsupported) }
        progress(nil)
        let (audioURL, cleanup) = try await Transcriber.audioFile(for: media)
        defer { if cleanup { try? FileManager.default.removeItem(at: audioURL) } }
        let samples = try AudioConverter().resampleAudioFile(audioURL)
        let duration = Double(samples.count) / Self.sampleRate

        // Only speech goes to the recogniser, so long pauses can't turn into invented text.
        let speech = try await vad.segmentSpeech(samples)
        let terms = vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let boosting = terms.isEmpty ? nil : try await VocabularyBoostingSession(
            vocabulary: CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) }),
            ctcModels: ctc)

        let share = mode == .coaching ? 0.8 : 1.0
        var words: [Word] = []
        progress(0)
        for (i, segment) in speech.enumerated() {
            let from = max(0, Int(segment.startTime * Self.sampleRate))
            let to = min(samples.count, Int(segment.endTime * Self.sampleRate))
            guard to > from else { continue }
            var clip = Array(samples[from..<to])
            // The recogniser wants at least a second of audio; pad short clips with silence.
            if clip.count < Int(Self.sampleRate) { clip += [Float](repeating: 0, count: Int(Self.sampleRate) - clip.count) }

            var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribe(clip, decoderState: &state)
            var clipWords = buildWordTimings(from: result.tokenTimings ?? []).map {
                Word(text: " " + $0.word, start: segment.startTime + $0.startTime, end: segment.startTime + $0.endTime)
            }
            if let boosting, let timings = result.tokenTimings,
               let output = await boosting.rescore(text: result.text, tokenTimings: timings, audioSamples: clip),
               output.wasModified {
                clipWords = Self.applying(output.replacements, to: clipWords)
            }
            Self.join(&words, clipWords, keepCapitalized: terms)
            progress(share * Double(i + 1) / Double(max(speech.count, 1)))
        }
        if let first = words.first { words[0].text = first.text.trimmingCharacters(in: .whitespaces) }

        var labels: [Int?]? = nil
        if mode == .coaching, !words.isEmpty {
            let diarizer = try await Self.makeDiarizer()
            let result = try await diarizer.process(audioURL) { done, total in
                progress(share + (1 - share) * Double(done) / Double(max(total, 1)))
            }
            var ids: [String: Int] = [:]
            let turns = result.segments.map { s -> SpeakerTurn in
                let id = ids[s.speakerId] ?? { ids[s.speakerId] = ids.count; return ids.count - 1 }()
                return SpeakerTurn(start: Double(s.startTimeSeconds), end: Double(s.endTimeSeconds), speaker: id)
            }
            labels = Segments.assignSpeakers(words: words, turns: turns)
        }

        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResult(text: text, words: words,
                                   segments: Segments.build(words: words, speakers: labels), duration: duration)
    }

    /// Each speech segment is transcribed on its own, so the model may end it with a full stop
    /// or capitalise the next one even mid-sentence. Across a short pause (under 3 s):
    /// - previous segment didn't end a sentence -> lower-case the next word;
    /// - next segment starts lower-case (the model heard a continuation) -> drop the stray stop.
    /// "I" and vocabulary terms keep their capitals.
    static func join(_ words: inout [Word], _ next: [Word], keepCapitalized terms: [String]) {
        var next = next
        if let first = next.first, let last = words.last, first.start - last.end < 3.0 {
            let plain = first.text.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            let protected = ["I", "I'm", "I've", "I'll", "I'd"].contains(plain)
                || terms.contains { $0.split(separator: " ").first.map(String.init) == plain }
            let endedSentence = last.text.last.map { ".?!".contains($0) } ?? false
            if !endedSentence, !protected, let initial = plain.first, initial.isUppercase,
               let range = next[0].text.range(of: String(initial)) {
                next[0].text.replaceSubrange(range, with: String(initial).lowercased())
            } else if let initial = plain.first, initial.isLowercase,
                      last.text.hasSuffix("."), !last.text.hasSuffix("..") {
                words[words.count - 1].text.removeLast()
            }
        }
        words += next
    }

    /// Two speakers exactly, models from the App Group cache (downloaded the first time).
    private static func makeDiarizer() async throws -> OfflineDiarizerManager {
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig.default.withSpeakers(exactly: 2))
        try await manager.prepareModels(directory: Store.models, configuration: neuralEngine)
        return manager
    }

    /// The rescorer returns corrected text, not timings. Put each replacement back into the
    /// word list, spanning the original words' time range, so timestamps stay right.
    ///
    /// FluidAudio's rescorer favours short terms: "MCC" outscores almost any longer stretch,
    /// so on its own it rewrites ordinary words ("It's an honor" -> "Isabel"). A replacement is
    /// kept only when the heard words already look like the term: similar spelling, about the
    /// same number of words, and not already containing it ("Reinfrancois" -> "Jean-François").
    static func applying(_ replacements: [VocabularyRescorer.RescoringResult], to words: [Word]) -> [Word] {
        var words = words
        func bare(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        }
        for r in replacements where r.shouldReplace {
            guard let replacement = r.replacementWord else { continue }
            let original = r.originalWord.split(separator: " ").map { bare(String($0)) }
            guard !original.isEmpty, words.count >= original.count,
                  original.count <= replacement.split(separator: " ").count + 1,
                  !original.joined(separator: " ").contains(bare(replacement)),
                  similarity(original.joined(), replacement) >= 0.6
            else { continue }
            for start in 0...(words.count - original.count)
            where (0..<original.count).allSatisfy({ bare(words[start + $0].text) == original[$0] }) {
                let last = words[start + original.count - 1]
                let trailing = String(last.text.reversed().prefix { $0.isPunctuation }.reversed())
                let leading = words[start].text.hasPrefix(" ") ? " " : ""
                words.replaceSubrange(start..<(start + original.count), with: [
                    Word(text: leading + replacement + trailing, start: words[start].start, end: last.end),
                ])
                break
            }
        }
        return words
    }

    /// 1 for the same letters, 0 for nothing in common (edit distance over letters only,
    /// ignoring case and accents).
    static func similarity(_ a: String, _ b: String) -> Double {
        func letters(_ s: String) -> [Character] {
            Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter(\.isLetter))
        }
        let x = letters(a), y = letters(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var previous = row[0]
            row[0] = i
            for j in 1...y.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (x[i - 1] == y[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return 1 - Double(row[y.count]) / Double(max(x.count, y.count))
    }
}
