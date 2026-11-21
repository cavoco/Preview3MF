import XCTest
@testable import Preview3MF

final class SharedPreferencesTests: XCTestCase {
    func testAutoRotateDefaultsToTrueAndRespectsStoredOverride() {
        let suite = "Preview3MFTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }

        XCTAssertTrue(SharedPreferences.autoRotateByDefault(in: store))

        store.set(false, forKey: SharedPreferences.autoRotateByDefaultKey)
        XCTAssertFalse(SharedPreferences.autoRotateByDefault(in: store))

        store.set(true, forKey: SharedPreferences.autoRotateByDefaultKey)
        XCTAssertTrue(SharedPreferences.autoRotateByDefault(in: store))
    }

    func testShowModelInfoDefaultsToTrueAndRespectsStoredOverride() {
        let suite = "Preview3MFTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }

        XCTAssertTrue(SharedPreferences.showModelInfo(in: store))

        store.set(false, forKey: SharedPreferences.showModelInfoKey)
        XCTAssertFalse(SharedPreferences.showModelInfo(in: store))

        store.set(true, forKey: SharedPreferences.showModelInfoKey)
        XCTAssertTrue(SharedPreferences.showModelInfo(in: store))
    }
}
