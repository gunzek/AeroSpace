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
        // Trim before the prefix check, exactly like hasUnmanagedSection /
        // analyzeBindingSection / stripBindingSection do. Matching the RAW line
        // here while those trim meant an indented marker (`  # AEROSPACE-UI …`)
        // was invisible to projectInto but visible to the duplicate check — so
        // we'd append a SECOND managed block (duplicate [gaps]/[[on-window-detected]]
        // → reload-config fails) and a later splice could delete user content
        // between the two blocks. All marker detection must be trim-then-hasPrefix.
        let startIdx = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(startKey) }
        let endIdx   = lines.lastIndex  { $0.trimmingCharacters(in: .whitespaces).hasPrefix(endKey) }

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

    /// Outcome of analysing the user's `[mode.main.binding]` table for import.
    ///
    /// The managed writer can only represent a binding as
    /// `shortcut = 'single-action'` — one single-quoted TOML literal, no `'`
    /// and no newline inside it. Anything richer (multi-action arrays,
    /// multi-line values, literal/basic strings the line parser can't cleanly
    /// extract, or a value containing a `'`) would either be silently dropped
    /// or, worse, written back in a form `generateBlock`→`requireSafeLiteral`
    /// rejects forever — and since the original table is stripped first, that
    /// permanently breaks every future sync. So import is all-or-nothing: if
    /// ANY binding is unrepresentable we refuse and name what would be lost,
    /// rather than dropping or poisoning.
    struct BindingImportAnalysis {
        /// Bindings we can faithfully round-trip through the managed writer.
        var importable: [(shortcut: String, action: String)] = []
        /// Human-readable descriptions of bindings we cannot represent. When
        /// non-empty the caller MUST refuse the import (don't strip, don't drop).
        var unrepresentable: [String] = []
    }

    /// Parse the user's existing `[mode.main.binding]` section, classifying each
    /// binding as importable or unrepresentable. Multi-line constructs (open
    /// `[...` arrays, `'''`/`"""` strings) are consumed as a unit so a later
    /// line is never mistaken for a fresh binding.
    static func analyzeBindingSection(from existing: String) -> BindingImportAnalysis {
        let lines = existing.components(separatedBy: "\n")
        var analysis = BindingImportAnalysis()
        var insideMarker = false
        var insideBinding = false
        var idx = 0
        while idx < lines.count {
            let raw = lines[idx]
            idx += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(startKey) { insideMarker = true; insideBinding = false; continue }
            if line.hasPrefix(endKey)   { insideMarker = false; insideBinding = false; continue }
            if insideMarker { continue }
            if line == "[mode.main.binding]" { insideBinding = true; continue }
            // Any other top-level table header ends the binding section.
            if insideBinding, line.hasPrefix("["), line.hasSuffix("]") {
                insideBinding = false
                continue
            }
            if !insideBinding { continue }
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equalsIdx = line.firstIndex(of: "=") else {
                // A non-blank, non-comment line with no `=` inside the binding
                // table is something the line parser can't read (dotted/inline
                // table, continuation, …). Refuse rather than drop it silently.
                analysis.unrepresentable.append("unparseable line: \(line)")
                continue
            }
            let key = String(line[..<equalsIdx]).trimmingCharacters(in: .whitespaces)
            let rhsRaw = String(line[line.index(after: equalsIdx)...]).trimmingCharacters(in: .whitespaces)
            let value = stripInlineComment(rhsRaw)
            let label = key.isEmpty ? line : key

            // Multi-line literal/basic strings: `'''` or `"""` not closed on the
            // same line. The line parser can't read these, and they may contain
            // newlines the writer can't emit. Refuse (and skip their body so we
            // don't misread it as more bindings).
            if (value.hasPrefix("'''") && !isClosedTriple(value, quote: "'''"))
                || (value.hasPrefix("\"\"\"") && !isClosedTriple(value, quote: "\"\"\"")) {
                analysis.unrepresentable.append("\(label): multi-line string")
                idx = skipMultiLine(lines, from: idx, terminator: value.hasPrefix("'''") ? "'''" : "\"\"\"")
                continue
            }
            // Single-line triple-quoted: collapses to a single value but the
            // line parser below would mis-strip it. Treat as unrepresentable to
            // stay conservative (these are rare in keybindings anyway).
            if value.hasPrefix("'''") || value.hasPrefix("\"\"\"") {
                analysis.unrepresentable.append("\(label): triple-quoted string")
                continue
            }

            // Arrays — multi-action bindings. The managed writer wraps a SINGLE
            // action in single quotes; it cannot represent `['a', 'b']`, and
            // importing it verbatim would poison every future sync. Refuse.
            if value.hasPrefix("[") {
                analysis.unrepresentable.append("\(label): multi-action array")
                if !value.hasSuffix("]") {
                    // Open array spanning multiple lines — skip its body.
                    idx = skipMultiLine(lines, from: idx, terminator: "]")
                }
                continue
            }

            // Single-line quoted scalars. We deliberately reject any extracted
            // action containing a `'` or newline (e.g. `"exec ... 'Mail'"`)
            // because the writer single-quotes the action and would throw on
            // round-trip — better to refuse the import than poison the sync.
            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                let action = String(value.dropFirst().dropLast())
                appendScalar(key: key, action: action, label: label, into: &analysis)
            } else if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                // Basic strings may carry escapes (`\"`, `\n`, …). A backslash
                // means our naive unquoting would produce the wrong action, so
                // refuse anything with an escape rather than import it wrong.
                let inner = String(value.dropFirst().dropLast())
                if inner.contains("\\") {
                    analysis.unrepresentable.append("\(label): escaped string")
                } else {
                    appendScalar(key: key, action: inner, label: label, into: &analysis)
                }
            } else {
                // Bare/unquoted or otherwise unrecognised value form.
                analysis.unrepresentable.append("\(label): unsupported value form")
            }
        }
        return analysis
    }

    /// Classify a cleanly-extracted single action: importable unless it carries
    /// a `'` or newline the managed writer would reject.
    private static func appendScalar(
        key: String, action: String, label: String, into analysis: inout BindingImportAnalysis,
    ) {
        if action.contains("'") || action.contains("\n") {
            analysis.unrepresentable.append("\(label): action contains a single quote")
        } else {
            analysis.importable.append((key, action))
        }
    }

    /// True if a value that starts with the triple-quote also closes it on the
    /// same (already inline-comment-stripped) line.
    private static func isClosedTriple(_ value: String, quote: String) -> Bool {
        value.count > quote.count * 2 && value.hasSuffix(quote)
    }

    /// Advance past the body of a multi-line construct, returning the index of
    /// the first line AFTER its terminator (or EOF). `from` is the index of the
    /// line following the opener.
    private static func skipMultiLine(_ lines: [String], from: Int, terminator: String) -> Int {
        var i = from
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1
            if trimmed.contains(terminator) { break }
        }
        return i
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
