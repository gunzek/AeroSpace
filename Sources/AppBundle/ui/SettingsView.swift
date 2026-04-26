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
                    case .homepage:    HomepagePlaceholder(store: store)
                    case .keybindings: ComingSoonView(title: "Keybindings", phase: "Phase 2")
                    case .gaps:        ComingSoonView(title: "Gaps", phase: "Phase 2")
                    case .catchAll:    ComingSoonView(title: "Catch-all workspaces", phase: "Phase 3")
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
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
            case .appRouting:  return "App Routing"
            case .homepage:    return "Homepage"
            case .keybindings: return "Keybindings"
            case .gaps:        return "Gaps"
            case .catchAll:    return "Catch-all"
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
                        AppRoutingRow(rule: $rule, onDelete: { remove(rule) })
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
                Button("Discard") { resetDraft() }
                    .disabled(!saveStatus.isDirty)
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!saveStatus.isDirty || hasInvalidRules)
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
        switch saveStatus {
            case .clean:                EmptyView()
            case .dirty:                Text("Unsaved changes").foregroundStyle(.orange).font(.caption)
            case .saving:               Text("Saving\u{2026}").foregroundStyle(.secondary).font(.caption)
            case .error(let message):   Text(message).foregroundStyle(.red).font(.caption).lineLimit(2)
            case .saved:                Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        }
    }

    private var hasInvalidRules: Bool {
        draft.contains { rule in
            rule.workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || rule.workspace.contains("'")
                || rule.appId.contains("'")
        }
    }

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
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            appIcon
                .frame(width: 24, height: 24)
            Text(rule.displayName)
                .frame(minWidth: 120, alignment: .leading)
                .lineLimit(1)
            Text(rule.appId)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            TextField("workspace", text: $rule.workspace)
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
            Picker("", selection: $rule.layout) {
                ForEach(AppLayout.allCases) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 100)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

private struct HomepagePlaceholder: View {
    @ObservedObject var store: UISettingsStore

    var body: some View {
        SettingsScaffold(title: "Homepage") {
            Text("Launch all routed apps with a single click. Wired up after App Routing is in place.")
                .foregroundStyle(.secondary)
            Toggle("Launch on AeroSpace startup", isOn: Binding(
                get: { store.state.homepage.launchOnStartup },
                set: { newValue in
                    try? store.update { $0.homepage.launchOnStartup = newValue }
                },
            ))
            .toggleStyle(.switch)
            .disabled(store.state.appRouting.isEmpty)
            if store.state.appRouting.isEmpty {
                Text("Add at least one App Routing rule first.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
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
