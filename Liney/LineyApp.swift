import SwiftData
import UIKit

@main
final class LineyApp: UIResponder, UIApplicationDelegate {
    lazy var container: ModelContainer = {
        do { return try ModelContainer(for: JournalEntry.self, EntryBlock.self, EntryPhoto.self) }
        catch { fatalError("Unable to open the journal store.") }
    }()
    /// Shared by every scene, so one authentication unlocks every window and they lock together.
    let appLock = AppLockModel()
    /// Shared by every scene, so each entry is edited in at most one window.
    let editorCoordinator = EntryEditorCoordinator()

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
    private var lockScene: AppLockScene?
    private var editors: SceneEditors?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene,
              let app = UIApplication.shared.delegate as? LineyApp else { return }
        let window = UIWindow(windowScene: scene)
        window.tintColor = UIColor(named: "LineyAqua") ?? .systemTeal
        self.window = window
        let lockScene = app.appLock.connectScene()
        self.lockScene = lockScene
        privacyShield = JournalPrivacyShield(window: window, lockScene: lockScene)
        let editors = app.editorCoordinator.connectScene(WindowSceneHandle(scene))
        self.editors = editors
        window.rootViewController = JournalSplitViewController(
            timeline: TimelineViewController(container: app.container, appLock: app.appLock, editors: editors))
        window.makeKeyAndVisible()
        privacyShield?.update()
    }

    func sceneWillEnterForeground(_ scene: UIScene) { lockScene?.willEnterForeground() }
    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let lockScene else { return }
        Task { await lockScene.didBecomeActive() }
    }
    func sceneWillResignActive(_ scene: UIScene) { lockScene?.willResignActive() }
    func sceneDidEnterBackground(_ scene: UIScene) { lockScene?.didEnterBackground() }
    func sceneDidDisconnect(_ scene: UIScene) { editors?.disconnect() }
}
