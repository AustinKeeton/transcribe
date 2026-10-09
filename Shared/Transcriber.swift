import AVFoundation
import Foundation
import Speech

struct TranscriptionResult: Sendable {
    var text: String
    var words: [Word]
    var segments: [Segment]
    var duration: Double?
}

enum TranscriberError: LocalizedError {
    case unavailable
    case noLanguage
    case noAudio

    var errorDescription: String? {
        switch self {
        case .unavailable: "On-device transcription isn't available on this device."
        case .noLanguage: "On-device transcription isn't available for this language."
        case .noAudio: "This file has no audio track."
        }
    }
}

/// Fraction of the audio transcribed so far, or nil while still preparing.
typealias TranscriptionProgress = @Sendable (Double?) -> Void

/// On-device transcription with SpeechAnalyzer + SpeechTranscriber (iOS 26).
enum Transcriber {
    static func transcribe(_ media: URL, progress: @escaping TranscriptionProgress = { _ in }) async throws -> TranscriptionResult {
        progress(nil)
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        if locale == nil {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        guard let locale else { throw TranscriberError.noLanguage }

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let (audioURL, cleanup) = try await audioFile(for: media)
        defer { if cleanup { try? FileManager.default.removeItem(at: audioURL) } }
        let audio = try AVAudioFile(forReading: audioURL)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        progress(0)

        // Word-level timings come from the audioTimeRange attribute on each text run.
        let collector = Task {
            var words: [Word] = []
            for try await result in transcriber.results where result.isFinal {
                var first = true
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    var text = String(result.text[run.range].characters)
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    // Results don't start with a space; separate them from the previous one.
                    if first, !words.isEmpty, !(text.first?.isWhitespace ?? false) { text = " " + text }
                    first = false
                    words.append(Word(text: text, start: range.start.seconds, end: range.end.seconds))
                }
                if duration > 0 { progress(min(result.range.end.seconds / duration, 1)) }
            }
            return words
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let words = try await collector.value
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResult(text: text, words: words, segments: Segments.build(words: words),
                                   duration: duration)
    }

    /// Audio files are read directly; for video, the audio track is exported to a temporary m4a.
    static func audioFile(for media: URL) async throws -> (URL, Bool) {
        if (try? AVAudioFile(forReading: media)) != nil { return (media, false) }
        let asset = AVURLAsset(url: media)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else { throw TranscriberError.noAudio }
        let out = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        try await session.export(to: out, as: .m4a)
        return (out, true)
    }
}
