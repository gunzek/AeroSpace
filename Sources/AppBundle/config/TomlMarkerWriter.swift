import Common
import Foundation

/// Owns the section of `~/.aerospace.toml` between two marker comments.
///
/// The Settings UI projects its JSON-backed `UIState` into a TOML block here so
/// AeroSpace's existing parser can consume it. Anything outside the markers is
/// the user's own config and is preserved byte-for-byte (no full TOML re-encode).
enum TomlMarkerWriter {
    /// Match prefix; allows the descriptive comment after `START` to evolve.
    static let startKey = "# AEROSPACE-UI START"
    static let endKey   = "# AEROSPACE-UI END"
    static let startLine = "# AEROSPACE-UI START -- managed by Settings UI; do not edit by hand"
    static let endLine   = endKey

    enum WriteError: Error, Equatable {
        /// Exactly one of the markers was found — treat as user damage and refuse to guess.
        case unbalancedMarkers
        /// A field that becomes part of a TOML literal-string (single-quoted) contained a `'` or newline.
        case unsafeLiteral(field: String, value: String)
        /// Settings UI wants to manage `[gaps]` but the user has a `[gaps]` table outside the
        /// marker block. Two `[gaps]` tables in the same TOML file is undefined behavior; refuse.
        case duplicateGapsSection
        /// Same as duplicateGapsSection but for `[mode.main.binding]`.
        case duplicateBindingSection
    }

    /// Render the managed block from a `UIState`. Pure; safe to call without I/O.
    static func generateBlock(from state: UIState) throws -> String {
        var lines: [String] = [startLine]

        if let gaps = state.gaps {
            lines.append("")
            lines.append("[gaps]")
            lines.append("inner.horizontal = \(gaps.innerHorizontal)")
            lines.append("inner.vertical = \(gaps.innerVertical)")
            lines.append("outer.left = \(gaps.outerHorizontal)")
            lines.append("outer.right = \(gaps.outerHorizontal)")
            lines.append("outer.top = \(gaps.outerVertical)")
            lines.append("outer.bottom = \(gaps.outerVertical)")
        }

        if let bindings = state.keybindings {
            lines.append("")
            lines.append("[mode.main.binding]")
            for rule in bindings {
                let shortcut = rule.shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
                let action = rule.action.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !shortcut.isEmpty, !action.isEmpty else { continue }
                try requireSafeLiteral(action, field: "binding-action")
                // Shortcut is a TOML key on the LHS, not a literal-string. AeroSpace
                // accepts the standard `mod-mod-key` form; we don't quote it.
                lines.append("\(shortcut) = '\(action)'")
            }
        }

        let focusFlag = state.followFocusOnRoute ? "--focus-follows-window " : ""
        for rule in state.appRouting {
            try requireSafeLiteral(rule.appId, field: "appId")
            try requireSafeLiteral(rule.workspace, field: "workspace")
            lines.append("")
            lines.append("[[on-window-detected]]")
            lines.append("if.app-id = '\(rule.appId)'")
            var commands = ["move-node-to-workspace \(focusFlag)\(rule.workspace)"]
            if rule.layout == .floating { commands.append("layout floating") }
            let runArr = commands.map { "'\($0)'" }.joined(separator: ", ")
            lines.append("run = [\(runArr)]")
        }
        lines.append("")
        lines.append(endLine)
        return lines.joined(separator: "\n")
    }

    /// Splice `block` into `existing` between the markers (or append if absent).
    /// Pure; the on-disk variant is `writeBlock(state:to:)`.
    static func projectInto(existing: String, block: String) throws -> String {
        let lines = existing.components(separatedBy: "\n")
        let startIdx = lines.firstIndex { $0.hasPrefix(startKey) }
        let endIdx   = lines.lastIndex  { $0.hasPrefix(endKey) }

        switch (startIdx, endIdx) {
            case (nil, nil):
                if existing.isEmpty { return block + "\n" }
                var prefix = existing
                if !prefix.hasSuffix("\n") { prefix += "\n" }
                if !prefix.hasSuffix("\n\n") { prefix += "\n" } // blank line separator
                return prefix + block + "\n"

            case (let s?, let e?) where s <= e:
                var next = Array(lines[..<s])
                next.append(contentsOf: block.components(separatedBy: "\n"))
                if e + 1 < lines.count {
                    next.append(contentsOf: lines[(e + 1)...])
                }
                return next.joined(separator: "\n")

            default:
                throw WriteError.unbalancedMarkers
        }
    }

    /// Read-modify-write `configUrl`. Creates the file (and parent dir) if missing.
    static func writeBlock(state: UIState, to configUrl: URL) throws {
        let block = try generateBlock(from: state)
        let existing: String = FileManager.default.fileExists(atPath: configUrl.path)
            ? (try String(contentsOf: configUrl, encoding: .utf8))
            : ""
        if state.gaps != nil, hasUnmanagedGapsSection(in: existing) {
            throw WriteError.duplicateGapsSection
        }
        if state.keybindings != nil, hasUnmanagedBindingSection(in: existing) {
            throw WriteError.duplicateBindingSection
        }
        let next = try projectInto(existing: existing, block: block)
        try FileManager.default.createDirectory(
            at: configUrl.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try next.write(to: configUrl, atomically: true, encoding: .utf8)
    }

    /// Walks the file outside of the AEROSPACE-UI block and returns true if it
    /// contains a top-level table header equal to `header`. Used so we don't end up
    /// with two `[gaps]` (or `[mode.main.binding]`) tables, which TOML doesn't support.
    static func hasUnmanagedGapsSection(in existing: String) -> Bool {
        hasUnmanagedSection(in: existing, header: "[gaps]")
    }

    static func hasUnmanagedBindingSection(in existing: String) -> Bool {
        hasUnmanagedSection(in: existing, header: "[mode.main.binding]")
    }

    private static func hasUnmanagedSection(in existing: String, header: String) -> Bool {
        let lines = existing.components(separatedBy: "\n")
        var insideMarker = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(startKey) { insideMarker = true; continue }
            if line.hasPrefix(endKey)   { insideMarker = false; continue }
            if insideMarker { continue }
            if line == header { return true }
        }
        return false
    }

    private static func requireSafeLiteral(_ value: String, field: String) throws {
        if value.contains("'") || value.contains("\n") {
            throw WriteError.unsafeLiteral(field: field, value: value)
        }
    }

    // MARK: import + strip helpers

    /// Parse the user's existing `[mode.main.binding]` section into
    /// `(shortcut, action)` pairs. Comments are skipped. Multi-action arrays
    /// (e.g. `['reload-config', 'mode main']`) come back with their raw `[...]`
    /// form intact so the UI's Custom-action template can round-trip them.
    static func extractBindingSection(from existing: String) -> [(shortcut: String, action: String)] {
        let lines = existing.components(separatedBy: "\n")
        var insideMarker = false
        var insideBinding = false
        var result: [(String, String)] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(startKey) { insideMarker = true; insideBinding = false; continue }
            if line.hasPrefix(endKey)   { insideMarker = false; insideBinding = false; continue }
            if insideMarker { continue }
            if line == "[mode.main.binding]" { insideBinding = true; continue }
            if insideBinding, line.hasPrefix("["), line.hasSuffix("]") {
                insideBinding = false
                continue
            }
            if !insideBinding { continue }
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equalsIdx = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equalsIdx]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equalsIdx)...]).trimmingCharacters(in: .whitespaces)
            value = stripInlineComment(value)
            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                result.append((key, String(value.dropFirst().dropLast())))
            } else if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                result.append((key, String(value.dropFirst().dropLast())))
            } else if value.hasPrefix("["), value.hasSuffix("]") {
                result.append((key, value))
            }
        }
        return result
    }

    /// Drop the user's `[mode.main.binding]` section (header + body up to the
    /// next top-level header or EOF) but leave anything inside the AEROSPACE-UI
    /// markers untouched. Used by the "Import & take over" flow.
    static func stripBindingSection(from existing: String) -> String {
        let lines = existing.components(separatedBy: "\n")
        var out: [String] = []
        var insideMarker = false
        var skip = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(startKey) { insideMarker = true; out.append(raw); continue }
            if line.hasPrefix(endKey)   { insideMarker = false; out.append(raw); continue }
            if insideMarker { out.append(raw); continue }
            if line == "[mode.main.binding]" { skip = true; continue }
            if skip, line.hasPrefix("["), line.hasSuffix("]") { skip = false }
            if skip { continue }
            out.append(raw)
        }
        return out.joined(separator: "\n")
    }

    /// Strip an inline `# comment` from a TOML value, but only when the `#`
    /// sits outside any `'` or `"` quote. Default-config bindings use this
    /// idiom heavily (`alt-q = 'workspace q' # switch to writing workspace`).
    private static func stripInlineComment(_ value: String) -> String {
        var inSingle = false
        var inDouble = false
        var idx = value.startIndex
        while idx < value.endIndex {
            let ch = value[idx]
            if ch == "'", !inDouble { inSingle.toggle() }
            else if ch == "\"", !inSingle { inDouble.toggle() }
            else if ch == "#", !inSingle, !inDouble {
                return String(value[..<idx]).trimmingCharacters(in: .whitespaces)
            }
            idx = value.index(after: idx)
        }
        return value
    }
}
