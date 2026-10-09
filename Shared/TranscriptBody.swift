import SwiftUI

/// Transcript as timestamped paragraphs, with a speaker label at each change of speaker.
/// Tapping a label renames that speaker everywhere. Falls back to plain text without segments.
struct TranscriptBody: View {
    let transcript: Transcript
    var rename: ((Int, String) -> Void)?

    @State private var renaming: Int?
    @State private var draft = ""

    var body: some View {
        let segments = transcript.segments
        if segments.isEmpty {
            Text(transcript.text.isEmpty ? "(no speech found)" : transcript.text).textSelection(.enabled)
        } else {
            let longRecording = (segments.last?.start ?? 0) >= 3600
            let paragraphs = Self.paragraphs(segments)
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
                            Text(p.text).textSelection(.enabled)
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

    /// Joins phrases into paragraphs, breaking at a change of speaker, a pause, or after ~30 s.
    nonisolated static func paragraphs(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for s in segments {
            if var last = out.last, last.speaker == s.speaker, s.start - last.end < 1.5, s.end - last.start < 30 {
                last.text += " " + s.text
                last.end = s.end
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
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
