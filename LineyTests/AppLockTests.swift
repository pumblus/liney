import UIKit
import XCTest
import Testing
@testable import Liney

@MainActor
final class AppLockTests: XCTestCase {
    func testAuthenticationFinishingWhileInactiveKeepsSnapshotCovered() async {
        let authenticator = SuspendedAuthenticator()
        let lock = makeLock(authenticator)
        let scene = lock.connectScene()
        let unlockTask = Task { await scene.didBecomeActive() }
        while authenticator.completion == nil { await Task.yield() }
        scene.willResignActive()
        authenticator.completion?.resume(returning: true)
        await unlockTask.value
        XCTAssertTrue(scene.hidesJournalContent)
    }

    func testBackgroundInvalidatesPendingAuthenticationAndForegroundRetries() async {
        let authenticator = SuspendedAuthenticator()
        let lock = makeLock(authenticator)
        let scene = lock.connectScene()
        let first = Task { await scene.didBecomeActive() }
        while authenticator.completion == nil { await Task.yield() }
        scene.willResignActive()
        scene.didEnterBackground()
        authenticator.completion?.resume(returning: true)
        await first.value
        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(scene.isSnapshotCovered)
        authenticator.completion = nil
        let retry = Task { await scene.didBecomeActive() }
        while authenticator.completion == nil { await Task.yield() }
        authenticator.completion?.resume(returning: true)
        await retry.value
        XCTAssertFalse(scene.hidesJournalContent)
    }

    func testInactiveAuthenticationSuccessDoesNotPromptAgainOnActive() async {
        let authenticator = SuspendedAuthenticator()
        let lock = makeLock(authenticator)
        let scene = lock.connectScene()
        let task = Task { await scene.didBecomeActive() }
        while authenticator.completion == nil { await Task.yield() }
        scene.willResignActive()
        authenticator.completion?.resume(returning: true)
        await task.value
        await scene.didBecomeActive()
        XCTAssertFalse(scene.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 1)
    }

    func testDisablingLockIgnoresPendingAuthenticationFailure() async {
        let authenticator = SuspendedAuthenticator()
        let lock = makeLock(authenticator)
        let scene = lock.connectScene()
        let task = Task { await scene.didBecomeActive() }
        while authenticator.completion == nil { await Task.yield() }
        let disabled = await lock.setEnabled(false)
        authenticator.completion?.resume(returning: false)
        await task.value
        XCTAssertTrue(disabled)
        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(scene.hidesJournalContent)
    }

    func testBackgroundInvalidatesPendingExportAuthorization() async {
        let authenticator = SuspendedAuthenticator()
        let lock = makeLock(authenticator)
        let scene = lock.connectScene()
        let task = Task { await lock.authenticateForExport() }
        while authenticator.completion == nil { await Task.yield() }
        scene.didEnterBackground()
        authenticator.completion?.resume(returning: true)
        let authorized = await task.value
        XCTAssertFalse(authorized)
        XCTAssertTrue(scene.hidesJournalContent)
    }

    func testSuccessfulLaunchAuthenticationShowsContent() async {
        let authenticator = FakeAuthenticator(results: [true])
        let lock = makeLock(authenticator)
        let scene = lock.connectScene()

        XCTAssertTrue(scene.hidesJournalContent)

        await scene.didBecomeActive()

        XCTAssertFalse(scene.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 1)
    }

    func testCancelledAuthenticationKeepsJournalLocked() async {
        let authenticator = FakeAuthenticator(results: [false])
        let lock = makeLock(authenticator)
        let scene = lock.connectScene()

        await scene.didBecomeActive()

        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(scene.hidesJournalContent)
        XCTAssertFalse(scene.isSnapshotCovered)
    }

    func testForegroundReturnRequiresAuthenticationAgain() async {
        let authenticator = FakeAuthenticator(results: [true, true])
        let lock = makeLock(authenticator)
        let scene = lock.connectScene()

        await scene.didBecomeActive()
        scene.willResignActive()
        scene.didEnterBackground()
        XCTAssertTrue(lock.isLocked)
        await scene.didBecomeActive()

        XCTAssertFalse(scene.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 2)
    }

    func testTemporaryInterruptionCoversWithoutRequiringAuthenticationAgain() async {
        let authenticator = FakeAuthenticator(results: [true])
        let lock = makeLock(authenticator)
        let scene = lock.connectScene()

        await scene.didBecomeActive()
        scene.willResignActive()
        XCTAssertTrue(scene.hidesJournalContent, "The app switcher snapshot stays covered while inactive")
        await scene.didBecomeActive()

        XCTAssertFalse(scene.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 1)
    }

    func testLockedScreenUnlockActionRetriesAuthentication() async {
        let authenticator = FakeAuthenticator(results: [false, true])
        let lock = makeLock(authenticator)
        let scene = lock.connectScene()

        await scene.didBecomeActive()
        await lock.unlock()

        XCTAssertFalse(scene.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 2)
    }

    func testSnapshotCoverOnlyAppliesWhenLockIsEnabled() {
        let disabled = makeLock(FakeAuthenticator(results: []), enabled: false).connectScene()
        disabled.willResignActive()
        XCTAssertFalse(disabled.hidesJournalContent)

        let scene = makeLock(FakeAuthenticator(results: [])).connectScene()
        scene.willResignActive()
        XCTAssertTrue(scene.isSnapshotCovered)
        XCTAssertTrue(scene.hidesJournalContent)
    }

    func testExportReauthLocksAfterCancelledAuthentication() async {
        let authenticator = FakeAuthenticator(results: [false])
        let lock = makeLock(authenticator)
        let scene = lock.connectScene()

        let authorized = await lock.authenticateForExport()

        XCTAssertFalse(authorized)
        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(scene.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 1)
    }

    func testExportWithoutAppLockDoesNotAuthenticate() async {
        let authenticator = FakeAuthenticator(results: [])
        let lock = makeLock(authenticator, enabled: false)
        let scene = lock.connectScene()

        let authorized = await lock.authenticateForExport()

        XCTAssertTrue(authorized)
        XCTAssertFalse(scene.hidesJournalContent)
        XCTAssertTrue(lock.isLocked, "Export without App Lock leaves lock state untouched")
        XCTAssertEqual(authenticator.callCount, 0)
    }

    func testGateMountsContentBehindInitialLockCover() async {
        let scene = makeLock(FakeAuthenticator(results: [])).connectScene()
        let probe = MountProbe()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = MountProbeViewController(probe: probe)
        window.makeKeyAndVisible()
        let shield = JournalPrivacyShield(window: window, lockScene: scene)
        shield.update()
        defer { shield.cover.isHidden = true; window.isHidden = true }
        await flushUIKitUpdates()

        XCTAssertTrue(scene.hidesJournalContent)
        XCTAssertFalse(shield.cover.isHidden)
        XCTAssertFalse(window.isUserInteractionEnabled)
        XCTAssertTrue(window.accessibilityElementsHidden)
        XCTAssertEqual(probe.appearances, 1)
        XCTAssertEqual(probe.disappearances, 0)
        window.isHidden = true
    }

    func testGateKeepsUnlockedContentMountedBehindLockCover() async {
        let authenticator = FakeAuthenticator(results: [true])
        let scene = makeLock(authenticator).connectScene()
        await scene.didBecomeActive()

        let probe = MountProbe()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = MountProbeViewController(probe: probe)
        window.makeKeyAndVisible()
        let shield = JournalPrivacyShield(window: window, lockScene: scene)
        shield.update()
        defer { shield.cover.isHidden = true; window.isHidden = true }
        await flushUIKitUpdates()

        XCTAssertEqual(probe.appearances, 1)
        XCTAssertEqual(probe.disappearances, 0)

        scene.willResignActive()
        await flushUIKitUpdates()

        XCTAssertTrue(scene.hidesJournalContent)
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
        let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: windowScene)
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
        let scene = makeLock(FakeAuthenticator(results: [true])).connectScene()
        let shield = JournalPrivacyShield(window: window, lockScene: scene)
        defer { shield.cover.isHidden = true }
        shield.update()
        XCTAssertTrue(shield.cover.isKeyWindow)
        XCTAssertFalse(input.isFirstResponder)
        XCTAssertTrue(root.presentedViewController === sheet)
        XCTAssertTrue(window.accessibilityElementsHidden)
        XCTAssertFalse(window.isUserInteractionEnabled)
        await scene.didBecomeActive()
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
        let scene = makeLock(FakeAuthenticator(results: []), enabled: false).connectScene()
        let shield = JournalPrivacyShield(window: window, lockScene: scene)
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
        let scene = lock.connectScene()
        #expect(scene.hidesJournalContent)

        let disabled = await lock.setEnabled(false)

        #expect(disabled)
        #expect(!lock.isEnabled)
        #expect(!lock.isLocked)
        #expect(!scene.hidesJournalContent)
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
        let scene = lock.connectScene()
        await scene.didBecomeActive()
        #expect(!scene.hidesJournalContent)

        scene.didEnterBackground()

        #expect(lock.isLocked)
        #expect(scene.isSnapshotCovered)
        #expect(scene.hidesJournalContent)
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
        let scene = lock.connectScene()
        await scene.didBecomeActive()
        let task = Task { await lock.setEnabled(true) }
        while authenticator.completion == nil { await Task.yield() }

        // The preference is written only after authentication returns.
        scene.willResignActive()
        if returnsActiveBeforeReply {
            await scene.didBecomeActive()
        }
        authenticator.completion?.resume(returning: true)
        let enabled = await task.value
        if !returnsActiveBeforeReply {
            await scene.didBecomeActive()
        }

        #expect(enabled)
        #expect(lock.isEnabled)
        #expect(!lock.isAuthenticating)
        #expect(!scene.hidesJournalContent)
        #expect(authenticator.callCount == 1)
    }

    @Test(arguments: [true, false])
    func enablingRejectsAuthenticationAfterBackgroundOrExplicitDisable(background: Bool) async {
        let authenticator = SuspendedAuthenticator()
        let lock = makeLock(authenticator)
        let scene = lock.connectScene()
        await scene.didBecomeActive()
        let task = Task { await lock.setEnabled(true) }
        while authenticator.completion == nil { await Task.yield() }

        if background {
            scene.willResignActive()
            scene.didEnterBackground()
        } else { _ = await lock.setEnabled(false) }
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

/// Several windows share one App Lock state; each window covers its own snapshot.
@MainActor
final class AppWideAppLockTests {
    private let suite = PreferenceSuite()
    deinit { suite.remove() }

    @Test
    func oneAuthenticationUnlocksEveryScene() async {
        let authenticator = FakeAuthenticator(results: [true])
        let lock = suite.makeLock(authenticator, enabled: true)
        let first = lock.connectScene()
        let second = lock.connectScene()

        await first.didBecomeActive()

        #expect(!first.hidesJournalContent)
        #expect(!lock.isLocked)
        await second.didBecomeActive()
        #expect(!second.hidesJournalContent)
        #expect(authenticator.callCount == 1)
    }

    @Test
    func cancellingLeavesEverySceneLockedWithoutPromptingOnFocusChange() async {
        let authenticator = FakeAuthenticator(results: [false, true])
        let lock = suite.makeLock(authenticator, enabled: true)
        let first = lock.connectScene()
        let second = lock.connectScene()

        await first.didBecomeActive()
        first.willResignActive()
        await second.didBecomeActive()
        second.willResignActive()
        await first.didBecomeActive()

        #expect(first.hidesJournalContent)
        #expect(second.hidesJournalContent)
        #expect(authenticator.callCount == 1)

        await lock.unlock()
        #expect(!first.hidesJournalContent)
        #expect(authenticator.callCount == 2)
    }

    @Test
    func onlyTheLastForegroundSceneEnteringTheBackgroundLocks() async {
        let authenticator = FakeAuthenticator(results: [true, true])
        let lock = suite.makeLock(authenticator, enabled: true)
        let first = lock.connectScene()
        let second = lock.connectScene()
        await first.didBecomeActive()
        await second.didBecomeActive()

        // Closing one window while the other stays in the foreground.
        first.willResignActive()
        first.didEnterBackground()
        #expect(!lock.isLocked)
        #expect(!second.hidesJournalContent)

        second.willResignActive()
        second.didEnterBackground()
        #expect(lock.isLocked)

        await second.didBecomeActive()
        await first.didBecomeActive()
        #expect(!first.hidesJournalContent)
        #expect(!second.hidesJournalContent)
        #expect(authenticator.callCount == 2)
    }

    @Test
    func aVisibleSceneThatNeverBecameActiveKeepsLineyInTheForeground() async {
        let authenticator = FakeAuthenticator(results: [true, true])
        let lock = suite.makeLock(authenticator, enabled: true)
        let first = lock.connectScene()
        let second = lock.connectScene()
        await first.didBecomeActive()
        first.didEnterBackground()
        second.didEnterBackground()

        // Returning brings both windows back; only one becomes active, and then it closes.
        first.willEnterForeground()
        second.willEnterForeground()
        await first.didBecomeActive()
        first.willResignActive()
        first.didEnterBackground()

        #expect(!lock.isLocked)
        #expect(authenticator.callCount == 2)
    }

    @Test
    func aSceneBecomingActiveDuringAnInFlightRequestDoesNotStartAnother() async {
        let authenticator = SuspendedAuthenticator()
        let lock = suite.makeLock(authenticator, enabled: true)
        let first = lock.connectScene()
        let second = lock.connectScene()

        let prompt = Task { await first.didBecomeActive() }
        while authenticator.completion == nil { await Task.yield() }
        first.willResignActive()
        await second.didBecomeActive()
        #expect(lock.isAuthenticating)
        await authenticator.reply(true)
        await prompt.value
        await first.didBecomeActive()

        #expect(authenticator.callCount == 1)
        #expect(!first.hidesJournalContent)
        #expect(!second.hidesJournalContent)
    }

    @Test
    func leavingTheForegroundDuringARequestIgnoresItsResultAndPromptsOnReturn() async {
        let authenticator = SuspendedAuthenticator()
        let lock = suite.makeLock(authenticator, enabled: true)
        let first = lock.connectScene()
        let second = lock.connectScene()

        let prompt = Task { await first.didBecomeActive() }
        while authenticator.completion == nil { await Task.yield() }
        first.willResignActive()
        await second.didBecomeActive()
        second.willResignActive()
        first.didEnterBackground()
        second.didEnterBackground()
        await authenticator.reply(true)
        await prompt.value
        #expect(lock.isLocked)

        let retry = Task { await second.didBecomeActive() }
        await authenticator.reply(true)
        await retry.value
        #expect(authenticator.callCount == 2)
        #expect(!second.hidesJournalContent)
        #expect(first.hidesJournalContent, "A scene still in the background stays covered")
    }

    @Test
    func turningAppLockOnOrOffInOneSceneUpdatesEveryScene() async {
        let lock = suite.makeLock(ApprovingAuthenticator(), enabled: false)
        let first = lock.connectScene()
        let second = lock.connectScene()
        var changes = (first: 0, second: 0)
        first.onChange = { changes.first += 1 }
        second.onChange = { changes.second += 1 }
        await second.didBecomeActive()
        second.willResignActive()
        await first.didBecomeActive()
        #expect(!second.hidesJournalContent, "Without App Lock an unfocused window shows its content")

        changes = (0, 0)
        #expect(await lock.setEnabled(true))
        #expect(changes.first > 0 && changes.second > 0)
        #expect(!first.hidesJournalContent)
        #expect(second.hidesJournalContent, "A visible but unfocused window covers once App Lock is on")

        changes = (0, 0)
        #expect(await lock.setEnabled(false))
        #expect(changes.first > 0 && changes.second > 0)
        #expect(!second.hidesJournalContent)
    }

    @Test
    func aNewSceneFollowsTheCurrentLockStateWithoutPrompting() async {
        let authenticator = FakeAuthenticator(results: [false, true])
        let lock = suite.makeLock(authenticator, enabled: true)
        let first = lock.connectScene()
        await first.didBecomeActive()

        let whileLocked = lock.connectScene()
        await whileLocked.didBecomeActive()
        #expect(whileLocked.hidesJournalContent)
        #expect(authenticator.callCount == 1)

        await lock.unlock()
        let whileUnlocked = lock.connectScene()
        #expect(whileUnlocked.hidesJournalContent, "A new window stays covered until it becomes active")
        await whileUnlocked.didBecomeActive()
        #expect(!whileUnlocked.hidesJournalContent)
        #expect(!whileLocked.hidesJournalContent)
        #expect(authenticator.callCount == 2)
    }

    @Test
    func settingsInAnotherWindowShowsTheChangedPreference() async throws {
        let lock = suite.makeLock(ApprovingAuthenticator(), enabled: false)
        let there = SettingsViewController(appLock: lock)
        let toggle = try appLockToggle(in: there)
        #expect(!toggle.isOn)

        _ = await lock.setEnabled(true)
        #expect(toggle.isOn)
        _ = await lock.setEnabled(false)
        #expect(!toggle.isOn)
    }

    private func appLockToggle(in settings: SettingsViewController) throws -> UISwitch {
        settings.loadViewIfNeeded()
        let cell = settings.tableView(settings.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        return try #require(cell.accessoryView as? UISwitch)
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
    private(set) var callCount = 0
    func authenticate(reason: String) async -> Bool {
        callCount += 1
        return await withCheckedContinuation { completion = $0 }
    }

    /// Waits until a request is in flight, then answers it.
    @MainActor
    func reply(_ success: Bool) async {
        while completion == nil { await Task.yield() }
        completion?.resume(returning: success)
        completion = nil
    }
}
