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
    // Floating apps don't live in the tiling tree at all — forcing one into a
    // TilingContainer slot is a semantic contradiction and was crashing AeroSpace
    // mid-Launch-Homepage. Skip cleanly.
    guard rule.layout != .floating else { return }
    guard let workspace = window.nodeWorkspace else { return }
    // Only place if the window actually landed on the rule's intended workspace —
    // otherwise the user moved it manually or the rule is stale and we should
    // not second-guess them.
    guard workspace.name == rule.workspace else { return }
    // Defense in depth: window must currently be parented to a TilingContainer.
    // Floating/popup/dialog windows have other parents (Workspace,
    // MacosPopupWindowsContainer, …) and our placement code assumes tiling.
    guard window.parent is TilingContainer else { return }

    placeWindowInSlot(window, slot: rule.slot, workspace: workspace)
}

/// 3.6 follow-up: walk every currently-known window and re-apply the slot
/// constraint defined by its routing rule. Called after a Settings UI Save so
/// existing windows snap to the layout the user just edited (the upstream
/// on-window-detected hook only fires for *new* windows).
@MainActor
func reapplySlotPlacementForAllWindows() {
    let state = UISettingsStore.shared.state
    if state.appRouting.allSatisfy({ $0.slot == .full }) { return }
    for window in MacWindow.allWindows {
        applySlotPlacement(window)
    }
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
            // First, get this window out of the root so it doesn't accidentally
            // end up as the "occupant" we then try to re-home into the column —
            // that would be a self-rebind loop.
            if window.parent === root { window.unbindFromParent() }
            guard let column = ensureSubColumn(in: root, atIndex: columnIndex, orientation: .v) else { return }
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
) -> TilingContainer? {
    if index < parent.children.count, let existing = parent.children[index] as? TilingContainer {
        if existing.orientation != orientation {
            existing.changeOrientation(orientation)
        }
        return existing
    }
    // Defense: the index we want to bind a new container at must be reachable.
    // bind() with index = parent.children.count appends; index > count would
    // be undefined behavior. If we somehow get there, bail rather than crash.
    let safeIndex = min(index, parent.children.count)
    // Nothing or a bare window at this position — wrap. Capture the occupant
    // (if any) BEFORE creating the new container, since binding the new
    // container shifts everything at safeIndex by one.
    let occupant = (safeIndex < parent.children.count) ? parent.children[safeIndex] : nil
    let column = TilingContainer(
        parent: parent,
        adaptiveWeight: WEIGHT_AUTO,
        orientation,
        .tiles,
        index: safeIndex,
    )
    // Only re-home the occupant if it's a Window — moving a TilingContainer would
    // be a recursive nest that can blow the layout tree's depth invariants.
    if let occupant, occupant is Window {
        occupant.unbindFromParent()
        occupant.bind(to: column, adaptiveWeight: WEIGHT_AUTO, index: 0)
    }
    return column
}
