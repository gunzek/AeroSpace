import AppKit
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

/// Window scaffold: sidebar + section router. All section content lives in
/// `ui/settings/<Name>Section.swift` — each renders its own grouped Form.
struct SettingsView: View {
    @State private var selection: SettingsSection = .appRouting
    @StateObject private var store = UISettingsStore.shared

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
                    case .appRouting:  AppRoutingSection(store: store)
                    case .homepage:    HomepageSection(store: store)
                    case .keybindings: KeybindingsSection(store: store)
                    case .gaps:        GapsSection(store: store)
                    case .catchAll:    CatchAllSection(store: store)
                    case .tweaks:      TweaksSection()
                    case .diagnostics: DiagnosticsSection()
                    case .about:       AboutSection(store: store)
                }
            }
            .navigationTitle(selection.title)
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
    case tweaks
    case diagnostics
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
            case .appRouting:  return "App Routing"
            case .homepage:    return "Homepage"
            case .keybindings: return "Keybindings"
            case .gaps:        return "Gaps"
            case .catchAll:    return "Catch-all"
            case .tweaks:      return "Tweaks"
            case .diagnostics: return "Diagnostics"
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
            case .tweaks:      return "gearshape.2"
            case .diagnostics: return "stethoscope"
            case .about:       return "info.circle"
        }
    }
}
