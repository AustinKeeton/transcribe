import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ModelsSection()
                Section {
                    Label("In person: phone flat on a hard table, halfway between you, mic uncovered.", systemImage: "iphone")
                    Label("Turn on Do Not Disturb or Airplane Mode while recording.", systemImage: "moon")
                    Label("Zoom or Meet: record on the computer or in the call app, then import the file.", systemImage: "video")
                    Label("Get the client's consent before recording.", systemImage: "hand.raised")
                } header: {
                    Text("Recording tips")
                }
                .font(.subheadline)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Model status and the one-time download (Wi-Fi only unless overridden).
struct ModelsSection: View {
    @Environment(Library.self) private var library

    /// Shown when Transcribe is tapped before the models are on the phone.
    static var standalone: some View {
        Form { ModelsSection() }.navigationTitle("Models needed")
    }

    var body: some View {
        Section {
            switch library.models {
            case .ready:
                Label("Ready", systemImage: "checkmark.circle")
            case .downloaded:
                Label("Downloaded", systemImage: "checkmark.circle")
            case .loading(let p):
                ProgressView(Engine.isDownloaded ? "Loading…" : "Downloading…", value: p)
            case .missing:
                download
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                download
            }
        } header: {
            Text("Models")
        } footer: {
            Text("Parakeet TDT 0.6B v2 (English), speaker diarization, voice detection and vocabulary boosting: about 650 MB, downloaded once. Everything runs on this iPhone's Neural Engine; recordings never leave it.")
        }
    }

    @ViewBuilder private var download: some View {
        if library.expensiveNetwork {
            Label("You're on cellular. Connect to Wi-Fi to download.", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.secondary)
            Button("Download anyway (about 650 MB)") {
                Task { await library.loadModels(allowExpensive: true) }
            }
        } else {
            Button("Download models (about 650 MB)") {
                Task { await library.loadModels() }
            }
        }
    }
}
