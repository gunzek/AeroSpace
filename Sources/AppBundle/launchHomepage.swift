import AppKit
import Common
import Foundation

/// Launches every app in the App Routing list.
///
/// The actual placement on the right workspace is handled by the existing
/// `[[on-window-detected]]` rules that the Settings UI writes via
/// TomlMarkerWriter — we just have to *open* the apps; AeroSpace catches the
/// new windows and routes them. We launch in parallel because each macOS
/// `openApplication` round-trip can be 100–300 ms and serial would feel slow
/// when the user has 6+ apps in their homepage.
///
/// `activates = false` keeps focus where the user is; without it the last
/// launched app would steal focus, which is jarring when the goal is bulk
/// startup, not "switch me to this one".
@MainActor
func launchHomepage(_ state: UIState) async {
    print("🏠 LaunchHomepage: start, \(state.appRouting.count) rule(s)")
    // First, snap any *already-open* routed apps to their target workspace
    // (openApplication on an already-running app is a no-op).
    await reapplyRoutingAndSlotsToAllWindows()

    // Per-app sequence: open → wait → spawn extras for THIS app → next.
    // Doing the spawn pass per-app instead of after all apps finished is
    // what fixes the "Spawn missing works, Launch Homepage doesn't" gap:
    // when ensureExtra runs immediately after a single openApplication,
    // the just-launched app is the freshest activation and macOS routes
    // ⌘N to it cleanly. With the previous all-then-ensure shape, by the
    // time we got to the spawn pass some other freshly-opened app had
    // grabbed focus and ⌘N landed on the wrong target.
    for rule in state.appRouting {
        guard let path = rule.appPath, FileManager.default.fileExists(atPath: path) else {
            print("🏠 LaunchHomepage: skip \(rule.displayName) — no appPath or file missing")
            continue
        }
        let url = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        print("🏠 LaunchHomepage: open \(rule.displayName) (\(rule.appId))")
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            print("🏠 LaunchHomepage: failed to open \(rule.displayName): \(error)")
            continue
        }
        // Long enough that the just-launched app's first window registered
        // in MacWindow.allWindowsMap before ensureExtra reads currentCount.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await ensureExtraWindowsViaCmdN(rule: rule)
        // Small breath between apps so the next openApplication doesn't
        // immediately steal focus from a window we just spawned.
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    print("🏠 LaunchHomepage: done")
}
