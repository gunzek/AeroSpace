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
/// MainActor re-entry guard for `launchHomepage`. The three entry points
/// (startup auto-launch, the `launch-homepage` keybinding command, and the
/// Settings button) can all fire close together. Each launchHomepage run
/// `await`s repeatedly (openApplication, settle sleeps, per-rule ⌘N), and the
/// guards inside `ensureExtraWindowsViaCmdN` read the LIVE window count to
/// decide how many ⌘N to send — so two interleaved runs each see the other's
/// not-yet-registered windows as "still missing" and both keep spawning →
/// overspawn. There's no value in running a second pass concurrently (the
/// in-flight one already reflects the current routing), so a re-entrant call
/// simply NO-OPs and lets the running pass finish. The pre-existing `launching`
/// flag in HomepageSection only debounced the button; this covers all callers.
@MainActor
private var launchHomepageInFlight = false

@MainActor
func launchHomepage(_ state: UIState) async {
    guard !launchHomepageInFlight else {
        print("🏠 LaunchHomepage: already in flight — ignoring re-entrant call")
        return
    }
    launchHomepageInFlight = true
    defer { launchHomepageInFlight = false }
    print("🏠 LaunchHomepage: start, \(state.appRouting.count) rule(s)")
    // Snap any already-open routed apps to their target workspace first
    // (openApplication on an already-running app is a no-op).
    await reapplyRoutingAndSlotsToAllWindows()

    // Phase 1: open every app in parallel. Earlier sequential openApplication
    // was a workaround for a slot-placement race that we've since fixed
    // (see SlotPlacement.swift's idempotency guards). Going back to a
    // TaskGroup brings 9-app launch from ~10 s of openApplication waits
    // down to ~1 s — apps start in parallel.
    await withTaskGroup(of: Void.self) { group in
        for rule in state.appRouting {
            guard let path = rule.appPath, FileManager.default.fileExists(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            let displayName = rule.displayName
            group.addTask {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                } catch {
                    print("🏠 LaunchHomepage: failed to open \(displayName): \(error)")
                }
            }
        }
    }
    print("🏠 LaunchHomepage: open pass done")

    // Phase 2: settle, then spawn extras per rule. Sequential because we
    // need each ensureExtra to "own" focus (activate + ⌘N) without
    // another spawn fighting for it. ensureExtra short-circuits in O(1)
    // for rules with no window matchers (target = 0), so the loop is
    // fast for the common case.
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    for rule in state.appRouting {
        await ensureExtraWindowsViaCmdN(rule: rule)
    }
    print("🏠 LaunchHomepage: done")
}
