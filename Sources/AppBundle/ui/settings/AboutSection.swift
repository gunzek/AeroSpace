import AppKit
import Common
import SwiftUI

/// About — version info and a pointer to the JSON sidecar backing the UI.
struct AboutSection: View {
    @ObservedObject var store: UISettingsStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Version") {
                    Text("\(aeroSpaceAppName) v\(aeroSpaceAppVersion)")
                }
                LabeledContent("Build") {
                    Text("Personal fork — \(gitShortHash)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Text(store.url.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.url])
                    }
                    .controlSize(.small)
                    .disabled(!FileManager.default.fileExists(atPath: store.url.path))
                }
            } header: {
                Text("UI state file")
            }
        }
        .formStyle(.grouped)
    }
}
