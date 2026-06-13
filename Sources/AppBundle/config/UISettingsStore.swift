import Common
import Foundation

let uiStateVersion = 1

struct UIState: Codable, Equatable {
    var version: Int = uiStateVersion
    var appRouting: [AppRoutingRule] = []
    var homepage: HomepageSettings = .default
    /// `nil` means "leave gaps to whatever the user has in their raw TOML";
    /// non-nil means UI is managing the `[gaps]` section.
    var gaps: GapsSettings? = nil
    var catchAll: CatchAllSettings = .default
    /// `nil` = "leave [mode.main.binding] to whatever the user has";
    /// non-nil = UI manages the keybinding table.
    var keybindings: [KeybindingRule]? = nil
    /// Phase 5: when true, on-window-detected emits the
    /// `--focus-follows-window` flag on `move-node-to-workspace`, so a newly
    /// routed window pulls focus to its target workspace. Same flag is
    /// honoured by the Swift hooks for catch-all reservation and slot
    /// placement so the user always sees where their window landed.
    var followFocusOnRoute: Bool = true
    /// Phase 6c: when true, clicking an app in the Dock follows the user to
    /// that app's workspace (instead of macOS's default — bring the app
    /// forward but keep workspace where it is). Implemented by an explicit
    /// handler in GlobalObserver (Phase 6b) once Honza's diagnostic 6a
    /// confirms whether one's needed at all.
    var followAppOnDockClick: Bool = true

    static let empty = UIState()

    init(
        version: Int = uiStateVersion,
        appRouting: [AppRoutingRule] = [],
        homepage: HomepageSettings = .default,
        gaps: GapsSettings? = nil,
        catchAll: CatchAllSettings = .default,
        keybindings: [KeybindingRule]? = nil,
        followFocusOnRoute: Bool = true,
        followAppOnDockClick: Bool = true,
    ) {
        self.version = version
        self.appRouting = appRouting
        self.homepage = homepage
        self.gaps = gaps
        self.catchAll = catchAll
        self.keybindings = keybindings
        self.followFocusOnRoute = followFocusOnRoute
        self.followAppOnDockClick = followAppOnDockClick
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? uiStateVersion
        appRouting = try c.decodeIfPresent([AppRoutingRule].self, forKey: .appRouting) ?? []
        homepage = try c.decodeIfPresent(HomepageSettings.self, forKey: .homepage) ?? .default
        gaps = try c.decodeIfPresent(GapsSettings.self, forKey: .gaps)
        catchAll = try c.decodeIfPresent(CatchAllSettings.self, forKey: .catchAll) ?? .default
        keybindings = try c.decodeIfPresent([KeybindingRule].self, forKey: .keybindings)
        followFocusOnRoute = try c.decodeIfPresent(Bool.self, forKey: .followFocusOnRoute) ?? true
        followAppOnDockClick = try c.decodeIfPresent(Bool.self, forKey: .followAppOnDockClick) ?? true
    }

    enum CodingKeys: String, CodingKey {
        case version, appRouting, homepage, gaps, catchAll, keybindings,
             followFocusOnRoute, followAppOnDockClick
    }
}

/// One row in the `[mode.main.binding]` table. Action stays as a raw string
/// because AeroSpace's grammar (multi-action sequences via `\;`, custom mode
/// switches, named modes) is wider than the preset list — but the UI exposes
/// `KeybindingActionTemplate` so users pick from a dropdown of common cases
/// instead of memorising syntax. Free-text fallback is still available via
/// the `.custom` template.
struct KeybindingRule: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// Shortcut in AeroSpace format, e.g. `alt-q`, `alt-shift-h`. Lowercase only.
    var shortcut: String
    /// Action string, e.g. `workspace q`, `focus left`, `reload-config`.
    var action: String
}

/// Predefined action presets surfaced in the Keybindings picker. Each case
/// owns the AeroSpace command syntax internally so the user never has to type
/// `workspace-back-and-forth` or remember whether it's `move` or `move-node`.
enum KeybindingActionTemplate: String, CaseIterable, Identifiable {
    // Workspace (parameterised → user types target workspace name)
    case workspaceSwitch          = "workspace"
    case workspaceMoveTo          = "move-node-to-workspace"
    case workspaceBackAndForth    = "workspace-back-and-forth"
    // Focus
    case focusLeft                = "focus left"
    case focusRight               = "focus right"
    case focusUp                  = "focus up"
    case focusDown                = "focus down"
    case focusBackAndForth        = "focus-back-and-forth"
    case focusNextMonitor         = "focus-monitor next"
    case focusPrevMonitor         = "focus-monitor prev"
    // Move window within workspace
    case moveLeft                 = "move left"
    case moveRight                = "move right"
    case moveUp                   = "move up"
    case moveDown                 = "move down"
    // Layout
    case layoutToggleFloatTile    = "layout floating tiling"
    case layoutTilesHV            = "layout tiles horizontal vertical"
    case layoutAccordionHV        = "layout accordion horizontal vertical"
    case fullscreen               = "fullscreen"
    case flattenTree              = "flatten-workspace-tree"
    // Window
    case closeWindow              = "close"
    case closeAllButCurrent       = "close-all-windows-but-current"
    // System
    case reloadConfig             = "reload-config"
    case launchHomepage           = "launch-homepage"
    case applyRouting             = "apply-routing"
    // Free-text escape hatch — preserves whatever is in `action` verbatim.
    case custom                   = ""

    var id: String { rawValue }

    /// True iff the template needs a user-supplied trailing argument
    /// (typically a workspace name like `q`).
    var requiresParameter: Bool {
        self == .workspaceSwitch || self == .workspaceMoveTo
    }

    /// Plain-language label for the dropdown.
    var displayName: String {
        switch self {
            case .workspaceSwitch:        return "Switch to workspace…"
            case .workspaceMoveTo:        return "Move window to workspace…"
            case .workspaceBackAndForth:  return "Switch to previous workspace"
            case .focusLeft:              return "Focus left"
            case .focusRight:             return "Focus right"
            case .focusUp:                return "Focus up"
            case .focusDown:              return "Focus down"
            case .focusBackAndForth:      return "Toggle focus back-and-forth"
            case .focusNextMonitor:       return "Focus next monitor"
            case .focusPrevMonitor:       return "Focus previous monitor"
            case .moveLeft:               return "Move window left"
            case .moveRight:              return "Move window right"
            case .moveUp:                 return "Move window up"
            case .moveDown:               return "Move window down"
            case .layoutToggleFloatTile:  return "Toggle floating ↔ tiling"
            case .layoutTilesHV:          return "Switch tiles orientation (H/V)"
            case .layoutAccordionHV:      return "Switch to accordion layout"
            case .fullscreen:             return "Toggle fullscreen"
            case .flattenTree:            return "Reset workspace layout"
            case .closeWindow:            return "Close window"
            case .closeAllButCurrent:     return "Close all but current"
            case .reloadConfig:           return "Reload config"
            case .launchHomepage:         return "Launch Homepage"
            case .applyRouting:           return "Apply routing to open windows"
            case .custom:                 return "Custom (raw action)"
        }
    }

    /// Section heading in the dropdown so the list scans cleanly.
    var category: String {
        switch self {
            case .workspaceSwitch, .workspaceMoveTo, .workspaceBackAndForth:
                return "Workspace"
            case .focusLeft, .focusRight, .focusUp, .focusDown,
                 .focusBackAndForth, .focusNextMonitor, .focusPrevMonitor:
                return "Focus"
            case .moveLeft, .moveRight, .moveUp, .moveDown:
                return "Move window"
            case .layoutToggleFloatTile, .layoutTilesHV, .layoutAccordionHV,
                 .fullscreen, .flattenTree:
                return "Layout"
            case .closeWindow, .closeAllButCurrent:
                return "Window"
            case .reloadConfig, .launchHomepage, .applyRouting:
                return "System"
            case .custom:
                return "Other"
        }
    }

    /// Reverse-detect which template best fits a raw action string. Used so
    /// existing rules from the JSON sidecar pick up the right preset on load.
    static func detect(from action: String) -> KeybindingActionTemplate {
        let trimmed = action.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .workspaceSwitch }
        // Parameterised templates: a present argument matches the prefix, but a
        // still-empty argument ("workspace " — what "Add binding" creates and
        // what clearing the workspace combo produces) trims down to the bare
        // command word and must resolve to the SAME template, not fall through
        // to `.custom`. Otherwise the picker bounces to "Custom (raw action)"
        // the moment the user clears the workspace, and an argument-less
        // `'workspace'` action would slip past the incomplete-row hold (`.custom`
        // requires no parameter) and reach the TOML, breaking reload-config.
        if trimmed == Self.workspaceSwitch.rawValue || trimmed.hasPrefix("workspace ") { return .workspaceSwitch }
        if trimmed == Self.workspaceMoveTo.rawValue || trimmed.hasPrefix("move-node-to-workspace ") { return .workspaceMoveTo }
        // Otherwise look for an exact match against any non-parameterised template.
        for template in KeybindingActionTemplate.allCases
        where template != .custom && !template.requiresParameter {
            if trimmed == template.rawValue { return template }
        }
        return .custom
    }

    /// Extract the parameter portion from an existing raw action string.
    static func parameter(from action: String, given template: KeybindingActionTemplate) -> String {
        let trimmed = action.trimmingCharacters(in: .whitespaces)
        switch template {
            case .workspaceSwitch:
                return String(trimmed.dropFirst("workspace ".count))
            case .workspaceMoveTo:
                return String(trimmed.dropFirst("move-node-to-workspace ".count))
            case .custom:
                return trimmed
            default:
                return ""
        }
    }

    /// Build the AeroSpace action string from a template + user parameter.
    func render(parameter: String) -> String {
        let cleanParam = parameter.trimmingCharacters(in: .whitespaces)
        switch self {
            case .workspaceSwitch:
                return "workspace \(cleanParam)"
            case .workspaceMoveTo:
                return "move-node-to-workspace \(cleanParam)"
            case .custom:
                return cleanParam
            default:
                return rawValue
        }
    }
}

/// Phase 3.5: redirect unrouted apps off "reserved" homepage workspaces once
/// they hit a window-count limit. A workspace is reserved iff at least one
/// AppRoutingRule targets it; that's the heuristic we use to decide what
/// counts as "homepage".
struct CatchAllSettings: Codable, Equatable {
    var enabled: Bool = false
    /// Threshold on the *number of windows already on the workspace* before a
    /// new unrouted window gets bumped. Default 3 — a value Honza picked.
    var workspaceLimit: Int = 3
    /// Workspaces eligible to receive redirected windows. Round-robin order.
    var catchAllWorkspaces: [String] = []

    static let `default` = CatchAllSettings()
}

struct GapsSettings: Codable, Equatable {
    /// Horizontal padding *between* tiled windows (pixels).
    var innerHorizontal: Int = 0
    /// Vertical padding *between* tiled windows (pixels).
    var innerVertical: Int = 0
    /// Padding from the screen edges, applied to both left and right.
    /// (Asymmetric outer gaps are intentionally not in the UI — edit the raw
    /// `[gaps]` TOML by hand if you need that.)
    var outerHorizontal: Int = 0
    /// Padding from the screen edges, applied to both top and bottom.
    var outerVertical: Int = 0
}

struct AppRoutingRule: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// CFBundleIdentifier — the key for `if.app-id` in `[[on-window-detected]]`.
    var appId: String
    /// Pretty name shown in the UI list.
    var displayName: String
    /// `/Applications/Foo.app` — used by Launch Homepage so we can `NSWorkspace.openApplication(at:)`.
    var appPath: String?
    /// Default workspace for windows of this app — used when no window matcher hits.
    var workspace: String
    var layout: AppLayout = .tiling
    /// Default slot when no window matcher hits. `.full` = no slot constraint.
    var slot: Slot = .full
    /// Per-window overrides matched by window-title substring/regex. First-match-wins;
    /// each matcher can override workspace and/or slot. Lets you put e.g.
    /// Finder window titled "Documents" on the left half and Finder window
    /// titled "Downloads" on the right half — same app, different positions.
    var windowMatchers: [WindowMatcher] = []

    init(
        id: UUID = UUID(),
        appId: String,
        displayName: String,
        appPath: String? = nil,
        workspace: String,
        layout: AppLayout = .tiling,
        slot: Slot = .full,
        windowMatchers: [WindowMatcher] = [],
    ) {
        self.id = id
        self.appId = appId
        self.displayName = displayName
        self.appPath = appPath
        self.workspace = workspace
        self.layout = layout
        self.slot = slot
        self.windowMatchers = windowMatchers
    }

    // Custom decoder so older JSON sidecars load with sensible defaults
    // instead of throwing on missing optional fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        appId = try c.decode(String.self, forKey: .appId)
        displayName = try c.decode(String.self, forKey: .displayName)
        appPath = try c.decodeIfPresent(String.self, forKey: .appPath)
        workspace = try c.decode(String.self, forKey: .workspace)
        layout = try c.decodeIfPresent(AppLayout.self, forKey: .layout) ?? .tiling
        slot = try c.decodeIfPresent(Slot.self, forKey: .slot) ?? .full
        windowMatchers = try c.decodeIfPresent([WindowMatcher].self, forKey: .windowMatchers) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id, appId, displayName, appPath, workspace, layout, slot, windowMatchers
    }
}

/// Per-window override under an AppRoutingRule. Matcher hits when the window
/// title contains `titleSubstring` (case-insensitive). When nil, the override
/// fields fall back to the parent rule's defaults.
struct WindowMatcher: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// Case-insensitive substring match against the window title. Empty
    /// string never matches (the matcher is treated as inactive).
    var titleSubstring: String = ""
    /// Override workspace for matching windows. nil = use parent rule's workspace.
    var workspaceOverride: String? = nil
    /// Override slot for matching windows. nil = use parent rule's slot.
    var slotOverride: Slot? = nil

    init(
        id: UUID = UUID(),
        titleSubstring: String = "",
        workspaceOverride: String? = nil,
        slotOverride: Slot? = nil,
    ) {
        self.id = id
        self.titleSubstring = titleSubstring
        self.workspaceOverride = workspaceOverride
        self.slotOverride = slotOverride
    }
}

/// Per-window slot inside a workspace. The placement logic lives in the
/// MacWindow.getOrRegister hook (Phase 3.6); TOML still just carries
/// `move-node-to-workspace`. `.full` means "no slot constraint".
enum Slot: String, Codable, CaseIterable, Identifiable {
    case full         = "full"
    case leftHalf     = "left-half"
    case rightHalf    = "right-half"
    case topHalf      = "top-half"
    case bottomHalf   = "bottom-half"
    case topLeft      = "top-left"
    case topRight     = "top-right"
    case bottomLeft   = "bottom-left"
    case bottomRight  = "bottom-right"

    var id: String { rawValue }

    var displayName: String {
        switch self {
            case .full:        return "Full workspace"
            case .leftHalf:    return "Left half"
            case .rightHalf:   return "Right half"
            case .topHalf:     return "Top half"
            case .bottomHalf:  return "Bottom half"
            case .topLeft:     return "Top left"
            case .topRight:    return "Top right"
            case .bottomLeft:  return "Bottom left"
            case .bottomRight: return "Bottom right"
        }
    }

    /// Two slots conflict when one is contained within the other (e.g. `leftHalf`
    /// covers `topLeft` + `bottomLeft`). Used by the UI to surface overlap warnings.
    ///
    /// `.full` is the "no slot constraint" sentinel — its placement is a runtime
    /// no-op (`placeWindowInSlot` returns false for `.full`), so it never claims a
    /// region and therefore never conflicts, not even with another `.full`. Two
    /// default `.full` rules on one workspace are a completely normal config; if
    /// `.full` counted as overlapping itself, that ordinary case would hold ALL
    /// TOML sync (gaps, keybindings, routing) forever (H1).
    func overlaps(_ other: Slot) -> Bool {
        if self == .full || other == .full { return false }
        if self == other { return true }
        let half: (Slot) -> Set<Slot> = {
            switch $0 {
                case .leftHalf:    return [.leftHalf, .topLeft, .bottomLeft]
                case .rightHalf:   return [.rightHalf, .topRight, .bottomRight]
                case .topHalf:     return [.topHalf, .topLeft, .topRight]
                case .bottomHalf:  return [.bottomHalf, .bottomLeft, .bottomRight]
                default:           return [$0]
            }
        }
        return !half(self).isDisjoint(with: half(other))
    }
}

enum AppLayout: String, Codable, CaseIterable, Identifiable {
    case tiling
    case floating

    var id: String { rawValue }
    var displayName: String {
        switch self {
            case .tiling:   return "Tiling"
            case .floating: return "Floating"
        }
    }
}

struct HomepageSettings: Codable, Equatable {
    var launchOnStartup: Bool = false

    static let `default` = HomepageSettings()
}

/// Sidecar JSON store. UI reads/writes `state` here; the TOML marker writer
/// (Phase 1.3) projects this into `~/.aerospace.toml` between markers.
@MainActor
final class UISettingsStore: ObservableObject {
    static let shared = UISettingsStore()

    @Published private(set) var state: UIState

    let url: URL

    /// P3 (perf): the JSON sidecar write is debounced. `update()` used to do
    /// createDirectory + full-state encode + atomic write on EVERY mutation —
    /// i.e. once per keystroke in the settings UI. The in-memory `state` (and
    /// thus the `@Published` UI + the TOML persister) is updated immediately,
    /// but the disk write is coalesced behind a short timer so a burst of edits
    /// hits the disk once. A clean quit flushes synchronously (see `flushNow`,
    /// wired from the app's termination paths) so nothing is lost on Cmd-Q; a
    /// hard crash can lose at most one debounce window of edits, which is
    /// acceptable for a UI-convenience sidecar.
    private var pendingWrite: Task<Void, Never>? = nil
    /// The state still owed to disk, or nil when the sidecar is up to date.
    /// Held so `flushNow()` can write the latest even if the timer hasn't fired.
    private var dirtyState: UIState? = nil
    private static let writeDebounceNanoseconds: UInt64 = 400_000_000

    private init() {
        let defaultUrl = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/aerospace/ui-state.json")
        self.url = defaultUrl
        self.state = (try? Self.read(from: defaultUrl)) ?? .empty
    }

    /// Apply an in-place mutation, publish immediately, and schedule a debounced
    /// disk write. The mutation can no longer fail (the encode/write moved off
    /// the synchronous path), but `throws` is kept so existing `try?` call sites
    /// stay valid; an encode failure now surfaces from the debounced write
    /// instead (logged, not thrown — there is no caller to catch it by then).
    func update(_ mutate: (inout UIState) -> Void) throws {
        var next = state
        mutate(&next)
        state = next
        scheduleWrite(next)
    }

    /// Coalesce the disk write: remember the latest state and (re)arm the timer.
    private func scheduleWrite(_ next: UIState) {
        dirtyState = next
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.writeDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.flushNow()
        }
    }

    /// Write any pending state to disk synchronously and clear the dirty flag.
    /// Safe to call when nothing is pending (no-op). Wired from the app's
    /// termination paths (clean Quit + signal handler) so a debounced edit is
    /// never lost on a graceful exit.
    func flushNow() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard let next = dirtyState else { return }
        dirtyState = nil
        do {
            try persist(next)
        } catch {
            DiagnosticsLog.shared.log(.sync, "ui-state write failed: \(error)")
        }
    }

    /// Created once (not per write — P3) the first time the sidecar directory
    /// is needed; FileManager.createDirectory is idempotent but the stat IPC it
    /// does was on the per-keystroke path.
    private var dirEnsured = false
    private func persist(_ state: UIState) throws {
        if !dirEnsured {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            dirEnsured = true
        }
        let data = try JSONEncoder.aeroSpaceDefault.encode(state)
        try data.write(to: url, options: [.atomic])
    }

    private static func read(from url: URL) throws -> UIState {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(UIState.self, from: data)
    }
}
