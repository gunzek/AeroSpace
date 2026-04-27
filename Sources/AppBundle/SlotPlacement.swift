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
func applySlotPlacement(_ window: Window) async {
    guard let appId = window.app.rawAppBundleId else { return }
    let state = UISettingsStore.shared.state
    guard let rule = state.appRouting.first(where: { $0.appId == appId }) else { return }
    guard rule.layout != .floating else { return }

    // Resolve effective workspace + slot via window-title matchers. First
    // active matcher (non-empty substring) whose case-insensitive substring
    // appears in the window title wins. Falls back to rule defaults.
    let title = ((try? await window.title) ?? "").lowercased()
    var effectiveWorkspace = rule.workspace
    var effectiveSlot = rule.slot
    for matcher in rule.windowMatchers {
        let needle = matcher.titleSubstring.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty, title.contains(needle) else { continue }
        if let ws = matcher.workspaceOverride, !ws.isEmpty { effectiveWorkspace = ws }
        if let s = matcher.slotOverride { effectiveSlot = s }
        break
    }

    // If matcher overrode the workspace and we're not already there, move first.
    if let currentWorkspace = window.nodeWorkspace, currentWorkspace.name != effectiveWorkspace {
        let target = Workspace.get(byName: effectiveWorkspace)
        if window.parent != nil { window.unbindFromParent() }
        window.bind(to: target.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    guard effectiveSlot != .full else { return }
    guard let workspace = window.nodeWorkspace, workspace.name == effectiveWorkspace else { return }
    guard window.parent is TilingContainer else { return }

    placeWindowInSlot(window, slot: effectiveSlot, workspace: workspace)
}

/// 3.6 follow-up (extended): walk every currently-known window and apply both
/// the routing (move to the rule's target workspace) AND the slot placement.
/// Called after a Settings UI Save so existing windows snap to the layout the
/// user just edited — the upstream `[[on-window-detected]]` hook only fires
/// for *new* windows, so without this Save would have no effect on already-
/// open apps and the user would have to close+reopen each one.
@MainActor
func reapplyRoutingAndSlotsToAllWindows() async {
    let state = UISettingsStore.shared.state
    if state.appRouting.isEmpty { return }
    for window in MacWindow.allWindows {
        guard let appId = window.app.rawAppBundleId else { continue }
        guard let rule = state.appRouting.first(where: { $0.appId == appId }) else { continue }

        // Resolve effective workspace via title match (matcher may override).
        let title = ((try? await window.title) ?? "").lowercased()
        var effectiveWorkspace = rule.workspace
        for matcher in rule.windowMatchers {
            let needle = matcher.titleSubstring.trimmingCharacters(in: .whitespaces).lowercased()
            guard !needle.isEmpty, title.contains(needle) else { continue }
            if let ws = matcher.workspaceOverride, !ws.isEmpty { effectiveWorkspace = ws }
            break
        }

        // 1. Move to the resolved workspace if not already there.
        if let currentWorkspace = window.nodeWorkspace, currentWorkspace.name != effectiveWorkspace {
            let targetWorkspace = Workspace.get(byName: effectiveWorkspace)
            if window.parent != nil { window.unbindFromParent() }
            if rule.layout == .floating {
                window.bind(to: targetWorkspace, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            } else {
                window.bind(to: targetWorkspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
        }

        // 2. Apply slot placement (which itself re-resolves matchers).
        await applySlotPlacement(window)
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
            // If our window is already a child of root at the column we want,
            // ensureSubColumn would pick it up as the "occupant" and try to
            // re-home self into the new column — a self-rebind loop. Pull it
            // out first. The subsequent place() call is idempotent and will
            // re-bind it correctly inside the column.
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
/// Otherwise rebind at the target index. Two crash conditions guarded here:
///  1. `unbindFromParent` asserts the node IS bound — quadrant placement
///     pre-unbinds, so we check `window.parent != nil` before unbinding.
///  2. `Array.insert(at: i)` traps when `i > count`. A fresh sub-container has
///     0 children; binding at slot index 1 (bottom) would crash. Clamp.
@MainActor
private func place(_ window: Window, in parent: TilingContainer, atIndex targetIndex: Int) {
    if window.parent === parent, window.ownIndex == targetIndex { return }
    if window.parent != nil {
        window.unbindFromParent()
    }
    let safeIndex = min(targetIndex, parent.children.count)
    window.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: safeIndex)
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
    // Only re-home the occupant if it's a Window AND still bound — moving a
    // TilingContainer would be a recursive nest, and unbinding an already-
    // unbound node would crash AeroSpace's assertion in unbindIfBound.
    if let occupant, occupant is Window, occupant.parent != nil {
        occupant.unbindFromParent()
        occupant.bind(to: column, adaptiveWeight: WEIGHT_AUTO, index: 0)
    }
    return column
}
