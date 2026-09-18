import Foundation
import LocalAuthentication
import UIKit

protocol AppAuthenticating {
    func authenticate(reason: String) async -> Bool
}

struct LocalAuthenticator: AppAuthenticating {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

@MainActor
final class AppLockModel {
    private(set) var isLocked = true { didSet { onChange?() } }
    private(set) var isSnapshotCovered = true { didSet { onChange?() } }
    private(set) var isAuthenticating = false { didSet { onChange?() } }
    var onChange: (() -> Void)?

    private var authenticationGeneration = 0
    private let authenticator: AppAuthenticating

    init(authenticator: AppAuthenticating = LocalAuthenticator()) {
        self.authenticator = authenticator
    }

    var hidesJournalContent: Bool {
        isLocked || isSnapshotCovered
    }

    func unlockIfNeeded(requiresLock: Bool) async {
        guard requiresLock else {
            disableLock()
            return
        }
        isSnapshotCovered = false
        guard isLocked, !isAuthenticating else { return }
        _ = await authenticate(reason: String(localized: "Unlock Liney to view your journal."))
    }

    func unlock(requiresLock: Bool) async {
        guard requiresLock else {
            disableLock()
            return
        }
        isLocked = true
        isSnapshotCovered = false
        guard !isAuthenticating else { return }
        _ = await authenticate(reason: String(localized: "Unlock Liney to view your journal."))
    }

    func protectSnapshot(requiresLock: Bool) {
        guard requiresLock else {
            disableLock()
            return
        }
        isLocked = true
        isSnapshotCovered = true
    }

    func didEnterBackground(requiresLock: Bool) {
        authenticationGeneration += 1
        protectSnapshot(requiresLock: requiresLock)
    }

    func authenticateForExport(requiresLock: Bool) async -> Bool {
        guard requiresLock else {
            disableLock()
            return true
        }
        guard !isAuthenticating else { return false }
        return await authenticate(reason: String(localized: "Authenticate to export your journal."))
    }

    func authenticateToEnable() async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let generation = authenticationGeneration
        let success = await authenticator.authenticate(
            reason: String(localized: "Authenticate to require Face ID for Liney.")
        )
        guard generation == authenticationGeneration else { return false }
        if success {
            isLocked = false
        }
        return success
    }

    func disableLock() {
        authenticationGeneration += 1
        isLocked = false
        isSnapshotCovered = false
    }

    private func authenticate(reason: String) async -> Bool {
        isAuthenticating = true
        defer { isAuthenticating = false }

        let generation = authenticationGeneration
        let success = await authenticator.authenticate(reason: reason)
        guard generation == authenticationGeneration else { return false }
        isLocked = !success
        return success
    }
}


/// Covers sheets and editors together without replacing their controller hierarchy.
@MainActor
final class JournalPrivacyShield {
    let cover: UIWindow
    private weak var window: UIWindow?
    private let appLock: AppLockModel
    private let requiresLock: () -> Bool

    init(window: UIWindow, appLock: AppLockModel, requiresLock: @escaping () -> Bool) {
        self.window = window
        self.appLock = appLock
        self.requiresLock = requiresLock
        if let scene = window.windowScene { cover = UIWindow(windowScene: scene) }
        else { cover = UIWindow(frame: window.bounds) }
        cover.windowLevel = .alert + 1
        cover.rootViewController = LockedJournalController(appLock: appLock) {
            Task { await appLock.unlock(requiresLock: requiresLock()) }
        }
        appLock.onChange = { [weak self] in self?.update() }
    }

    func update() {
        let hidden = requiresLock() && appLock.hidesJournalContent
        window?.accessibilityElementsHidden = hidden
        window?.isUserInteractionEnabled = !hidden
        if hidden {
            // End composition and move keyboard focus above the journal as well as covering pixels.
            if !cover.isKeyWindow {
                window?.endEditing(true)
                cover.makeKeyAndVisible()
            }
        } else if !cover.isHidden {
            cover.isHidden = true
            window?.makeKeyAndVisible()
        }
        (cover.rootViewController as? LockedJournalController)?.update()
    }
}

final class LockedJournalController: UIViewController {
    let appLock: AppLockModel
    let unlock: () -> Void
    private var button: UIButton!
    init(appLock: AppLockModel, unlock: @escaping () -> Void) {
        self.appLock = appLock
        self.unlock = unlock
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityViewIsModal = true
        button = actionButton(String(localized: "Unlock"), action: unlock)
        installStack([bodyLabel(String(localized: "Liney Locked"), style: .title2),
                      bodyLabel(String(localized: "Unlock to view your private journal.")), button], centered: true)
        update()
    }
    func update() { button?.isEnabled = !appLock.isAuthenticating }
}
