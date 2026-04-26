@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class TomlMarkerWriterTest: XCTestCase {
    // MARK: generateBlock

    func testGenerateBlockEmpty() throws {
        let block = try TomlMarkerWriter.generateBlock(from: .empty)
        assertEquals(block, """
            \(TomlMarkerWriter.startLine)

            \(TomlMarkerWriter.endLine)
            """)
    }

    func testGenerateBlockTiling() throws {
        var state = UIState.empty
        state.appRouting = [
            AppRoutingRule(appId: "com.apple.Safari", displayName: "Safari", workspace: "q"),
        ]
        let block = try TomlMarkerWriter.generateBlock(from: state)
        assertEquals(block, """
            \(TomlMarkerWriter.startLine)

            [[on-window-detected]]
            if.app-id = 'com.apple.Safari'
            run = ['move-node-to-workspace q']

            \(TomlMarkerWriter.endLine)
            """)
    }

    func testGenerateBlockFloating() throws {
        var state = UIState.empty
        state.appRouting = [
            AppRoutingRule(appId: "com.apple.systempreferences", displayName: "Settings", workspace: "z", layout: .floating),
        ]
        let block = try TomlMarkerWriter.generateBlock(from: state)
        assertEquals(block, """
            \(TomlMarkerWriter.startLine)

            [[on-window-detected]]
            if.app-id = 'com.apple.systempreferences'
            run = ['move-node-to-workspace z', 'layout floating']

            \(TomlMarkerWriter.endLine)
            """)
    }

    func testGenerateBlockRejectsSingleQuoteInAppId() {
        var state = UIState.empty
        state.appRouting = [AppRoutingRule(appId: "evil'id", displayName: "x", workspace: "q")]
        XCTAssertThrowsError(try TomlMarkerWriter.generateBlock(from: state)) { error in
            assertEquals(error as? TomlMarkerWriter.WriteError, .unsafeLiteral(field: "appId", value: "evil'id"))
        }
    }

    // MARK: projectInto

    func testProjectIntoAppendsWhenNoMarkers() throws {
        let existing = """
            config-version = 2
            start-at-login = true
            """
        let block = "# AEROSPACE-UI START\nx\n# AEROSPACE-UI END"
        let next = try TomlMarkerWriter.projectInto(existing: existing, block: block)
        assertEquals(next, """
            config-version = 2
            start-at-login = true

            # AEROSPACE-UI START
            x
            # AEROSPACE-UI END

            """)
    }

    func testProjectIntoReplacesBetweenMarkers() throws {
        let existing = """
            config-version = 2

            # AEROSPACE-UI START -- old note
            old content
            # AEROSPACE-UI END

            after = true
            """
        let block = "# AEROSPACE-UI START\nNEW\n# AEROSPACE-UI END"
        let next = try TomlMarkerWriter.projectInto(existing: existing, block: block)
        assertEquals(next, """
            config-version = 2

            # AEROSPACE-UI START
            NEW
            # AEROSPACE-UI END

            after = true
            """)
    }

    func testProjectIntoThrowsOnUnbalancedMarkers() {
        let existing = "# AEROSPACE-UI START\nfoo"
        let block = "# AEROSPACE-UI START\nx\n# AEROSPACE-UI END"
        XCTAssertThrowsError(try TomlMarkerWriter.projectInto(existing: existing, block: block)) { error in
            assertEquals(error as? TomlMarkerWriter.WriteError, .unbalancedMarkers)
        }
    }

    // MARK: writeBlock (filesystem)

    func testWriteBlockCreatesFileWhenMissing() throws {
        let dir = makeTempDir()
        let url = dir.appending(path: ".aerospace.toml")
        var state = UIState.empty
        state.appRouting = [AppRoutingRule(appId: "com.example.foo", displayName: "Foo", workspace: "q")]
        try TomlMarkerWriter.writeBlock(state: state, to: url)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.contains("[[on-window-detected]]"))
        XCTAssertTrue(written.contains("if.app-id = 'com.example.foo'"))
        XCTAssertTrue(written.contains("# AEROSPACE-UI START"))
        XCTAssertTrue(written.contains("# AEROSPACE-UI END"))
    }

    func testWriteBlockPreservesUserContent() throws {
        let dir = makeTempDir()
        let url = dir.appending(path: ".aerospace.toml")
        let userBefore = """
            # MY NOTES
            config-version = 2
            start-at-login = true
            """
        try userBefore.write(to: url, atomically: true, encoding: .utf8)

        var state = UIState.empty
        state.appRouting = [AppRoutingRule(appId: "com.example.foo", displayName: "Foo", workspace: "q")]
        try TomlMarkerWriter.writeBlock(state: state, to: url)

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("# MY NOTES\n"))
        XCTAssertTrue(written.contains("config-version = 2"))
        XCTAssertTrue(written.contains("start-at-login = true"))
        XCTAssertTrue(written.contains("if.app-id = 'com.example.foo'"))
    }

    func testWriteBlockReplacesOnSecondCall() throws {
        let dir = makeTempDir()
        let url = dir.appending(path: ".aerospace.toml")

        var state = UIState.empty
        state.appRouting = [AppRoutingRule(appId: "com.example.foo", displayName: "Foo", workspace: "q")]
        try TomlMarkerWriter.writeBlock(state: state, to: url)

        state.appRouting = [AppRoutingRule(appId: "com.example.bar", displayName: "Bar", workspace: "w")]
        try TomlMarkerWriter.writeBlock(state: state, to: url)

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(written.contains("com.example.foo"))
        XCTAssertTrue(written.contains("com.example.bar"))
        XCTAssertEqual(written.components(separatedBy: TomlMarkerWriter.startKey).count - 1, 1)
        XCTAssertEqual(written.components(separatedBy: TomlMarkerWriter.endKey).count - 1, 1)
    }

    // MARK: helpers

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "aerospace-marker-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
