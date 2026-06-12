import AppKit
import SwiftUI

/// In-memory diagnostics event log (phase 8). Decision paths that used to be
/// debuggable only via SSH detective work (Dock-click follow, settings sync,
/// window routing) log short why-messages here, and the Diagnostics Settings
/// section renders them live. Nothing is persisted — the log exists to make
/// the *next* "it stopped working" report self-explaining, not to be an audit
/// trail.
///
/// Lives in util/ because it is cross-cutting: producers are observer/persister
/// code, the only consumer is the Settings UI; it belongs to neither layer.
///
/// Logging is deliberately cheap: appending a small value struct. All string
/// formatting (relative timestamps, the copy-all dump) happens at display or
/// copy time, so calls cost ~nothing while the Settings window is closed.
@MainActor
final class DiagnosticsLog: ObservableObject {
    static let shared = DiagnosticsLog()

    enum Category: String, CaseIterable, Identifiable {
        case activation
        case dockClick
        case routing
        case sync

        var id: String { rawValue }

        /// Human label for the filter picker.
        var title: String {
            switch self {
                case .activation: return "Activation"
                case .dockClick:  return "Dock"
                case .routing:    return "Routing"
                case .sync:       return "Sync"
            }
        }

        /// Short bracket tag for log rows and the plain-text dump, so lines
        /// stay greppable and roughly column-aligned in monospaced rendering.
        var tag: String { "[\(rawValue)]" }
    }

    struct Entry: Identifiable {
        /// Monotonic counter, not array index — stays stable when the ring
        /// buffer drops old entries, so SwiftUI list diffing doesn't confuse
        /// shifted rows.
        let id: Int
        let date: Date
        let category: Category
        let message: String
    }

    /// Oldest first (append order). The Settings section reverses for display;
    /// keeping storage append-only makes `log()` O(1) amortized.
    @Published private(set) var entries: [Entry] = []

    /// Internal (not private) so the Settings section's footer can state the
    /// real limit without hardcoding a second copy of the number.
    static let capacity = 300
    private var nextId = 0

    // No "diagnostics started" self-test entry: it had to live in *some*
    // category and polluted that category's filter (and real instrumentation
    // exists since M2, so activations fill the log within seconds anyway).
    // The section's "No events yet." empty state covers the fresh-start case.
    private init() {}

    func log(_ category: Category, _ message: String) {
        entries.append(Entry(id: nextId, date: Date(), category: category, message: message))
        nextId += 1
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// Plain-text dump for Copy-all. Uses absolute timestamps (unlike the UI's
    /// relative ones) because the dump is meant to be pasted into a report and
    /// read out of context, possibly hours later.
    func plainTextDump() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return entries
            .map { "\(formatter.string(from: $0.date)) \($0.category.tag) \($0.message)" }
            .joined(separator: "\n")
    }
}
