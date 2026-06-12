import SwiftUI

/// Homepage — one click launches every app in the App Routing list; each
/// lands on its pinned workspace via the rules saved to ~/.aerospace.toml.
struct HomepageSection: View {
    @ObservedObject var store: UISettingsStore
    @State private var launching = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Button {
                        launchNow()
                    } label: {
                        Label(launching ? "Launching\u{2026}" : "Launch Homepage Now", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.state.appRouting.isEmpty || launching)

                    Spacer()

                    Text("\(store.state.appRouting.count) app\(store.state.appRouting.count == 1 ? "" : "s") will open")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    if store.state.appRouting.isEmpty {
                        Text("Add at least one App Routing rule before this does anything.")
                            .foregroundStyle(.orange)
                    }
                    Text("Launches every app from the App Routing list; each lands on its pinned workspace. Tip: bind a shortcut to \u{201C}Launch Homepage\u{201D} in Keybindings to trigger it without opening Settings.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Launch on AeroSpace startup", isOn: Binding(
                    get: { store.state.homepage.launchOnStartup },
                    set: { newValue in
                        // Read at startup from the JSON sidecar — not part of the
                        // TOML projection, so no persister sync needed.
                        try? store.update { $0.homepage.launchOnStartup = newValue }
                    },
                ))
                .toggleStyle(.switch)
            } footer: {
                Text("Opens the whole homepage automatically every time AeroSpace starts.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
