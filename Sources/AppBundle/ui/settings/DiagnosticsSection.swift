import SwiftUI

/// Diagnostics — live view of the in-memory DiagnosticsLog. Exists so that
/// "Dock click did nothing" reports can be self-diagnosed from inside the app
/// instead of via SSH: open this section, reproduce, read why each decision
/// path bailed (or didn't fire at all).
struct DiagnosticsSection: View {
    @ObservedObject private var diagnostics = DiagnosticsLog.shared
    /// nil = All. Filter is view-local state: it only affects what's shown,
    /// never what's recorded.
    @State private var filter: DiagnosticsLog.Category? = nil

    private var visibleEntries: [DiagnosticsLog.Entry] {
        // Storage is oldest-first (cheap appends); display wants newest-first
        // so the latest event is visible without scrolling.
        let newestFirst = diagnostics.entries.reversed()
        guard let filter else { return Array(newestFirst) }
        return newestFirst.filter { $0.category == filter }
    }

    var body: some View {
        Form {
            Section {
                Picker("Category", selection: $filter) {
                    Text("All").tag(DiagnosticsLog.Category?.none)
                    ForEach(DiagnosticsLog.Category.allCases) { category in
                        Text(category.title).tag(Optional(category))
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    // Copy-all always dumps the FULL buffer regardless of the
                    // filter — a bug report should carry full context, the
                    // filter is just a reading aid.
                    Button("Copy All") {
                        diagnostics.plainTextDump().copyToClipboard()
                    }
                    Button("Clear") {
                        diagnostics.clear()
                    }
                    Spacer()
                }
            } footer: {
                Text("In-memory only (last \(DiagnosticsLog.capacity) events). Cleared on app restart.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if visibleEntries.isEmpty {
                    Text(filter == nil ? "No events yet." : "No events in this category yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleEntries) { entry in
                        row(entry)
                    }
                }
            } header: {
                Text("Events (\(visibleEntries.count))")
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ entry: DiagnosticsLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.category.tag)
                .foregroundStyle(.secondary)
            Text(entry.message)
            Spacer()
            // Relative ("2 min ago") rather than absolute: when debugging
            // "I just clicked and nothing happened", recency is the question.
            // `style: .relative` (not `format: .relative(...)`) because the
            // style variant self-updates as time passes — the format variant
            // renders once and a quiet log would show "5 seconds ago" forever.
            // The absolute timestamp lives in the Copy-all dump.
            Text(entry.date, style: .relative)
                .foregroundStyle(.tertiary)
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }
}
