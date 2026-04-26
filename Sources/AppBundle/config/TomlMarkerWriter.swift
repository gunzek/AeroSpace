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
    }

    /// Render the managed block from a `UIState`. Pure; safe to call without I/O.
    static func generateBlock(from state: UIState) throws -> String {
        var lines: [String] = [startLine]
        for rule in state.appRouting {
            try requireSafeLiteral(rule.appId, field: "appId")
            try requireSafeLiteral(rule.workspace, field: "workspace")
            lines.append("")
            lines.append("[[on-window-detected]]")
            lines.append("if.app-id = '\(rule.appId)'")
            var commands = ["move-node-to-workspace \(rule.workspace)"]
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
        let next = try projectInto(existing: existing, block: block)
        try FileManager.default.createDirectory(
            at: configUrl.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try next.write(to: configUrl, atomically: true, encoding: .utf8)
    }

    private static func requireSafeLiteral(_ value: String, field: String) throws {
        if value.contains("'") || value.contains("\n") {
            throw WriteError.unsafeLiteral(field: field, value: value)
        }
    }
}
