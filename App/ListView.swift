import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ListView: View {
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var showingSettings = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        @Bindable var library = library
        NavigationStack(path: $library.path) {
            List {
                ForEach(library.items) { t in
                    NavigationLink(value: t.id) {
                        Row(t: t, working: library.working.contains(t.id), stage: library.progress[t.id])
                    }
                }
                .onDelete { offsets in
                    offsets.map { library.items[$0] }.forEach(library.delete)
                }
            }
            .overlay {
                if library.items.isEmpty {
                    ContentUnavailableView("No recordings",
                                           systemImage: "waveform",
                                           description: Text("Share audio or video to Transcribe, or tap +."))
                }
            }
            .navigationTitle("Transcribe")
            .navigationDestination(for: UUID.self) { id in DetailView(id: id) }
            .toolbar {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
                Menu("Add", systemImage: "plus") {
                    Button("From Files", systemImage: "folder") { importing = true }
                    PhotosPicker(selection: $photoItem, matching: .videos) {
                        Label("From Photos", systemImage: "photo.on.rectangle")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .onChange(of: photoItem) {
                guard let item = photoItem else { return }
                photoItem = nil
                Task {
                    if let movie = try? await item.loadTransferable(type: MediaFile.self) {
                        library.importCopy(movie.url, name: movie.name)
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audiovisualContent]) { result in
                if case .success(let url) = result {
                    Task { await library.importFile(url) }
                }
            }
        }
        // Pick up recordings the share sheet added while the app was in the background.
        .onChange(of: scenePhase) {
            if scenePhase == .active { library.reload() }
        }
    }
}

private struct Row: View {
    @Environment(Library.self) private var library
    let t: Transcript
    let working: Bool
    let stage: Library.Stage?
    @AppStorage("rawText") private var raw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t.displayTitle).font(.headline).lineLimit(2)
            if let subtitle = t.subtitle, !working {
                Text(subtitle).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            if working {
                TranscribeProgress(progress: stage?.value, label: stage?.label ?? "Preparing…")
            } else {
                status
            }
            HStack {
                Text(t.created, format: .dateTime.month().day().hour().minute())
                if t.template != nil || t.title != nil { Text(t.sourceName).lineLimit(1) }
            }
            .font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var status: some View {
        switch t.status {
        case .done:
            Text(t.text.isEmpty ? "(no speech found)" : raw ? t.text : Readable.format(t.text))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        case .pending:
            TranscribeButton(t: t)
        case .failed:
            Label(t.error ?? "Failed", systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.red).lineLimit(2)
            TranscribeButton(t: t, title: "Try again")
        }
    }
}

/// Opens the transcription options. Borderless so it works inside a list row's link.
struct TranscribeButton: View {
    @Environment(Library.self) private var library
    let t: Transcript
    var title = "Transcribe"
    @State private var showingOptions = false

    var body: some View {
        Button {
            showingOptions = true
        } label: {
            Label(title, systemImage: "waveform")
                .font(.subheadline.bold())
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.tint.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $showingOptions) {
            if library.modelsDownloaded {
                TranscribeOptionsView(t: t)
            } else {
                NavigationStack { ModelsSection.standalone }
            }
        }
    }
}

/// A video from Photos, copied out of the picker's temporary file.
struct MediaFile: Transferable {
    let url: URL
    let name: String?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let copy = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString + "." + received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MediaFile(url: copy, name: received.file.lastPathComponent)
        }
    }
}
