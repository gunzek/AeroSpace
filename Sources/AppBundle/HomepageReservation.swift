import AppKit
import Common

/// Phase 3.5 — homepage workspace reservation.
///
/// Decision matrix (only redirects when ALL of these hold):
///   1. `catchAll.enabled` is on
///   2. The window's app has *no* routing rule (routed apps own their target
///      workspace; reservation must not override the user's explicit pin)
///   3. The window currently lives on a *reserved* workspace — defined as a
///      workspace that has at least one routing rule pointing to it
///   4. The reserved workspace would hold more than `workspaceLimit` windows
///      counting this new arrival (tiled + floating). `workspaceLimit` is read
///      as "at most N windows on a reserved workspace", so the (N+1)-th arrival
///      is bumped — see the `>` check below.
///   5. `catchAllWorkspaces` is non-empty
///
/// If all hold, the window is unbound from its current parent and rebound to
/// the rootTilingContainer of the next catch-all workspace, picked round-robin.
@MainActor
enum HomepageReservation {
    /// Round-robin cursor. In-process state — restarting AeroSpace resets to 0,
    /// which is fine: the "fairness" is across a session, not a multi-day
    /// distribution. Persisting it would surprise users far more than help.
    private static var cursor: Int = 0

    static func applyIfNeeded(_ window: Window) {
        let state = UISettingsStore.shared.state
        guard state.catchAll.enabled else { return }
        guard let appId = window.app.rawAppBundleId else { return }
        // Rule 2: routed apps are not subject to reservation. Their on-window-detected
        // callback already moved them where they belong; do not second-guess.
        if state.appRouting.contains(where: { $0.appId == appId }) { return }
        guard let workspace = window.nodeWorkspace else { return }
        let workspaceName = workspace.name
        // Rule 5 (cheap pre-check): any catch-all configured? If not, bail before
        // we walk the routing array.
        let candidates = state.catchAll.catchAllWorkspaces
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != workspaceName }
        guard !candidates.isEmpty else { return }
        // Rule 3: the current workspace must be reserved (= referenced by at least
        // one routing rule). Otherwise it's "scratch" and unrouted apps belong here.
        let isReserved = state.appRouting.contains { $0.workspace == workspaceName }
        guard isReserved else { return }
        // Rule 4: capacity. Count BOTH tiled leaves and floating windows — floating
        // windows are bound directly to the Workspace node, not into
        // rootTilingContainer, so counting only tiling leaves would let a workspace
        // full of floating windows never bump. This arrival is ALREADY bound to the
        // workspace and thus included in `windowCount`. `workspaceLimit` means "at
        // most N windows stay", so the N-th arrival keeps it at N (no bump) and only
        // the (N+1)-th arrival — which pushes the count to N+1 — is moved on. Hence
        // strict `>`: count==N is fine, count>N bumps.
        let windowCount = workspace.rootTilingContainer.allLeafWindowsRecursive.count
            + workspace.floatingWindows.count
        guard windowCount > state.catchAll.workspaceLimit else { return }

        let target = candidates[cursor % candidates.count]
        cursor &+= 1
        let targetWorkspace = Workspace.get(byName: target)
        window.unbindFromParent()
        // Match upstream `moveWindowToWorkspace`: a floating window binds to the
        // Workspace node (preserving its floating state), a tiled window to the
        // root tiling container. Force-tiling a deliberately-floating window here
        // would be a regression.
        let targetContainer: NonLeafTreeNodeObject = window.isFloating
            ? targetWorkspace
            : targetWorkspace.rootTilingContainer
        window.bind(
            to: targetContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: INDEX_BIND_LAST,
        )
        // Phase 5 honour: if the user wants follow-on-route, pull focus to
        // the catch-all workspace too. Same toggle as the routing rule
        // generates `--focus-follows-window` for.
        if state.followFocusOnRoute {
            _ = targetWorkspace.focusWorkspace()
        }
    }
}
