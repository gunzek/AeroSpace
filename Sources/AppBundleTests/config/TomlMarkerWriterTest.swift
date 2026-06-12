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
            run = ['move-node-to-workspace --focus-follows-window q']

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
            run = ['move-node-to-workspace --focus-follows-window z', 'layout floating']

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

    // MARK: Phase 2 — gaps & keybindings

    func testGenerateBlockEmitsGapsWhenSet() throws {
        var state = UIState.empty
        state.gaps = GapsSettings(innerHorizontal: 4, innerVertical: 2, outerHorizontal: 8, outerVertical: 6)
        let block = try TomlMarkerWriter.generateBlock(from: state)
        XCTAssertTrue(block.contains("[gaps]"))
        XCTAssertTrue(block.contains("inner.horizontal = 4"))
        XCTAssertTrue(block.contains("inner.vertical = 2"))
        XCTAssertTrue(block.contains("outer.left = 8"))
        XCTAssertTrue(block.contains("outer.right = 8"))
        XCTAssertTrue(block.contains("outer.top = 6"))
        XCTAssertTrue(block.contains("outer.bottom = 6"))
    }

    func testGenerateBlockOmitsGapsWhenNil() throws {
        let block = try TomlMarkerWriter.generateBlock(from: .empty)
        XCTAssertFalse(block.contains("[gaps]"))
    }

    func testGenerateBlockEmitsBindings() throws {
        var state = UIState.empty
        state.keybindings = [
            KeybindingRule(shortcut: "alt-q", action: "workspace q"),
            KeybindingRule(shortcut: "alt-shift-h", action: "focus left"),
        ]
        let block = try TomlMarkerWriter.generateBlock(from: state)
        XCTAssertTrue(block.contains("[mode.main.binding]"))
        XCTAssertTrue(block.contains("alt-q = 'workspace q'"))
        XCTAssertTrue(block.contains("alt-shift-h = 'focus left'"))
    }

    func testGenerateBlockSkipsBlankBindingRows() throws {
        var state = UIState.empty
        state.keybindings = [
            KeybindingRule(shortcut: "", action: "workspace q"),
            KeybindingRule(shortcut: "alt-q", action: ""),
            KeybindingRule(shortcut: "  ", action: "  "),
            KeybindingRule(shortcut: "alt-r", action: "reload-config"),
        ]
        let block = try TomlMarkerWriter.generateBlock(from: state)
        XCTAssertTrue(block.contains("alt-r = 'reload-config'"))
        XCTAssertFalse(block.contains("workspace q"))
        XCTAssertFalse(block.contains("alt-q"))
    }

    func testWriteBlockRefusesDuplicateGaps() throws {
        let dir = makeTempDir()
        let url = dir.appending(path: ".aerospace.toml")
        try """
            config-version = 2
            [gaps]
            inner.horizontal = 1
            """.write(to: url, atomically: true, encoding: .utf8)
        var state = UIState.empty
        state.gaps = GapsSettings(innerHorizontal: 5)
        XCTAssertThrowsError(try TomlMarkerWriter.writeBlock(state: state, to: url)) { error in
            assertEquals(error as? TomlMarkerWriter.WriteError, .duplicateGapsSection)
        }
    }

    func testWriteBlockRefusesDuplicateBindings() throws {
        let dir = makeTempDir()
        let url = dir.appending(path: ".aerospace.toml")
        try """
            config-version = 2
            [mode.main.binding]
            alt-q = 'workspace q'
            """.write(to: url, atomically: true, encoding: .utf8)
        var state = UIState.empty
        state.keybindings = [KeybindingRule(shortcut: "alt-w", action: "workspace w")]
        XCTAssertThrowsError(try TomlMarkerWriter.writeBlock(state: state, to: url)) { error in
            assertEquals(error as? TomlMarkerWriter.WriteError, .duplicateBindingSection)
        }
    }

    func testWriteBlockAllowsDuplicateMarkerCheckForUnmanagedSections() throws {
        // A managed section inside the marker block must NOT be detected by the
        // duplicate check (otherwise re-saving would always fail).
        let dir = makeTempDir()
        let url = dir.appending(path: ".aerospace.toml")
        var state = UIState.empty
        state.gaps = GapsSettings(innerHorizontal: 3)
        try TomlMarkerWriter.writeBlock(state: state, to: url) // first write
        // second write should also succeed — the [gaps] inside markers is OURS
        state.gaps = GapsSettings(innerHorizontal: 7)
        XCTAssertNoThrow(try TomlMarkerWriter.writeBlock(state: state, to: url))
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.contains("inner.horizontal = 7"))
        XCTAssertFalse(written.contains("inner.horizontal = 3"))
    }

    // MARK: Phase 3.6 — Slot overlap

    func testSlotOverlapSelf() {
        for slot in Slot.allCases {
            XCTAssertTrue(slot.overlaps(slot), "\(slot) should overlap itself")
        }
    }

    func testSlotOverlapHalfContainsQuadrants() {
        XCTAssertTrue(Slot.leftHalf.overlaps(.topLeft))
        XCTAssertTrue(Slot.leftHalf.overlaps(.bottomLeft))
        XCTAssertFalse(Slot.leftHalf.overlaps(.topRight))
        XCTAssertFalse(Slot.leftHalf.overlaps(.bottomRight))
        XCTAssertFalse(Slot.leftHalf.overlaps(.rightHalf))
    }

    func testSlotOverlapDisjointQuadrants() {
        XCTAssertFalse(Slot.topLeft.overlaps(.topRight))
        XCTAssertFalse(Slot.topLeft.overlaps(.bottomRight))
        XCTAssertFalse(Slot.topLeft.overlaps(.bottomLeft)) // share neither column nor row in our 2x2 model
    }

    func testSlotFullDoesNotOverlapOtherSlots() {
        // .full is "no constraint"; treating it as overlapping everything would
        // make Save unworkable. We only overlap-check between non-full slots in
        // practice; verify the symmetry assumption holds at least for self.
        XCTAssertTrue(Slot.full.overlaps(.full))
        XCTAssertFalse(Slot.full.overlaps(.leftHalf))
        XCTAssertFalse(Slot.leftHalf.overlaps(.full))
    }

    // MARK: Phase 1.2 — Codable migration

    func testUIStateDecodesWithoutSlotField() throws {
        let json = """
            {
              "version": 1,
              "appRouting": [
                { "id": "11111111-1111-1111-1111-111111111111", "appId": "com.example.foo",
                  "displayName": "Foo", "workspace": "q" }
              ],
              "homepage": { "launchOnStartup": false }
            }
            """
        let data = json.data(using: .utf8)!
        let state = try JSONDecoder().decode(UIState.self, from: data)
        assertEquals(state.appRouting.count, 1)
        assertEquals(state.appRouting[0].slot, .full)
        assertEquals(state.appRouting[0].layout, .tiling)
        XCTAssertNil(state.gaps)
        XCTAssertNil(state.keybindings)
        assertEquals(state.catchAll.enabled, false)
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
