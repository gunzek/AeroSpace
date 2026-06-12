import SwiftUI

/// Resolves the user's `~/.aerospace.toml` (XDG-aware) with a sensible fallback
/// when no file exists yet — matches the lookup used by Open-Config in MenuBar.
enum SettingsConfigPath {
    static func aerospaceTomlUrl() -> URL {
        switch findCustomConfigUrl() {
            case .file(let url): return url
            case .noCustomConfigExists, .ambiguousConfigError:
                return FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: configDotfileName)
        }
    }
}

/// Inline persister status for section footers: "Applying…" while a TOML
/// write + reload-config round-trip is in flight, the last sync error
/// otherwise. Renders nothing when the persister is idle and happy, so
/// footers can compose it unconditionally.
///
/// Errors are scoped: a footer shows section-scoped errors only when they
/// belong to its own `scope` (so a keybindings table conflict never renders
/// under the Gaps sliders), while `.general` errors (I/O failures, unsafe
/// literals) show in every footer — the user should see those wherever they
/// happen to be.
struct SyncStatusFooter: View {
    var scope: SettingsPersister.ErrorScope = .general
    @ObservedObject private var persister = SettingsPersister.shared

    var body: some View {
        if persister.syncing {
            Text("Applying\u{2026}")
                .foregroundStyle(.secondary)
        } else if let hold = persister.holdReason {
            // The validation hold is global (any sync projects full state),
            // so every footer shows it — the message names the offending
            // section, which is what a user editing a *different* section
            // needs to understand why their change didn't apply.
            Text("Changes kept but not applied: \(hold).")
                .foregroundStyle(.orange)
        } else if let error = persister.lastError, error.scope == scope || error.scope == .general {
            Text(error.message)
                .foregroundStyle(.red)
        }
    }
}
