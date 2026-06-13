import AppKit
import Common

/// Phase 8 (M3). Real Dock-click detector that closes the gap in the
/// activation-based workspace follow (GlobalObserver.onActivate): macOS posts
/// NO didActivateApplicationNotification when the clicked Dock icon belongs to
/// the app that is ALREADY frontmost — e.g. the user switches to an empty
/// workspace (the previous app stays frontmost) and clicks that app's Dock
/// icon. The notification path sees nothing, so phase 6b silently did nothing.
///
/// This monitor watches raw left-mouse-ups, AX-hit-tests whether the click
/// landed on a Dock *app icon*, and:
///   - clicked app already frontmost  → runs the shared follow core itself
///     (GlobalObserver.followAppToItsWorkspace — the gap case)
///   - clicked app not frontmost      → logs and defers; the activation
///     notification WILL fire and onActivate handles it (no double-switch:
///     only one of the two paths ever acts on a given click)
@MainActor
enum DockClickMonitor {
    /// Guards against double installation (initObserver is called from app
    /// startup which should run once, but a leaked second global monitor
    /// would double-log every Dock click forever — cheap insurance).
    private static var installed = false

    /// The Dock's application AX element, cached by pid and re-resolved when
    /// the Dock restarts (killall Dock / crash — a stale element would return
    /// errors forever). Hit-testing against the Dock's app element instead of
    /// the system-wide element matters twice over:
    ///   1. Timeout scope. Per the AX header, setting a messaging timeout on
    ///      the SYSTEM-WIDE element sets it "globally for this process" — it
    ///      would silently cap every AX call AeroSpace makes (window reads,
    ///      resizes) at 0.1 s and break management of slow apps. On a regular
    ///      element the timeout applies to that element only.
    ///   2. Who gets messaged. The system-wide hit-test messages whatever
    ///      process owns the pixel under the cursor — a hung app would stall
    ///      the main thread on every click. The app-element variant only ever
    ///      talks to the Dock. (Trade-off: the hit-test is no longer occlusion-
    ///      aware across apps, but the Dock floats above normal windows and we
    ///      additionally require the clicked app to be frontmost, so a false
    ///      hit through some exotic overlay is harmless.)
    /// 0.1 s is plenty for the Dock — if the lookup times out it was not a
    /// Dock click worth acting on.
    ///
    /// P1 (perf): the Dock pid is now cached via NSWorkspace launch/terminate
    /// notifications instead of calling `runningApplications(...)` on EVERY
    /// click. That lookup is a synchronous IPC, and the .leftMouseUp handler
    /// fires for every system-wide left click — so it must never run per click
    /// on the common (non-Dock) path. The cache is invalidated when the Dock
    /// process terminates (crash / `killall Dock`) and lazily re-resolved on
    /// the next click that survives the geometric prefilter.
    private static var cachedDock: (pid: pid_t, element: AXUIElement)?

    /// Look up the Dock pid. Resolved lazily and cached until the Dock dies;
    /// the NSWorkspace.didTerminateApplicationNotification observer (initObserver)
    /// drops the cache so a restarted Dock gets a fresh element.
    private static func dockAppElement() -> AXUIElement? {
        if let cachedDock {
            // The didTerminate observer normally drops the cache when the Dock
            // dies, but notification delivery can lag a restart; verify the
            // cached pid is still live before trusting its element so a brief
            // stale-pid window (during a Dock restart) can't make us hit-test a
            // dead process. Cheap: this runs only on clicks that survived the
            // geometric prefilter (near a screen edge), not on every click.
            if NSRunningApplication(processIdentifier: cachedDock.pid) != nil {
                return cachedDock.element
            }
            self.cachedDock = nil
        }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier else { return nil }
        let element = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(element, 0.1)
        cachedDock = (pid, element)
        return element
    }

    /// Geometric pre-filter: the Dock occupies one screen edge (bottom / left /
    /// right), which is exactly the strip a screen's `frame` covers but its
    /// `visibleFrame` doesn't. Comparing the two per screen yields the Dock's
    /// band without any AX call; a click outside every band can't be on the
    /// Dock, so we skip the expensive AX hit-test (the overwhelmingly common
    /// case — almost every click lands inside a window, far from the edge).
    ///
    /// `point` is in Cocoa screen coordinates (bottom-left origin), the same as
    /// `NSScreen.frame`/`visibleFrame`, so no flip here. We widen each band by a
    /// margin to stay robust against rounding and the Dock's hover-magnification
    /// (icons grow past the resting band). When the Dock is hidden (auto-hide),
    /// frame==visibleFrame so no band exists — but a hidden Dock reveals on
    /// hover and the reveal still sits at the edge, so we also always allow a
    /// thin strip along each screen's outer edges as a fallback.
    private static func mightBeOnDock(cocoaScreenPoint point: CGPoint) -> Bool {
        // 80px, not a tight ~24px: when Dock magnification is on, a hovered icon
        // grows toward `largesize` (up to 128px) and its TOP edge rises well
        // past the resting band — a click there would otherwise be pre-filtered
        // out and silently miss the dock-follow. This prefilter is only a cheap
        // gate before the authoritative AX hit-test (which has no false
        // positives), so a generous band costs at most an occasional extra AX
        // call for a near-edge click and can never cause a false dock-follow.
        let margin: CGFloat = 80
        for screen in NSScreen.screens {
            let frame = screen.frame
            guard frame.contains(point) else { continue }
            let visible = screen.visibleFrame
            // Bottom band: visible bottom sits above the frame bottom.
            if visible.minY - frame.minY > 1, point.y <= visible.minY + margin { return true }
            // Left band: visible left sits right of the frame left.
            if visible.minX - frame.minX > 1, point.x <= visible.minX + margin { return true }
            // Right band: visible right sits left of the frame right.
            if frame.maxX - visible.maxX > 1, point.x >= visible.maxX - margin { return true }
            // Auto-hidden Dock (no inset): allow a thin reveal strip on the
            // bottom/left/right outer edges so a click on the just-revealed
            // Dock still gets hit-tested.
            if point.y <= frame.minY + margin { return true }
            if point.x <= frame.minX + margin { return true }
            if point.x >= frame.maxX - margin { return true }
        }
        return false
    }

    static func initObserver() {
        if installed { return }
        installed = true
        // P1: drop the cached Dock element when the Dock process dies, so a
        // restarted Dock (crash / `killall Dock`) gets a fresh element instead
        // of a stale one that errors forever. Matches the NSWorkspace observer
        // pattern in GlobalObserver.initObserver.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main,
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.dock" else { return }
            MainActor.assumeIsolated { cachedDock = nil }
        }
        // Global monitor (not CGEventTap): observes clicks delivered to OTHER
        // apps — the Dock — and is covered by the already-granted
        // Accessibility permission. No Input Monitoring permission involved.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { event in
            // NSEvent is not Sendable — extract the only scalar we need
            // before entering MainActor-isolated code. Global-monitor events
            // have no window, so locationInWindow IS in Cocoa screen
            // coordinates (bottom-left origin). Global monitor callbacks run
            // on the main thread but the closure is not MainActor-annotated;
            // assumeIsolated is the same pattern ShortcutRecorder uses.
            let cocoaScreenPoint = event.locationInWindow
            MainActor.assumeIsolated {
                handleLeftMouseUp(cocoaScreenPoint: cocoaScreenPoint)
            }
        }
    }

    private static func handleLeftMouseUp(cocoaScreenPoint: CGPoint) {
        // Cheap guards first: bail before ANY AX call when the result could
        // never be acted on. This handler fires for every left click anywhere
        // on the system, so the common path must stay near-free.
        if !TrayMenuModel.shared.isEnabled { return }
        if !UISettingsStore.shared.state.followAppOnDockClick { return }
        // P1: geometric pre-filter BEFORE any AX call. The Dock lives on a
        // screen edge; a click nowhere near an edge can't be on it, so skip the
        // synchronous AX hit-test IPC entirely — that's the common path for
        // nearly every click on screen.
        if !mightBeOnDock(cocoaScreenPoint: cocoaScreenPoint) { return }
        guard let bundleId = dockAppBundleId(atCocoaScreenPoint: cocoaScreenPoint) else {
            // Not a Dock app-icon click (regular window, desktop, trash,
            // folder, separator, minimized-window item, AX error, ...).
            // Deliberately silent: logging here would bury real events under
            // a line per click anywhere on screen.
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId else {
            // The activation notification is about to fire for this app —
            // onActivate runs the same shared core and logs its own decision.
            DiagnosticsLog.shared.log(.dockClick, "dock click \(bundleId) → deferring to activation handler")
            return
        }
        // The gap case: frontmost app re-clicked in the Dock → no activation
        // notification will come, we must follow here. The shared core
        // re-checks the toggle/guards (harmless) and flips
        // dockClickFollowGuard around the actual switch, so any activation
        // notifications *caused by* the switch are suppressed or land on
        // "window on current workspace" — same re-entry story as phase 6b.
        Task { @MainActor in
            let decision = await GlobalObserver.followAppToItsWorkspace(
                bundleId: bundleId,
                refreshEvent: .globalObserver("dockClickMonitor"),
            )
            DiagnosticsLog.shared.log(.dockClick, "dock click \(bundleId) (frontmost) → \(decision)")
        }
    }

    /// AX hit-test: returns the bundle id of the app whose Dock icon sits at
    /// the given point, or nil for anything else. Defensive on every step —
    /// AX can return errors, elements of overlapping windows, or items
    /// missing attributes (trash, folders, separators), and the monitor must
    /// never crash on weird elements.
    private static func dockAppBundleId(atCocoaScreenPoint point: CGPoint) -> String? {
        // Cocoa screen coordinates are bottom-left-origin; AX hit-testing
        // wants top-left-origin. Same flip as `mouseLocation` (mouse.swift) /
        // monitorFrameNormalized: y' = mainScreenHeight - y.
        let axPoint = CGPoint(x: point.x, y: mainMonitor.height - point.y)
        // Hit-test restricted to the Dock process (see dockAppElement) — a
        // miss (point not over any Dock element) returns an error, which is
        // exactly the silent "not a Dock click" path we want.
        guard let dock = dockAppElement() else { return nil }
        var hit: AXUIElement?
        guard unsafe AXUIElementCopyElementAtPosition(dock, Float(axPoint.x), Float(axPoint.y), &hit) == .success,
              let hit
        else { return nil }
        // The hit element is normally the dock item itself, but walk a couple
        // of parents just in case the hit lands on a child element. Bounded
        // walk — the Dock's AX tree is shallow (app element > list > item).
        // Per-element timeout: attribute reads message the Dock with the
        // GLOBAL timeout otherwise (the dock element's 0.1 s doesn't carry
        // over to elements it returns).
        var element = hit
        for _ in 0 ..< 3 {
            _ = AXUIElementSetMessagingTimeout(element, 0.1)
            if element.get(Ax.subroleAttr) == "AXApplicationDockItem" {
                // App dock items expose the bundle URL via AXURL. Items
                // without it (or with a non-bundle URL) are not app icons.
                guard let url = element.get(axUrlAttr) else { return nil }
                return Bundle(url: url)?.bundleIdentifier
            }
            guard let parent = element.get(axParentAttr) else { return nil }
            element = parent
        }
        return nil
    }
}

// Attributes the rest of the codebase doesn't need — kept private here
// instead of widening the shared Ax enum.

/// kAXURLAttribute of a Dock app item = file URL of the app bundle.
/// CFURL is toll-free bridged to NSURL which bridges to URL.
private let axUrlAttr = Ax.ReadableAttrImpl<URL>(
    key: kAXURLAttribute,
    getter: { $0 as? URL },
)

private let axParentAttr = Ax.ReadableAttrImpl<AXUIElement>(
    key: kAXParentAttribute,
    // CF types don't support `as?` runtime checks reliably — verify the
    // CFTypeID by hand before the (then guaranteed-safe) force cast.
    getter: { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil },
)
