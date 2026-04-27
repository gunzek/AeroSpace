import AppKit
import Common
import SwiftUI
import UniformTypeIdentifiers

public let settingsWindowId = "\(aeroSpaceAppName).settings"

@MainActor
public func getSettingsWindow() -> some Scene {
    SwiftUI.Window("AeroSpace Settings", id: settingsWindowId) {
        SettingsView()
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                for window in NSApplication.shared.windows where window.identifier?.rawValue == settingsWindowId {
                    window.level = .normal
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
            }
            .onDisappear {
                NSApp.setActivationPolicy(.accessory)
            }
    }
    .windowResizability(.contentMinSize)
}

struct SettingsView: View {
    @State private var selection: SettingsSection = .appRouting
    @StateObject private var store = UISettingsStore.shared

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch selection {
                    case .appRouting:  AppRoutingSection(store: store)
                    case .homepage:    HomepageSection(store: store)
                    case .keybindings: KeybindingsSection(store: store)
                    case .gaps:        GapsSection(store: store)
                    case .catchAll:    CatchAllSection(store: store)
                    case .tweaks:      TweaksSection()
                    case .about:       AboutSection(store: store)
                }
            }
            .frame(minWidth: 480, minHeight: 360)
        }
        .frame(minWidth: 720, minHeight: 460)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case appRouting
    case homepage
    case keybindings
    case gaps
    case catchAll
    case tweaks
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
            case .appRouting:  return "App Routing"
            case .homepage:    return "Homepage"
            case .keybindings: return "Keybindings"
            case .gaps:        return "Gaps"
            case .catchAll:    return "Catch-all"
            case .tweaks:      return "Tweaks"
            case .about:       return "About"
        }
    }

    var systemImage: String {
        switch self {
            case .appRouting:  return "rectangle.3.group"
            case .homepage:    return "house"
            case .keybindings: return "keyboard"
            case .gaps:        return "ruler"
            case .catchAll:    return "tray.2"
            case .tweaks:      return "gearshape.2"
            case .about:       return "info.circle"
        }
    }
}

private struct AppRoutingSection: View {
    @ObservedObject var store: UISettingsStore
    @State private var draft: [AppRoutingRule] = []
    @State private var saveStatus: SaveStatus = .clean

    enum SaveStatus: Equatable {
        case clean
        case dirty
        case saving
        case error(String)
        case saved

        var isDirty: Bool { self != .clean && self != .saved }
    }

    var body: some View {
        SettingsScaffold(title: "App Routing") {
            Text("Pin apps to specific workspaces. Save writes the rules into ~/.aerospace.toml and reloads AeroSpace.")
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    addAppFromPicker()
                } label: {
                    Label("Add app…", systemImage: "plus")
                }
                Spacer()
                Text("\(draft.count) rule\(draft.count == 1 ? "" : "s")")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach($draft) { $rule in
                        AppRoutingRow(
                            rule: $rule,
                            conflictsWith: conflictsByRule[rule.id] ?? [],
                            onDelete: { remove(rule) },
                        )
                        .onChange(of: rule) { _ in markDirty() }
                    }
                    if draft.isEmpty {
                        Text("No rules yet. Click \u{201C}Add app\u{2026}\u{201D} to pick an app from /Applications.")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }
                }
            }
            .frame(minHeight: 160)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack {
                statusLabel
                Spacer()
                Button("Apply to open windows") { applyNow() }
                    .help("Move every currently-open app from your routing list to its assigned workspace and slot, without needing a Save first.")
                    .disabled(store.state.appRouting.isEmpty)
                Button("Discard") { resetDraft() }
                    .disabled(!saveStatus.isDirty)
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!saveStatus.isDirty || hasInvalidRules || hasConflicts)
            }
        }
        .onAppear { resetDraft() }
        .onChange(of: store.state.appRouting) { newValue in
            // External update wins only if the user hasn't started editing.
            if !saveStatus.isDirty { draft = newValue }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if hasConflicts {
            Label("Slot conflict — fix the highlighted rows", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.caption)
        } else {
            switch saveStatus {
                case .clean:                EmptyView()
                case .dirty:                Text("Unsaved changes").foregroundStyle(.orange).font(.caption)
                case .saving:               Text("Saving\u{2026}").foregroundStyle(.secondary).font(.caption)
                case .error(let message):   Text(message).foregroundStyle(.red).font(.caption).lineLimit(2)
                case .saved:                Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            }
        }
    }

    private var hasInvalidRules: Bool {
        draft.contains { rule in
            rule.workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || rule.workspace.contains("'")
                || rule.appId.contains("'")
        }
    }

    /// For each rule with at least one overlap, the names of the colliding rules.
    /// Two rules collide when they target the same workspace and their slots overlap
    /// (e.g. `leftHalf` overlaps `topLeft`). Used to disable Save and surface a row warning.
    private var conflictsByRule: [UUID: [String]] {
        var result: [UUID: [String]] = [:]
        for a in draft {
            let cleanA = a.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanA.isEmpty else { continue }
            let collisions = draft.filter { b in
                guard a.id != b.id else { return false }
                let cleanB = b.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleanA == cleanB && a.slot.overlaps(b.slot)
            }
            if !collisions.isEmpty { result[a.id] = collisions.map(\.displayName) }
        }
        return result
    }

    private var hasConflicts: Bool { !conflictsByRule.isEmpty }

    private func resetDraft() {
        draft = store.state.appRouting
        saveStatus = .clean
    }

    private func markDirty() {
        if saveStatus != .dirty { saveStatus = .dirty }
    }

    private func remove(_ rule: AppRoutingRule) {
        draft.removeAll { $0.id == rule.id }
        markDirty()
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
        if draft.contains(where: { $0.appId == id }) {
            saveStatus = .error("\(displayName) is already in the list.")
            return
        }
        let rule = AppRoutingRule(
            appId: id,
            displayName: displayName,
            appPath: url.path,
            workspace: "",
        )
        draft.append(rule)
        markDirty()
    }

    private func applyNow() {
        // Force-reapply current saved rules to live windows. Useful when
        // users edit JSON directly or when Save is greyed-out (no dirty
        // changes) but they still want existing windows to snap to layout.
        saveStatus = .saving
        Task { @MainActor in
            if let token: RunSessionGuard = .isServerEnabled {
                try? await runLightSession(.menuBarButton, token) {
                    await reapplyRoutingAndSlotsToAllWindows()
                }
            } else {
                await reapplyRoutingAndSlotsToAllWindows()
            }
            saveStatus = .saved
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if saveStatus == .saved { saveStatus = .clean }
        }
    }

    private func save() {
        let snapshot = draft
        saveStatus = .saving
        Task { @MainActor in
            do {
                var next = store.state
                next.appRouting = snapshot
                try store.replace(next)
                let configUrl = SettingsConfigPath.aerospaceTomlUrl()
                try TomlMarkerWriter.writeBlock(state: next, to: configUrl)
                if let token: RunSessionGuard = .isServerEnabled {
                    try await runLightSession(.menuBarButton, token) {
                        _ = try await reloadConfig()
                        // Phase 3.6 follow-up: snap currently-open windows to the new
                        // routing rules (move to target workspace) AND any new slot
                        // assignments. Without this, Save would only affect *future*
                        // windows — already-open apps would stay where they are.
                        await reapplyRoutingAndSlotsToAllWindows()
                    }
                }
                saveStatus = .saved
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if saveStatus == .saved { saveStatus = .clean }
            } catch {
                saveStatus = .error("Save failed: \(error)")
            }
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
                TextField("workspace", text: Binding(
                    get: { rule.workspace },
                    set: { rule.workspace = $0.uppercased() },
                ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                Picker("", selection: $rule.slot) {
                    ForEach(Slot.allCases) { slot in
                        Text(slot.displayName).tag(slot)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(hasConflict ? Color.orange : Color.clear, lineWidth: 1.5),
        )
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
/// row exposes title substring + optional workspace + optional slot. Saving
/// these rules persists into the JSON sidecar; the placement happens at
/// runtime via SlotPlacement (no TOML side — purely Swift hook).
private struct WindowMatcherList: View {
    @Binding var matchers: [WindowMatcher]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Window-specific overrides (first match wins, by case-insensitive substring of window title)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(matchers.enumerated()), id: \.element.id) { idx, _ in
                HStack(spacing: 8) {
                    TextField("title contains…", text: Binding(
                        get: { matchers[idx].titleSubstring },
                        set: { matchers[idx].titleSubstring = $0 },
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    Text("→")
                        .foregroundStyle(.tertiary)
                    TextField("workspace", text: Binding(
                        get: { matchers[idx].workspaceOverride ?? "" },
                        set: { newValue in
                            let cleaned = newValue.uppercased()
                            matchers[idx].workspaceOverride = cleaned.isEmpty ? nil : cleaned
                        },
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    Picker("", selection: Binding<Slot?>(
                        get: { matchers[idx].slotOverride },
                        set: { matchers[idx].slotOverride = $0 },
                    )) {
                        Text("(inherit slot)").tag(Slot?.none)
                        ForEach(Slot.allCases) { slot in
                            Text(slot.displayName).tag(Slot?.some(slot))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
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
                    matchers.append(WindowMatcher())
                } label: {
                    Label("Add window rule", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
        }
    }
}

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

private struct HomepageSection: View {
    @ObservedObject var store: UISettingsStore
    @State private var launching = false

    var body: some View {
        SettingsScaffold(title: "Homepage") {
            Text("One click launches every app in the App Routing list. Each lands on its pinned workspace via the rules saved to ~/.aerospace.toml.")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    launchNow()
                } label: {
                    Label(launching ? "Launching\u{2026}" : "Launch Homepage Now", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.state.appRouting.isEmpty || launching)

                Text("\(store.state.appRouting.count) app\(store.state.appRouting.count == 1 ? "" : "s") will open")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Toggle("Launch on AeroSpace startup", isOn: Binding(
                get: { store.state.homepage.launchOnStartup },
                set: { newValue in
                    try? store.update { $0.homepage.launchOnStartup = newValue }
                },
            ))
            .toggleStyle(.switch)

            if store.state.appRouting.isEmpty {
                Text("Add at least one App Routing rule before this does anything.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private func launchNow() {
        launching = true
        let snapshot = store.state
        Task { @MainActor in
            await launchHomepage(snapshot)
            launching = false
        }
    }
}

private struct ComingSoonView: View {
    let title: String
    let phase: String

    var body: some View {
        SettingsScaffold(title: title) {
            Text("Planned for \(phase).")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct KeybindingsSection: View {
    @ObservedObject var store: UISettingsStore
    @State private var draft: [KeybindingRule]? = nil
    @State private var saveStatus: String? = nil
    @State private var dirty: Bool = false

    private var managed: Bool { draft != nil }

    var body: some View {
        SettingsScaffold(title: "Keybindings") {
            Text("UI-managed `[mode.main.binding]` table. When enabled, Settings UI owns this section — remove any `[mode.main.binding]` table from ~/.aerospace.toml first or Save will refuse.")
                .foregroundStyle(.secondary)

            Toggle("Manage keybindings from this UI", isOn: Binding(
                get: { managed },
                set: { newValue in
                    draft = newValue ? (draft ?? []) : nil
                    dirty = true
                },
            ))
            .toggleStyle(.switch)

            if managed, hasUnmanagedBlockInToml() {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Existing [mode.main.binding] found in your TOML", systemImage: "info.circle")
                            .font(.subheadline)
                        Text("Click \u{201C}Import existing bindings\u{201D} to pull every shortcut from your raw config into this list and have Settings UI take over from there. The original section will be removed on the next Save.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Import existing bindings") { importFromConfig() }
                            .buttonStyle(.bordered)
                    }
                    .padding(8)
                }
            }

            if let bindings = draft {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(bindings.enumerated()), id: \.element.id) { idx, _ in
                            KeybindingRow(
                                shortcut: shortcutBinding(at: idx),
                                action: actionBinding(at: idx),
                                onDelete: {
                                    draft?.remove(at: idx)
                                    dirty = true
                                },
                            )
                        }
                        if bindings.isEmpty {
                            Text("No bindings yet. Click \u{201C}Add binding\u{201D} below.")
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 16)
                        }
                    }
                }
                .frame(minHeight: 160)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack {
                    Button {
                        draft?.append(KeybindingRule(shortcut: "", action: "workspace "))
                        dirty = true
                    } label: {
                        Label("Add binding", systemImage: "plus")
                    }
                    Spacer()
                }

                Text("Pick an action from the dropdown — it covers the common AeroSpace commands so you don't have to memorise the syntax. \u{201C}Custom (raw action)\u{201D} lets you type any AeroSpace command verbatim.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let saveStatus {
                    Text(saveStatus)
                        .font(.caption)
                        .foregroundStyle(saveStatus.hasPrefix("Error") ? .red : .secondary)
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!dirty)
            }
            Spacer()
        }
        .onAppear { draft = store.state.keybindings; dirty = false }
        .onChange(of: store.state.keybindings) { newValue in
            if !dirty { draft = newValue }
        }
    }

    private func shortcutBinding(at idx: Int) -> Binding<String> {
        Binding(
            get: { draft?[idx].shortcut ?? "" },
            set: { draft?[idx].shortcut = $0; dirty = true },
        )
    }

    private func actionBinding(at idx: Int) -> Binding<String> {
        Binding(
            get: { draft?[idx].action ?? "" },
            set: { draft?[idx].action = $0; dirty = true },
        )
    }

    private func save() {
        let snapshot = draft
        Task { @MainActor in
            do {
                var next = store.state
                next.keybindings = snapshot
                try store.replace(next)
                let configUrl = SettingsConfigPath.aerospaceTomlUrl()
                try TomlMarkerWriter.writeBlock(state: next, to: configUrl)
                if let token: RunSessionGuard = .isServerEnabled {
                    try await runLightSession(.menuBarButton, token) { _ = try await reloadConfig() }
                }
                dirty = false
                saveStatus = "Saved"
            } catch TomlMarkerWriter.WriteError.duplicateBindingSection {
                saveStatus = "Error: remove the existing [mode.main.binding] table from ~/.aerospace.toml before enabling UI-managed keybindings."
            } catch let TomlMarkerWriter.WriteError.unsafeLiteral(field, value) {
                saveStatus = "Error: \(field) contains an unsafe character ('\(value)'). Single quotes are not allowed."
            } catch {
                saveStatus = "Error: \(error)"
            }
        }
    }

    /// Cache-free check: re-reads the TOML each time it's queried so the banner
    /// disappears immediately after the user clicks Import & Save.
    private func hasUnmanagedBlockInToml() -> Bool {
        let url = SettingsConfigPath.aerospaceTomlUrl()
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return TomlMarkerWriter.hasUnmanagedBindingSection(in: raw)
    }

    /// Pull every shortcut from the user's raw `[mode.main.binding]` table
    /// into the draft list, then strip the section from the TOML so the next
    /// Save can write a clean marker block. We strip *before* Save (not as
    /// part of writeBlock) so an aborted import leaves the TOML intact.
    private func importFromConfig() {
        let url = SettingsConfigPath.aerospaceTomlUrl()
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            saveStatus = "Error: couldn't read \(url.path)"
            return
        }
        let extracted = TomlMarkerWriter.extractBindingSection(from: raw)
        if extracted.isEmpty {
            saveStatus = "No bindings found in [mode.main.binding] — nothing to import."
            return
        }
        // Drop the original section now so the "duplicate" banner clears, but
        // KEEP the AEROSPACE-UI markers and everything else.
        let stripped = TomlMarkerWriter.stripBindingSection(from: raw)
        do {
            try stripped.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            saveStatus = "Error stripping original section: \(error)"
            return
        }
        // Append imported rules to the existing draft (deduped by shortcut so
        // a re-import doesn't double up).
        var existing = draft ?? []
        let existingShortcuts = Set(existing.map(\.shortcut))
        for (shortcut, action) in extracted where !existingShortcuts.contains(shortcut) {
            existing.append(KeybindingRule(shortcut: shortcut, action: action))
        }
        draft = existing
        dirty = true
        saveStatus = "Imported \(extracted.count) binding\(extracted.count == 1 ? "" : "s") — click Save to write the marker block."
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
    let onDelete: () -> Void

    private var template: KeybindingActionTemplate {
        KeybindingActionTemplate.detect(from: action)
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
            TextField("alt-q", text: $shortcut)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .font(.system(.body, design: .monospaced))
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
                TextField("workspace name", text: Binding(
                    get: { parameter },
                    set: { newParam in
                        action = template.render(parameter: newParam.uppercased())
                    },
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .font(.system(.body, design: .monospaced))
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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct CatchAllSection: View {
    @ObservedObject var store: UISettingsStore
    @State private var newWorkspaceField: String = ""

    var body: some View {
        let settings = store.state.catchAll

        SettingsScaffold(title: "Catch-all workspaces") {
            Text("When a homepage workspace already holds enough windows, redirect new unrouted apps to a catch-all workspace instead of cramming them in. Routed apps always land on their pinned workspace regardless.")
                .foregroundStyle(.secondary)

            Toggle("Reserve homepage workspaces", isOn: Binding(
                get: { settings.enabled },
                set: { newValue in mutate { $0.enabled = newValue } },
            ))
            .toggleStyle(.switch)

            HStack {
                Text("Window limit per workspace").frame(width: 200, alignment: .leading)
                Stepper(value: Binding(
                    get: { settings.workspaceLimit },
                    set: { newValue in mutate { $0.workspaceLimit = max(1, newValue) } },
                ), in: 1 ... 10) {
                    Text("\(settings.workspaceLimit)")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 32, alignment: .trailing)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Catch-all workspaces (round-robin order)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if settings.catchAllWorkspaces.isEmpty {
                    Text("None — add at least one to enable redirection.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(Array(settings.catchAllWorkspaces.enumerated()), id: \.offset) { idx, name in
                        HStack {
                            Text("\(idx + 1).")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(name)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button(role: .destructive) {
                                mutate { $0.catchAllWorkspaces.remove(at: idx) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                HStack {
                    TextField("workspace name (e.g. t)", text: $newWorkspaceField)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") { addWorkspace() }
                        .disabled(newWorkspaceField.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Spacer()
        }
    }

    private func addWorkspace() {
        let name = newWorkspaceField.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        mutate { settings in
            if !settings.catchAllWorkspaces.contains(name) {
                settings.catchAllWorkspaces.append(name)
            }
        }
        newWorkspaceField = ""
    }

    private func mutate(_ change: (inout CatchAllSettings) -> Void) {
        var settings = store.state.catchAll
        change(&settings)
        try? store.update { $0.catchAll = settings }
    }
}

private struct GapsSection: View {
    @ObservedObject var store: UISettingsStore
    @State private var draft: GapsSettings? = nil
    @State private var saveStatus: String? = nil

    private var managed: Bool { draft != nil }

    var body: some View {
        SettingsScaffold(title: "Gaps") {
            Text("Padding between tiled windows and the screen edges. When enabled, Settings UI owns the `[gaps]` section in ~/.aerospace.toml — the raw `[gaps]` block (if any) must be removed first.")
                .foregroundStyle(.secondary)

            Toggle("Manage gaps from this UI", isOn: Binding(
                get: { managed },
                set: { newValue in
                    draft = newValue ? (draft ?? GapsSettings()) : nil
                    persist()
                },
            ))
            .toggleStyle(.switch)

            if let bound = draft {
                let binding = Binding<GapsSettings>(
                    get: { bound },
                    set: { newValue in draft = newValue; persist() },
                )
                VStack(spacing: 8) {
                    GapSlider(label: "Inner horizontal", value: binding.innerHorizontal)
                    GapSlider(label: "Inner vertical",   value: binding.innerVertical)
                    GapSlider(label: "Outer horizontal", value: binding.outerHorizontal)
                    GapSlider(label: "Outer vertical",   value: binding.outerVertical)
                }
                .padding(8)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let saveStatus {
                Text(saveStatus)
                    .font(.caption)
                    .foregroundStyle(saveStatus.hasPrefix("Error") ? .red : .secondary)
            }
            Spacer()
        }
        .onAppear { draft = store.state.gaps }
        .onChange(of: store.state.gaps) { newValue in
            // External update wins only if user hasn't been touching the sliders.
            if draft != newValue { draft = newValue }
        }
    }

    private func persist() {
        let snapshot = draft
        Task { @MainActor in
            do {
                var next = store.state
                next.gaps = snapshot
                try store.replace(next)
                let configUrl = SettingsConfigPath.aerospaceTomlUrl()
                try TomlMarkerWriter.writeBlock(state: next, to: configUrl)
                if let token: RunSessionGuard = .isServerEnabled {
                    try await runLightSession(.menuBarButton, token) { _ = try await reloadConfig() }
                }
                saveStatus = "Saved"
            } catch TomlMarkerWriter.WriteError.duplicateGapsSection {
                saveStatus = "Error: remove the existing [gaps] block from ~/.aerospace.toml before enabling UI-managed gaps."
            } catch {
                saveStatus = "Error: \(error)"
            }
        }
    }
}

private struct GapSlider: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        HStack {
            Text(label).frame(width: 140, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0.rounded()) },
                ),
                in: 0 ... 50,
                step: 1,
            )
            Text("\(value) px")
                .font(.system(.body, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
        }
    }
}

private struct TweaksSection: View {
    @State private var resizeSpedUp = SystemTweaks.isResizeSpedUp()

    var body: some View {
        SettingsScaffold(title: "Tweaks") {
            Text("System-wide adjustments that complement AeroSpace. These touch macOS defaults outside the app.")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Speed up window resize animations (macOS-wide)", isOn: Binding(
                        get: { resizeSpedUp },
                        set: { newValue in
                            _ = SystemTweaks.setResizeSpedUp(newValue)
                            resizeSpedUp = SystemTweaks.isResizeSpedUp()
                        },
                    ))
                    .toggleStyle(.switch)
                    Text("Sets `NSWindowResizeTime` to ~0.001 s. macOS default is ~0.2 s, which dominates the perceived latency when AeroSpace re-tiles a workspace. Most apps pick the new value up immediately; some need a relaunch.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }
            Spacer()
        }
    }
}

private struct AboutSection: View {
    @ObservedObject var store: UISettingsStore

    var body: some View {
        SettingsScaffold(title: "About") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(aeroSpaceAppName) v\(aeroSpaceAppVersion)")
                    .font(.headline)
                Text("Personal fork — \(gitShortHash)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Divider().padding(.vertical, 4)
                Text("UI state file:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(store.url.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.url])
                    }
                    .controlSize(.small)
                    .disabled(!FileManager.default.fileExists(atPath: store.url.path))
                }
            }
            Spacer()
        }
    }
}

private struct SettingsScaffold<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
