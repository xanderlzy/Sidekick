import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One transcript: its paragraphs as selectable text, with rename, timestamps, Copy, Export and Delete.
struct TranscriptDetailView: View {
    let tool: TranscribeTool
    let transcript: Transcript
    let queue: TranscribeQueue
    let close: () -> Void

    @AppStorage(TranscribeTool.showTimestampsKey) private var showTimestamps = true
    @State private var title = ""
    @FocusState private var titleFocused: Bool
    @State private var confirmingDelete = false
    @State private var copied = false
    @State private var exportError: String?

    var body: some View {
        let paragraphs = TranscribeTool.paragraphs(for: transcript)
        let hasText = !paragraphs.isEmpty || transcript.status == .done
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            header
            actions(hasText: hasText)
            if paragraphs.isEmpty {
                Text(emptyText).font(Theme.Font.body).foregroundStyle(Theme.fg(0.5))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in
                            ParagraphRow(paragraph: p, showTimestamp: showTimestamps)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { title = transcript.title }
        .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
        .onChange(of: transcript.title) { _, new in if !titleFocused { title = new } }
        .alert("Delete this transcript?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its text will be gone. This can't be undone.")
        }
        .alert("Couldn't export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Button {
                commitTitle()
                close()
            } label: {
                Label("Transcripts", systemImage: "chevron.left")
                    .font(Theme.Font.caption).foregroundStyle(Theme.fg(0.5))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)

            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.Font.title)
                .focused($titleFocused)
                .onSubmit { commitTitle() }
            Text(transcriptMeta(transcript)).font(Theme.Font.caption).monospacedDigit().foregroundStyle(Theme.fg(0.4))
            TranscriptStatusLine(transcript: transcript, progress: queue.progress[transcript.id])
            if transcript.status == .incomplete, let reason = transcript.failureReason {
                Text(reason).font(Theme.Font.caption).foregroundStyle(Theme.fg(0.4))
            }
        }
    }

    private func actions(hasText: Bool) -> some View {
        HStack(spacing: 8) {
            Toggle("Timestamps", isOn: $showTimestamps)
                .toggleStyle(MonoToggleStyle())
                .font(Theme.Font.body)
                .fixedSize()
                .padding(.trailing, 8)
            Button(copied ? "Copied" : "Copy", action: copy).buttonStyle(MonoButtonStyle())
                .disabled(!hasText).opacity(hasText ? 1 : 0.4)
            Button("Export…", action: export).buttonStyle(MonoButtonStyle())
                .disabled(!hasText).opacity(hasText ? 1 : 0.4)
            if TranscribeTool.canRetry(transcript) {
                Button("Retry") { queue.retry(transcript) }.buttonStyle(MonoButtonStyle())
            }
            Spacer(minLength: 0)
            Button {
                if TranscribeTool.deleteNeedsConfirmation(transcript) { confirmingDelete = true } else { delete() }
            } label: {
                Label("Delete", systemImage: "trash").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(MonoButtonStyle())
        }
    }

    private var emptyText: String {
        switch transcript.status {
        case .done: TranscriptFormatter.noSpeechText
        case .transcribing: "The text will appear here as it's transcribed."
        default: TranscribeTool.statusText(for: transcript) ?? ""
        }
    }

    private func commitTitle() {
        title = tool.rename(transcript, to: title)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TranscribeTool.exportText(for: transcript, timestamps: showTimestamps),
                                       forType: .string)
        withAnimation(Motion.snappy) { copied = true }
        Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation(Motion.snappy) { copied = false } }
    }

    private func export() {
        commitTitle()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(transcript.title).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = TranscribeTool.exportText(for: transcript, timestamps: showTimestamps)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func delete() {
        close()
        withAnimation(Motion.fluid) { tool.delete(transcript) }
    }
}

private struct ParagraphRow: View {
    let paragraph: Paragraph
    let showTimestamp: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if showTimestamp {
                Text(TranscribeTool.clock(paragraph.start))
                    .font(Theme.Font.caption).monospacedDigit()
                    .foregroundStyle(Theme.fg(0.4))
                    .frame(width: 56, alignment: .leading)
            }
            Text(paragraph.text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: 640, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
