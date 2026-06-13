import SwiftUI

/// Gaps — padding between tiled windows and screen edges. Live model: the
/// JSON sidecar saves on every slider tick; the TOML projection is debounced
/// through SettingsPersister so a drag doesn't re-layout every workspace
/// mid-flight.
struct GapsSection: View {
    @ObservedObject var store: UISettingsStore
    @ObservedObject private var persister = SettingsPersister.shared

    /// nil `store.state.gaps` = UI keeps hands off the `[gaps]` section.
    private var managed: Bool { store.state.gaps != nil }

    var body: some View {
        Form {
            Section {
                Toggle("Manage gaps from this UI", isOn: Binding(
                    get: { managed },
                    set: { newValue in
                        // Enabling seeds an all-zero block; disabling drops it.
                        try? store.update { $0.gaps = newValue ? ($0.gaps ?? GapsSettings()) : nil }
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

            if managed {
                // Bind straight through the store (like CatchAllSection). The
                // get falls back to an all-zero anchor so the sliders always
                // have a non-nil value even mid-flip; the set only fires while
                // `managed`, so it can never resurrect a disabled [gaps] block.
                let binding = Binding<GapsSettings>(
                    get: { store.state.gaps ?? GapsSettings() },
                    set: { newValue in
                        try? store.update { $0.gaps = newValue }
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
