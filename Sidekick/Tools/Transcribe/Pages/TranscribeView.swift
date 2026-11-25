import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The drop area, Choose Files…, and every transcript, newest first. Opens one in place to read it.
struct TranscribeView: View {
    let tool: TranscribeTool
    let store: TranscriptStore
    let queue: TranscribeQueue
    /// Same context the queue writes through, so status, progress text and new items show up live.
    @Query(sort: \Transcript.dateAdded, order: .reverse) private var transcripts: [Transcript]
    @State private var openID: UUID?
    @State private var targeted = false
    @State private var pendingRemoval: Transcript?

    var body: some View {
        Group {
            if let openID, let t = transcripts.first(where: { $0.id == openID }) {
                TranscriptDetailView(tool: tool, transcript: t, queue: queue) {
                    withAnimation(Motion.fluid) { self.openID = nil }
                }
                .transition(.opacity)
            } else {
                list.transition(.opacity)
            }
        }
        .animation(Motion.fluid, value: openID)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            PageHeader(title: "Transcripts",
                       subtitle: "Drop lectures or other recordings. They're transcribed one at a time on this Mac.") {
                Button("Choose Files…", action: chooseFiles).buttonStyle(MonoButtonStyle(prominent: true))
            }

            VStack(alignment: .leading, spacing: Theme.Space.item) {
                dropArea
                if !queue.rejected.isEmpty { rejections }
            }

            if transcripts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing here yet").font(.system(size: 15, weight: .semibold))
                    Text("Your transcripts will appear here.").font(Theme.Font.body).foregroundStyle(Theme.fg(0.5))
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(transcripts) { t in
                            TranscriptRow(transcript: t, progress: queue.progress[t.id],
                                          open: { withAnimation(Motion.fluid) { openID = t.id } },
                                          retry: { queue.retry(t) },
                                          cancel: { $pendingRemoval.request(t, remove: remove) })
                        }
                    }
                    .animation(Motion.fluid, value: transcripts.count)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            tool.add(files)
            return true
        } isTargeted: { targeted = $0 }
        .confirmingRemoval($pendingRemoval, remove: remove)
    }

    private func remove(_ t: Transcript) {
        withAnimation(Motion.fluid) { tool.delete(t) }
    }

    private var dropArea: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.doc").font(.system(size: 15)).foregroundStyle(Theme.fg(0.5))
            Text("Drop audio or video files here").font(Theme.Font.body).foregroundStyle(Theme.fg(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, transcripts.isEmpty ? 48 : 20)
        .background {
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .fill(Theme.fg(targeted ? 0.05 : 0))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(Theme.fg(targeted ? 0.45 : 0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .animation(Motion.snappy, value: targeted)
    }

    private var rejections: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(queue.rejected.enumerated()), id: \.offset) { _, r in
                Text("\(r.name): \(r.reason)")
                    .font(Theme.Font.caption).foregroundStyle(Theme.fg(0.55)).lineLimit(1).truncationMode(.middle)
            }
        }
        .transition(.opacity)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audiovisualContent]
        panel.prompt = "Transcribe"
        guard panel.runModal() == .OK else { return }
        tool.add(panel.urls)
    }
}

/// "21 Nov 2026 at 14:05 · 52:10"
@MainActor func transcriptMeta(_ t: Transcript) -> String {
    var parts = [t.dateAdded.formatted(date: .abbreviated, time: .shortened)]
    if t.duration > 0 { parts.append(TranscribeTool.clock(t.duration)) }
    return parts.joined(separator: " · ")
}

/// Running: a progress bar and percentage. Otherwise the status line, if any.
struct TranscriptStatusLine: View {
    let transcript: Transcript
    let progress: Double?

    var body: some View {
        if transcript.status == .transcribing {
            HStack(spacing: 10) {
                ProgressBar(fraction: progress ?? 0).frame(maxWidth: 220)
                Text("\(Int((progress ?? 0) * 100))%").font(Theme.Font.caption).monospacedDigit()
                    .foregroundStyle(Theme.fg(0.5))
            }
        } else if let text = TranscribeTool.statusText(for: transcript) {
            Text(text).font(Theme.Font.caption).foregroundStyle(Theme.fg(0.55))
        }
    }
}

private struct TranscriptRow: View {
    let transcript: Transcript
    let progress: Double?
    let open: () -> Void
    let retry: () -> Void
    let cancel: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(transcript.title).font(Theme.Font.body).lineLimit(1)
                    Text(transcriptMeta(transcript)).font(Theme.Font.caption).monospacedDigit()
                        .foregroundStyle(Theme.fg(0.4))
                    TranscriptStatusLine(transcript: transcript, progress: progress)
                }
                Spacer(minLength: 12)
                if TranscribeTool.canRetry(transcript) {
                    Button("Retry", action: retry).buttonStyle(MonoButtonStyle())
                } else if TranscribeTool.canCancel(transcript) {
                    Button("Cancel", action: cancel).buttonStyle(MonoButtonStyle())
                }
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.fg(0.3))
            }
            .padding(.vertical, 11).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fg(hovering ? 0.04 : 0)))
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
            Hairline()
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

// MARK: - Removal confirmation, shared by the list's Cancel and the detail view's Delete

extension Binding where Value == Transcript? {
    /// Removes `t` right away when nothing would be lost, otherwise holds it for the confirmation.
    @MainActor func request(_ t: Transcript, remove: (Transcript) -> Void) {
        if TranscribeTool.deleteNeedsConfirmation(t) { wrappedValue = t } else { remove(t) }
    }
}

private struct ConfirmRemoval: ViewModifier {
    @Binding var pending: Transcript?
    let remove: (Transcript) -> Void

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                      presenting: pending) { t in
            Button("Delete", role: .destructive) { remove(t) }
            Button("Keep", role: .cancel) {}
        } message: { _ in
            Text("Its text will be gone. This can't be undone.")
        }
    }

    private var title: String {
        guard let pending, !pending.isDeleted else { return "Delete this transcript?" }
        return TranscribeTool.canCancel(pending) ? "Stop and delete this transcript?" : "Delete this transcript?"
    }
}

extension View {
    /// Shows the delete confirmation while `pending` is set, and calls `remove` if the user confirms.
    func confirmingRemoval(_ pending: Binding<Transcript?>, remove: @escaping (Transcript) -> Void) -> some View {
        modifier(ConfirmRemoval(pending: pending, remove: remove))
    }
}
