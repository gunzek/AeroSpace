import SwiftUI

/// Keybindings — UI-managed `[mode.main.binding]` table. Live model (Phase 7):
/// every edit mutates the JSON sidecar immediately; the TOML projection goes
/// through SettingsPersister. While the list contains duplicate shortcuts or
/// incomplete rows (empty shortcut, missing required parameter) the TOML sync
/// is HELD — the sidecar keeps the draft, the footer explains why nothing
/// applied yet, and no half-finished binding ever reaches the TOML.
struct KeybindingsSection: View {
    @ObservedObject var store: UISettingsStore
    @ObservedObject private var persister = SettingsPersister.shared
    /// Short-lived inline message (import results). Replaces the old
    /// saveStatus label — there is no Save button anymore.
    @State private var notice: String? = nil
    @State private var noticeExpiry: Task<Void, Never>? = nil
    /// Confirmation gate for turning the manage-toggle OFF: that nils the
    /// whole bindings list out of the JSON sidecar *and* the TOML, so one
    /// accidental click must not be enough.
    @State private var confirmDisableManaged = false

    private var managed: Bool { store.state.keybindings != nil }
    private var bindings: [KeybindingRule] { store.state.keybindings ?? [] }

    var body: some View {
        Form {
            Section {
                Toggle("Manage keybindings from this UI", isOn: Binding(
                    get: { managed },
                    set: { newValue in
                        // Live flip between nil ("hands off, TOML is the
                        // user's") and [] (UI owns the table). One-shot
                        // change that adds/removes the whole section —
                        // apply right away, no debounce needed.
                        if newValue || bindings.isEmpty {
                            // Enabling, or disabling an empty list — nothing
                            // destructive, no confirmation needed.
                            try? store.update { $0.keybindings = newValue ? ($0.keybindings ?? []) : nil }
                            syncAfterEdit(immediate: true)
                        } else {
                            // Disabling with rows present destroys the whole
                            // list (sidecar + TOML) — confirm first. The
                            // store stays untouched until confirmed, so a
                            // cancel re-renders the toggle back ON.
                            confirmDisableManaged = true
                        }
                    },
                ))
                .toggleStyle(.switch)
                .alert("Disable UI-managed keybindings?", isPresented: $confirmDisableManaged) {
                    Button("Disable", role: .destructive) {
                        try? store.update { $0.keybindings = nil }
                        syncAfterEdit(immediate: true)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The bindings list will be removed from Settings and ~/.aerospace.toml.")
                }
            } footer: {
                Text("When enabled, Settings UI owns the [mode.main.binding] table in ~/.aerospace.toml. An existing hand-written table must be imported (below) or removed first — TOML doesn\u{2019}t allow two of them.")
                    .foregroundStyle(.secondary)
            }

            if managed, hasUnmanagedBlockInToml() {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Existing [mode.main.binding] found in your TOML", systemImage: "info.circle")
                            .font(.subheadline)
                        Text("Click \u{201C}Import existing bindings\u{201D} to pull every shortcut from your raw config into this list and have Settings UI take over from there. The original section is removed as part of the import; the managed block is written automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // Import strips the user's raw table immediately but
                        // the managed replacement only lands when the sync
                        // can run — so importing while the sync is held would
                        // leave the running config with no bindings table at
                        // all. Blocked until the hold clears.
                        let hold = SettingsValidity.holdReason(for: store.state)
                        Button("Import existing bindings") { importFromConfig() }
                            .buttonStyle(.bordered)
                            .disabled(hold != nil)
                        if let hold {
                            Text("Import is disabled while changes are held (\(hold)) \u{2014} fix the highlighted rows first.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if managed {
                bindingsSection
            }
        }
        .formStyle(.grouped)
    }

    private var bindingsSection: some View {
        let dupShortcuts = SettingsValidity.duplicateShortcutSet(in: bindings)
        return Section {
            ForEach(bindings) { rule in
                let sc = rule.shortcut.trimmingCharacters(in: .whitespaces).lowercased()
                let isDuplicate = !sc.isEmpty && dupShortcuts.contains(sc)
                KeybindingRow(
                    shortcut: shortcutBinding(for: rule),
                    action: actionBinding(for: rule),
                    isDuplicate: isDuplicate,
                    onDelete: { removeRule(rule) },
                )
                .listRowBackground(isDuplicate ? Color.orange.opacity(0.15) : nil)
            }
            if bindings.isEmpty {
                Text("No bindings yet. Click \u{201C}Add binding\u{201D} below.")
                    .foregroundStyle(.secondary)
            }
            Button {
                try? store.update { $0.keybindings?.append(KeybindingRule(shortcut: "", action: "workspace ")) }
                // The fresh row is incomplete (empty shortcut), so this
                // always holds the sync until the user fills it in.
                syncAfterEdit()
            } label: {
                Label("Add binding", systemImage: "plus")
            }
        } header: {
            Text("Bindings")
        } footer: {
            statusFooter
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            if hasDuplicateShortcuts {
                Label("Duplicate shortcuts on the highlighted rows \u{2014} changes are kept but not applied until fixed.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if hasIncompleteRows {
                Label("A row is missing its shortcut or workspace \u{2014} changes are kept but not applied until fixed.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let notice {
                Text(notice)
                    .foregroundStyle(notice.hasPrefix("Error") ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            } else {
                SyncStatusFooter(scope: .keybindings)
            }
            Text("Pick an action from the dropdown \u{2014} \u{201C}Custom (raw action)\u{201D} accepts any AeroSpace command verbatim. Changes are written into ~/.aerospace.toml automatically.")
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: validation

    /// Validation logic lives in `SettingsValidity` (shared with the
    /// persister-level hold) — these are just view-local conveniences for the
    /// footer captions.
    private var hasDuplicateShortcuts: Bool {
        !SettingsValidity.duplicateShortcutSet(in: bindings).isEmpty
    }

    private var hasIncompleteRows: Bool {
        bindings.contains { SettingsValidity.isIncompleteKeybinding($0) }
    }

    // MARK: live mutation plumbing

    /// Every edit lands in the store (JSON) first, then the TOML sync runs.
    /// The validation hold is enforced *inside* the persister (whole-state
    /// `SettingsValidity` check before every write), not here — per-section
    /// gating couldn't stop a sync triggered from another section from
    /// flushing this section's invalid draft into TOML.
    ///
    /// `immediate` rule (consistent across all sections): one-shot discrete
    /// actions (toggles, row delete, import) sync now — a half-second lag on
    /// a single click just feels broken; binding-driven edits that can fire
    /// rapidly (typing, recording, picker churn) stay debounced.
    private func syncAfterEdit(immediate: Bool = false) {
        if immediate {
            persister.syncNow()
        } else {
            persister.scheduleSync()
        }
    }

    private func mutateRule(_ id: UUID, _ change: (inout KeybindingRule) -> Void) {
        try? store.update { state in
            guard var rules = state.keybindings,
                  let idx = rules.firstIndex(where: { $0.id == id }) else { return }
            change(&rules[idx])
            state.keybindings = rules
        }
        syncAfterEdit()
    }

    private func shortcutBinding(for rule: KeybindingRule) -> Binding<String> {
        Binding(
            get: { store.state.keybindings?.first { $0.id == rule.id }?.shortcut ?? rule.shortcut },
            set: { newValue in mutateRule(rule.id) { $0.shortcut = newValue } },
        )
    }

    private func actionBinding(for rule: KeybindingRule) -> Binding<String> {
        Binding(
            get: { store.state.keybindings?.first { $0.id == rule.id }?.action ?? rule.action },
            set: { newValue in mutateRule(rule.id) { $0.action = newValue } },
        )
    }

    private func removeRule(_ rule: KeybindingRule) {
        try? store.update { $0.keybindings?.removeAll { $0.id == rule.id } }
        syncAfterEdit(immediate: true) // one-shot click — no debounce
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeExpiry?.cancel()
        noticeExpiry = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    // MARK: import flow

    /// Cache-free check: re-reads the TOML each time it's queried so the banner
    /// disappears immediately after a successful import.
    private func hasUnmanagedBlockInToml() -> Bool {
        let url = SettingsConfigPath.aerospaceTomlUrl()
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return TomlMarkerWriter.hasUnmanagedBindingSection(in: raw)
    }

    /// Pull every shortcut from the user's raw `[mode.main.binding]` table
    /// into the managed list, then strip the section from the TOML so the
    /// follow-up sync can write a clean marker block. We strip *before*
    /// mutating the store so an aborted import leaves the store intact.
    private func importFromConfig() {
        // Refuse while the sync is held: the strip below removes the user's
        // bindings from the TOML immediately, but the managed replacement can
        // only be written once the state is valid again — importing while
        // held would leave the running config with no bindings table for as
        // long as the hold lasts. (The button is disabled too; this guard
        // keeps the invariant even if the view's hold caption is stale.)
        if let reason = SettingsValidity.holdReason(for: store.state) {
            showNotice("Error: can't import while changes are held (\(reason)) — fix the highlighted rows first.")
            return
        }
        let url = SettingsConfigPath.aerospaceTomlUrl()
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            showNotice("Error: couldn't read \(url.path)")
            return
        }
        let extracted = TomlMarkerWriter.extractBindingSection(from: raw)
        if extracted.isEmpty {
            showNotice("No bindings found in [mode.main.binding] — nothing to import.")
            return
        }
        // Drop the original section now so the "duplicate" banner clears, but
        // KEEP the AEROSPACE-UI markers and everything else.
        let stripped = TomlMarkerWriter.stripBindingSection(from: raw)
        do {
            try stripped.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showNotice("Error stripping original section: \(error)")
            return
        }
        // Append imported rules to the managed list (deduped by shortcut so a
        // re-import doesn't double up; normalized the same way duplicate
        // detection is, so an import can never create a held duplicate). The
        // follow-up sync writes the marker block — no Save click anymore.
        try? store.update { state in
            var existing = state.keybindings ?? []
            var existingShortcuts = Set(existing.map { SettingsValidity.normalizedShortcut($0.shortcut) })
            for (shortcut, action) in extracted {
                let normalized = SettingsValidity.normalizedShortcut(shortcut)
                guard !existingShortcuts.contains(normalized) else { continue }
                existingShortcuts.insert(normalized)
                existing.append(KeybindingRule(shortcut: shortcut, action: action))
            }
            state.keybindings = existing
        }
        syncAfterEdit(immediate: true) // one-shot click — no debounce
        // syncNow refreshes the persister hold synchronously, so this reads
        // the post-import verdict: "applying" only when the sync really runs.
        if let reason = persister.holdReason {
            showNotice("Imported \(extracted.count) binding\(extracted.count == 1 ? "" : "s") — kept but not applied (\(reason)).")
        } else {
            showNotice("Imported \(extracted.count) binding\(extracted.count == 1 ? "" : "s") — applying automatically.")
        }
    }
}

/// One editable row in the Keybindings table. Internally translates between
/// the user-friendly action picker + parameter field and the raw `action`
/// string stored in the rule (e.g. picker = "Switch to workspace…", param =
/// "Q" → action = "workspace Q"). Free-text mode bypasses the picker via
/// the `.custom` template.
private struct KeybindingRow: View {
    @Binding var shortcut: String
    @Binding var action: String
    var isDuplicate: Bool = false
    let onDelete: () -> Void

    private var template: KeybindingActionTemplate {
        // Shared resolution with the validity hold (NOT raw detect): a
        // parameterised action with an empty argument ("workspace ") must
        // keep resolving to its workspace template, or the picker bounces to
        // "Custom (raw action)" the moment the user clears the workspace —
        // and the two must agree on what counts as an incomplete row.
        SettingsValidity.template(for: action)
    }

    private var parameter: String {
        KeybindingActionTemplate.parameter(from: action, given: template)
    }

    private static let groupedTemplates: [(String, [KeybindingActionTemplate])] = {
        var seenOrder: [String] = []
        var byCategory: [String: [KeybindingActionTemplate]] = [:]
        for template in KeybindingActionTemplate.allCases {
            if byCategory[template.category] == nil { seenOrder.append(template.category) }
            byCategory[template.category, default: []].append(template)
        }
        return seenOrder.map { ($0, byCategory[$0] ?? []) }
    }()

    var body: some View {
        HStack(spacing: 8) {
            // Click-to-record (raw-edit fallback behind the pencil); shows
            // its own duplicate warning icon + orange border, so the row
            // doesn't need a separate one.
            ShortcutRecorderField(shortcut: $shortcut, isDuplicate: isDuplicate)
            Text("=")
                .foregroundStyle(.tertiary)
            Picker("", selection: Binding(
                get: { template },
                set: { newTemplate in
                    // Switching templates: keep the parameter when the new
                    // template still wants one (e.g. "Switch to workspace" →
                    // "Move window to workspace" both take a workspace name).
                    let keptParam = newTemplate.requiresParameter ? parameter : ""
                    action = newTemplate.render(parameter: keptParam)
                },
            )) {
                ForEach(Self.groupedTemplates, id: \.0) { category, templates in
                    Section(category) {
                        ForEach(templates) { template in
                            Text(template.displayName).tag(template)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 220, maxWidth: 260)

            if template.requiresParameter {
                // requiresParameter is true only for the workspace templates
                // (switch/move-to), so a workspace combo fits every case.
                // WorkspacePicker uppercases on its own — no .uppercased()
                // needed here.
                WorkspacePicker(label: "", workspace: Binding(
                    get: { parameter },
                    set: { newParam in
                        action = template.render(parameter: newParam)
                    },
                ))
            } else if template == .custom {
                TextField("raw action (e.g. mode service)", text: Binding(
                    get: { parameter },
                    set: { newAction in
                        action = newAction
                    },
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            }

            Spacer(minLength: 0)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}
