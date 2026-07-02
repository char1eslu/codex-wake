import SwiftUI

@main
struct CodexWakeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Codex Keeper") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: MainWindowMetrics.minimumSize.width, minHeight: MainWindowMetrics.minimumSize.height)
        }
        .defaultSize(width: MainWindowMetrics.defaultSize.width, height: MainWindowMetrics.defaultSize.height)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Install Command Line Tool...") {
                    Task { await model.installCommandLineTool() }
                }
                .disabled(model.isInstallingCommandLineTool || model.isUninstallingCommandLineTool)

                Button("Uninstall Command Line Tool...") {
                    Task { await model.uninstallCommandLineTool() }
                }
                .disabled(model.isInstallingCommandLineTool || model.isUninstallingCommandLineTool)
            }

            CommandGroup(replacing: .newItem) {
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Find") {
                    NotificationCenter.default.post(name: .codexWakeFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Clear Search") {
                    model.clearSearch()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(model.searchText.isEmpty)
            }
        }
    }
}

extension Notification.Name {
    static let codexWakeFocusSearch = Notification.Name("codexWakeFocusSearch")
    static let codexWakeNavigateThread = Notification.Name("codexWakeNavigateThread")
    static let codexWakeScrollDetail = Notification.Name("codexWakeScrollDetail")
}
