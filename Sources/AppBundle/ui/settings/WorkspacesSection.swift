import SwiftUI

/// Workspaces — declare managed workspaces with optional per-workspace window
/// limits. The ROW ORDER is the overflow priority: when a workspace is full,
/// new/excess windows spill into the first workspace below it (in this list)
/// that still has free space. An empty limit field means unlimited.
///
/// These settings live purely in the JSON sidecar — enforcement is a Swift
/// runtime hook (HomepageReservation), nothing is projected into TOML, so
/// saving to the store is the whole persistence story (no persister sync).
struct WorkspacesSection: View {
    @ObservedObject var store: UISettingsStore

    var body: some View {
        let settings = store.state.workspaceLimits

        Form {
            Section {
                Toggle("Enforce window limits", isOn: Binding(
                    get: { settings.enabled },
                    set: { newValue in mutate { $0.enabled = newValue } },
                ))
                .toggleStyle(.switch)
            } footer: {
                Text("Cap how many windows each workspace holds. When a workspace is full, the next window spills into the first workspace below it in this list that still has room — so the row order is the overflow priority. Leave a limit empty for no cap. Applies to routed apps too.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if settings.workspaces.isEmpty {
                    Text("None — add a workspace to start managing limits.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(settings.workspaces.enumerated()), id: \.offset) { idx, _ in
                        workspaceRow(idx: idx, count: settings.workspaces.count)
                    }
                }
                HStack {
                    Button {
                        mutate { $0.workspaces.append(ManagedWorkspace(name: "", limit: nil)) }
                    } label: {
                        Label("Add workspace", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            } header: {
                Text("Managed workspaces (top row = highest overflow priority)")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func workspaceRow(idx: Int, count: Int) -> some View {
        HStack {
            Text("\(idx + 1).")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tertiary)

            // Name (stored UPPERCASED via WorkspacePicker).
            WorkspacePicker(
                label: "",
                workspace: Binding(
                    get: { store.state.workspaceLimits.workspaces.indices.contains(idx) ? store.state.workspaceLimits.workspaces[idx].name : "" },
                    set: { newValue in mutate { settings in
                        guard settings.workspaces.indices.contains(idx) else { return }
                        settings.workspaces[idx].name = newValue.uppercased()
                    } },
                ),
            )

            Spacer(minLength: 8)

            // Max windows — empty field = unlimited (nil).
            Text("Max")
                .foregroundStyle(.secondary)
            TextField(
                "",
                text: Binding(
                    get: {
                        let ws = store.state.workspaceLimits.workspaces
                        guard ws.indices.contains(idx), let limit = ws[idx].limit, limit > 0 else { return "" }
                        return String(limit)
                    },
                    set: { newValue in mutate { settings in
                        guard settings.workspaces.indices.contains(idx) else { return }
                        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                        if let n = Int(trimmed), n > 0 {
                            settings.workspaces[idx].limit = n
                        } else {
                            settings.workspaces[idx].limit = nil
                        }
                    } },
                ),
                prompt: Text("∞"),
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
            .multilineTextAlignment(.trailing)

            // Reorder — drag (.onMove) needs a real List, but these rows live in
            // a grouped Form, so explicit up/down buttons (matching how the App
            // Routing matcher list reorders).
            Button {
                mutate { settings in
                    guard idx > 0, settings.workspaces.indices.contains(idx) else { return }
                    settings.workspaces.swapAt(idx, idx - 1)
                }
            } label: {
                Image(systemName: "chevron.up")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(idx == 0)
            .help("Move up — higher rows receive overflow first.")

            Button {
                mutate { settings in
                    guard idx < settings.workspaces.count - 1, settings.workspaces.indices.contains(idx) else { return }
                    settings.workspaces.swapAt(idx, idx + 1)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(idx == count - 1)
            .help("Move down — lower rows only get overflow the rows above passed on.")

            Button(role: .destructive) {
                mutate { settings in
                    guard settings.workspaces.indices.contains(idx) else { return }
                    settings.workspaces.remove(at: idx)
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func mutate(_ change: (inout WorkspaceLimitsSettings) -> Void) {
        var settings = store.state.workspaceLimits
        change(&settings)
        try? store.update { $0.workspaceLimits = settings }
    }
}
