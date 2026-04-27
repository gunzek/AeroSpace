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
    // Window matchers (any kind) define how many slots this app expects.
    // No matchers → no spawning; the rule's default slot already covers
    // the single-window case.
    let target = rule.windowMatchers.count
    guard target > 0 else { return }

    let currentCount = MacWindow.allWindows.count { $0.app.rawAppBundleId == rule.appId }
    let needed = target - currentCount
    guard needed > 0 else { return }

    guard let runningApp = NSRunningApplication
        .runningApplications(withBundleIdentifier: rule.appId)
        .first
    else { return }

    runningApp.activate()
    // Give macOS a beat to actually shift focus before we post keystrokes.
    // 300 ms feels conservative; some apps (Electron-based) need at least
    // 200 ms to honour the ⌘N keystroke after activation.
    try? await Task.sleep(nanoseconds: 300_000_000)

    let source = CGEventSource(stateID: .hidSystemState)
    let nKeyCode: CGKeyCode = 0x2D // ANSI virtual key for "N"

    for _ in 0..<needed {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: nKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: nKeyCode, keyDown: false)
        else { continue }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        // Pause between repeats so each window fully registers (and gets a
        // unique title) before the next ⌘N goes in. Without this, the second
        // and third events can arrive while the first window is still mid-
        // creation and get dropped or duplicated unpredictably.
        try? await Task.sleep(nanoseconds: 350_000_000)
    }
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
