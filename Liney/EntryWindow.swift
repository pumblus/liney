import SwiftData
import UIKit

/// An entry window: one entry's editor alone. Its title in the app switcher is the Entry
/// Date, never the entry's title or text, and it shows none while App Lock is locked.
@MainActor final class EntryWindow {
    let entryID: UUID
    let editor: EntryEditorViewController
    let root: UINavigationController
    private let appLock: AppLockModel
    private let scene: any SceneHandle

    /// Takes the entry from any editor beside a timeline, saving its edits first. Nil when the
    /// entry no longer exists, or another window keeps it and has been brought forward.
    init?(entryID: UUID, container: ModelContainer, appLock: AppLockModel, editors: SceneEditors,
          storage: PhotoStorage = PhotoStorage()) {
        guard editors.claimEntryWindow(for: entryID) else { return nil }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let entry = try? context.entry(id: entryID) else { return nil }
        self.entryID = entryID
        editor = EntryEditorViewController(entry: entry, isNew: false, context: context, storage: storage, editors: editors)
        root = UINavigationController(rootViewController: editor)
        self.appLock = appLock
        scene = editors.handle
        editor.onTitleChange = { [weak self] in self?.updateTitle() }
        appLock.addObserver(self) { [weak self] in self?.updateTitle() }
        updateTitle()
    }

    private func updateTitle() {
        scene.setTitle(appLock.isEnabled && appLock.isLocked ? nil : editor.title)
    }
}
