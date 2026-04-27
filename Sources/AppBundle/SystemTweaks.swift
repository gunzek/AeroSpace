import AppKit
import Common
import Foundation

/// Phase 4a: macOS-wide window resize animation length, measured in seconds.
/// macOS default is ~0.2 s — for AeroSpace's heavy refresh-then-relayout cycle
/// that is the dominant visible delay, and 0.001 makes the system feel instant.
/// Stored as a defaults key under the global domain so any app respects it.
enum SystemTweaks {
    static let resizeKey = "NSWindowResizeTime"
    /// "Effectively instant" — anything below ~0.005 reads as a single frame
    /// at 60 Hz, which is what we want.
    static let fastResize: Double = 0.001

    /// Read the current `NSWindowResizeTime` from the global defaults domain.
    /// `nil` means the key is unset (i.e. macOS uses its built-in default).
    static func currentResizeTime() -> Double? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "-g", resizeKey]
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe() // discard "domain pair does not exist"
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let raw = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8,
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.flatMap { Double($0) }
    }

    /// Returns true iff `NSWindowResizeTime` is set to ≤ `fastResize` (allowing
    /// for tiny floating point noise). The check is "≤" rather than "==" so any
    /// hand-set "even faster" value the user already had still reads as on.
    static func isResizeSpedUp() -> Bool {
        guard let current = currentResizeTime() else { return false }
        return current <= fastResize + 0.0001
    }

    /// Apply or remove the speed-up. Uses `/usr/bin/defaults` so the change
    /// goes through cfprefsd properly (writing via UserDefaults to the global
    /// domain is unreliable from non-system apps).
    @discardableResult
    static func setResizeSpedUp(_ enabled: Bool) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = enabled
            ? ["write", "-g", resizeKey, "-float", String(fastResize)]
            : ["delete", "-g", resizeKey]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        // `defaults delete` exits non-zero if the key wasn't set; that's fine.
        if !enabled, task.terminationStatus != 0 { return true }
        return task.terminationStatus == 0
    }

    /// True iff Dock is currently configured to fold minimized windows into
    /// the app icon (`minimize-to-application = true`) AND uses the fast
    /// `scale` minimize effect. We treat both as a single "instant minimize"
    /// toggle — they're complementary and both contribute to the goal of
    /// "minimize feels instant when AeroSpace stashes non-visible windows".
    static func isInstantMinimizeOn() -> Bool {
        readDockBool("minimize-to-application") == true
            && readDockString("mineffect") == "scale"
    }

    /// Make Dock minimize feel near-instant: fold thumbnails into the app
    /// icon (so 5 stashed windows ≠ 5 separate Dock items) and use the
    /// `scale` effect (much shorter than the default Genie). macOS does not
    /// expose a "set minimize duration to zero" knob, but `scale` plus
    /// reduced-motion at the system level (Accessibility → Motion) gets very
    /// close to instant.
    @discardableResult
    static func setInstantMinimize(_ enabled: Bool) -> Bool {
        let writes: [(String, [String])] = enabled
            ? [
                ("minimize-to-application", ["-bool", "true"]),
                ("mineffect", ["-string", "scale"]),
            ]
            : [
                ("minimize-to-application", ["-bool", "false"]),
                ("mineffect", ["-string", "genie"]),
            ]
        var allOK = true
        for (key, args) in writes {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            task.arguments = ["write", "com.apple.dock", key] + args
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus != 0 { allOK = false }
            } catch {
                allOK = false
            }
        }
        // Restart Dock so the new settings take effect.
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["Dock"]
        killall.standardOutput = Pipe()
        killall.standardError = Pipe()
        try? killall.run()
        killall.waitUntilExit()
        return allOK
    }

    private static func readDockString(_ key: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "com.apple.dock", key]
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        return String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8,
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readDockBool(_ key: String) -> Bool? {
        guard let raw = readDockString(key) else { return nil }
        return raw == "1" || raw.lowercased() == "true"
    }
}
