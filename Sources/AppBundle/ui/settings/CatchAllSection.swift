import SwiftUI

/// Catch-all workspaces — redirect new unrouted apps off crowded homepage
/// workspaces. Catch-all settings live purely in the JSON sidecar: the
/// redirection is a Swift runtime hook, nothing of it is projected into TOML,
/// so saving to the store is the whole persistence story (no persister sync).
struct CatchAllSection: View {
    @ObservedObject var store: UISettingsStore
    @State private var newWorkspaceField: String = ""

    var body: some View {
        let settings = store.state.catchAll

        Form {
            Section {
                Toggle("Reserve homepage workspaces", isOn: Binding(
                    get: { settings.enabled },
                    set: { newValue in mutate { $0.enabled = newValue } },
                ))
                .toggleStyle(.switch)

                LabeledContent("Window limit per workspace") {
                    Stepper(value: Binding(
                        get: { settings.workspaceLimit },
                        set: { newValue in mutate { $0.workspaceLimit = max(1, newValue) } },
                    ), in: 1 ... 10) {
                        Text("\(settings.workspaceLimit)")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            } footer: {
                Text("When a homepage workspace already holds enough windows, redirect new unrouted apps to a catch-all workspace instead of cramming them in. Routed apps always land on their pinned workspace regardless.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if settings.catchAllWorkspaces.isEmpty {
                    Text("None — add at least one to enable redirection.")
                        .foregroundStyle(.secondary)
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
                    }
                }
                HStack {
                    // SEMANTICS (deliberate change): WorkspacePicker
                    // canonicalizes typed names to UPPERCASE, like every other
                    // workspace field in this UI (routing rules, matcher
                    // overrides, keybinding parameters). Workspace names are
                    // case-sensitive at runtime (Workspace.get(byName:)), so
                    // newly added catch-alls land on e.g. "T" where the old
                    // free-typed field would have produced "t". Names already
                    // stored in the list are NOT rewritten and keep working
                    // exactly as typed — and uppercase is what the reservation
                    // logic compares against anyway, since routing-rule
                    // workspaces have always been uppercased.
                    WorkspacePicker(label: "", workspace: $newWorkspaceField)
                    Button("Add") { addWorkspace() }
                        .disabled(newWorkspaceField.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Catch-all workspaces (round-robin order)")
            }
        }
        .formStyle(.grouped)
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
