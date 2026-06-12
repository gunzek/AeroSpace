import AppKit
import HotKey
import SwiftUI

/// Click-to-record shortcut field emitting AeroSpace binding syntax (e.g.
/// "alt-shift-q"). The emitted string is built by reverse lookup of the same
/// tables the config parser uses (config.keyMapping.resolve() for the key
/// token, modifiersMap's tokens in ModifierFlags.toString() order for the
/// modifiers), so whatever this field produces is guaranteed to parse back
/// through parseBinding — see the DEBUG round-trip check at the bottom.
@MainActor
struct ShortcutRecorderField: View {
    @Binding var shortcut: String      // AeroSpace syntax, e.g. "alt-shift-q"
    var isDuplicate: Bool = false      // orange highlight + warning icon

    @State private var isRecording = false
    /// Modifiers currently held while recording — live preview only, never
    /// committed without a terminating non-modifier key.
    @State private var heldModifiers: NSEvent.ModifierFlags = []
    @State private var isRawEditing = false
    /// Active NSEvent local monitors. Must be empty whenever isRecording is
    /// false: a leaked monitor inside the AeroSpace app would keep eating the
    /// user's keystrokes forever.
    @State private var eventMonitors: [Any] = []

    /// The only modifiers the config parser knows (see modifiersMap).
    private static let recognizedModifiers: NSEvent.ModifierFlags = [.shift, .option, .control, .command]

    var body: some View {
        HStack(spacing: 4) {
            if isRawEditing {
                rawEditor
            } else {
                recorderButton
            }
            if isDuplicate {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Duplicate shortcut — the same key combo is bound more than once")
            }
            Button {
                // Entering raw mode must kill an in-flight recording, otherwise
                // typing into the text field would be swallowed by the monitor.
                if !isRawEditing { stopRecording() }
                isRawEditing.toggle()
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(isRawEditing ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(isRawEditing ? "Back to click-to-record" : "Edit the raw shortcut string")
        }
        .onAppear {
            #if DEBUG
            verifyShortcutRoundTripOnce()
            #endif
        }
        // The view can disappear mid-recording (tab switch, window close) —
        // this is the last line of defense against leaked monitors.
        .onDisappear { stopRecording() }
    }

    private var recorderButton: some View {
        Button {
            // Second click while recording = cancel, same as Esc.
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(displayText)
                .font(.body.monospaced())
                .foregroundStyle(isRecording || shortcut.isEmpty ? Color.secondary : Color.primary)
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1.5),
        )
    }

    private var rawEditor: some View {
        TextField("e.g. alt-shift-q", text: $shortcut)
            .textFieldStyle(.roundedBorder)
            .font(.body.monospaced())
            .frame(minWidth: 110, maxWidth: 160)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isDuplicate ? Color.orange : Color.clear, lineWidth: 1.5),
            )
    }

    private var displayText: String {
        if isRecording {
            // Live-preview held modifiers so the user sees the combo build up.
            return heldModifiers.isEmpty ? "Press shortcut…" : heldModifiers.toString() + "-…"
        }
        return shortcut.isEmpty ? "Click to record" : shortcut
    }

    private var borderColor: Color {
        if isRecording { return .accentColor }
        if isDuplicate { return .orange }  // same treatment as conflict rows in Settings
        return .clear
    }

    // MARK: - Recording lifecycle

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        heldModifiers = []
        // Only Sendable scalars (keyCode, flags) cross into the MainActor
        // hop — NSEvent itself is not Sendable. Swallow decision comes back
        // as a Bool so the non-isolated closure never touches view state.
        let keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let swallow = MainActor.assumeIsolated { handleKeyDown(keyCode: keyCode, flags: flags) }
            return swallow ? nil : event
        }
        // flagsChanged drives the modifier live-preview only; modifier-only
        // "shortcuts" are not valid AeroSpace bindings (the parser requires a
        // key token), so nothing is ever committed from here.
        let flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { handleFlagsChanged(flags: flags) }
            return event  // never swallow flagsChanged — AppKit needs them
        }
        eventMonitors = [keyDownMonitor, flagsMonitor].compactMap { $0 }
    }

    /// Ends recording and removes the monitors. Idempotent so it's safe to
    /// call from Esc, cancel-click, commit, raw-edit toggle, and onDisappear.
    private func stopRecording() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors = []
        isRecording = false
        heldModifiers = []
    }

    /// Returns true when the event must be swallowed (every keyDown during
    /// recording is — otherwise the keystroke would also trigger UI actions).
    private func handleKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard isRecording else { return false }
        guard let key = Key(carbonKeyCode: UInt32(keyCode)) else { return true }
        let modifiers = flags.intersection(Self.recognizedModifiers)
        if key == .escape, modifiers.isEmpty {
            // Bare Esc cancels without touching the binding. (Esc with
            // modifiers is a legitimate combo and commits below; a bare "esc"
            // binding can still be entered via the raw editor.)
            stopRecording()
            return true
        }
        guard let token = Self.keyToken(for: key) else {
            // Key with no AeroSpace notation (capsLock, fn, …) — ignore and
            // keep recording so a stray press doesn't end the session.
            return true
        }
        // Bare keys are valid bindings: parseBinding's dropLast() on a single
        // token yields empty modifiers and succeeds. Mirror
        // HotkeyBinding.descriptionWithKeyCode's exact construction.
        shortcut = modifiers.isEmpty ? token : modifiers.toString() + "-" + token
        stopRecording()
        return true
    }

    private func handleFlagsChanged(flags: NSEvent.ModifierFlags) {
        guard isRecording else { return }
        heldModifiers = flags.intersection(Self.recognizedModifiers)
    }

    // MARK: - NSEvent → AeroSpace syntax

    /// Reverse lookup of the active notation→Key table, so the emitted token
    /// is exactly what the running config's parser accepts (qwerty by default,
    /// but dvorak/colemak presets and [key-mapping.key-notation-to-key-code]
    /// overrides are honored too). On the rare collision (two notations for
    /// one physical key after preset merging) the lexicographically smallest
    /// wins — deterministic, and every candidate parses back to the same key.
    private static func keyToken(for key: Key) -> String? {
        config.keyMapping.resolve()
            .filter { $0.value == key }
            .keys
            .sorted()
            .first
    }
}

// MARK: - DEBUG round-trip check

#if DEBUG
@MainActor private var didVerifyShortcutRoundTrip = false

/// Emits a representative sample of combos through the same code path the
/// recorder uses and asserts each parses back through parseBinding to the
/// exact (modifiers, key) pair. Covers: letters, digits, f-keys, arrows,
/// punctuation, keypad, bare keys, every single modifier, and the full
/// four-modifier stack. Verified set (qwerty): "alt-shift-q", "cmd-1",
/// "ctrl-f5", "shift-left", "cmd-shift-keypad7", "space", "alt-period",
/// "alt-ctrl-cmd-shift-backslash", "cmd-enter", "ctrl-tab".
@MainActor private func verifyShortcutRoundTripOnce() {
    if didVerifyShortcutRoundTrip { return }
    didVerifyShortcutRoundTrip = true
    let samples: [(NSEvent.ModifierFlags, Key)] = [
        ([.option, .shift], .q),                              // letter, two modifiers
        ([.command], .one),                                   // digit
        ([.control], .f5),                                    // f-key
        ([.shift], .leftArrow),                               // arrow
        ([.command, .shift], .keypad7),                       // keypad
        ([], .space),                                         // bare key, no modifiers
        ([.option], .period),                                 // punctuation notation
        ([.option, .control, .command, .shift], .backslash),  // all four modifiers
        ([.command], .return),                                // "enter" notation
        ([.control], .tab),                                   // ctrl combo
    ]
    let mapping = config.keyMapping.resolve()
    for (modifiers, key) in samples {
        guard let token = mapping.filter({ $0.value == key }).keys.sorted().first else {
            assertionFailure("ShortcutRecorderField round-trip: no notation for key \(key)")
            continue
        }
        let emitted = modifiers.isEmpty ? token : modifiers.toString() + "-" + token
        switch parseBinding(emitted, .rootKey("ShortcutRecorderField.roundTrip"), mapping) {
            case .success(let parsed):
                assert(
                    parsed.0 == modifiers && parsed.1 == key,
                    "ShortcutRecorderField round-trip mismatch for '\(emitted)': parsed \(parsed)",
                )
            case .failure(let error):
                assertionFailure("ShortcutRecorderField emitted unparseable shortcut '\(emitted)': \(error)")
        }
    }
}
#endif

// MARK: - Previews

// PreviewProvider (not #Preview) because the package targets macOS 13 and the
// #Preview macro requires macOS 14.
private struct ShortcutRecorderFieldPreviewHost: View {
    @State private var shortcut = "alt-shift-q"
    @State private var duplicated = "cmd-1"
    @State private var empty = ""

    var body: some View {
        Form {
            ShortcutRecorderField(shortcut: $shortcut)
            ShortcutRecorderField(shortcut: $duplicated, isDuplicate: true)
            ShortcutRecorderField(shortcut: $empty)
        }
        .formStyle(.grouped)
        .frame(width: 360)
    }
}

struct ShortcutRecorderField_Previews: PreviewProvider {
    static var previews: some View {
        ShortcutRecorderFieldPreviewHost()
    }
}
