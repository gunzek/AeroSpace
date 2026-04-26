import AppKit
import Common

/// Phase 3.6 hook: after the upstream `[[on-window-detected]]` callbacks have
/// landed a window on its target workspace, this function consults the
/// per-rule `slot` setting and reshapes the workspace's tiling tree so the
/// window ends up exactly where the user wants it.
///
/// This sits *outside* AeroSpace's TOML/Command system on purpose. Encoding
/// "left-half" as a chained TOML command sequence (`split horizontal` →
/// `move-node-here`) is brittle because each command depends on the MRU
/// state and on whether a sibling already exists. A direct tree mutation is
/// shorter, idempotent, and keeps the slot logic in one Swift file instead
/// of three (CmdKind + CmdArgs + Command + manifest plumbing).
@MainActor
func applySlotPlacement(_ window: Window) {
    guard let appId = window.app.rawAppBundleId else { return }
    let state = UISettingsStore.shared.state
    guard let rule = state.appRouting.first(where: { $0.appId == appId }) else { return }
    guard rule.slot != .full else { return }
    guard let workspace = window.nodeWorkspace else { return }
    // Only place if the window actually landed on the rule's intended workspace —
    // otherwise the user moved it manually or the rule is stale and we should
    // not second-guess them.
    guard workspace.name == rule.workspace else { return }

    placeWindowInSlot(window, slot: rule.slot, workspace: workspace)
}

@MainActor
private func placeWindowInSlot(_ window: Window, slot: Slot, workspace: Workspace) {
    let root = workspace.rootTilingContainer

    switch slot {
        case .full:
            return

        case .leftHalf, .rightHalf:
            ensureOrientation(root, .h)
            place(window, in: root, atIndex: slot == .leftHalf ? 0 : 1)

        case .topHalf, .bottomHalf:
            ensureOrientation(root, .v)
            place(window, in: root, atIndex: slot == .topHalf ? 0 : 1)

        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            ensureOrientation(root, .h)
            let columnIndex   = (slot == .topLeft || slot == .bottomLeft) ? 0 : 1
            let verticalIndex = (slot == .topLeft || slot == .topRight)   ? 0 : 1
            let column = ensureSubColumn(in: root, atIndex: columnIndex, orientation: .v)
            place(window, in: column, atIndex: verticalIndex)
    }
}

/// Set container orientation only when it actually needs to change. Avoids
/// triggering the normalization cascade for no reason.
@MainActor
private func ensureOrientation(_ container: TilingContainer, _ orientation: Orientation) {
    if container.orientation != orientation {
        container.changeOrientation(orientation)
    }
}

/// Idempotent insert: if the window already sits at the right slot, do nothing.
/// Otherwise unbind from current parent and rebind at the target index. The
/// child currently at that index gets shifted by one (`Array.insert(at:)`
/// behaviour in TreeNode.bind).
@MainActor
private func place(_ window: Window, in parent: TilingContainer, atIndex targetIndex: Int) {
    if window.parent === parent, window.ownIndex == targetIndex { return }
    window.unbindFromParent()
    window.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: targetIndex)
}

/// Returns a TilingContainer at `parent.children[index]` with the requested
/// orientation. Three cases:
///   1. Slot already holds a TilingContainer with the right orientation → reuse.
///   2. Slot holds a TilingContainer with the wrong orientation → flip it.
///   3. Slot holds a Window (or nothing) → wrap it (or create empty) in a new
///      sub-container so the next placement has a stable two-slot column.
@MainActor
private func ensureSubColumn(
    in parent: TilingContainer,
    atIndex index: Int,
    orientation: Orientation,
) -> TilingContainer {
    if index < parent.children.count, let existing = parent.children[index] as? TilingContainer {
        if existing.orientation != orientation {
            existing.changeOrientation(orientation)
        }
        return existing
    }
    // Nothing or a bare window at this index — wrap.
    let occupant = (index < parent.children.count) ? parent.children[index] : nil
    let column = TilingContainer(
        parent: parent,
        adaptiveWeight: WEIGHT_AUTO,
        orientation,
        .tiles,
        index: index,
    )
    if let occupant {
        // bind() above inserted the new column at `index`, shifting the bare
        // window to index+1. Move that window into the new column so the slot
        // grid stays consistent (we don't want orphan windows at the root).
        occupant.unbindFromParent()
        occupant.bind(to: column, adaptiveWeight: WEIGHT_AUTO, index: 0)
    }
    return column
}
