import SwiftUI
import Combine
import Sparkle

/// Holds the Sparkle updater for the lifetime of the app. `canCheckForUpdates`
/// mirrors the updater's own state so the menu item greys out while a check is
/// already running.
final class UpdaterModel: ObservableObject {
    @Published var canCheckForUpdates = false

    let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

@main
struct Preview3MFApp: App {
    @StateObject private var updater = UpdaterModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.controller.checkForUpdates(nil)
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}
