import AppKit
import Common

enum GlobalObserver {
    /// Phase 6b recursion guard. focusWorkspace() triggers downstream AX
    /// activity (focusing a window inside the new workspace), and some apps
    /// — most notoriously Arc / Chromium variants — react to that with
    /// another didActivateApplicationNotification, which would re-enter
    /// onDockClickActivate and yank us back. Without this latch you get a
    /// flicker loop. See AeroSpace discussion #1375.
    @MainActor private static var dockClickFollowGuard = false

    private static func onNotif(_ notification: Notification) {
        // Third line of defence against lock screen window. See: closedWindowsCache
        // Second and third lines of defence are technically needed only to avoid potential flickering
        if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == lockScreenAppBundleId {
            return
        }
        let notifName = notification.name.rawValue
        Task { @MainActor in
            if !TrayMenuModel.shared.isEnabled { return }
            if notifName == NSWorkspace.didActivateApplicationNotification.rawValue {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName), optimisticallyPreLayoutWorkspaces: true)
            } else {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName))
            }
        }
    }

    /// Phase 6b. Fires on every app activation — including Dock clicks. When
    /// `followAppOnDockClick` is on, finds the activated app's most-relevant
    /// window across all workspaces and switches AeroSpace to that workspace.
    /// Falls through to the upstream onNotif path so refresh + focus-cache
    /// updates still happen.
    private static func onActivate(_ notification: Notification) {
        let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if activatedApp?.bundleIdentifier == lockScreenAppBundleId { return }
        // Pull every value we need out of `notification` synchronously, before
        // hopping to the MainActor. The notification's userInfo dictionary
        // isn't Sendable, and capturing it in a Task triggers strict-
        // concurrency errors. The bundle id is a plain String which is fine.
        let notifName = notification.name.rawValue
        let bundleId = activatedApp?.bundleIdentifier
        Task { @MainActor in
            // Diagnostics (phase 8): every activation that reaches this
            // handler logs exactly one `.activation` line saying which exit
            // was taken. Lock-screen activations are filtered above on
            // purpose (pure noise). The app label falls back to "unknown-app"
            // for the two exits that fire before the bundleId guard.
            let appLabel = bundleId ?? "unknown-app"
            if !TrayMenuModel.shared.isEnabled {
                DiagnosticsLog.shared.log(.activation, "activated \(appLabel) → skipped: server disabled")
                return
            }
            scheduleCancellableCompleteRefreshSession(.globalObserver(notifName), optimisticallyPreLayoutWorkspaces: true)

            guard let bundleId else {
                DiagnosticsLog.shared.log(.activation, "activated unknown-app → skipped: no bundle id")
                return
            }
            // The follow core is shared with DockClickMonitor (M3) so the
            // tie-break logic exists exactly once; only the log category and
            // prefix differ between the two entry points.
            let decision = await followAppToItsWorkspace(bundleId: bundleId, refreshEvent: .globalObserver(notifName))
            DiagnosticsLog.shared.log(.activation, "activated \(bundleId) → \(decision)")
        }
    }

    /// Shared workspace-follow core (phase 6b logic, extracted in phase 8 M3).
    /// Called from two places that must behave identically:
    ///   - onActivate (didActivateApplicationNotification — Dock click on a
    ///     NON-frontmost app, cmd-tab, etc.)
    ///   - DockClickMonitor (raw Dock click on an ALREADY-frontmost app, where
    ///     macOS posts no activation notification at all)
    /// Returns a short decision string ("switched to W" / "skipped: <reason>")
    /// so each caller can log it under its own diagnostics category — the
    /// helper itself never logs, keeping activation vs dockClick lines
    /// distinguishable.
    @MainActor
    static func followAppToItsWorkspace(bundleId: String, refreshEvent: RefreshSessionEvent) async -> String {
        guard !dockClickFollowGuard else { return "skipped: re-entry guard" }
        guard UISettingsStore.shared.state.followAppOnDockClick else { return "skipped: follow-on-dock-click off" }

        let appWindows = MacWindow.allWindows.filter { $0.app.rawAppBundleId == bundleId }
        if appWindows.isEmpty { return "skipped: no known windows" }

        // Already on a workspace where this app has a window? Stay put —
        // the user only sees a *jump* if they're somewhere else.
        let currentWorkspace = focus.workspace
        if appWindows.contains(where: { $0.nodeWorkspace == currentWorkspace }) {
            return "skipped: window on current workspace \(currentWorkspace.name)"
        }

        // Tie-breaking when the app spans multiple non-current workspaces:
        //   1. a workspace that is already visible on some monitor (so the
        //      user can see the result without a heavy switch)
        //   2. mostRecent window of any workspace the app lives on
        //   3. just the first one we found
        let visibleNames = Set(monitors.map { $0.activeWorkspace.name })
        let target: MacWindow
        if let onVisible = appWindows.first(where: { ($0.nodeWorkspace?.name).map(visibleNames.contains) ?? false }) {
            target = onVisible
        } else {
            target = appWindows.first!
        }
        guard let targetWorkspace = target.nodeWorkspace,
              targetWorkspace != currentWorkspace
        else {
            return "skipped: target workspace unresolved"
        }
        guard let token: RunSessionGuard = .isServerEnabled else {
            return "skipped: server disabled"
        }

        dockClickFollowGuard = true
        defer { dockClickFollowGuard = false }
        do {
            try await runLightSession(refreshEvent, token) {
                _ = targetWorkspace.focusWorkspace()
            }
        } catch {
            // Same swallow-and-carry-on behavior as the previous `try?`, but
            // the log must not claim a switch that never ran.
            return "skipped: session for \(targetWorkspace.name) failed (\(error))"
        }
        return "switched to \(targetWorkspace.name)"
    }

    private static func onHideApp(_ notification: Notification) {
        let notifName = notification.name.rawValue
        Task { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.globalObserver(notifName), token) {
                if config.automaticallyUnhideMacosHiddenApps {
                    if let w = prevFocus?.windowOrNil,
                       w.macAppUnsafe.nsApp.isHidden,
                       // "Hide others" (cmd-alt-h) -> don't force focus
                       // "Hide app" (cmd-h) -> force focus
                       MacApp.allAppsMap.values.count(where: { $0.nsApp.isHidden }) == 1
                    {
                        // Force focus
                        _ = w.focusWindow()
                        w.nativeFocus()
                    }
                    for app in MacApp.allAppsMap.values {
                        app.nsApp.unhide()
                    }
                }
            }
        }
    }

    @MainActor
    static func initObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: onNotif)
        // Phase 6b: split didActivateApplicationNotification onto its own
        // handler so we can layer the Dock-click workspace-follow on top.
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: onActivate)
        nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main, using: onHideApp)
        nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: onNotif)

        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            // todo reduce number of refreshSession in the callback
            //  resetManipulatedWithMouseIfPossible might call its own refreshSession
            //  The end of the callback calls refreshSession
            Task { @MainActor in
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                try await resetManipulatedWithMouseIfPossible()
                let mouseLocation = mouseLocation
                let clickedMonitor = mouseLocation.monitorApproximation
                switch true {
                    // Detect clicks on desktop of different monitors
                    case clickedMonitor.activeWorkspace != focus.workspace:
                        _ = try await runLightSession(.globalObserverLeftMouseUp, token) {
                            clickedMonitor.activeWorkspace.focusWorkspace()
                        }
                    // Detect close button clicks for unfocused windows. Yes, kAXUIElementDestroyedNotification is that unreliable
                    //  And trigger new window detection that could be delayed due to mouseDown event
                    default:
                        scheduleCancellableCompleteRefreshSession(.globalObserverLeftMouseUp)
                }
            }
        }
    }
}
