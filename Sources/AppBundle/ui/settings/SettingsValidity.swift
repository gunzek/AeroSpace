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
        let template = KeybindingActionTemplate.detect(from: rule.action)
        return template.requiresParameter
            && KeybindingActionTemplate.parameter(from: rule.action, given: template)
                .trimmingCharacters(in: .whitespaces).isEmpty
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

    /// TomlMarkerWriter writes the action as a single-quoted TOML literal
    /// (`alt-q = 'workspace q'`) and runs it through `requireSafeLiteral`, which
    /// HARD-throws on a `'` or newline. Without this check that throw happened
    /// only at write time → a post-write `.general` sync error that blocked
    /// every section with no culprit row highlighted (H3). Mirror the writer's
    /// rule here so an unsafe action is a HELD state with its row highlighted,
    /// exactly like a duplicate/incomplete shortcut. The validity layer must
    /// never let the writer's safety check be the FIRST place a bad value is
    /// caught.
    static func isUnsafeAction(_ action: String) -> Bool {
        action.contains("'") || action.contains("\n")
    }

    /// The workspace parameter embedded in a `workspace <ws>` /
    /// `move-node-to-workspace <ws>` keybinding action is interpolated unquoted
    /// into the command token, so it has the same constraints as a routing
    /// workspace (no interior whitespace, no `'`). `isUnsafeAction` already
    /// catches the `'`; this adds the interior-whitespace token-break case that
    /// a quote-free action would otherwise sneak past (H2 via keybindings).
    static func hasUnsafeWorkspaceParameter(_ rule: KeybindingRule) -> Bool {
        let template = KeybindingActionTemplate.detect(from: rule.action)
        guard template.requiresParameter else { return false }
        let param = KeybindingActionTemplate.parameter(from: rule.action, given: template)
        return isUnsafeWorkspaceName(param)
    }

    // MARK: workspace name (shared by routing + keybinding workspace params)

    /// A workspace name is unsafe when it can't survive the round-trip into the
    /// managed TOML. Both writers interpolate it UNQUOTED into a command token:
    /// `move-node-to-workspace <ws>` (routing) and `workspace <ws>` /
    /// `move-node-to-workspace <ws>` (keybinding actions). The whole command is
    /// then wrapped in a single-quoted TOML literal and split back into argv on
    /// whitespace by AeroSpace's command parser. So:
    ///   - a `'` or newline breaks the surrounding TOML literal (unsafeLiteral);
    ///   - ANY interior whitespace (space, tab, …) makes the command token split
    ///     into extra argv entries → "too many arguments" → reload-config rejects
    ///     the whole config and falls back to defaults (H2).
    /// The empty check stays the caller's job (it distinguishes an in-progress
    /// row from a genuinely bad one), so this only flags non-empty-but-broken.
    static func isUnsafeWorkspaceName(_ workspace: String) -> Bool {
        let ws = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ws.isEmpty else { return false } // empty handled separately
        if ws.contains("'") { return true }
        // Interior whitespace (after trimming the ends) breaks the bare token.
        return ws.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    // MARK: app routing

    /// A routing rule is invalid while its workspace is empty, contains a single
    /// quote, or contains interior whitespace (any of which corrupts the
    /// unquoted `move-node-to-workspace <ws>` command token), or its appId
    /// contains a single quote (TomlMarkerWriter writes single-quoted TOML
    /// literals, so a `'` would break the file).
    static func isInvalidRoutingRule(_ rule: AppRoutingRule) -> Bool {
        rule.workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isUnsafeWorkspaceName(rule.workspace)
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
        // Action `'`/newline (H3) — held with the row highlighted instead of a
        // post-write hard error from requireSafeLiteral.
        if bindings.contains(where: { isUnsafeAction($0.action) }) {
            return "a keybinding action contains a single quote or newline that can't be written to TOML"
        }
        // Workspace parameter with interior whitespace (H2 via keybindings).
        if bindings.contains(where: hasUnsafeWorkspaceParameter) {
            return "a keybinding targets a workspace name with a space (breaks the command)"
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
