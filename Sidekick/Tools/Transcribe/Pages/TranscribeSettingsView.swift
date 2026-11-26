import SwiftUI

struct TranscribeSettingsView: View {
    let engines: SpeechEngines
    @AppStorage(TranscribeQueue.cleanupKey) private var cleanup = false
    private let cleanupAvailable = SystemModelClient().isAvailable

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                PageHeader("Transcribe Settings")

                SettingsSection("Transcription") {
                    EngineSettings(engineKey: TranscribeQueue.engineKey, defaultEngine: .whisper,
                                   models: engines.whisperModel, onChange: {})
                    if cleanupAvailable {
                        SettingsRow(title: "Clean up transcripts",
                                    detail: "Removes filler words. Applies to files you add after turning it on.") {
                            Toggle("", isOn: $cleanup).toggleStyle(MonoToggleStyle()).labelsHidden()
                        }
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .scrollIndicators(.never)
    }
}
