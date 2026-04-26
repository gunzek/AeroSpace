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
