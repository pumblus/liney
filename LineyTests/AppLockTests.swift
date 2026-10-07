import UIKit
import XCTest
import Testing
@testable import Liney

@MainActor
final class AppLockTests: XCTestCase {
    func testAuthenticationFinishingWhileInactiveKeepsSnapshotCovered() async {
        let authenticator = SuspendedAuthenticator()
        let lock = makeLock(authenticator)
        let unlockTask = Task { await lock.unlock() }
        while authenticator.completion == nil { await Task.yield() }
        lock.protectSnapshot()
        authenticator.completion?.resume(returning: true)
        await unlockTask.value
        XCTAssertTrue(lock.hidesJournalContent)
    }

    func testBackgroundInvalidatesPendingAuthenticationAndForegroundRetries() async {
        let authenticator = SuspendedAuthenticator()
        let lock = makeLock(authenticator)
        let first = Task { await lock.unlock() }
        while authenticator.completion == nil { await Task.yield() }
        lock.didEnterBackground()
        authenticator.completion?.resume(returning: true)
        await first.value
        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(lock.isSnapshotCovered)
        authenticator.completion = nil
        let retry = Task { await lock.unlock() }
        while authenticator.completion == nil { await Task.yield() }
        authenticator.completion?.resume(returning: true)
        await retry.value
        XCTAssertFalse(lock.hidesJournalContent)
    }

    func testInactiveAuthenticationSuccessDoesNotPromptAgainOnActive() async {
        let authenticator = SuspendedAuthenticator()
        let lock = makeLock(authenticator)
        let task = Task { await lock.unlock() }
        while authenticator.completion == nil { await Task.yield() }
        lock.protectSnapshot()
        authenticator.completion?.resume(returning: true)
        await task.value
        await lock.unlock()
        XCTAssertFalse(lock.hidesJournalContent)
    }

    func testDisablingLockIgnoresPendingAuthenticationFailure() async {
        let authenticator = SuspendedAuthenticator()
        let lock = makeLock(authenticator)
        let task = Task { await lock.unlock() }
        while authenticator.completion == nil { await Task.yield() }
        let disabled = await lock.setEnabled(false)
        authenticator.completion?.resume(returning: false)
        await task.value
        XCTAssertTrue(disabled)
        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.hidesJournalContent)
    }

    func testBackgroundInvalidatesPendingExportAuthorization() async {
        let authenticator = SuspendedAuthenticator()
        let lock = makeLock(authenticator)
        let task = Task { await lock.authenticateForExport() }
        while authenticator.completion == nil { await Task.yield() }
        lock.didEnterBackground()
        authenticator.completion?.resume(returning: true)
        let authorized = await task.value
        XCTAssertFalse(authorized)
        XCTAssertTrue(lock.hidesJournalContent)
    }

    func testSuccessfulLaunchAuthenticationShowsContent() async {
        let authenticator = FakeAuthenticator(results: [true])
        let lock = makeLock(authenticator)

        XCTAssertTrue(lock.hidesJournalContent)

        await lock.unlock()

        XCTAssertFalse(lock.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 1)
    }

    func testCancelledAuthenticationKeepsJournalLocked() async {
        let authenticator = FakeAuthenticator(results: [false])
        let lock = makeLock(authenticator)

        await lock.unlock()

        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(lock.hidesJournalContent)
        XCTAssertFalse(lock.isSnapshotCovered)
    }

    func testForegroundReturnRequiresAuthenticationAgain() async {
        let authenticator = FakeAuthenticator(results: [true, true])
        let lock = makeLock(authenticator)

        await lock.unlock()
        lock.protectSnapshot()
        lock.didEnterBackground()
        XCTAssertTrue(lock.isLocked)
        await lock.unlock()

        XCTAssertFalse(lock.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 2)
    }

    func testTemporaryInterruptionCoversWithoutRequiringAuthenticationAgain() async {
        let authenticator = FakeAuthenticator(results: [true])
        let lock = makeLock(authenticator)

        await lock.unlock()
        lock.protectSnapshot()
        XCTAssertTrue(lock.hidesJournalContent, "The app switcher snapshot stays covered while inactive")
        await lock.unlock()

        XCTAssertFalse(lock.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 1)
    }

    func testLockedScreenUnlockActionRetriesAuthentication() async {
        let authenticator = FakeAuthenticator(results: [false, true])
        let lock = makeLock(authenticator)

        await lock.unlock()
        await lock.unlock()

        XCTAssertFalse(lock.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 2)
    }

    func testSnapshotCoverOnlyAppliesWhenLockIsEnabled() {
        let disabled = makeLock(FakeAuthenticator(results: []), enabled: false)
        disabled.protectSnapshot()
        XCTAssertFalse(disabled.hidesJournalContent)

        let lock = makeLock(FakeAuthenticator(results: []))
        lock.protectSnapshot()
        XCTAssertTrue(lock.isSnapshotCovered)
        XCTAssertTrue(lock.hidesJournalContent)
    }

    func testExportReauthLocksAfterCancelledAuthentication() async {
        let authenticator = FakeAuthenticator(results: [false])
        let lock = makeLock(authenticator)

        let authorized = await lock.authenticateForExport()

        XCTAssertFalse(authorized)
        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(lock.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 1)
    }

    func testExportWithoutAppLockDoesNotAuthenticate() async {
        let authenticator = FakeAuthenticator(results: [])
        let lock = makeLock(authenticator, enabled: false)

        let authorized = await lock.authenticateForExport()

        XCTAssertTrue(authorized)
        XCTAssertFalse(lock.hidesJournalContent)
        XCTAssertTrue(lock.isLocked, "Export without App Lock leaves lock state untouched")
        XCTAssertEqual(authenticator.callCount, 0)
    }

    func testGateMountsContentBehindInitialLockCover() async {
        let lock = makeLock(FakeAuthenticator(results: []))
        let probe = MountProbe()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = MountProbeViewController(probe: probe)
        window.makeKeyAndVisible()
        let shield = JournalPrivacyShield(window: window, appLock: lock)
        shield.update()
        defer { shield.cover.isHidden = true; window.isHidden = true }
        await flushUIKitUpdates()

        XCTAssertTrue(lock.hidesJournalContent)
        XCTAssertFalse(shield.cover.isHidden)
        XCTAssertFalse(window.isUserInteractionEnabled)
        XCTAssertTrue(window.accessibilityElementsHidden)
        XCTAssertEqual(probe.appearances, 1)
        XCTAssertEqual(probe.disappearances, 0)
        window.isHidden = true
    }

    func testGateKeepsUnlockedContentMountedBehindLockCover() async {
        let authenticator = FakeAuthenticator(results: [true])
        let lock = makeLock(authenticator)
        await lock.unlock()

        let probe = MountProbe()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = MountProbeViewController(probe: probe)
        window.makeKeyAndVisible()
        let shield = JournalPrivacyShield(window: window, appLock: lock)
        shield.update()
        defer { shield.cover.isHidden = true; window.isHidden = true }
        await flushUIKitUpdates()

        XCTAssertEqual(probe.appearances, 1)
        XCTAssertEqual(probe.disappearances, 0)

        lock.protectSnapshot()
        await flushUIKitUpdates()

        XCTAssertTrue(lock.hidesJournalContent)
        XCTAssertFalse(shield.cover.isHidden)
        XCTAssertFalse(window.isUserInteractionEnabled)
        XCTAssertTrue(window.accessibilityElementsHidden)
        XCTAssertEqual(probe.appearances, 1)
        XCTAssertEqual(probe.disappearances, 0)
        window.isHidden = true
    }

    func testSettingsRenderInDarkModeAndLargestDynamicType() async throws {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = SettingsViewController(appLock: makeLock(FakeAuthenticator(results: [])))
        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        controller.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        window.makeKeyAndVisible()
        await flushUIKitUpdates()

        let renderedView = try XCTUnwrap(window.rootViewController?.view)
        renderedView.setNeedsLayout()
        renderedView.layoutIfNeeded()
        XCTAssertEqual(renderedView.window, window)
        XCTAssertFalse(renderedView.bounds.isEmpty)
        window.isHidden = true
    }

    func testPrivacyCoverProtectsPresentedSheetAndKeyboardUntilUnlock() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let sheet = UIViewController()
        let input = UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        input.text = "Synthetic private input"
        sheet.view.addSubview(input)
        root.present(sheet, animated: false)
        await flushUIKitUpdates()
        input.becomeFirstResponder()
        let lock = makeLock(FakeAuthenticator(results: [true]))
        let shield = JournalPrivacyShield(window: window, appLock: lock)
        defer { shield.cover.isHidden = true }
        shield.update()
        XCTAssertTrue(shield.cover.isKeyWindow)
        XCTAssertFalse(input.isFirstResponder)
        XCTAssertTrue(root.presentedViewController === sheet)
        XCTAssertTrue(window.accessibilityElementsHidden)
        XCTAssertFalse(window.isUserInteractionEnabled)
        await lock.unlock()
        XCTAssertTrue(shield.cover.isHidden)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertFalse(window.accessibilityElementsHidden)
        XCTAssertTrue(window.isUserInteractionEnabled)
        XCTAssertTrue(root.presentedViewController === sheet)
        XCTAssertEqual(input.text, "Synthetic private input")
        root.dismiss(animated: false)
    }

    func testPrivacyCoverIsNotShownWhenLockIsDisabled() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let lock = makeLock(FakeAuthenticator(results: []), enabled: false)
        let shield = JournalPrivacyShield(window: window, appLock: lock)
        shield.update()
        XCTAssertTrue(shield.cover.isHidden)
        XCTAssertTrue(window.isUserInteractionEnabled)
        XCTAssertFalse(window.accessibilityElementsHidden)
    }

    private func makeLock(_ authenticator: some AppAuthenticating, enabled: Bool = true) -> AppLockModel {
        let suite = PreferenceSuite()
        addTeardownBlock { suite.remove() }
        return suite.makeLock(authenticator, enabled: enabled)
    }

    private func flushUIKitUpdates() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor
final class AppLockCopyTests {
    private let suite = PreferenceSuite()
    deinit { suite.remove() }

    @Test
    func disablingNeedsNoAuthenticationAndClearsTheLock() async {
        let authenticator = FakeAuthenticator(results: [])
        let lock = suite.makeLock(authenticator, enabled: true)
        #expect(lock.hidesJournalContent)

        let disabled = await lock.setEnabled(false)

        #expect(disabled)
        #expect(!lock.isEnabled)
        #expect(!lock.isLocked)
        #expect(!lock.isSnapshotCovered)
        #expect(authenticator.callCount == 0)
    }

    @Test
    func preferenceKeepsTheStoredKey() async {
        suite.defaults.set(true, forKey: "liney.requiresAppLock")
        let lock = AppLockModel(authenticator: FakeAuthenticator(results: [true]), defaults: suite.defaults)
        #expect(lock.isEnabled, "Users who already enabled App Lock stay locked after updating")

        _ = await lock.setEnabled(false)
        #expect(suite.defaults.object(forKey: "liney.requiresAppLock") as? Bool == false)

        #expect(await lock.setEnabled(true))
        #expect(suite.defaults.object(forKey: "liney.requiresAppLock") as? Bool == true)
    }

    @Test
    func backgroundRelocksAnUnlockedJournal() async {
        let lock = suite.makeLock(FakeAuthenticator(results: [true]), enabled: true)
        await lock.unlock()
        #expect(!lock.hidesJournalContent)

        lock.didEnterBackground()

        #expect(lock.isLocked)
        #expect(lock.isSnapshotCovered)
        #expect(lock.hidesJournalContent)
    }

    @Test
    func exportAuthenticationUnlocksTheJournal() async {
        let authenticator = FakeAuthenticator(results: [true])
        let lock = suite.makeLock(authenticator, enabled: true)

        #expect(await lock.authenticateForExport())
        #expect(!lock.isLocked)
        #expect(authenticator.reasons == [String(localized: "Authenticate to export your journal.")])
    }

    @Test(arguments: [true, false])
    func enablingSurvivesAuthenticationPromptLifecycle(returnsActiveBeforeReply: Bool) async {
        let authenticator = SuspendedAuthenticator()
        let lock = makeLock(authenticator)
        await lock.unlock()
        let task = Task { await lock.setEnabled(true) }
        while authenticator.completion == nil { await Task.yield() }

        // The preference is written only after authentication returns.
        lock.protectSnapshot()
        if returnsActiveBeforeReply {
            await lock.unlock()
        }
        authenticator.completion?.resume(returning: true)
        let enabled = await task.value

        #expect(enabled)
        #expect(lock.isEnabled)
        #expect(!lock.isAuthenticating)
        #expect(!lock.hidesJournalContent)
    }

    @Test(arguments: [true, false])
    func enablingRejectsAuthenticationAfterBackgroundOrExplicitDisable(background: Bool) async {
        let authenticator = SuspendedAuthenticator()
        let lock = makeLock(authenticator)
        await lock.unlock()
        let task = Task { await lock.setEnabled(true) }
        while authenticator.completion == nil { await Task.yield() }

        if background { lock.didEnterBackground() }
        else { _ = await lock.setEnabled(false) }
        authenticator.completion?.resume(returning: true)

        let enabled = await task.value
        #expect(!enabled)
        #expect(!lock.isEnabled)
        #expect(!lock.isAuthenticating)
    }

    @Test(arguments: [true, false])
    func enablingUsesDeviceNeutralAuthenticationReason(success: Bool) async {
        let authenticator = FakeAuthenticator(results: [success])
        let lock = makeLock(authenticator)

        let enabled = await lock.setEnabled(true)

        #expect(enabled == success)
        #expect(lock.isEnabled == success)
        #expect(lock.isLocked == !success)
        #expect(!lock.isAuthenticating)
        #expect(authenticator.reasons == [String(localized: "Authenticate to enable App Lock for Liney.")])
    }

    @Test
    func settingsLabelsTheToggleAsAppLock() throws {
        let controller = SettingsViewController(appLock: makeLock(FakeAuthenticator(results: [])))
        controller.loadViewIfNeeded()
        let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        let content = try #require(cell.contentConfiguration as? UIListContentConfiguration)
        let toggle = try #require(cell.accessoryView as? UISwitch)

        #expect(content.text == String(localized: "App Lock"))
        #expect(toggle.accessibilityLabel == content.text)
        #expect(content.image == UIImage(systemName: "lock"))
    }

    /// Starts with App Lock disabled, as Settings sees it before the user turns it on.
    private func makeLock(_ authenticator: some AppAuthenticating) -> AppLockModel {
        suite.makeLock(authenticator, enabled: false)
    }
}

/// An isolated preference store, so App Lock tests never read or write the app's standard defaults.
private struct PreferenceSuite {
    let name = "AppLockTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: name)! }

    @MainActor
    func makeLock(_ authenticator: some AppAuthenticating, enabled: Bool) -> AppLockModel {
        defaults.set(enabled, forKey: "liney.requiresAppLock")
        return AppLockModel(authenticator: authenticator, defaults: defaults)
    }

    func remove() { defaults.removePersistentDomain(forName: name) }
}

private final class FakeAuthenticator: AppAuthenticating {
    private var results: [Bool]
    private(set) var callCount = 0
    private(set) var reasons: [String] = []

    init(results: [Bool]) {
        self.results = results
    }

    func authenticate(reason: String) async -> Bool {
        callCount += 1
        reasons.append(reason)
        return results.isEmpty ? false : results.removeFirst()
    }
}

private final class MountProbe {
    var appearances = 0
    var disappearances = 0
}

private final class MountProbeViewController: UIViewController {
    let probe: MountProbe
    init(probe: MountProbe) { self.probe = probe; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); probe.appearances += 1 }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); probe.disappearances += 1 }
}

private final class SuspendedAuthenticator: AppAuthenticating {
    var completion: CheckedContinuation<Bool, Never>?
    func authenticate(reason: String) async -> Bool {
        await withCheckedContinuation { completion = $0 }
    }
}
