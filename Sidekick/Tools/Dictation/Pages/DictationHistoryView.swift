import SwiftUI
import SwiftData

struct DictationHistoryView: View {
    let env: DictationEnvironment
    @Query(sort: \DictationRecord.date, order: .reverse) private var records: [DictationRecord]
    @State private var search = ""
    @State private var confirmingClear = false

    private var filtered: [DictationRecord] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return records }
        return records.filter {
            $0.finalText.localizedCaseInsensitiveContains(q) || ($0.appName ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                Text("History").font(Theme.Font.title)
                Spacer()
                SearchField(text: $search)
                Button("Clear all") { confirmingClear = true }
                    .buttonStyle(MonoButtonStyle())
                    .disabled(records.isEmpty)
                    .opacity(records.isEmpty ? 0.4 : 1)
            }
            if filtered.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(Formatting.groupByDay(filtered, date: \.date), id: \.day) { group in
                            Section {
                                ForEach(group.items) { record in
                                    HistoryRow(record: record, delete: {
                                        withAnimation(Motion.fluid) { env.history.delete(record) }
                                    })
                                }
                            } header: {
                                SectionLabel(text: Formatting.dayLabel(group.day))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 18).padding(.bottom, 6)
                                    .background(Theme.bg())
                            }
                        }
                    }
                    .animation(Motion.fluid, value: filtered.count)
                }
                .scrollIndicators(.never)
            }
        }
        .confirmationDialog("Delete all history?", isPresented: $confirmingClear) {
            Button("Delete all", role: .destructive) { withAnimation(Motion.fluid) { env.history.deleteAll() } }
        } message: {
            Text("Your stats stay. This can't be undone.")
        }
    }

    @ViewBuilder private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(records.isEmpty ? "Nothing here yet" : "No matches")
                .font(.system(size: 15, weight: .semibold))
            Text(records.isEmpty
                 ? (RetentionPolicy.current().keepsNew ? "Your dictations will appear here." : "History is turned off in Settings.")
                 : "Try a different word.")
                .font(Theme.Font.body).foregroundStyle(Theme.fg(0.5))
        }
        .padding(.top, 40)
        .transition(.opacity)
    }
}

private struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.fg(0.4))
            TextField("Search", text: $text).textFieldStyle(.plain).font(Theme.Font.body).focused($focused)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: focused || !text.isEmpty ? 220 : 160)
        .background(Capsule().strokeBorder(Theme.fg(focused ? 0.35 : 0.15), lineWidth: 1))
        .animation(Motion.snappy, value: focused)
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    let delete: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(record.date.formatted(date: .omitted, time: .shortened))
                .font(Theme.Font.caption).monospacedDigit()
                .foregroundStyle(Theme.fg(0.4))
                .frame(width: 64, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.finalText).font(Theme.Font.body).lineLimit(2).textSelection(.enabled)
                if let app = record.appName {
                    Text(app).font(Theme.Font.caption).foregroundStyle(Theme.fg(0.4))
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Button(copied ? "Copied" : "Copy") { copy() }.buttonStyle(MonoButtonStyle())
                Button(action: delete) {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(MonoButtonStyle())
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 10).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fg(hovering ? 0.04 : 0)))
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.finalText, forType: .string)
        withAnimation(Motion.snappy) { copied = true }
        Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation(Motion.snappy) { copied = false } }
    }
}
