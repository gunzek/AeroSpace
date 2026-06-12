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
/// Maps `MacWindow.windowId` → matcher id. Once a matcher claims a window,
/// the assignment persists across refreshes so that closing a different
/// window doesn't yank this one to a new slot. Cleared on window destroy
/// (the upstream `garbageCollect` path) — see SlotPlacement.swift's
/// `forgetMatcherAssignment(for:)` below.
@MainActor
private var matcherAssignmentByWindow: [UInt32: UUID] = [:]

@MainActor
func forgetMatcherAssignment(for windowId: UInt32) {
    matcherAssignmentByWindow.removeValue(forKey: windowId)
}

@MainActor
func applySlotPlacement(_ window: Window) async {
    guard let appId = window.app.rawAppBundleId else { return }
    let state = UISettingsStore.shared.state
    guard let rule = state.appRouting.first(where: { $0.appId == appId }) else { return }
    guard rule.layout != .floating else { return }

    // Two-pass matcher resolution:
    //   1. Title-based matchers (non-empty substring) match by case-insensitive
    //      window-title contains.
    //   2. Title-agnostic matchers (empty substring) are claim-once: the first
    //      one not yet assigned to another window of this app wins, and the
    //      assignment sticks until the window is destroyed. This is what lets
    //      a user say "I want 2 Safari windows side-by-side, don't care which
    //      arrives first" — AeroSpace just feeds incoming windows into the
    //      next free slot.
    let rawTitle = (try? await window.title) ?? ""
    let title = rawTitle.lowercased()
    var effectiveWorkspace = rule.workspace
    var effectiveSlot = rule.slot
    var hit: WindowMatcher? = nil

    // Pass 1: title-based matches
    for matcher in rule.windowMatchers {
        let needle = matcher.titleSubstring.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty, title.contains(needle) else { continue }
        hit = matcher
        break
    }

    // Pass 2: title-agnostic claim-once
    if hit == nil {
        let titleAgnostic = rule.windowMatchers.filter { $0.titleSubstring.trimmingCharacters(in: .whitespaces).isEmpty }
        if !titleAgnostic.isEmpty {
            // If this window already claimed a matcher, keep it stable.
            if let priorId = matcherAssignmentByWindow[window.windowId],
               let prior = titleAgnostic.first(where: { $0.id == priorId })
            {
                hit = prior
            } else {
                // Otherwise find the first matcher not currently claimed by
                // another live window of THIS app. We scope by app so two
                // different routed apps with the same matcher count don't
                // poach each other's slots.
                let liveWindowIdsForApp = Set(MacWindow.allWindows
                    .filter { $0.app.rawAppBundleId == appId }
                    .map(\.windowId))
                let claimedByOthers: Set<UUID> = Set(
                    matcherAssignmentByWindow
                        .filter { liveWindowIdsForApp.contains($0.key) && $0.key != window.windowId }
                        .map(\.value),
                )
                if let firstFree = titleAgnostic.first(where: { !claimedByOthers.contains($0.id) }) {
                    matcherAssignmentByWindow[window.windowId] = firstFree.id
                    hit = firstFree
                }
            }
        }
    }

    if let m = hit {
        if let ws = m.workspaceOverride, !ws.isEmpty { effectiveWorkspace = ws }
        if let s = m.slotOverride { effectiveSlot = s }
    }

    // If matcher overrode the workspace and we're not already there, move first.
    var movedWorkspace = false
    if let currentWorkspace = window.nodeWorkspace, currentWorkspace.name != effectiveWorkspace {
        let target = Workspace.get(byName: effectiveWorkspace)
        if window.parent != nil { window.unbindFromParent() }
        window.bind(to: target.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        movedWorkspace = true
        // Phase 5: pull focus to the matcher's target workspace too.
        if state.followFocusOnRoute {
            _ = target.focusWorkspace()
        }
    }

    // Diagnostics (phase 8): this function is hot — it runs for every detected
    // window AND once per window on every reapply-all — so only actual layout
    // changes log (window re-bound, root orientation flipped, sub-column
    // created/flipped), never no-ops (a window already sitting in its slot
    // stays silent).
    var placedSlot: Slot? = nil
    defer {
        if movedWorkspace || placedSlot != nil {
            logRoutingPlacement(window, title: rawTitle, appId: appId, workspace: effectiveWorkspace, slot: placedSlot)
        }
    }

    guard effectiveSlot != .full else { return }
    guard let workspace = window.nodeWorkspace, workspace.name == effectiveWorkspace else { return }
    guard window.parent is TilingContainer else { return }

    if placeWindowInSlot(window, slot: effectiveSlot, workspace: workspace) {
        placedSlot = effectiveSlot
    }
    // Phase 5: even if the upstream `--focus-follows-window` flag took us to
    // the workspace already, repeating focusWorkspace() is safe (idempotent).
    // Critical when slot placement crossed a workspace boundary above.
    if state.followFocusOnRoute {
        _ = workspace.focusWorkspace()
    }
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
    var processed = 0
    for window in MacWindow.allWindows {
        guard let appId = window.app.rawAppBundleId else { continue }
        guard let rule = state.appRouting.first(where: { $0.appId == appId }) else { continue }
        processed += 1

        // Resolve effective workspace via title match (matcher may override).
        let rawTitle = (try? await window.title) ?? ""
        let title = rawTitle.lowercased()
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
            // Diagnostics: this move happens before applySlotPlacement runs
            // (which then sees the window already on the right workspace and
            // stays silent about it), so log it here. A window that also gets
            // slot-placed below produces a second line — both are real moves.
            logRoutingPlacement(window, title: rawTitle, appId: appId, workspace: effectiveWorkspace, slot: nil)
        }

        // 2. Apply slot placement (which itself re-resolves matchers).
        await applySlotPlacement(window)
    }
    DiagnosticsLog.shared.log(.routing, "reapplied routing to \(processed) windows")
}

/// Diagnostics (phase 8): one `.routing` line per actual window move, e.g.
/// "Inbox (Mail) → workspace M slot left-half (rule: com.apple.mail)".
/// `slot: nil` = workspace move only (no slot, or slot placement was a no-op).
@MainActor
private func logRoutingPlacement(_ window: Window, title: String, appId: String, workspace: String, slot: Slot?) {
    let appLabel = window.app.name ?? appId
    let titleLabel = title.isEmpty ? "<untitled>" : title
    let slotPart = slot.map { " slot \($0.rawValue)" } ?? ""
    DiagnosticsLog.shared.log(.routing, "\(titleLabel) (\(appLabel)) → workspace \(workspace)\(slotPart) (rule: \(appId))")
}

/// Returns true when the placement visibly changed the layout — the window
/// was re-bound, the root orientation flipped, or a sub-column was created or
/// flipped. False only for a true no-op (everything already in place).
/// Diagnostics-only return value — the placement behavior is unchanged.
@MainActor
private func placeWindowInSlot(_ window: Window, slot: Slot, workspace: Workspace) -> Bool {
    let root = workspace.rootTilingContainer

    switch slot {
        case .full:
            return false

        case .leftHalf, .rightHalf:
            let reoriented = ensureOrientation(root, .h)
            return place(window, in: root, atIndex: slot == .leftHalf ? 0 : 1) || reoriented

        case .topHalf, .bottomHalf:
            let reoriented = ensureOrientation(root, .v)
            return place(window, in: root, atIndex: slot == .topHalf ? 0 : 1) || reoriented

        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let reoriented = ensureOrientation(root, .h)
            let columnIndex   = (slot == .topLeft || slot == .bottomLeft) ? 0 : 1
            let verticalIndex = (slot == .topLeft || slot == .topRight)   ? 0 : 1
            // If our window is already a child of root at the column we want,
            // ensureSubColumn would pick it up as the "occupant" and try to
            // re-home self into the new column — a self-rebind loop. Pull it
            // out first. The subsequent place() call is idempotent and will
            // re-bind it correctly inside the column.
            if window.parent === root { window.unbindFromParent() }
            guard let (column, columnMutated) = ensureSubColumn(in: root, atIndex: columnIndex, orientation: .v) else { return reoriented }
            return place(window, in: column, atIndex: verticalIndex) || columnMutated || reoriented
    }
}

/// Set container orientation only when it actually needs to change. Avoids
/// triggering the normalization cascade for no reason. Returns whether it did
/// (a flip is a visible layout change, so it counts for diagnostics).
@MainActor
private func ensureOrientation(_ container: TilingContainer, _ orientation: Orientation) -> Bool {
    if container.orientation != orientation {
        container.changeOrientation(orientation)
        return true
    }
    return false
}

/// Idempotent insert: if the window already sits at the right slot, do nothing.
/// Otherwise rebind at the target index. Two crash conditions guarded here:
///  1. `unbindFromParent` asserts the node IS bound — quadrant placement
///     pre-unbinds, so we check `window.parent != nil` before unbinding.
///  2. `Array.insert(at: i)` traps when `i > count`. A fresh sub-container has
///     0 children; binding at slot index 1 (bottom) would crash. Clamp.
@MainActor
private func place(_ window: Window, in parent: TilingContainer, atIndex targetIndex: Int) -> Bool {
    if window.parent === parent, window.ownIndex == targetIndex { return false }
    if window.parent != nil {
        window.unbindFromParent()
    }
    let safeIndex = min(targetIndex, parent.children.count)
    window.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: safeIndex)
    return true
}

/// Returns a TilingContainer at `parent.children[index]` with the requested
/// orientation, plus whether getting there mutated the layout (for the
/// diagnostics "did anything visibly change" classification). Three cases:
///   1. Slot already holds a TilingContainer with the right orientation → reuse.
///   2. Slot holds a TilingContainer with the wrong orientation → flip it.
///   3. Slot holds a Window (or nothing) → wrap it (or create empty) in a new
///      sub-container so the next placement has a stable two-slot column.
@MainActor
private func ensureSubColumn(
    in parent: TilingContainer,
    atIndex index: Int,
    orientation: Orientation,
) -> (column: TilingContainer, mutated: Bool)? {
    if index < parent.children.count, let existing = parent.children[index] as? TilingContainer {
        if existing.orientation != orientation {
            existing.changeOrientation(orientation)
            return (existing, true)
        }
        return (existing, false)
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
    // A freshly created column is always a layout mutation.
    return (column, true)
}
