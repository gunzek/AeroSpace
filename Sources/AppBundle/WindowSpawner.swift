import AppKit
import Common
import CoreGraphics
import Foundation

/// Sends ⌘N to a target app the right number of times so it ends up with as
/// many windows as the user's AppRoutingRule has slots defined for. macOS
/// `openApplication` is idempotent — calling it on an already-running app
/// just activates it without spawning a window. To honour "I want 2 Finder
/// windows side-by-side", AeroSpace has to actually fire the new-window
/// shortcut itself.
///
/// Uses CGEvent rather than AppleScript so we don't trip the Automation
/// permission dialog (Accessibility, which AeroSpace already has, is
/// sufficient for posting synthetic key events). Activates the target app
/// first via NSRunningApplication so the keystroke lands in the right place,
/// then waits a beat for macOS to take focus before posting the events.
@MainActor
func ensureExtraWindowsViaCmdN(rule: AppRoutingRule) async {
    let target = rule.windowMatchers.count
    guard target > 0 else { return }

    // Retry up to 4 times. Each iteration: re-check window count, activate
    // the app, sleep enough that activation actually lands, post a single
    // ⌘N, sleep so the new window registers, loop. When Launch Homepage
    // fires this right after a flurry of openApplication calls the focus
    // can be racing — the single "activate once and post N events" version
    // missed because some other just-launched app stole focus mid-loop.
    // Per-iteration activate + verify-frontmost survives the race.
    let maxAttempts = max(target, 1) + 3 // give a few retries above the bare minimum
    var attempts = 0
    while attempts < maxAttempts {
        attempts += 1
        let currentCount = MacWindow.allWindows.count { $0.app.rawAppBundleId == rule.appId }
        let needed = target - currentCount
        if needed <= 0 {
            print("ensureExtraWindowsViaCmdN[\(rule.displayName)]: done at attempt \(attempts), have \(currentCount)/\(target)")
            return
        }

        guard let runningApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: rule.appId)
            .first
        else {
            print("ensureExtraWindowsViaCmdN[\(rule.displayName)]: app not running, give up")
            return
        }

        runningApp.activate()
        // Long enough that macOS has actually shifted focus over.
        try? await Task.sleep(nanoseconds: 600_000_000)

        // Verify the right app is frontmost — if Launch Homepage still has
        // another app activating in the background it can steal focus mid-
        // sleep. If we're not on top, re-activate and wait once more.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != rule.appId {
            runningApp.activate()
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let nKeyCode: CGKeyCode = 0x2D
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: nKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: nKeyCode, keyDown: false)
        else {
            print("ensureExtraWindowsViaCmdN[\(rule.displayName)]: failed to build CGEvent")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        print("ensureExtraWindowsViaCmdN[\(rule.displayName)]: posted ⌘N (attempt \(attempts), need \(needed))")

        // Wait for the new window to register before re-checking.
        try? await Task.sleep(nanoseconds: 700_000_000)
    }

    let finalCount = MacWindow.allWindows.count { $0.app.rawAppBundleId == rule.appId }
    print("ensureExtraWindowsViaCmdN[\(rule.displayName)]: gave up after \(maxAttempts) attempts, have \(finalCount)/\(target)")
}

/// Walk every routing rule and ensure each routed app has at least as many
/// windows as it has slots. Used by Launch Homepage and by an explicit UI
/// button so Honza can manually re-trigger the spawn dance when the system
/// drifted (e.g. macOS quit Finder during sleep).
@MainActor
func ensureExtraWindowsForAllRoutedApps() async {
    let state = UISettingsStore.shared.state
    for rule in state.appRouting {
        await ensureExtraWindowsViaCmdN(rule: rule)
    }
}
