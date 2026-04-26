import Common
import SwiftUI

public let settingsWindowId = "\(aeroSpaceAppName).settings"

@MainActor
public func getSettingsWindow() -> some Scene {
    SwiftUI.Window("AeroSpace Settings", id: settingsWindowId) {
        SettingsView()
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                for window in NSApplication.shared.windows where window.identifier?.rawValue == settingsWindowId {
                    window.level = .normal
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
            }
            .onDisappear {
                NSApp.setActivationPolicy(.accessory)
            }
    }
    .windowResizability(.contentMinSize)
}

struct SettingsView: View {
    @State private var selection: SettingsSection = .appRouting

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch selection {
                    case .appRouting: AppRoutingPlaceholder()
                    case .homepage:   HomepagePlaceholder()
                    case .keybindings: ComingSoonView(title: "Keybindings", phase: "Phase 2")
                    case .gaps:        ComingSoonView(title: "Gaps", phase: "Phase 2")
                    case .catchAll:    ComingSoonView(title: "Catch-all workspaces", phase: "Phase 3")
                    case .about:       AboutSection()
                }
            }
            .frame(minWidth: 480, minHeight: 360)
        }
        .frame(minWidth: 720, minHeight: 460)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case appRouting
    case homepage
    case keybindings
    case gaps
    case catchAll
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
            case .appRouting:  return "App Routing"
            case .homepage:    return "Homepage"
            case .keybindings: return "Keybindings"
            case .gaps:        return "Gaps"
            case .catchAll:    return "Catch-all"
            case .about:       return "About"
        }
    }

    var systemImage: String {
        switch self {
            case .appRouting:  return "rectangle.3.group"
            case .homepage:    return "house"
            case .keybindings: return "keyboard"
            case .gaps:        return "ruler"
            case .catchAll:    return "tray.2"
            case .about:       return "info.circle"
        }
    }
}

private struct AppRoutingPlaceholder: View {
    var body: some View {
        SettingsScaffold(title: "App Routing") {
            Text("Pin apps to specific workspaces. Coming in the next step of Phase 1.")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct HomepagePlaceholder: View {
    var body: some View {
        SettingsScaffold(title: "Homepage") {
            Text("Launch all routed apps with a single click. Wired up after App Routing is in place.")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct ComingSoonView: View {
    let title: String
    let phase: String

    var body: some View {
        SettingsScaffold(title: title) {
            Text("Planned for \(phase).")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct AboutSection: View {
    var body: some View {
        SettingsScaffold(title: "About") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(aeroSpaceAppName) v\(aeroSpaceAppVersion)")
                    .font(.headline)
                Text("Personal fork — \(gitShortHash)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct SettingsScaffold<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
