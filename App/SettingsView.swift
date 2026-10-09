import SwiftUI

struct SettingsView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var library = library
        NavigationStack {
            Form {
                Section {
                    Picker("Engine", selection: $library.engine) {
                        Text("Apple (built in)").tag(Transcript.Engine.apple)
                        Text("Parakeet").tag(Transcript.Engine.parakeet)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    parakeetStatus
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("Both run on this iPhone. Parakeet is often more accurate but is a one-time download of about 630 MB. Used the next time you tap Transcribe.")
                }

                Section {
                    switch library.speakerModel {
                    case .ready: Label("Ready", systemImage: "checkmark.circle")
                    case .loading(let p): ProgressView("Downloading…", value: p)
                    case .failed(let message): failed(message) { await library.loadSpeakerModel() }
                    case .idle:
                        Button(SpeakerModel.isDownloaded ? "Load now" : "Download now (about 100 MB)") {
                            Task { await library.loadSpeakerModel() }
                        }
                    }
                } header: {
                    Text("Speaker labels")
                } footer: {
                    Text("Uses FluidAudio's Sortformer model to label who is speaking. It downloads (about 100 MB, once) the first time you transcribe, or now.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    @ViewBuilder private var parakeetStatus: some View {
        switch library.parakeetModel {
        case .loading(let p):
            ProgressView("Downloading Parakeet…", value: p)
        case .failed(let message):
            failed(message) { await library.loadParakeet() }
        case .ready, .idle:
            if library.parakeetModel == .ready || Parakeet.isDownloaded {
                Button("Delete Parakeet download", role: .destructive) {
                    Task { await library.removeParakeet() }
                }
            }
        }
    }

    private func failed(_ message: String, retry: @escaping @MainActor () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            Button("Try again") { Task { await retry() } }
        }
    }
}
