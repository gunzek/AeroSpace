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
            if !TrayMenuModel.shared.isEnabled { return }
            scheduleCancellableCompleteRefreshSession(.globalObserver(notifName), optimisticallyPreLayoutWorkspaces: true)

            guard !dockClickFollowGuard else { return }
            guard UISettingsStore.shared.state.followAppOnDockClick else { return }
            guard let bundleId else { return }

            let appWindows = MacWindow.allWindows.filter { $0.app.rawAppBundleId == bundleId }
            if appWindows.isEmpty { return }

            // Already on a workspace where this app has a window? Stay put —
            // the user only sees a *jump* if they're somewhere else.
            let currentWorkspace = focus.workspace
            if appWindows.contains(where: { $0.nodeWorkspace == currentWorkspace }) { return }

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
            else { return }
            guard let token: RunSessionGuard = .isServerEnabled else { return }

            dockClickFollowGuard = true
            defer { dockClickFollowGuard = false }
            try? await runLightSession(.globalObserver(notifName), token) {
                _ = targetWorkspace.focusWorkspace()
            }
        }
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
