import UIKit
import XCTest
import Testing
@testable import Liney

@MainActor
final class AppLockTests: XCTestCase {
    func testAuthenticationFinishingWhileInactiveKeepsSnapshotCovered() async {
        let authenticator = SuspendedAuthenticator()
        let lock = AppLockModel(authenticator: authenticator)
        let unlockTask = Task { await lock.unlockIfNeeded(requiresLock: true) }
        while authenticator.completion == nil { await Task.yield() }
        lock.protectSnapshot(requiresLock: true)
        authenticator.completion?.resume(returning: true)
        await unlockTask.value
        XCTAssertTrue(lock.hidesJournalContent)
    }

    func testBackgroundInvalidatesPendingAuthenticationAndForegroundRetries() async {
        let authenticator = SuspendedAuthenticator()
        let lock = AppLockModel(authenticator: authenticator)
        let first = Task { await lock.unlockIfNeeded(requiresLock: true) }
        while authenticator.completion == nil { await Task.yield() }
        lock.didEnterBackground(requiresLock: true)
        authenticator.completion?.resume(returning: true)
        await first.value
        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(lock.isSnapshotCovered)
        authenticator.completion = nil
        let retry = Task { await lock.unlockIfNeeded(requiresLock: true) }
        while authenticator.completion == nil { await Task.yield() }
        authenticator.completion?.resume(returning: true)
        await retry.value
        XCTAssertFalse(lock.hidesJournalContent)
    }

    func testInactiveAuthenticationSuccessDoesNotPromptAgainOnActive() async {
        let authenticator = SuspendedAuthenticator()
        let lock = AppLockModel(authenticator: authenticator)
        let task = Task { await lock.unlockIfNeeded(requiresLock: true) }
        while authenticator.completion == nil { await Task.yield() }
        lock.protectSnapshot(requiresLock: true)
        authenticator.completion?.resume(returning: true)
        await task.value
        await lock.unlockIfNeeded(requiresLock: true)
        XCTAssertFalse(lock.hidesJournalContent)
    }

    func testDisablingLockIgnoresPendingAuthenticationFailure() async {
        let authenticator = SuspendedAuthenticator()
        let lock = AppLockModel(authenticator: authenticator)
        let task = Task { await lock.unlockIfNeeded(requiresLock: true) }
        while authenticator.completion == nil { await Task.yield() }
        lock.disableLock()
        authenticator.completion?.resume(returning: false)
        await task.value
        XCTAssertFalse(lock.hidesJournalContent)
    }

    func testBackgroundInvalidatesPendingExportAuthorization() async {
        let authenticator = SuspendedAuthenticator()
        let lock = AppLockModel(authenticator: authenticator)
        let task = Task { await lock.authenticateForExport(requiresLock: true) }
        while authenticator.completion == nil { await Task.yield() }
        lock.didEnterBackground(requiresLock: true)
        authenticator.completion?.resume(returning: true)
        let authorized = await task.value
        XCTAssertFalse(authorized)
        XCTAssertTrue(lock.hidesJournalContent)
    }

    func testSuccessfulLaunchAuthenticationShowsContent() async {
        let authenticator = FakeAuthenticator(results: [true])
        let lock = AppLockModel(authenticator: authenticator)

        XCTAssertTrue(lock.hidesJournalContent)

        await lock.unlockIfNeeded(requiresLock: true)

        XCTAssertFalse(lock.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 1)
    }

    func testCancelledAuthenticationKeepsJournalLocked() async {
        let authenticator = FakeAuthenticator(results: [false])
        let lock = AppLockModel(authenticator: authenticator)

        await lock.unlockIfNeeded(requiresLock: true)

        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(lock.hidesJournalContent)
        XCTAssertFalse(lock.isSnapshotCovered)
    }

    func testForegroundReturnRequiresAuthenticationAgain() async {
        let authenticator = FakeAuthenticator(results: [true, true])
        let lock = AppLockModel(authenticator: authenticator)

        await lock.unlockIfNeeded(requiresLock: true)
        lock.protectSnapshot(requiresLock: true)
        lock.didEnterBackground(requiresLock: true)
        XCTAssertTrue(lock.isLocked)
        await lock.unlockIfNeeded(requiresLock: true)

        XCTAssertFalse(lock.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 2)
    }

    func testTemporaryInterruptionCoversWithoutRequiringAuthenticationAgain() async {
        let authenticator = FakeAuthenticator(results: [true])
        let lock = AppLockModel(authenticator: authenticator)

        await lock.unlockIfNeeded(requiresLock: true)
        lock.protectSnapshot(requiresLock: true)
        XCTAssertTrue(lock.hidesJournalContent, "The app switcher snapshot stays covered while inactive")
        await lock.unlockIfNeeded(requiresLock: true)

        XCTAssertFalse(lock.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 1)
    }

    func testLockedScreenUnlockActionRetriesAuthentication() async {
        let authenticator = FakeAuthenticator(results: [false, true])
        let lock = AppLockModel(authenticator: authenticator)

        await lock.unlockIfNeeded(requiresLock: true)
        await lock.unlock(requiresLock: true)

        XCTAssertFalse(lock.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 2)
    }

    func testSnapshotCoverOnlyAppliesWhenLockIsEnabled() {
        let lock = AppLockModel(authenticator: FakeAuthenticator(results: []))

        lock.protectSnapshot(requiresLock: false)
        XCTAssertFalse(lock.hidesJournalContent)

        lock.protectSnapshot(requiresLock: true)
        XCTAssertTrue(lock.isSnapshotCovered)
        XCTAssertTrue(lock.hidesJournalContent)
    }

    func testExportReauthLocksAfterCancelledAuthentication() async {
        let authenticator = FakeAuthenticator(results: [false])
        let lock = AppLockModel(authenticator: authenticator)

        let authorized = await lock.authenticateForExport(requiresLock: true)

        XCTAssertFalse(authorized)
        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(lock.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 1)
    }

    func testExportWithoutAppLockDoesNotAuthenticate() async {
        let authenticator = FakeAuthenticator(results: [])
        let lock = AppLockModel(authenticator: authenticator)

        let authorized = await lock.authenticateForExport(requiresLock: false)

        XCTAssertTrue(authorized)
        XCTAssertFalse(lock.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 0)
    }

    func testGateMountsContentBehindInitialLockCover() async {
        let lock = AppLockModel(authenticator: FakeAuthenticator(results: []))
        let probe = MountProbe()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = MountProbeViewController(probe: probe)
        window.makeKeyAndVisible()
        let shield = JournalPrivacyShield(window: window, appLock: lock, requiresLock: { true })
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
        let lock = AppLockModel(authenticator: authenticator)
        await lock.unlockIfNeeded(requiresLock: true)

        let probe = MountProbe()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = MountProbeViewController(probe: probe)
        window.makeKeyAndVisible()
        let shield = JournalPrivacyShield(window: window, appLock: lock, requiresLock: { true })
        shield.update()
        defer { shield.cover.isHidden = true; window.isHidden = true }
        await flushUIKitUpdates()

        XCTAssertEqual(probe.appearances, 1)
        XCTAssertEqual(probe.disappearances, 0)

        lock.protectSnapshot(requiresLock: true)
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
        let controller = SettingsViewController(appLock: AppLockModel(authenticator: FakeAuthenticator(results: [])))
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
        let lock = AppLockModel(authenticator: FakeAuthenticator(results: [true]))
        let shield = JournalPrivacyShield(window: window, appLock: lock, requiresLock: { true })
        defer { shield.cover.isHidden = true }
        shield.update()
        XCTAssertTrue(shield.cover.isKeyWindow)
        XCTAssertFalse(input.isFirstResponder)
        XCTAssertTrue(root.presentedViewController === sheet)
        XCTAssertTrue(window.accessibilityElementsHidden)
        XCTAssertFalse(window.isUserInteractionEnabled)
        await lock.unlockIfNeeded(requiresLock: true)
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
        let lock = AppLockModel(authenticator: FakeAuthenticator(results: []))
        let shield = JournalPrivacyShield(window: window, appLock: lock, requiresLock: { false })
        shield.update()
        XCTAssertTrue(shield.cover.isHidden)
        XCTAssertTrue(window.isUserInteractionEnabled)
        XCTAssertFalse(window.accessibilityElementsHidden)
    }

    private func flushUIKitUpdates() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor
struct AppLockCopyTests {
    @Test(arguments: [true, false])
    func enablingSurvivesAuthenticationPromptLifecycle(returnsActiveBeforeReply: Bool) async {
        let authenticator = SuspendedAuthenticator()
        let lock = AppLockModel(authenticator: authenticator)
        await lock.unlockIfNeeded(requiresLock: false)
        let task = Task { await lock.authenticateToEnable() }
        while authenticator.completion == nil { await Task.yield() }

        // Settings persists the enabled preference only after authentication returns.
        lock.protectSnapshot(requiresLock: false)
        if returnsActiveBeforeReply {
            await lock.unlockIfNeeded(requiresLock: false)
        }
        authenticator.completion?.resume(returning: true)
        let enabled = await task.value

        #expect(enabled)
        #expect(!lock.isAuthenticating)
        #expect(!lock.hidesJournalContent)
    }

    @Test(arguments: [true, false])
    func enablingRejectsAuthenticationAfterBackgroundOrExplicitDisable(background: Bool) async {
        let authenticator = SuspendedAuthenticator()
        let lock = AppLockModel(authenticator: authenticator)
        await lock.unlockIfNeeded(requiresLock: false)
        let task = Task { await lock.authenticateToEnable() }
        while authenticator.completion == nil { await Task.yield() }

        if background { lock.didEnterBackground(requiresLock: false) }
        else { lock.disableLock() }
        authenticator.completion?.resume(returning: true)

        let enabled = await task.value
        #expect(!enabled)
        #expect(!lock.isAuthenticating)
    }

    @Test(arguments: [true, false])
    func enablingUsesDeviceNeutralAuthenticationReason(success: Bool) async {
        let authenticator = FakeAuthenticator(results: [success])
        let lock = AppLockModel(authenticator: authenticator)

        let enabled = await lock.authenticateToEnable()

        #expect(enabled == success)
        #expect(lock.isLocked == !success)
        #expect(!lock.isAuthenticating)
        #expect(authenticator.reasons == [String(localized: "Authenticate to enable App Lock for Liney.")])
    }

    @Test
    func settingsLabelsTheToggleAsAppLock() throws {
        let controller = SettingsViewController(appLock: AppLockModel(authenticator: FakeAuthenticator(results: [])))
        controller.loadViewIfNeeded()
        let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        let content = try #require(cell.contentConfiguration as? UIListContentConfiguration)
        let toggle = try #require(cell.accessoryView as? UISwitch)

        #expect(content.text == String(localized: "App Lock"))
        #expect(toggle.accessibilityLabel == content.text)
        #expect(content.image == UIImage(systemName: "lock"))
    }
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
