import SwiftUI

/// Chosen per transcription: coaching (two speakers) or single speaker, plus vocabulary.
struct TranscribeOptionsView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let t: Transcript

    @State private var mode: Engine.Mode
    @State private var vocabulary: String
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var unplugged = false

    init(t: Transcript) {
        self.t = t
        _mode = State(initialValue: t.mode.flatMap(Engine.Mode.init) ?? .coaching)
        _vocabulary = State(initialValue: (t.vocabulary ?? []).joined(separator: ", "))
    }

    private var terms: [String] {
        vocabulary.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Recording", selection: $mode) {
                        Label("Coaching (2 speakers)", systemImage: "person.2").tag(Engine.Mode.coaching)
                        Label("Single speaker", systemImage: "person").tag(Engine.Mode.single)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } footer: {
                    Text(mode == .coaching
                         ? "Speaker labels on, exactly two speakers."
                         : "Speaker labels off. Splitting one voice in two is avoided.")
                }

                Section {
                    TextField("Client name, company, coaching terms", text: $vocabulary, axis: .vertical)
                        .textInputAutocapitalization(.words)
                    let suggestions = Library.recentVocabulary.filter { s in
                        !terms.contains { $0.caseInsensitiveCompare(s) == .orderedSame }
                    }
                    if !suggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(suggestions.prefix(20), id: \.self) { s in
                                    Button(s) { vocabulary = (terms + [s]).joined(separator: ", ") }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Vocabulary")
                } footer: {
                    Text("Separate with commas. Names and terms the recognizer might not know.")
                }

                if lowPower || unplugged {
                    Section {
                        if lowPower { Label("Turn off Low Power Mode for long recordings.", systemImage: "bolt.slash") }
                        if unplugged { Label("Plug in for long recordings.", systemImage: "powerplug") }
                    }
                    .foregroundStyle(.orange)
                }

                Section {
                    Text("Make sure everyone recorded agreed to it. Some states require everyone's consent.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Transcribe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let (mode, terms) = (mode, terms)
                        Task { await library.process(t, mode: mode, vocabulary: terms) }
                        dismiss()
                    }
                }
            }
            .onAppear {
                UIDevice.current.isBatteryMonitoringEnabled = true
                unplugged = UIDevice.current.batteryState == .unplugged
            }
        }
    }
}
