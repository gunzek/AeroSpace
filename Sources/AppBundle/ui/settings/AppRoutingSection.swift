import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// App Routing — pin apps to workspaces and slots. Live model (Phase 7):
/// every edit mutates the JSON sidecar immediately; the TOML projection goes
/// through SettingsPersister. While any rule is invalid (empty/quoted
/// workspace, slot conflict) the TOML sync is HELD — the sidecar keeps the
/// draft so nothing is lost, and the footer explains why nothing applied yet.
struct AppRoutingSection: View {
    @ObservedObject var store: UISettingsStore
    @ObservedObject private var persister = SettingsPersister.shared
    /// Short-lived inline message (duplicate-app guard, apply confirmation).
    /// Replaces the old saveStatus label — there is no Save button anymore.
    @State private var notice: String? = nil
    @State private var noticeExpiry: Task<Void, Never>? = nil
    @State private var applying = false

    var body: some View {
        Form {
            // Phase 5 + 6c: two global focus-follow toggles. Saved into the
            // JSON sidecar live. followFocusOnRoute also changes the TOML
            // output (it adds the --focus-follows-window flag to every
            // routing rule), so it additionally schedules a persister sync;
            // the app-level honoring (catch-all + slot placement) is read at
            // runtime so it activates immediately either way.
            Section {
                Toggle("Follow window when routed (auto-switch to workspace)", isOn: Binding(
                    get: { store.state.followFocusOnRoute },
                    set: { newValue in
                        try? store.update { $0.followFocusOnRoute = newValue }
                        // TOML carries this flag — sync it through. One-shot
                        // toggle, so immediately (same rule as everywhere).
                        syncAfterEdit(immediate: true)
                    },
                ))
                .toggleStyle(.switch)

                Toggle("Follow app to its workspace on Dock click", isOn: Binding(
                    get: { store.state.followAppOnDockClick },
                    set: { newValue in
                        // Runtime-only flag (GlobalObserver reads it live) — never
                        // projected into TOML, so no persister sync needed.
                        try? store.update { $0.followAppOnDockClick = newValue }
                    },
                ))
                .toggleStyle(.switch)
            } header: {
                Text("Focus follow")
            } footer: {
                Text("\u{201C}Follow when routed\u{201D} pulls you to a newly opened app\u{2019}s workspace so you see it land. \u{201C}Follow on Dock click\u{201D} switches to the workspace where the clicked app already lives, instead of yanking the window to you. Both apply immediately.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(store.state.appRouting) { rule in
                    AppRoutingRow(
                        rule: ruleBinding(for: rule),
                        conflictsWith: conflictsByRule[rule.id] ?? [],
                        onDelete: { remove(rule) },
                    )
                    .listRowBackground(
                        (conflictsByRule[rule.id] ?? []).isEmpty ? nil : Color.orange.opacity(0.15),
                    )
                }
                if store.state.appRouting.isEmpty {
                    Text("No rules yet. Click \u{201C}Add app\u{2026}\u{201D} to pick an app from /Applications.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        addAppFromPicker()
                    } label: {
                        Label("Add app\u{2026}", systemImage: "plus")
                    }
                    Spacer()
                    Button("Apply to open windows") { applyNow() }
                        .help("Move every currently-open app from your routing list to its assigned workspace and slot right now.")
                        .disabled(store.state.appRouting.isEmpty || applying)
                }
            } header: {
                Text("Rules")
            } footer: {
                statusFooter
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            if hasConflicts {
                Label("Slot conflict between the highlighted rules \u{2014} changes are kept but not applied until fixed.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if hasInvalidRules {
                Label("Every rule needs a workspace (single quotes are not allowed) \u{2014} changes are kept but not applied until fixed.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if applying {
                Text("Applying to open windows\u{2026}")
                    .foregroundStyle(.secondary)
            } else if let notice {
                Text(notice)
                    .foregroundStyle(.secondary)
            } else {
                SyncStatusFooter()
            }
            Text("Rules are written into ~/.aerospace.toml automatically. \(store.state.appRouting.count) rule\(store.state.appRouting.count == 1 ? "" : "s").")
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: validation

    /// Validation logic lives in `SettingsValidity` (shared with the
    /// persister-level hold) — these are just view-local conveniences for the
    /// footer captions and row highlights.
    private var hasInvalidRules: Bool {
        store.state.appRouting.contains { SettingsValidity.isInvalidRoutingRule($0) }
    }

    private var conflictsByRule: [UUID: [String]] {
        SettingsValidity.routingConflicts(in: store.state.appRouting)
    }

    private var hasConflicts: Bool { !conflictsByRule.isEmpty }

    // MARK: live mutation plumbing

    /// Every row edit lands in the store (JSON) first, then the TOML sync is
    /// scheduled. The validation hold is enforced *inside* the persister
    /// (whole-state `SettingsValidity` check before every write), not here —
    /// per-section gating couldn't stop a sync triggered from another section
    /// from flushing this section's invalid draft into TOML.
    ///
    /// `immediate` rule (consistent across all sections): one-shot discrete
    /// actions (toggles, row delete) sync now — a half-second lag on a single
    /// click just feels broken; row-binding edits stay debounced because the
    /// same binding also carries typed workspace text.
    private func syncAfterEdit(immediate: Bool = false) {
        if immediate {
            persister.syncNow()
        } else {
            persister.scheduleSync()
        }
    }

    private func ruleBinding(for rule: AppRoutingRule) -> Binding<AppRoutingRule> {
        Binding(
            get: { store.state.appRouting.first { $0.id == rule.id } ?? rule },
            set: { newValue in
                try? store.update { state in
                    guard let idx = state.appRouting.firstIndex(where: { $0.id == rule.id }) else { return }
                    state.appRouting[idx] = newValue
                }
                syncAfterEdit()
            },
        )
    }

    private func remove(_ rule: AppRoutingRule) {
        try? store.update { $0.appRouting.removeAll { $0.id == rule.id } }
        syncAfterEdit(immediate: true) // one-shot click — no debounce
    }

    private func addAppFromPicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app"
        panel.message = "Pick a .app to pin to a workspace"
        panel.allowedContentTypes = [UTType.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundle = Bundle(url: url)
        let id = bundle?.bundleIdentifier
            ?? url.deletingPathExtension().lastPathComponent
        let displayName = (bundle?.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        if store.state.appRouting.contains(where: { $0.appId == id }) {
            showNotice("\(displayName) is already in the list.")
            return
        }
        let rule = AppRoutingRule(
            appId: id,
            displayName: displayName,
            appPath: url.path,
            workspace: "",
        )
        try? store.update { $0.appRouting.append(rule) }
        // The fresh rule has an empty workspace, so this always holds the
        // sync — exactly right: the footer prompts the user to fill it in.
        syncAfterEdit()
    }

    private func applyNow() {
        // Force-reapply current rules to live windows. Useful when users edit
        // JSON directly, or after rule edits — the persister only runs
        // reload-config, it deliberately never yanks already-open windows
        // around (imagine that on every debounced keystroke).
        applying = true
        Task { @MainActor in
            if let token: RunSessionGuard = .isServerEnabled {
                try? await runLightSession(.menuBarButton, token) {
                    await reapplyRoutingAndSlotsToAllWindows()
                }
            } else {
                await reapplyRoutingAndSlotsToAllWindows()
            }
            applying = false
            showNotice("Applied to open windows.")
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeExpiry?.cancel()
        noticeExpiry = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }
}

private struct AppRoutingRow: View {
    @Binding var rule: AppRoutingRule
    let conflictsWith: [String]
    let onDelete: () -> Void
    @State private var matchersExpanded = false

    private var hasConflict: Bool { !conflictsWith.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                appIcon
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.displayName)
                        .frame(minWidth: 100, alignment: .leading)
                        .lineLimit(1)
                    Text(rule.appId)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(minWidth: 140, alignment: .leading)
                Spacer(minLength: 8)
                // Combo of known workspace names + free text; uppercases on
                // its own, matching the old TextField's canonicalization.
                WorkspacePicker(label: "", workspace: $rule.workspace)
                // Mini screen diagram; click opens the slot grid popover.
                SlotPicker(slot: $rule.slot)
                Picker("", selection: $rule.layout) {
                    ForEach(AppLayout.allCases) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 90)
                if hasConflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Slot overlaps with: " + conflictsWith.joined(separator: ", "))
                }
                Button {
                    matchersExpanded.toggle()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: matchersExpanded ? "chevron.down.circle" : "chevron.right.circle")
                        Text("\(rule.windowMatchers.count)")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .foregroundStyle(rule.windowMatchers.isEmpty ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Per-window overrides — match by window title to put separate windows of the same app on different workspaces or slots.")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if matchersExpanded {
                WindowMatcherList(matchers: $rule.windowMatchers)
                    .padding(.top, 4)
                    .padding(.leading, 36)
                    .padding(.trailing, 8)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let path = rule.appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .foregroundStyle(.secondary)
        }
    }
}

/// Editable list of WindowMatcher overrides for a single AppRoutingRule.
/// First-match-wins; matchers with empty title are inactive (grayed). Each
/// row exposes title substring + optional workspace + optional slot. Edits
/// flow through the parent rule binding, so they persist live into the JSON
/// sidecar; the placement happens at runtime via SlotPlacement (no TOML side
/// — purely Swift hook).
private struct WindowMatcherList: View {
    @Binding var matchers: [WindowMatcher]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Window slots — first window of this app to open takes slot 1, second takes slot 2, and so on. Order in this list = order of priority. Closing a window frees its slot for the next one to arrive.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(matchers.enumerated()), id: \.element.id) { idx, _ in
                HStack(spacing: 8) {
                    Text("Slot \(idx + 1)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 50, alignment: .leading)
                    // Empty = inherit the rule's workspace; the picker
                    // renders that as "(none)" and uppercases typed names,
                    // matching the old TextField's canonicalization.
                    WorkspacePicker(
                        label: "",
                        workspace: Binding(
                            get: { matchers[idx].workspaceOverride ?? "" },
                            set: { newValue in
                                matchers[idx].workspaceOverride = newValue.isEmpty ? nil : newValue
                            },
                        ),
                        allowEmpty: true,
                    )
                    // nil = inherit the rule's slot (dashed diagram).
                    OptionalSlotPicker(slot: $matchers[idx].slotOverride)
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        matchers.remove(at: idx)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
            HStack {
                Button {
                    // New slots are title-agnostic by default — that's the
                    // "claim-on-arrival" mode. The titleSubstring field is
                    // intentionally not surfaced in the UI for now.
                    matchers.append(WindowMatcher())
                } label: {
                    Label("Add window slot", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
        }
    }
}
