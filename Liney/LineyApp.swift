import SwiftData
import UIKit

@main
final class LineyApp: UIResponder, UIApplicationDelegate {
    lazy var container: ModelContainer = {
        do { return try ModelContainer(for: JournalEntry.self, EntryBlock.self, EntryPhoto.self) }
        catch { fatalError("Unable to open the journal store.") }
    }()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Recorded before any scene creates a context, so the sweep never moves a photo copied by this launch.
        let launchedAt = Date.now
        JournalExporter().deleteTemporaryExports()
        DayOneImporter().deleteTemporaryImports()
        let container = container
        Task.detached(priority: .background) {
            PhotoStorage().sweepOrphanedPhotoFiles(launchedAt: launchedAt) {
                try PhotoStorage.referencedFileNames(in: ModelContext(container))
            }
        }
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

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene,
              let app = UIApplication.shared.delegate as? LineyApp else { return }
        let window = UIWindow(windowScene: scene)
        window.tintColor = UIColor(named: "LineyAqua") ?? .systemTeal
        self.window = window
        privacyShield = JournalPrivacyShield(window: window, appLock: appLock)
        showRoot(container: app.container)
        window.makeKeyAndVisible()
        privacyShield?.update()
    }

    private func showRoot(container: ModelContainer) {
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

    func sceneDidBecomeActive(_ scene: UIScene) {
        Task { await appLock.unlock() }
    }
    func sceneWillResignActive(_ scene: UIScene) { appLock.protectSnapshot() }
    func sceneDidEnterBackground(_ scene: UIScene) { appLock.didEnterBackground() }
}
