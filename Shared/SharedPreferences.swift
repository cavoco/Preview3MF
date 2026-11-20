import Foundation

/// Preferences shared between the host app and its sandboxed Quick Look extension
/// through the app group container.
enum SharedPreferences {
    static let suiteName = "XPBX8CKBGU.com.preview3mf"
    static let autoRotateByDefaultKey = "autoRotateByDefault"
    static let showModelInfoKey = "showModelInfo"

    /// Shared app-group defaults store, falling back to `.standard` if the suite
    /// cannot be opened (for example, in unsigned local builds).
    static let defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard

    static func autoRotateByDefault(in store: UserDefaults = defaults) -> Bool {
        if let value = store.object(forKey: autoRotateByDefaultKey) as? Bool {
            return value
        }
        return true
    }

    static func showModelInfo(in store: UserDefaults = defaults) -> Bool {
        if let value = store.object(forKey: showModelInfoKey) as? Bool {
            return value
        }
        return true
    }

    static func setShowModelInfo(_ value: Bool, in store: UserDefaults = defaults) {
        store.set(value, forKey: showModelInfoKey)
    }
}
