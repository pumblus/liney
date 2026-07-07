import XCTest
@testable import Liney

@MainActor
final class AppLockTests: XCTestCase {
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
