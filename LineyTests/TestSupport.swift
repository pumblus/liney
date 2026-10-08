import SwiftData
import Testing
import UIKit
@testable import Liney

// Fixture helpers shared by every suite. Add new cross-suite helpers here.

struct SyntheticFailure: Error { }

struct ApprovingAuthenticator: AppAuthenticating {
    func authenticate(reason: String) async -> Bool { true }
}

struct DenyingAuthenticator: AppAuthenticating {
    func authenticate(reason: String) async -> Bool { false }
}

func makeInMemoryContainer() throws -> ModelContainer {
    try ModelContainer(for: JournalEntry.self, EntryBlock.self, EntryPhoto.self,
                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

/// A solid-color JPEG of exactly `size` pixels.
func makeJPEGData(size: CGSize = CGSize(width: 32, height: 24), color: UIColor = .systemBlue) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 1) { context in
        color.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}

/// A `PhotoStorage` rooted in a fresh temporary directory; the caller removes `directory`.
func makeTemporaryPhotoStorage() -> (storage: PhotoStorage, directory: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return (PhotoStorage(baseURL: directory), directory)
}

/// Every view of type `T` in `view`'s hierarchy, `view` included, in depth-first order.
func descendants<T: UIView>(_ view: UIView, as type: T.Type) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, as: type) }
}

/// The alert presented above `controller`'s window root, waiting up to ten seconds.
@MainActor
func waitForAlert(from controller: UIViewController) async throws -> UIAlertController {
    for _ in 0..<500 {
        if let alert = presentedAlert(from: controller) { return alert }
        try await Task.sleep(for: .milliseconds(20))
    }
    return try #require(presentedAlert(from: controller))
}

@MainActor
func presentedAlert(from controller: UIViewController) -> UIAlertController? {
    var root = controller
    while let parent = root.parent { root = parent }
    var presented = root.presentedViewController
    while let current = presented {
        if let alert = current as? UIAlertController { return alert }
        presented = current.presentedViewController
    }
    return nil
}

// Fixture builders: production writes blocks through the editor and importer instead.
extension JournalEntry {
    func setBody(_ body: String, in context: ModelContext) {
        let existingTextBlocks = textBlocks
        func remove(_ block: EntryBlock) { blocks.removeAll { $0.id == block.id }; context.delete(block) }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            existingTextBlocks.forEach(remove)
        } else if let block = existingTextBlocks.first {
            block.text = body
            existingTextBlocks.dropFirst().forEach(remove)
        } else {
            let block = EntryBlock(sortIndex: 0, text: body, entry: self)
            blocks.append(block)
            context.insert(block)
        }
        normalizeBlocks(in: context)
    }

    @discardableResult
    func insertPhotoGroup(fileNames: [String], focusedTextBlockID: UUID? = nil, cursorOffset: Int? = nil,
                          in context: ModelContext) -> EntryBlock? {
        insertPhotoGroup(photos: fileNames.map { PhotoGroupItem(fileName: $0) },
                         focusedTextBlockID: focusedTextBlockID, cursorOffset: cursorOffset, in: context)
    }
}

extension PhotoImportResult {
    init(fileNames: [String], failedCount: Int) {
        self.init(photos: fileNames.map { PhotoGroupItem(fileName: $0) }, failedCount: failedCount)
    }
}

/// A scene as the editor coordinator sees it, recording what the system was asked to do,
/// because a real scene request cannot run in unit tests.
@MainActor final class FakeScene: SceneHandle {
    private(set) var activationCount = 0
    private(set) var destructionCount = 0
    private(set) var title: String?
    func activate() { activationCount += 1 }
    func destroy() { destructionCount += 1 }
    func setTitle(_ title: String?) { self.title = title }
}

/// Taps the action titled `title`: dismisses `alert`, then runs the action's handler, as UIKit does.
@MainActor
func perform(_ title: String, in alert: UIAlertController) async throws {
    typealias Handler = @convention(block) (UIAlertAction) -> Void
    let action = try #require(alert.actions.first { $0.title == title })
    let handler = try #require(action.value(forKey: "handler") as AnyObject?)
    await withCheckedContinuation { continuation in alert.dismiss(animated: false) { continuation.resume() } }
    unsafeBitCast(handler, to: Handler.self)(action)
}

/// An isolated preference store, so App Lock fixtures never read or write the app's standard
/// defaults. Call `remove()` when the test ends.
struct PreferenceSuite {
    let name = "LineyTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: name)! }

    /// App Lock with its preference `enabled`, starting locked as at launch.
    @MainActor
    func makeLock(_ authenticator: any AppAuthenticating = ApprovingAuthenticator(), enabled: Bool = false) -> AppLockModel {
        defaults.set(enabled, forKey: "liney.requiresAppLock")
        return AppLockModel(authenticator: authenticator, defaults: defaults)
    }

    func remove() { defaults.removePersistentDomain(forName: name) }
}

// Mounted windows. Fixtures cannot connect scenes, so they show roots on the live app scene.

/// Shows `root` in a key window `width` × 800 pt, at `sizeClass` width when given.
@MainActor
func mountInWindow(_ root: UIViewController, sizeClass: UIUserInterfaceSizeClass? = nil,
                   width: CGFloat = 1100) throws -> UIWindow {
    if let sizeClass { root.traitOverrides.horizontalSizeClass = sizeClass }
    let live = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: live)
    window.frame = CGRect(x: 0, y: 0, width: width, height: 800)
    window.rootViewController = root
    window.makeKeyAndVisible()
    return window
}

/// Lets layout and short transitions in `window` finish.
@MainActor
func waitForLayout(_ window: UIWindow) async throws {
    window.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(400))
}

/// Waits until `timeline` lists `days` days of entries.
@MainActor
func waitForRows(_ days: Int, in timeline: TimelineViewController) async throws {
    for _ in 0..<100 where timeline.tableView.numberOfSections != days {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(timeline.tableView.numberOfSections == days)
}

/// A full window, the scene root and its timeline, mounted once `days` days of entries are listed.
@MainActor
func mountJournal(_ container: ModelContainer, days: Int, sizeClass: UIUserInterfaceSizeClass = .regular,
                  width: CGFloat = 1100, appLock: AppLockModel? = nil, storage: PhotoStorage? = nil,
                  editors: SceneEditors? = nil) async throws -> (root: JournalSplitViewController, window: UIWindow) {
    let timeline = TimelineViewController(container: container,
                                          appLock: appLock ?? AppLockModel(authenticator: DenyingAuthenticator()),
                                          storage: storage ?? makeTemporaryPhotoStorage().storage, editors: editors)
    let root = JournalSplitViewController(timeline: timeline)
    let window = try mountInWindow(root, sizeClass: sizeClass, width: width)
    try await waitForRows(days, in: timeline)
    try await waitForLayout(window)
    return (root, window)
}

/// Dismisses anything presented over each window's root, then hides the window.
@MainActor
func unmount(_ windows: UIWindow...) async {
    for window in windows {
        if let presented = window.rootViewController?.presentedViewController {
            await withCheckedContinuation { continuation in
                presented.dismiss(animated: false) { continuation.resume() }
            }
        }
        window.isHidden = true
    }
}

/// Types into the editor's first text block as a person would, before the debounced save runs.
@MainActor
func typeInFirstBlock(_ text: String, of editor: EntryEditorViewController) throws {
    let input = try #require(descendants(editor.view, as: BlockTextView.self).first)
    input.text = text
    input.delegate?.textViewDidChange?(input)
}
