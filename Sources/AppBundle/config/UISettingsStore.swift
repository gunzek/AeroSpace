import Common
import Foundation

let uiStateVersion = 1

struct UIState: Codable, Equatable {
    var version: Int = uiStateVersion
    var appRouting: [AppRoutingRule] = []
    var homepage: HomepageSettings = .default

    static let empty = UIState()
}

struct AppRoutingRule: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// CFBundleIdentifier — the key for `if.app-id` in `[[on-window-detected]]`.
    var appId: String
    /// Pretty name shown in the UI list.
    var displayName: String
    /// `/Applications/Foo.app` — used by Launch Homepage so we can `NSWorkspace.openApplication(at:)`.
    var appPath: String?
    /// Workspace name (e.g. "q", "1", "main"). Free-form; matches `move-node-to-workspace <name>`.
    var workspace: String
    var layout: AppLayout = .tiling
    /// Per-window position within the workspace (Phase 3.6). `.full` = no slot constraint
    /// (default tiling behaviour); other values pin the window to a specific sub-area.
    var slot: Slot = .full

    init(
        id: UUID = UUID(),
        appId: String,
        displayName: String,
        appPath: String? = nil,
        workspace: String,
        layout: AppLayout = .tiling,
        slot: Slot = .full,
    ) {
        self.id = id
        self.appId = appId
        self.displayName = displayName
        self.appPath = appPath
        self.workspace = workspace
        self.layout = layout
        self.slot = slot
    }

    // Custom decoder so older JSON sidecars (pre-Phase-3.6, no `slot` field)
    // load with sensible defaults instead of throwing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        appId = try c.decode(String.self, forKey: .appId)
        displayName = try c.decode(String.self, forKey: .displayName)
        appPath = try c.decodeIfPresent(String.self, forKey: .appPath)
        workspace = try c.decode(String.self, forKey: .workspace)
        layout = try c.decodeIfPresent(AppLayout.self, forKey: .layout) ?? .tiling
        slot = try c.decodeIfPresent(Slot.self, forKey: .slot) ?? .full
    }

    enum CodingKeys: String, CodingKey {
        case id, appId, displayName, appPath, workspace, layout, slot
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
    func overlaps(_ other: Slot) -> Bool {
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

    private init() {
        let defaultUrl = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/aerospace/ui-state.json")
        self.url = defaultUrl
        self.state = (try? Self.read(from: defaultUrl)) ?? .empty
    }

    /// Test seam — lets unit tests target a temp file.
    init(url: URL) {
        self.url = url
        self.state = (try? Self.read(from: url)) ?? .empty
    }

    /// Apply an in-place mutation, persist, and publish. Mutation runs only if
    /// persist succeeds, so observers never see a state that didn't make it to disk.
    func update(_ mutate: (inout UIState) -> Void) throws {
        var next = state
        mutate(&next)
        try persist(next)
        state = next
    }

    func replace(_ next: UIState) throws {
        try persist(next)
        state = next
    }

    func reload() {
        if let loaded = try? Self.read(from: url) {
            state = loaded
        }
    }

    private func persist(_ state: UIState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let data = try JSONEncoder.aeroSpaceDefault.encode(state)
        try data.write(to: url, options: [.atomic])
    }

    private static func read(from url: URL) throws -> UIState {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(UIState.self, from: data)
    }
}
