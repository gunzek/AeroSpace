import SwiftUI

/// Gaps — padding between tiled windows and screen edges. Live model: the
/// JSON sidecar saves on every slider tick; the TOML projection is debounced
/// through SettingsPersister so a drag doesn't re-layout every workspace
/// mid-flight.
struct GapsSection: View {
    @ObservedObject var store: UISettingsStore
    @ObservedObject private var persister = SettingsPersister.shared
    /// Local mirror of `store.state.gaps` so slider bindings have a non-nil
    /// anchor while managed; nil = UI keeps hands off the `[gaps]` section.
    @State private var draft: GapsSettings? = nil

    private var managed: Bool { draft != nil }

    var body: some View {
        Form {
            Section {
                Toggle("Manage gaps from this UI", isOn: Binding(
                    get: { managed },
                    set: { newValue in
                        draft = newValue ? (draft ?? GapsSettings()) : nil
                        persistDraft()
                        // One-shot change that adds/removes the whole [gaps]
                        // block — apply right away, no debounce needed.
                        persister.syncNow()
                    },
                ))
                .toggleStyle(.switch)
            } footer: {
                Text("Padding between tiled windows and the screen edges. When enabled, Settings UI owns the [gaps] section in ~/.aerospace.toml — a raw [gaps] block (if any) must be removed first.")
                    .foregroundStyle(.secondary)
            }

            if let bound = draft {
                let binding = Binding<GapsSettings>(
                    get: { bound },
                    set: { newValue in
                        draft = newValue
                        persistDraft()
                        // Sliders fire on every tick of a drag; the JSON
                        // sidecar tracks each tick, but rewriting the TOML +
                        // reload-config per tick re-layouts every workspace
                        // mid-drag. Debounce so only the final value lands.
                        persister.scheduleSync()
                    },
                )
                Section {
                    GapSlider(label: "Inner horizontal", value: binding.innerHorizontal)
                    GapSlider(label: "Inner vertical",   value: binding.innerVertical)
                    GapSlider(label: "Outer horizontal", value: binding.outerHorizontal)
                    GapSlider(label: "Outer vertical",   value: binding.outerVertical)
                } header: {
                    Text("Gap sizes")
                } footer: {
                    SyncStatusFooter(scope: .gaps)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = store.state.gaps }
        .onChange(of: store.state.gaps) { newValue in
            // External update wins only if user hasn't been touching the sliders.
            if draft != newValue { draft = newValue }
        }
    }

    /// JSON sidecar saves on every change; the TOML side is the persister's
    /// job (debounced or immediate, the caller decides).
    private func persistDraft() {
        try? store.update { $0.gaps = draft }
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
