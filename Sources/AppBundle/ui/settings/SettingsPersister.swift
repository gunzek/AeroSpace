import SwiftUI

/// Shared TOML-side persistence for the live-save settings model (Phase 7).
///
/// Sections write every UI change into the JSON sidecar (`UISettingsStore`)
/// immediately; the projection into `~/.aerospace.toml` + `reload-config` goes
/// through this helper instead of each section rolling its own save(). Two
/// entry points:
///
/// - `scheduleSync()` — 500 ms debounce. For rapid-fire controls (slider
///   drags) so we don't rewrite the TOML and re-layout every workspace on
///   each tick; only the state after the last tick gets written.
/// - `syncNow()` — immediate. For one-shot changes (toggles, add/remove)
///   where the extra half-second of latency would just feel laggy.
///
/// The TOML is always regenerated from the *full* current store state
/// (`TomlMarkerWriter.writeBlock`), so a coalesced sync writes exactly what a
/// per-change write would have — content identical, just fewer disk hits.
@MainActor
final class SettingsPersister: ObservableObject {
    static let shared = SettingsPersister()

    /// Which settings section a sync error belongs to. The persister is
    /// shared, but its errors are not all global: a `[gaps]`-conflict error
    /// shown under the Keybindings list (or vice versa) would only confuse.
    /// `SyncStatusFooter` uses this to show scoped errors in their own
    /// section only; `.general` errors (I/O failures, unsafe literals — the
    /// message names the offending field) render in every footer.
    enum ErrorScope {
        case gaps
        case keybindings
        case general
    }

    struct SyncError {
        let message: String
        let scope: ErrorScope
    }

    /// The last failed sync; nil after a successful one. Sections surface
    /// this inline via `SyncStatusFooter` — there is no Save button left to
    /// attach an error to.
    @Published var lastError: SyncError? = nil
    /// True while a TOML write + reload-config round-trip is in flight.
    @Published var syncing: Bool = false
    /// Non-nil while the TOML sync is held because the whole-state validity
    /// predicate (`SettingsValidity.holdReason`) failed. The hold is global —
    /// the persister projects the FULL store state, so a sync triggered from
    /// any section is held while *any* section's state is invalid. Published
    /// so `SyncStatusFooter` can explain in every section why nothing applied.
    @Published var holdReason: String? = nil

    private var debounceTask: Task<Void, Never>? = nil
    /// True while `performSync` is running (including a queued re-run).
    /// Unlike `syncing` this is not published — it's pure serialization
    /// bookkeeping, not UI state.
    private var syncInFlight = false
    /// Set when a sync arrives while another is in flight; the in-flight run
    /// loops once more after finishing, so the latest state always lands.
    private var needsResync = false
    private static let debounceNanoseconds: UInt64 = 500_000_000

    /// Debounced sync: (re)starts the 500 ms timer; the write happens once
    /// the user stops changing things.
    func scheduleSync() {
        refreshHoldReason()
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            // A newer change (or a syncNow) superseded this timer — bail
            // before touching disk so only the latest state gets written.
            guard !Task.isCancelled else { return }
            self?.debounceTask = nil
            await self?.performSync(trigger: "debounced")
        }
    }

    /// Edit-driven sync used by every section after mutating the store.
    /// `immediate` rule (consistent across all sections): one-shot discrete
    /// actions (toggles, row delete, import) sync now — a half-second lag on a
    /// single click just feels broken; binding-driven edits that can fire
    /// rapidly (typing, recording, picker churn) stay debounced. Previously
    /// each section carried a verbatim copy of this dispatch.
    func sync(immediate: Bool) {
        if immediate {
            syncNow()
        } else {
            scheduleSync()
        }
    }

    /// Immediate sync. Cancels any pending debounce first — the immediate
    /// write already covers whatever that timer was waiting to persist.
    func syncNow() {
        refreshHoldReason()
        debounceTask?.cancel()
        debounceTask = nil
        Task { @MainActor [weak self] in
            await self?.performSync(trigger: "immediate")
        }
    }

    /// Re-evaluate the validation hold against the current store state. Runs
    /// eagerly on every sync entry (so footers update without waiting for the
    /// debounce) and again inside `performSync` (the state may change while
    /// the debounce timer runs — the write-time check is the one with teeth).
    private func refreshHoldReason() {
        holdReason = SettingsValidity.holdReason(for: UISettingsStore.shared.state)
    }

    /// Serialized entry point: a sync issued while a previous one still
    /// awaits `reloadConfig()` must not overlap (it would clear `syncing`
    /// early and reload twice). Instead it parks a `needsResync` flag and the
    /// in-flight run performs one more pass after finishing — since every
    /// pass projects the *full* current store state, one trailing pass covers
    /// any number of parked requests.
    /// Diagnostics (phase 8): `.sync` lines are logged at FIRE time, not
    /// schedule time — a debounce timer that gets superseded never writes, so
    /// logging it would just spam. The same applies to the validation hold:
    /// it's logged here (once per sync attempt) rather than in
    /// `refreshHoldReason()`, which runs on every keystroke during a debounce.
    /// Each pass logs its own "started" line; the trailing pass triggered by
    /// a parked `needsResync` is labeled "(coalesced)" — it writes the full
    /// current state on behalf of however many requests parked, and reusing
    /// the first pass's trigger label would lie about who caused it.
    private func performSync(trigger: String) async {
        if syncInFlight {
            needsResync = true
            return
        }
        syncInFlight = true
        defer { syncInFlight = false }
        var passTrigger = trigger
        repeat {
            needsResync = false
            // Whole-state validity gate: the persister projects the FULL
            // store state, so per-section gating can't stop e.g. a Gaps
            // slider sync from flushing a held duplicate-shortcut draft into
            // TOML. When held, skip the write entirely — the JSON sidecar
            // keeps the draft, and because every section syncs after every
            // edit (and every pass projects full state), the first sync after
            // the state turns valid writes everything that was held.
            refreshHoldReason()
            if let holdReason {
                DiagnosticsLog.shared.log(.sync, "sync held: \(holdReason)")
                continue
            }
            DiagnosticsLog.shared.log(.sync, "sync started (\(passTrigger))")
            passTrigger = "coalesced"
            syncing = true
            await writeAndReload()
            syncing = false
        } while needsResync
    }

    /// Mirrors what the old per-section save() functions did: project the
    /// full UI state into the marker block, then reload-config inside a light
    /// session (skipped when the server is disabled, same as before).
    private func writeAndReload() async {
        do {
            let state = UISettingsStore.shared.state
            let configUrl = SettingsConfigPath.aerospaceTomlUrl()
            try TomlMarkerWriter.writeBlock(state: state, to: configUrl)
            if let token: RunSessionGuard = .isServerEnabled {
                try await runLightSession(.menuBarButton, token) { _ = try await reloadConfig() }
                DiagnosticsLog.shared.log(.sync, "wrote TOML + reload ok")
            } else {
                DiagnosticsLog.shared.log(.sync, "wrote TOML (server disabled, reload skipped)")
            }
            lastError = nil
        } catch TomlMarkerWriter.WriteError.duplicateGapsSection {
            lastError = SyncError(
                message: "Error: remove the existing [gaps] block from ~/.aerospace.toml before enabling UI-managed gaps.",
                scope: .gaps,
            )
        } catch TomlMarkerWriter.WriteError.duplicateBindingSection {
            lastError = SyncError(
                message: "Error: remove the existing [mode.main.binding] table from ~/.aerospace.toml before enabling UI-managed keybindings.",
                scope: .keybindings,
            )
        } catch let TomlMarkerWriter.WriteError.unsafeLiteral(field, value) {
            lastError = SyncError(
                message: "Error: \(field) contains an unsafe character ('\(value)'). Single quotes are not allowed.",
                scope: .general,
            )
        } catch {
            lastError = SyncError(message: "Error: \(error)", scope: .general)
        }
        // One error line covers all catch arms — lastError always reflects
        // THIS run here (success path nils it before falling through).
        if let lastError {
            DiagnosticsLog.shared.log(.sync, "sync error: \(lastError.message)")
        }
    }
}

/// Short-lived inline status line shown in a section footer (duplicate-app
/// guard, import results, apply confirmation). Replaces the per-section
/// `notice`/`noticeExpiry`/`showNotice` trio that App Routing and Keybindings
/// each carried — those had DRIFTED (4 s vs 6 s timeouts, and only one of them
/// styled "Error" messages red). One helper, one 5 s timeout, one styling rule.
@MainActor
final class SettingsNotice: ObservableObject {
    @Published private(set) var text: String? = nil
    private var expiry: Task<Void, Never>? = nil
    private static let timeoutNanoseconds: UInt64 = 5_000_000_000

    /// Show `message` and auto-clear it after the shared timeout. A later
    /// `show` supersedes an earlier one (the pending clear is cancelled).
    func show(_ message: String) {
        text = message
        expiry?.cancel()
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.text = nil
        }
    }

    /// Footer text styled by content: messages starting with "Error" render
    /// red, everything else secondary. (Keybindings did this; App Routing
    /// didn't — now both do.)
    @ViewBuilder
    func view() -> some View {
        if let text {
            Text(text)
                .foregroundStyle(text.hasPrefix("Error") ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
    }
}
