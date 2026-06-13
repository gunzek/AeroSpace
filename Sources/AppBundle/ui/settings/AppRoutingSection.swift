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
    @StateObject private var notice = SettingsNotice()
    @State private var applying = false

    var body: some View {
        // P4 (perf): compute the O(n²) conflict map ONCE per render into a
        // local, instead of re-evaluating the `conflictsByRule` computed
        // property ~2× per row + once in the footer (→ O(n³) per keystroke).
        // Indexed by rule id below; the footer reads emptiness off the same map.
        let conflicts = SettingsValidity.routingConflicts(in: store.state.appRouting)
        return Form {
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
                        persister.sync(immediate: true)
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
                        conflictsWith: conflicts[rule.id] ?? [],
                        onDelete: { remove(rule) },
                    )
                    .listRowBackground(
                        (conflicts[rule.id] ?? []).isEmpty ? nil : Color.orange.opacity(0.15),
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
                statusFooter(hasConflicts: !conflicts.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func statusFooter(hasConflicts: Bool) -> some View {
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
            } else if notice.text != nil {
                notice.view()
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

    // MARK: live mutation plumbing

    // Every edit lands in the store (JSON) first, then the TOML sync runs via
    // `persister.sync(immediate:)`. The validation hold is enforced *inside*
    // the persister (whole-state `SettingsValidity` check before every write),
    // not here — per-section gating couldn't stop a sync triggered from another
    // section from flushing this section's invalid draft into TOML. Row-binding
    // edits stay debounced (the same binding carries typed workspace text);
    // one-shot clicks sync immediately.

    private func ruleBinding(for rule: AppRoutingRule) -> Binding<AppRoutingRule> {
        Binding(
            get: { store.state.appRouting.first { $0.id == rule.id } ?? rule },
            set: { newValue in
                try? store.update { state in
                    guard let idx = state.appRouting.firstIndex(where: { $0.id == rule.id }) else { return }
                    state.appRouting[idx] = newValue
                }
                persister.sync(immediate: false)
            },
        )
    }

    private func remove(_ rule: AppRoutingRule) {
        try? store.update { $0.appRouting.removeAll { $0.id == rule.id } }
        persister.sync(immediate: true) // one-shot click — no debounce
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
            notice.show("\(displayName) is already in the list.")
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
        persister.sync(immediate: false)
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
            notice.show("Applied to open windows.")
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

    /// P4 (perf): cache the per-app icon by path. `NSWorkspace.icon(forFile:)`
    /// is a non-trivial lookup and was being called per row on every render
    /// (i.e. per keystroke anywhere in the section). Icons don't change during
    /// a session, so a process-wide cache is safe. @MainActor-isolated (the
    /// view is), so the unsynchronised static dictionary is single-threaded.
    @MainActor private static var iconCache: [String: NSImage] = [:]
    private static func cachedIcon(forPath path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }

    @ViewBuilder
    private var appIcon: some View {
        if let path = rule.appPath {
            Image(nsImage: Self.cachedIcon(forPath: path))
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
/// Each row exposes title substring + optional workspace + optional slot and
/// works in one of two modes, mirroring SlotPlacement's two-pass resolution:
/// non-empty title = title matcher (checked first, in list order), empty
/// title = claim-on-arrival slot (fills with incoming windows in order).
/// Edits flow through the parent rule binding, so they persist live into the
/// JSON sidecar; the placement happens at runtime via SlotPlacement (no TOML
/// side — purely Swift hook).
private struct WindowMatcherList: View {
    @Binding var matchers: [WindowMatcher]

    /// Set-time-safe element binding: resolves the row by its stable id on
    /// every get/set instead of trusting an index captured at render time.
    /// See the comment inside the ForEach for the failure mode this avoids.
    /// The get-fallback only fires if the row vanished mid-update (the set
    /// guard then drops the write on the floor — nothing to write to).
    private func matcherBinding(for id: UUID) -> Binding<WindowMatcher> {
        Binding(
            get: { matchers.first { $0.id == id } ?? WindowMatcher() },
            set: { newValue in
                guard let i = matchers.firstIndex(where: { $0.id == id }) else { return }
                matchers[i] = newValue
            },
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Per-window overrides. Title rows are checked first, top to bottom \u{2014} the first whose text the window title contains (case-insensitive) wins, even over arrival rows above it. Rows with an empty title are arrival slots: windows that no title row matched claim them in order (Arrival 1 fills first), and closing a window frees its slot for the next one. Order within each kind is priority \u{2014} use the arrows to reorder \u{2014} but reordering only affects windows that arrive or change later; already-placed windows keep their assignment.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(matchers.enumerated()), id: \.element.id) { idx, matcher in
                // `idx` is safe only for RENDER-time decisions (labels,
                // disabled states) — it is recomputed on every body pass.
                // Mutations must NOT capture it: on macOS the NSTextField
                // behind a focused TextField can commit its text while
                // another row's delete/reorder is mid-flight (focus loss
                // during teardown), and a setter firing through a stale idx
                // writes to the wrong row or traps out of bounds. Every
                // binding and button action below therefore re-resolves the
                // row by its stable `id` at set-time.
                let id = matcher.id
                // Trimmed check matches the runtime exactly: SlotPlacement
                // trims whitespace before deciding which pass a matcher
                // belongs to, so a row containing only spaces is still an
                // arrival slot and must show as one.
                let isTitleMatcher = !matcher.titleSubstring
                    .trimmingCharacters(in: .whitespaces).isEmpty
                // Arrival slots fill in list order *among themselves* (title
                // rows don't consume arrival order), so the visible number
                // counts only the empty-title rows above this one. Title rows
                // get a mode word instead of a number — a flat "Slot 3" on a
                // title row would imply arrival ordering it doesn't have.
                let arrivalNumber = matchers[..<idx]
                    .filter { $0.titleSubstring.trimmingCharacters(in: .whitespaces).isEmpty }
                    .count + 1
                HStack(spacing: 8) {
                    // Mode badge — makes the two row kinds tell apart at a
                    // glance even in the dense row: textformat = title
                    // matcher, tray = claim-on-arrival slot.
                    Image(systemName: isTitleMatcher ? "textformat" : "tray")
                        .foregroundStyle(isTitleMatcher ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                        .help(isTitleMatcher
                            ? "Title matcher \u{2014} applies to windows whose title contains the text (case-insensitive)."
                            : "Arrival slot \u{2014} claims the next window of this app that no title matcher caught.")
                    Text(isTitleMatcher ? "Title" : "Arrival \(arrivalNumber)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 56, alignment: .leading)
                    TextField(
                        "title contains\u{2026} (empty = next free window)",
                        text: matcherBinding(for: id).titleSubstring,
                    )
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 200)
                    .help("Case-insensitive \u{201C}contains\u{201D} match against the window title (surrounding spaces are ignored). Leave empty to make this row a claim-on-arrival slot instead.")
                    // Empty = inherit the rule's workspace; the picker
                    // renders that as "(none)" and uppercases typed names,
                    // matching the old TextField's canonicalization.
                    WorkspacePicker(
                        label: "",
                        workspace: Binding(
                            get: { matchers.first { $0.id == id }?.workspaceOverride ?? "" },
                            set: { newValue in
                                guard let i = matchers.firstIndex(where: { $0.id == id }) else { return }
                                matchers[i].workspaceOverride = newValue.isEmpty ? nil : newValue
                            },
                        ),
                        allowEmpty: true,
                    )
                    // nil = inherit the rule's slot (dashed diagram).
                    OptionalSlotPicker(slot: matcherBinding(for: id).slotOverride)
                    Spacer(minLength: 0)
                    // Reorder = priority change in both runtime passes. Drag
                    // (.onMove) needs a real List — this is a VStack nested in
                    // a Form row — so explicit buttons it is. The mutation
                    // goes through the same rule binding as deletes (store
                    // update + debounced sync; matchers are JSON-only anyway,
                    // the TOML projection never sees them).
                    Button {
                        guard let i = matchers.firstIndex(where: { $0.id == id }), i > 0 else { return }
                        matchers.swapAt(i, i - 1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(idx == 0)
                    .help("Move up \u{2014} earlier rows win when several could match. Affects only windows placed from now on.")
                    Button {
                        guard let i = matchers.firstIndex(where: { $0.id == id }), i < matchers.count - 1 else { return }
                        matchers.swapAt(i, i + 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(idx == matchers.count - 1)
                    .help("Move down \u{2014} later rows only get windows the rows above passed on. Affects only windows placed from now on.")
                    Button(role: .destructive) {
                        matchers.removeAll { $0.id == id }
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
                    // New rows start title-agnostic (claim-on-arrival mode);
                    // typing into the title field flips them into title
                    // matchers.
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
