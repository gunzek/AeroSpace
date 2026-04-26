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
    let toLaunch: [(URL, String)] = state.appRouting.compactMap { rule in
        guard let path = rule.appPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return (URL(fileURLWithPath: path), rule.displayName)
    }
    if toLaunch.isEmpty { return }

    await withTaskGroup(of: Void.self) { group in
        for (url, name) in toLaunch {
            group.addTask {
                // Construct the config inside the task so we don't smuggle a
                // shared NSWorkspace.OpenConfiguration across the MainActor boundary
                // (which Swift 6 strict concurrency rejects as a sending hazard).
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                } catch {
                    print("Launch Homepage: failed to open \(name) at \(url.path): \(error)")
                }
            }
        }
    }
}
