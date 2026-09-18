import SwiftData
import UIKit

@main
final class LineyApp: UIResponder, UIApplicationDelegate {
    lazy var container: ModelContainer = {
        do { return try ModelContainer(for: JournalEntry.self, EntryBlock.self, EntryPhoto.self) }
        catch { fatalError("Unable to open the journal store.") }
    }()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        JournalExporter().deleteTemporaryExports()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Journal", sessionRole: session.role)
        configuration.delegateClass = JournalSceneDelegate.self
        return configuration
    }
}

final class JournalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var privacyShield: JournalPrivacyShield?
    private let appLock = AppLockModel()
    private var requiresLock: Bool { UserDefaults.standard.bool(forKey: "liney.requiresAppLock") }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene,
              let app = UIApplication.shared.delegate as? LineyApp else { return }
        let window = UIWindow(windowScene: scene)
        window.tintColor = UIColor(named: "LineyAqua") ?? .systemTeal
        self.window = window
        privacyShield = JournalPrivacyShield(window: window, appLock: appLock, requiresLock: { [weak self] in
            self?.requiresLock ?? true
        })
        showRoot(container: app.container)
        window.makeKeyAndVisible()
        updateLock()
    }

    private func showRoot(container: ModelContainer) {
        if !UserDefaults.standard.bool(forKey: "liney.hasCompletedOnboarding") {
            window?.rootViewController = UINavigationController(rootViewController: OnboardingController(container: container) { [weak self] in
                UserDefaults.standard.set(true, forKey: "liney.hasCompletedOnboarding")
                self?.showRoot(container: container)
            })
            return
        }
        let timeline = TimelineViewController(container: container, appLock: appLock)
        let navigation = UINavigationController(rootViewController: timeline)
        navigation.navigationBar.prefersLargeTitles = true
        if UIDevice.current.userInterfaceIdiom == .pad {
            let split = UISplitViewController(style: .doubleColumn)
            split.preferredDisplayMode = .oneBesideSecondary
            split.setViewController(navigation, for: .primary)
            split.setViewController(UINavigationController(rootViewController: MessageController(
                title: String(localized: "No Entry Selected"),
                message: String(localized: "Choose an entry from the timeline once entries exist."))), for: .secondary)
            window?.rootViewController = split
        } else { window?.rootViewController = navigation }
    }

    private func updateLock() { privacyShield?.update() }

    func sceneDidBecomeActive(_ scene: UIScene) {
        Task { await appLock.unlockIfNeeded(requiresLock: requiresLock) }
    }
    func sceneWillResignActive(_ scene: UIScene) { appLock.protectSnapshot(requiresLock: requiresLock) }
    func sceneDidEnterBackground(_ scene: UIScene) { appLock.didEnterBackground(requiresLock: requiresLock) }
}

final class OnboardingController: UIViewController {
    let container: ModelContainer
    let finish: () -> Void
    init(container: ModelContainer, finish: @escaping () -> Void) {
        self.container = container; self.finish = finish
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Liney"
        installStack([bodyLabel("Liney", style: .largeTitle),
                      bodyLabel(String(localized: "A light journal for words and photos."), style: .title3),
                      bodyLabel(String(localized: "Your journal stays on this device. No account, no server, no ads, and no analytics.")),
                      actionButton(String(localized: "Start Writing"), action: finish),
                      actionButton(String(localized: "Import Journal")) { [weak self] in
            guard let self else { return }
            let controller = ImportJournalViewController(container: self.container, onFinished: self.finish)
            self.present(UINavigationController(rootViewController: controller), animated: true)
        }], centered: true)
    }
}
