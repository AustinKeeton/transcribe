import SwiftUI

/// Bar with percent once work is running; spinner while preparing.
struct TranscribeProgress: View {
    let progress: Double?
    var label = "Transcribing…"

    var body: some View {
        if let progress {
            ProgressView(value: progress) {
                HStack {
                    Text(label)
                    Spacer()
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            ProgressView { Text(label).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}
