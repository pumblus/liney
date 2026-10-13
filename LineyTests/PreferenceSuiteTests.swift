import Foundation
import Testing

@MainActor
struct PreferenceSuiteTests {
    @Test
    func writingThroughASuiteLeavesNoPlist() async throws {
        let preferences = URL.libraryDirectory.appending(path: "Preferences")
        let testPlists = {
            Set(try FileManager.default.contentsOfDirectory(atPath: preferences.path(percentEncoded: false))
                .filter { $0.hasPrefix("LineyTests.") })
        }
        let before = try testPlists()
        let suite = PreferenceSuite()

        suite.defaults.set(true, forKey: "liney.requiresAppLock")

        #expect(suite.defaults.bool(forKey: "liney.requiresAppLock"))
        // cfprefsd writes a new domain's plist within milliseconds, so a second shows whether it would.
        try await waitUntil(timeout: .seconds(1)) { try testPlists() != before }
        #expect(try testPlists() == before)
    }
}
