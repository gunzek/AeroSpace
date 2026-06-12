import SwiftUI

/// Tweaks — system-wide adjustments that complement AeroSpace. These touch
/// macOS defaults outside the app, so they bypass both the JSON sidecar and
/// the TOML projection entirely.
struct TweaksSection: View {
    @State private var resizeSpedUp = SystemTweaks.isResizeSpedUp()

    var body: some View {
        Form {
            Section {
                Toggle("Speed up window resize animations (macOS-wide)", isOn: Binding(
                    get: { resizeSpedUp },
                    set: { newValue in
                        _ = SystemTweaks.setResizeSpedUp(newValue)
                        resizeSpedUp = SystemTweaks.isResizeSpedUp()
                    },
                ))
                .toggleStyle(.switch)
            } header: {
                Text("macOS defaults")
            } footer: {
                Text("Sets `NSWindowResizeTime` to ~0.001 s. macOS default is ~0.2 s, which dominates the perceived latency when AeroSpace re-tiles a workspace. Most apps pick the new value up immediately; some need a relaunch.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
