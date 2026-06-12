import Foundation

/// Whole-state validity for the live-save settings model.
///
/// The pinned semantics say "while state is invalid the TOML sync is HELD" —
/// and `SettingsPersister` always projects the FULL store state, so the hold
/// must be global, not per-section: a Gaps slider drag must never flush a
/// held duplicate-shortcut draft from Keybindings into the TOML. This enum is
/// the single source of truth: the persister consults `holdReason(for:)`
/// before every write, and the sections reuse the same helpers for their
/// inline captions, so the UI warnings and the persister-level hold can never
/// disagree about what counts as invalid.
enum SettingsValidity {
    // MARK: keybindings

    /// Set of shortcuts that appear more than once (case-insensitive,
    /// whitespace-trimmed). Empty shortcut is excluded — it means an
    /// in-progress row the user hasn't typed yet (handled by the
    /// incomplete-row hold instead).
    static func duplicateShortcutSet(in bindings: [KeybindingRule]) -> Set<String> {
        var seen: Set<String> = []
        var dups: Set<String> = []
        for b in bindings {
            let sc = normalizedShortcut(b.shortcut)
            guard !sc.isEmpty else { continue }
            if seen.contains(sc) { dups.insert(sc) } else { seen.insert(sc) }
        }
        return dups
    }

    /// Canonical form used for duplicate detection (and import dedupe, so the
    /// two can't disagree): trimmed + lowercased.
    static func normalizedShortcut(_ shortcut: String) -> String {
        shortcut.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// A row is incomplete while the shortcut is empty or a parameterised
    /// template (e.g. "Switch to workspace…") still misses its parameter.
    /// Such rows hold the TOML sync — TomlMarkerWriter would silently skip an
    /// empty-shortcut row, but a "workspace " action with no target would be
    /// written verbatim and break reload-config.
    static func isIncompleteKeybinding(_ rule: KeybindingRule) -> Bool {
        if rule.shortcut.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        let template = template(for: rule.action)
        return template.requiresParameter
            && KeybindingActionTemplate.parameter(from: rule.action, given: template)
                .trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Template detection that survives a missing parameter. `detect(from:)`
    /// trims before its prefix checks, so a parameterised action whose
    /// argument is still empty ("workspace " — exactly what "Add binding"
    /// creates and what clearing the workspace combo produces) trims to
    /// "workspace", misses the `"workspace "` prefix check, and falls through
    /// to `.custom`. That bounced the row's picker to "Custom (raw action)"
    /// mid-edit AND slipped past the incomplete-row hold (`.custom` requires
    /// no parameter), letting an argument-less `'workspace'` action reach the
    /// TOML and break reload-config. Map the bare command words back to their
    /// parameterised templates before falling back to detect.
    static func template(for action: String) -> KeybindingActionTemplate {
        let trimmed = action.trimmingCharacters(in: .whitespaces)
        if trimmed == KeybindingActionTemplate.workspaceSwitch.rawValue { return .workspaceSwitch }
        if trimmed == KeybindingActionTemplate.workspaceMoveTo.rawValue { return .workspaceMoveTo }
        return KeybindingActionTemplate.detect(from: action)
    }

    /// TomlMarkerWriter writes the shortcut as a bare TOML key
    /// (`alt-q = 'workspace Q'`) with no quoting — only the action side goes
    /// through requireSafeLiteral. Any character outside TOML's bare-key set
    /// (A-Z a-z 0-9 `_` `-`) therefore corrupts the whole config file: a
    /// space splits the key, `#` comments out the rest of the line, `=`
    /// breaks the assignment. Every AeroSpace notation (letters, digits,
    /// dashes: "alt-shift-q", "cmd-keypad7") fits the set; only the raw-edit
    /// fallback can produce anything else, and such a row holds the sync.
    static func isUnsafeShortcut(_ shortcut: String) -> Bool {
        let sc = shortcut.trimmingCharacters(in: .whitespaces)
        guard !sc.isEmpty else { return false } // empty = incomplete-row hold's job
        return !sc.unicodeScalars.allSatisfy { Self.tomlBareKeyScalars.contains($0) }
    }

    private static let tomlBareKeyScalars =
        CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    // MARK: app routing

    /// A routing rule is invalid while its workspace is empty or any literal
    /// contains a single quote (TomlMarkerWriter writes single-quoted TOML
    /// literals, so a `'` would break the file).
    static func isInvalidRoutingRule(_ rule: AppRoutingRule) -> Bool {
        rule.workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || rule.workspace.contains("'")
            || rule.appId.contains("'")
    }

    /// For each rule with at least one overlap, the names of the colliding
    /// rules. Two rules collide when they target the same workspace and their
    /// slots overlap (e.g. `leftHalf` overlaps `topLeft`). Used to hold the
    /// TOML sync and surface a row warning.
    static func routingConflicts(in rules: [AppRoutingRule]) -> [UUID: [String]] {
        var result: [UUID: [String]] = [:]
        for a in rules {
            let cleanA = a.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanA.isEmpty else { continue }
            let collisions = rules.filter { b in
                guard a.id != b.id else { return false }
                let cleanB = b.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleanA == cleanB && a.slot.overlaps(b.slot)
            }
            if !collisions.isEmpty { result[a.id] = collisions.map(\.displayName) }
        }
        return result
    }

    // MARK: whole-state predicate

    /// nil = the state is valid and safe to project into TOML.
    /// non-nil = a short human-readable reason why the sync is held; the
    /// message names the offending section so a footer in any section can
    /// point the user at the right place.
    static func holdReason(for state: UIState) -> String? {
        let bindings = state.keybindings ?? []
        if !duplicateShortcutSet(in: bindings).isEmpty {
            return "Keybindings has duplicate shortcuts"
        }
        if bindings.contains(where: isIncompleteKeybinding) {
            return "a keybinding row is missing its shortcut or workspace"
        }
        if bindings.contains(where: { isUnsafeShortcut($0.shortcut) }) {
            return "a keybinding shortcut contains characters that can't be written to TOML"
        }
        if state.appRouting.contains(where: isInvalidRoutingRule) {
            return "an App Routing rule has an empty or invalid workspace"
        }
        if !routingConflicts(in: state.appRouting).isEmpty {
            return "App Routing rules have a slot conflict"
        }
        return nil
    }
}
