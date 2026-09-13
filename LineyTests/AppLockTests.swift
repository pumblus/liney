import SwiftUI
import UIKit
import XCTest
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
        await lock.unlockIfNeeded(requiresLock: true)

        XCTAssertFalse(lock.hidesJournalContent)
        XCTAssertEqual(authenticator.callCount, 2)
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
        window.rootViewController = UIHostingController(
            rootView: AppLockGate(requiresAppLock: .constant(true), appLock: lock) {
                MountProbeView(probe: probe)
            }
        )
        window.makeKeyAndVisible()
        await flushSwiftUIUpdates()

        XCTAssertTrue(lock.hidesJournalContent)
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
        window.rootViewController = UIHostingController(
            rootView: AppLockGate(requiresAppLock: .constant(true), appLock: lock) {
                MountProbeView(probe: probe)
            }
        )
        window.makeKeyAndVisible()
        await flushSwiftUIUpdates()

        XCTAssertEqual(probe.appearances, 1)
        XCTAssertEqual(probe.disappearances, 0)

        lock.protectSnapshot(requiresLock: true)
        await flushSwiftUIUpdates()

        XCTAssertTrue(lock.hidesJournalContent)
        XCTAssertEqual(probe.appearances, 1)
        XCTAssertEqual(probe.disappearances, 0)
        window.isHidden = true
    }

    func testSettingsRenderInDarkModeAndLargestDynamicType() async throws {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(
            rootView: SettingsView(
                requiresAppLock: .constant(false),
                appLock: AppLockModel(authenticator: FakeAuthenticator(results: []))
            )
            .environment(\.dynamicTypeSize, .accessibility5)
            .preferredColorScheme(.dark)
        )
        window.makeKeyAndVisible()
        await flushSwiftUIUpdates()

        let renderedView = try XCTUnwrap(window.rootViewController?.view)
        renderedView.setNeedsLayout()
        renderedView.layoutIfNeeded()
        XCTAssertEqual(renderedView.window, window)
        XCTAssertFalse(renderedView.bounds.isEmpty)
        window.isHidden = true
    }

    private func flushSwiftUIUpdates() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }
}

private final class FakeAuthenticator: AppAuthenticating {
    private var results: [Bool]
    private(set) var callCount = 0

    init(results: [Bool]) {
        self.results = results
    }

    func authenticate(reason: String) async -> Bool {
        callCount += 1
        return results.isEmpty ? false : results.removeFirst()
    }
}

private final class MountProbe {
    var appearances = 0
    var disappearances = 0
}

private struct MountProbeView: View {
    let probe: MountProbe

    var body: some View {
        Text("Mounted journal content")
            .onAppear {
                probe.appearances += 1
            }
            .onDisappear {
                probe.disappearances += 1
            }
    }
}

private final class SuspendedAuthenticator: AppAuthenticating {
    var completion: CheckedContinuation<Bool, Never>?
    func authenticate(reason: String) async -> Bool {
        await withCheckedContinuation { completion = $0 }
    }
}
