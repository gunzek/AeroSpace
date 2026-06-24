import AppKit
import Common

/// Per-workspace window capacity enforcement.
///
/// A "managed" workspace is one listed in `UISettingsStore.shared.state.workspaceLimits.workspaces`.
/// Each managed workspace may carry a `limit` (max number of windows). When the
/// feature is enabled and a workspace exceeds its limit, surplus windows are
/// pushed to the first managed workspace (in user-defined order) that still has
/// free capacity — the *overflow target*. The user order in `workspaces` is the
/// overflow priority; alphabetical order is irrelevant.
///
/// Unlike the previous catch-all reservation, routed apps are NOT exempt: the
/// capacity limit applies to every window regardless of routing rules.
@MainActor
enum HomepageReservation {
    // MARK: - Helpers

    /// Effective limit for a workspace: the configured limit if it's a managed
    /// workspace whose limit is > 0, otherwise nil (unlimited / unmanaged).
    /// Match is on the UPPERCASED canonical workspace name.
    static func limit(for ws: Workspace) -> Int? {
        let state = UISettingsStore.shared.state
        let key = ws.name.uppercased()
        guard let managed = state.workspaceLimits.workspaces.first(where: { $0.name == key }) else {
            return nil
        }
        guard let limit = managed.limit, limit > 0 else { return nil }
        return limit
    }

    /// Count BOTH tiled leaves and floating windows. Floating windows bind
    /// directly to the Workspace node, not into rootTilingContainer, so counting
    /// only tiling leaves would let a workspace full of floating windows never
    /// hit its limit.
    static func windowCount(of ws: Workspace) -> Int {
        ws.rootTilingContainer.allLeafWindowsRecursive.count + ws.floatingWindows.count
    }

    /// Resolve the live `Workspace` for a managed (UPPERCASED) name. Match is
    /// case-insensitive so a CLI-created lowercase workspace still binds to its
    /// managed entry instead of `Workspace.get(byName:)` minting an empty
    /// uppercase duplicate. Falls back to `get(byName:)` when nothing matches.
    static func resolveWorkspace(named managedName: String) -> Workspace {
        Workspace.all.first { $0.name.uppercased() == managedName.uppercased() }
            ?? Workspace.get(byName: managedName)
    }

    /// First managed workspace (in user-defined order) other than `source` that
    /// still has free capacity (unlimited, or current count < limit). Returns nil
    /// when there is nowhere to put a surplus window.
    static func overflowTarget(excluding source: Workspace) -> Workspace? {
        let state = UISettingsStore.shared.state
        let sourceKey = source.name.uppercased()
        for managed in state.workspaceLimits.workspaces {
            if managed.name.uppercased() == sourceKey { continue }
            let candidate = resolveWorkspace(named: managed.name)
            // Unlimited target always has room; limited target only if below limit.
            if let lim = managed.limit, lim > 0 {
                if windowCount(of: candidate) < lim {
                    return candidate
                }
            } else {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Move primitive

    /// Move `window` to `target` matching upstream `moveWindowToWorkspace`:
    /// a floating window binds to the Workspace node (preserving floating state),
    /// a tiled window to the root tiling container. Honours follow-focus.
    private static func move(_ window: Window, to target: Workspace) {
        window.unbindFromParent()
        let targetContainer: NonLeafTreeNodeObject = window.isFloating
            ? target
            : target.rootTilingContainer
        window.bind(
            to: targetContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: INDEX_BIND_LAST,
        )
        if UISettingsStore.shared.state.followFocusOnRoute {
            _ = target.focusWorkspace()
        }
    }

    // MARK: - Entry points

    /// Legacy entry point preserved for call sites (MacWindow on-window-detected).
    /// Repurposed to the new capacity enforcement.
    static func applyIfNeeded(_ window: Window) {
        enforceOnArrival(window)
    }

    /// On a new window arrival: if its workspace is now over its limit, push THIS
    /// (just-arrived) window to the overflow target. Applies to routed apps too.
    static func enforceOnArrival(_ window: Window) {
        let state = UISettingsStore.shared.state
        guard state.workspaceLimits.enabled else { return }
        guard let workspace = window.nodeWorkspace else { return }
        guard let lim = limit(for: workspace) else { return }
        guard windowCount(of: workspace) > lim else { return }

        guard let target = overflowTarget(excluding: workspace) else {
            DiagnosticsLog.shared.log(
                .routing,
                "Capacity: \(workspace.name) over limit \(lim) but no overflow target with free space — leaving window in place"
            )
            return
        }
        DiagnosticsLog.shared.log(
            .routing,
            "Capacity: \(workspace.name) over limit \(lim) — moving arriving window to \(target.name)"
        )
        move(window, to: target)
    }

    /// On a full reset (apply-routing / launch-homepage): for each managed
    /// workspace that is over its limit, keep the windows that BELONG there first
    /// (an app routing rule or window matcher targets this workspace), keep the
    /// first `limit`, and evict the rest one by one through `overflowTarget`,
    /// recomputing counts as we go so over-eviction doesn't miscount.
    static func enforceAllOnReset() {
        let state = UISettingsStore.shared.state
        guard state.workspaceLimits.enabled else { return }

        // A single pass is not enough: when several sources overflow into a
        // target that sits EARLIER in the list, that target was already
        // processed and can end up over its own limit. Repeat the eviction
        // pass until a full sweep makes no move (fixpoint), with a hard cap so
        // a pathological config (e.g. every target full) can never spin forever.
        let maxIterations = state.workspaceLimits.workspaces.count + 1
        for _ in 0..<maxIterations {
            var movedThisPass = false

            for managed in state.workspaceLimits.workspaces {
                guard let lim = managed.limit, lim > 0 else { continue }
                let workspace = resolveWorkspace(named: managed.name)
                let windows = workspace.rootTilingContainer.allLeafWindowsRecursive
                    + Array(workspace.floatingWindows)
                guard windows.count > lim else { continue }

                // Stable partition: windows that belong here (by routing) come first.
                let belongs = windows.filter { belongsTo(window: $0, workspaceName: managed.name) }
                let others = windows.filter { !belongsTo(window: $0, workspaceName: managed.name) }
                let ordered = belongs + others

                // Keep the first `lim`; evict the surplus tail one at a time.
                let surplus = ordered.dropFirst(lim)
                for window in surplus {
                    guard let target = overflowTarget(excluding: workspace) else {
                        DiagnosticsLog.shared.log(
                            .routing,
                            "Capacity reset: \(workspace.name) over limit \(lim) but no overflow target with free space — leaving surplus in place"
                        )
                        break
                    }
                    DiagnosticsLog.shared.log(
                        .routing,
                        "Capacity reset: evicting window from \(workspace.name) to \(target.name)"
                    )
                    move(window, to: target)
                    movedThisPass = true
                }
            }

            if !movedThisPass { break }
        }
    }

    /// True if `window`'s app has a routing rule (or window matcher) targeting
    /// `workspaceName`. Comparison is on the canonical UPPERCASED workspace name.
    private static func belongsTo(window: Window, workspaceName: String) -> Bool {
        guard let appId = window.app.rawAppBundleId else { return false }
        let key = workspaceName.uppercased()
        let state = UISettingsStore.shared.state
        for rule in state.appRouting where rule.appId == appId {
            if rule.workspace.uppercased() == key { return true }
            for matcher in rule.windowMatchers {
                if let override = matcher.workspaceOverride, override.uppercased() == key {
                    return true
                }
            }
        }
        return false
    }
}
