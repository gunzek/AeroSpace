import AppKit
import SwiftUI

/// Combo-box style workspace selector: a free-text field (always editable, so
/// brand-new workspace names can be typed before they exist anywhere) plus a
/// dropdown of every workspace name the app already knows about. Values are
/// stored UPPERCASED — the canonical form used across the UI state, so menu
/// picks and typed text dedupe to the same workspace.
@MainActor
struct WorkspacePicker: View {
    let label: String                  // visible label; "" → no label
    @Binding var workspace: String     // stored UPPERCASED; "" = unset (valid only when allowEmpty)
    var allowEmpty: Bool = false       // "" rendered as "(none)" menu choice

    var body: some View {
        if label.isEmpty {
            control
        } else {
            LabeledContent(label) { control }
        }
    }

    private var control: some View {
        HStack(spacing: 4) {
            TextField(
                "",
                text: uppercasedWorkspace,
                prompt: Text(allowEmpty ? "(none)" : "Workspace"),
            )
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 70, maxWidth: 130)
            Menu {
                if allowEmpty {
                    Button("(none)") { workspace = "" }
                    Divider()
                }
                ForEach(knownWorkspaceNames, id: \.self) { name in
                    Button(name) { workspace = name }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pick from known workspaces")
        }
    }

    /// Uppercase on the way in so the stored value is always canonical no
    /// matter how the user typed it.
    private var uppercasedWorkspace: Binding<String> {
        Binding(
            get: { workspace },
            set: { workspace = $0.uppercased() },
        )
    }

    /// Union of live workspace names and every name already referenced in the
    /// UI state. `Workspace.all` is plain in-memory MainActor state, so it's
    /// always safe to read — when the server is disabled it's merely empty,
    /// and the store-derived names below keep the menu useful.
    private var knownWorkspaceNames: [String] {
        var names: Set<String> = []
        for liveWorkspace in Workspace.all {
            names.insert(liveWorkspace.name.uppercased())
        }
        let state = UISettingsStore.shared.state
        for rule in state.appRouting {
            names.insert(rule.workspace.uppercased())
            for matcher in rule.windowMatchers {
                if let override = matcher.workspaceOverride {
                    names.insert(override.uppercased())
                }
            }
        }
        for catchAllWorkspace in state.catchAll.catchAllWorkspaces {
            names.insert(catchAllWorkspace.uppercased())
        }
        for managed in state.workspaceLimits.workspaces {
            names.insert(managed.name.uppercased())
        }
        // Show the current value too, so a name that came from raw TOML or an
        // old sidecar is visibly part of the menu.
        names.insert(workspace.uppercased())
        names.remove("")
        return names.sorted()
    }
}

// MARK: - Previews

// PreviewProvider (not #Preview) because the package targets macOS 13 and the
// #Preview macro requires macOS 14.
private struct WorkspacePickerPreviewHost: View {
    @State private var workspace = "Q"
    @State private var optionalWorkspace = ""

    var body: some View {
        Form {
            WorkspacePicker(label: "Workspace", workspace: $workspace)
            WorkspacePicker(label: "Override", workspace: $optionalWorkspace, allowEmpty: true)
            WorkspacePicker(label: "", workspace: $workspace)
        }
        .formStyle(.grouped)
        .frame(width: 360)
    }
}

struct WorkspacePicker_Previews: PreviewProvider {
    static var previews: some View {
        WorkspacePickerPreviewHost()
    }
}
