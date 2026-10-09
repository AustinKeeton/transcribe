import SwiftUI

struct ShareView: View {
    let model: ShareModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .adding:
                    ProgressView("Adding…")
                case .added:
                    ContentUnavailableView {
                        Label("Added to Transcribe", systemImage: "checkmark.circle")
                    } description: {
                        Text(model.name)
                    } actions: {
                        Button("Open Transcribe") { model.open() }
                            .buttonStyle(.borderedProminent)
                    }
                case .failed:
                    ContentUnavailableView("Couldn't add this",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(model.error))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Transcribe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.close() }
                }
            }
        }
    }
}
