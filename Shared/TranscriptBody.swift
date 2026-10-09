import SwiftUI

/// Transcript as timestamped paragraphs, with a speaker label at each change of speaker.
/// Tapping a label renames that speaker everywhere. Falls back to plain text without segments.
struct TranscriptBody: View {
    let transcript: Transcript
    var rename: ((Int, String) -> Void)?

    /// Off: every word as said, formatted, with pauses marked. On: the engine's raw text.
    @AppStorage("rawText") private var raw = false
    @State private var renaming: Int?
    @State private var draft = ""

    var body: some View {
        let segments = transcript.segments
        if segments.isEmpty {
            Text(transcript.text.isEmpty ? "(no speech found)" : raw ? transcript.text : Readable.format(transcript.text))
                .textSelection(.enabled)
        } else {
            let longRecording = (segments.last?.start ?? 0) >= 3600
            let paragraphs = Self.paragraphs(segments, pauses: !raw)
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(paragraphs.indices, id: \.self) { i in
                    let p = paragraphs[i]
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(Self.timestamp(p.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: longRecording ? 58 : 36, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            if let speaker = p.speaker, i == 0 || paragraphs[i - 1].speaker != speaker {
                                speakerLabel(speaker)
                            }
                            Text(raw ? p.text : Readable.format(p.text)).textSelection(.enabled)
                        }
                    }
                }
            }
            .alert("Name this speaker", isPresented: Binding(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } })
            ) {
                TextField("Name", text: $draft)
                Button("Save") { if let s = renaming { rename?(s, draft) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Used for every paragraph from this speaker.")
            }
        }
    }

    @ViewBuilder private func speakerLabel(_ speaker: Int) -> some View {
        let label = Text(transcript.speakerName(speaker))
            .font(.caption.bold())
            .foregroundStyle(Self.color(speaker))
        if rename != nil {
            Button {
                let name = transcript.speakerName(speaker)
                draft = name.hasPrefix("Speaker ") ? "" : name
                renaming = speaker
            } label: {
                HStack(spacing: 3) {
                    label
                    Image(systemName: "pencil").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    /// Joins phrases into paragraphs. Breaks at a change of speaker; at a pause or after ~30 s
    /// only once the sentence has ended, so a paragraph never stops mid-sentence (up to ~90 s).
    /// With `pauses`, silences inside a paragraph are marked ("…" or "[pause, 5 s]").
    nonisolated static func paragraphs(_ segments: [Segment], pauses: Bool = false) -> [Segment] {
        var out: [Segment] = []
        for s in smoothed(segments) {
            if var last = out.last, last.speaker == s.speaker {
                let sentenceEnded = last.text.last.map { ".?!".contains($0) } ?? false
                let gap = s.start - last.end
                let shortGap = gap < 1.5 && s.end - last.start < 30
                if shortGap || (!sentenceEnded && s.end - last.start < 90) {
                    if pauses, let marker = Readable.pause(gap, afterSentenceEnd: sentenceEnded) {
                        last.text += " " + marker
                    }
                    last.text += " " + s.text
                    last.end = s.end
                    out[out.count - 1] = last
                    continue
                }
            }
            out.append(s)
        }
        return out
    }

    /// The speaker model sometimes gives a few words to the wrong person in the middle of
    /// someone's turn ("of us", "I might"). A fragment of up to three words, not a finished
    /// sentence, with the same speaker on both sides is given to that speaker.
    nonisolated static func smoothed(_ segments: [Segment]) -> [Segment] {
        var segments = segments
        guard segments.count > 2 else { return segments }
        for i in 1..<(segments.count - 1) {
            let around = segments[i - 1].speaker
            let text = segments[i].text
            if let around, around == segments[i + 1].speaker, segments[i].speaker != around,
               text.split(separator: " ").count <= 3, !(text.last.map { ".?!".contains($0) } ?? false) {
                segments[i].speaker = around
            }
        }
        return segments
    }

    static func color(_ speaker: Int) -> Color {
        [Color.blue, .orange, .green, .purple][speaker % 4]
    }

    static func timestamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
