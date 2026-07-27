import SwiftUI
import Combine
import Sparkle

/// Holds the Sparkle updater for the lifetime of the app. `canCheckForUpdates`
/// mirrors the updater's own state so the menu item greys out while a check is
/// already running.
final class UpdaterModel: ObservableObject {
    @Published var canCheckForUpdates = false

    /// Written straight back to Sparkle, which persists it in user defaults.
    @Published var checksAutomatically: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = checksAutomatically }
    }

    let controller: SPUStandardUpdaterController

    init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        // Read the existing preference rather than forcing a value, so a user who
        // already opted out stays opted out. `didSet` doesn't fire during init.
        self.checksAutomatically = controller.updater.automaticallyChecksForUpdates

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        Form {
            Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
            Text("Updates are verified against Preview3MF's signing key before they install.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 380)
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

        Settings {
            UpdateSettingsView(updater: updater)
        }
    }
}
