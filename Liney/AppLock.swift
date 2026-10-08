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

/// The one App Lock state for the whole app, shared by every scene.
@MainActor
final class AppLockModel {
    private(set) var isLocked = true { didSet { notifyObservers() } }
    private(set) var isAuthenticating = false { didSet { notifyObservers() } }

    private var authenticationGeneration = 0
    /// Set at launch and whenever Liney leaves the foreground; the next scene to become active consumes it.
    private var promptsOnActivation = true
    private let scenes = NSHashTable<AppLockScene>.weakObjects()
    private var observers: [Observer] = []
    private let authenticator: AppAuthenticating
    private let defaults: UserDefaults

    private struct Observer {
        weak var owner: AnyObject?
        let onChange: () -> Void
    }

    init(authenticator: AppAuthenticating = LocalAuthenticator(), defaults: UserDefaults = .standard) {
        self.authenticator = authenticator
        self.defaults = defaults
    }

    var isEnabled: Bool { defaults.requiresAppLock }

    /// Calls `onChange` after every lock, authentication, or preference change until `owner` is released.
    func addObserver(_ owner: AnyObject, onChange: @escaping () -> Void) {
        observers.append(Observer(owner: owner, onChange: onChange))
    }

    /// New and restored scenes start covered and follow the current lock state.
    func connectScene() -> AppLockScene {
        let scene = AppLockScene(appLock: self)
        scenes.add(scene)
        return scene
    }

    /// Enabling requires authentication; the preference is written only when it succeeds.
    func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else {
            defaults.requiresAppLock = false
            authenticationGeneration += 1
            isLocked = false
            return true
        }
        guard let success = await authenticate(reason: String(localized: "Authenticate to enable App Lock for Liney.")),
              success
        else { return false }
        defaults.requiresAppLock = true
        isLocked = false
        return true
    }

    /// The locked screen's Unlock action; the only request after a failed or cancelled one.
    func unlock() async {
        guard isEnabled else {
            isLocked = false
            return
        }
        guard isLocked,
              let success = await authenticate(reason: String(localized: "Unlock Liney to view your journal."))
        else { return }
        isLocked = !success
    }

    /// A cancelled or failed prompt cancels only the export; the lock state is left alone.
    func authenticateForExport() async -> Bool {
        guard isEnabled else { return true }
        guard let success = await authenticate(reason: String(localized: "Authenticate to export your journal."))
        else { return false }
        if success { isLocked = false }
        return success
    }

    /// Only the first activation after launch or a return to the foreground prompts,
    /// and never while another scene's request is in flight.
    fileprivate func sceneDidBecomeActive() async {
        guard isEnabled, isLocked, promptsOnActivation, !isAuthenticating else { return }
        promptsOnActivation = false
        await unlock()
    }

    /// Liney as a whole leaves the foreground only when its last foreground scene does.
    fileprivate func sceneDidEnterBackground() {
        guard !scenes.allObjects.contains(where: \.isForeground) else { return }
        authenticationGeneration += 1
        promptsOnActivation = true
        if isEnabled { isLocked = true }
    }

    private func notifyObservers() {
        observers.removeAll { $0.owner == nil }
        for observer in observers { observer.onChange() }
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

/// One scene's view of the app-wide App Lock. The snapshot cover belongs to the scene:
/// it covers when the scene resigns active, even if still visible, and covering never locks.
@MainActor
final class AppLockScene {
    let appLock: AppLockModel
    /// Called when this scene's cover or the app-wide lock state changes.
    var onChange: (() -> Void)?
    private(set) var isSnapshotCovered = true { didSet { onChange?() } }
    fileprivate private(set) var isForeground = false

    fileprivate init(appLock: AppLockModel) {
        self.appLock = appLock
        appLock.addObserver(self) { [weak self] in self?.onChange?() }
    }

    var hidesJournalContent: Bool {
        appLock.isEnabled && (appLock.isLocked || isSnapshotCovered)
    }

    /// A visible window counts as foreground even if it never becomes active.
    func willEnterForeground() { isForeground = true }

    func didBecomeActive() async {
        isForeground = true
        isSnapshotCovered = false
        await appLock.sceneDidBecomeActive()
    }

    func willResignActive() { isSnapshotCovered = true }

    func didEnterBackground() {
        isForeground = false
        isSnapshotCovered = true
        appLock.sceneDidEnterBackground()
    }
}

/// Covers sheets and editors together without replacing their controller hierarchy.
@MainActor
final class JournalPrivacyShield {
    let cover: UIWindow
    private weak var window: UIWindow?
    private let lockScene: AppLockScene

    init(window: UIWindow, lockScene: AppLockScene) {
        self.window = window
        self.lockScene = lockScene
        if let scene = window.windowScene { cover = UIWindow(windowScene: scene) }
        else { cover = UIWindow(frame: window.bounds) }
        cover.windowLevel = .alert + 1
        let appLock = lockScene.appLock
        cover.rootViewController = LockedJournalController(appLock: appLock) {
            Task { await appLock.unlock() }
        }
        lockScene.onChange = { [weak self] in self?.update() }
    }

    func update() {
        let hidden = lockScene.hidesJournalContent
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
