import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One transcript: its paragraphs as selectable text, with rename, timestamps, Copy, Export and Delete.
///
/// Split into child views so progress updates and typing in the title only redraw their own lines;
/// the paragraphs are decoded once per new batch of text, in `TranscriptText`.
struct TranscriptDetailView: View {
    let tool: TranscribeTool
    let transcript: Transcript
    let queue: TranscribeQueue
    let close: () -> Void

    @AppStorage(TranscribeTool.showTimestampsKey) private var showTimestamps = true
    @State private var pendingRemoval: Transcript?
    /// The title as typed; owned here so Export can commit it. Typing only redraws cheap parts.
    @State private var draftTitle = ""
    @State private var copied = false
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Button(action: close) {
                    Label("Transcripts", systemImage: "chevron.left")
                        .font(Theme.Font.caption).foregroundStyle(Theme.fg(0.5))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
                TitleField(tool: tool, transcript: transcript, title: $draftTitle)
                DetailStatus(transcript: transcript, queue: queue)
            }
            actions
            TranscriptText(transcript: transcript, showTimestamps: showTimestamps)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmingRemoval($pendingRemoval, remove: remove)
        .alert("Couldn't export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var actions: some View {
        let hasText = transcript.status == .done || TranscribeTool.hasStoredText(transcript)
        return HStack(spacing: 8) {
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
                $pendingRemoval.request(transcript, remove: remove)
            } label: {
                Label("Delete", systemImage: "trash").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(MonoButtonStyle())
        }
    }

    private func remove(_ t: Transcript) {
        close()
        withAnimation(Motion.fluid) { tool.delete(t) }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TranscribeTool.exportText(for: transcript, timestamps: showTimestamps),
                                       forType: .string)
        withAnimation(Motion.snappy) { copied = true }
        Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation(Motion.snappy) { copied = false } }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(tool.rename(transcript, to: draftTitle)).txt"
        draftTitle = transcript.title
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = TranscribeTool.exportText(for: transcript, timestamps: showTimestamps)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

/// The renamable title. Commits on Return, when focus leaves, and when the page closes;
/// a blank title reverts.
private struct TitleField: View {
    let tool: TranscribeTool
    let transcript: Transcript
    @Binding var title: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Title", text: $title)
            .textFieldStyle(.plain)
            .font(Theme.Font.title)
            .focused($focused)
            .onSubmit(commit)
            .onAppear { title = transcript.title }
            .onDisappear(perform: commit)
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onChange(of: transcript.title) { _, new in if !focused { title = new } }
    }

    private func commit() {
        title = tool.rename(transcript, to: title)
    }
}

/// Date, duration and status. The only part of the page that follows progress.
private struct DetailStatus: View {
    let transcript: Transcript
    let queue: TranscribeQueue

    var body: some View {
        Text(transcriptMeta(transcript)).font(Theme.Font.caption).monospacedDigit().foregroundStyle(Theme.fg(0.4))
        TranscriptStatusLine(transcript: transcript, progress: queue.progress[transcript.id])
        if transcript.status == .incomplete, let reason = transcript.failureReason {
            Text(reason).font(Theme.Font.caption).foregroundStyle(Theme.fg(0.4))
        }
    }
}

/// The paragraphs, decoded and grouped only when the stored text changes (each new batch while
/// transcribing, a retry, or cleanup finishing).
private struct TranscriptText: View {
    let transcript: Transcript
    let showTimestamps: Bool
    @State private var paragraphs: [Paragraph] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded {
                Color.clear.frame(height: 0)
            } else if paragraphs.isEmpty {
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
        .onAppear(perform: reload)
        .onChange(of: transcript.segmentsData) { _, _ in reload() }
        .onChange(of: transcript.cleanedData) { _, _ in reload() }
    }

    private func reload() {
        guard !transcript.isDeleted else { return }
        paragraphs = TranscribeTool.paragraphs(for: transcript)
        loaded = true
    }

    private var emptyText: String {
        switch transcript.status {
        case .done: TranscriptFormatter.noSpeechText
        case .transcribing: "The text will appear here as it's transcribed."
        default: TranscribeTool.statusText(for: transcript) ?? ""
        }
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
