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
///   4. The reserved workspace already holds `> workspaceLimit` windows (after
///      this new arrival)
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
        // Rule 4: capacity. We compare against the configured limit; equality means
        // "limit just reached" → bump.
        let windowCount = workspace.rootTilingContainer.allLeafWindowsRecursive.count
        guard windowCount > state.catchAll.workspaceLimit else { return }

        let target = candidates[cursor % candidates.count]
        cursor &+= 1
        let targetWorkspace = Workspace.get(byName: target)
        window.unbindFromParent()
        window.bind(
            to: targetWorkspace.rootTilingContainer,
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
