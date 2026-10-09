import SwiftUI

struct DetailView: View {
    @Environment(Library.self) private var library
    let id: UUID
    @AppStorage("rawText") private var raw = false

    var body: some View {
        if let t = library.items.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if library.working.contains(t.id) {
                        let stage = library.progress[t.id]
                        TranscribeProgress(progress: stage?.value, label: stage?.label ?? "Preparing…")
                    } else if t.status == .pending {
                        ContentUnavailableView {
                            Label("Not transcribed yet", systemImage: "waveform")
                        } description: {
                            Text(t.sourceName)
                        } actions: {
                            TranscribeButton(t: t)
                        }
                    } else if t.status == .failed {
                        Label(t.error ?? "Failed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        TranscribeButton(t: t, title: "Try again")
                    } else if let error = t.upgradeError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary)
                        if t.hasMedia { TranscribeButton(t: t, title: "Try again") }
                    }
                    if t.status == .done {
                        if let subtitle = t.subtitle {
                            Text(subtitle).font(.title3.weight(.semibold))
                        }
                        TranscriptBody(transcript: t) { library.rename(t, speaker: $0, to: $1) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(t.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if t.status == .done, !t.text.isEmpty {
                    Menu("Options", systemImage: "ellipsis") {
                        Toggle("Raw text", systemImage: "text.quote", isOn: $raw)
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = t.exportText(raw: raw)
                        }
                    }
                    ShareLink(item: t.exportText(raw: raw))
                }
            }
        } else {
            ContentUnavailableView("Not found", systemImage: "questionmark")
        }
    }
}
