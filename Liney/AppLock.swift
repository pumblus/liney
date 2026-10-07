import Foundation
import LocalAuthentication
import UIKit

private extension UserDefaults {
    var requiresAppLock: Bool {
        get { bool(forKey: "liney.requiresAppLock") }
        set { set(newValue, forKey: "liney.requiresAppLock") }
    }
}

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
    // Read on every use so each scene's model sees the current preference.
    private let defaults: UserDefaults

    init(authenticator: AppAuthenticating = LocalAuthenticator(), defaults: UserDefaults = .standard) {
        self.authenticator = authenticator
        self.defaults = defaults
    }

    var isEnabled: Bool { defaults.requiresAppLock }

    var hidesJournalContent: Bool {
        isEnabled && (isLocked || isSnapshotCovered)
    }

    /// Enabling requires authentication; the preference is written only when it succeeds.
    func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else {
            defaults.requiresAppLock = false
            authenticationGeneration += 1
            clearLockPresentation()
            return true
        }
        guard let success = await authenticate(reason: String(localized: "Authenticate to enable App Lock for Liney.")),
              success
        else { return false }
        defaults.requiresAppLock = true
        isLocked = false
        return true
    }

    func unlock() async {
        guard isEnabled else {
            clearLockPresentation()
            return
        }
        isSnapshotCovered = false
        guard isLocked,
              let success = await authenticate(reason: String(localized: "Unlock Liney to view your journal."))
        else { return }
        isLocked = !success
    }

    /// Temporary interruptions (Control Center, banners, the Face ID prompt) only cover content.
    func protectSnapshot() {
        guard isEnabled else {
            clearLockPresentation()
            return
        }
        isSnapshotCovered = true
    }

    /// Leaving the foreground requires authentication again on return.
    func didEnterBackground() {
        authenticationGeneration += 1
        protectSnapshot()
        if isEnabled { isLocked = true }
    }

    func authenticateForExport() async -> Bool {
        guard isEnabled else { return true }
        guard let success = await authenticate(reason: String(localized: "Authenticate to export your journal."))
        else { return false }
        isLocked = !success
        return success
    }

    private func clearLockPresentation() {
        // Prompt lifecycle callbacks arrive while enabling is still authenticating.
        // Clearing the disabled lock's UI must not invalidate that pending authentication.
        isLocked = false
        isSnapshotCovered = false
    }

    /// Returns nil when another authentication is in progress or a background or disable superseded this one.
    private func authenticate(reason: String) async -> Bool? {
        guard !isAuthenticating else { return nil }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let generation = authenticationGeneration
        let success = await authenticator.authenticate(reason: reason)
        guard generation == authenticationGeneration else { return nil }
        return success
    }
}

/// Covers sheets and editors together without replacing their controller hierarchy.
@MainActor
final class JournalPrivacyShield {
    let cover: UIWindow
    private weak var window: UIWindow?
    private let appLock: AppLockModel

    init(window: UIWindow, appLock: AppLockModel) {
        self.window = window
        self.appLock = appLock
        if let scene = window.windowScene { cover = UIWindow(windowScene: scene) }
        else { cover = UIWindow(frame: window.bounds) }
        cover.windowLevel = .alert + 1
        cover.rootViewController = LockedJournalController(appLock: appLock) {
            Task { await appLock.unlock() }
        }
        appLock.onChange = { [weak self] in self?.update() }
    }

    func update() {
        let hidden = appLock.hidesJournalContent
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
        button.setContentHuggingPriority(.required, for: .vertical)
        button.configuration?.cornerStyle = .capsule
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 28, bottom: 14, trailing: 28)
        let symbol = UIImageView(image: UIImage(systemName: "lock.fill"))
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 36, weight: .regular)
        symbol.tintColor = .secondaryLabel
        symbol.contentMode = .center
        symbol.isAccessibilityElement = false
        symbol.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let heading = bodyLabel(String(localized: "Liney Locked"), style: .title2)
        heading.textAlignment = .center
        heading.accessibilityTraits.insert(.header)
        let detail = bodyLabel(String(localized: "Unlock to view your private journal."))
        detail.textAlignment = .center
        detail.textColor = .secondaryLabel
        let buttonRow = UIStackView(arrangedSubviews: [UIView(), button, UIView()])
        buttonRow.arrangedSubviews[0].widthAnchor.constraint(equalTo: buttonRow.arrangedSubviews[2].widthAnchor).isActive = true
        installStack([symbol, heading, detail, buttonRow], centered: true)
        update()
    }
    func update() { button?.isEnabled = !appLock.isAuthenticating }
}
