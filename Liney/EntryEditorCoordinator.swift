import UIKit

/// A connected scene as the coordinator sees it. Tests substitute fakes, because a real
/// scene request cannot run in unit tests.
@MainActor protocol SceneHandle: AnyObject {
    /// Brings this scene's window forward.
    func activate()
}

/// A window scene, brought forward through the system.
final class WindowSceneHandle: SceneHandle {
    private weak var scene: UIWindowScene?
    init(_ scene: UIWindowScene) { self.scene = scene }

    func activate() {
        guard let scene else { return }
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: scene.session))
    }
}

/// The app-wide record of which scene holds an editor for which entry, by entry UUID. It is
/// the one place that keeps each entry edited in at most one place, so windows never
/// overwrite each other.
@MainActor final class EntryEditorCoordinator {
    private struct Registration {
        let entryID: UUID
        weak var editor: EntryEditorViewController?
        weak var scene: SceneEditors?
    }
    private var registrations: [Registration] = []

    /// Call once per scene when it connects; the scene keeps the result until it disconnects.
    func connectScene(_ handle: any SceneHandle) -> SceneEditors {
        SceneEditors(coordinator: self, handle: handle)
    }

    /// The scene holding an editor for `id`, if any.
    func scene(editing id: UUID) -> SceneEditors? {
        liveRegistrations().first { $0.entryID == id }?.scene
    }

    /// `id` was deleted: every editor still showing it closes, and its unflushed input goes with the entry.
    func entryDeleted(_ id: UUID) {
        for registration in liveRegistrations() where registration.entryID == id {
            registration.editor?.closeForDeletedEntry()
        }
    }

    fileprivate func register(_ editor: EntryEditorViewController, in scene: SceneEditors) {
        unregister(editor)
        registrations.append(Registration(entryID: editor.entry.id, editor: editor, scene: scene))
    }

    fileprivate func unregister(_ editor: EntryEditorViewController) {
        registrations.removeAll { $0.editor == nil || $0.editor === editor }
    }

    fileprivate func disconnect(_ scene: SceneEditors) {
        registrations.removeAll { $0.scene == nil || $0.scene === scene }
    }

    /// Registrations whose editor and scene are still alive.
    private func liveRegistrations() -> [Registration] {
        registrations.removeAll { $0.editor == nil || $0.scene == nil }
        return registrations
    }
}

/// One scene's editors as the coordinator sees them. The scene delegate keeps it; the
/// scene's timeline and editors report through it.
@MainActor final class SceneEditors {
    let coordinator: EntryEditorCoordinator
    let handle: any SceneHandle

    fileprivate init(coordinator: EntryEditorCoordinator, handle: any SceneHandle) {
        self.coordinator = coordinator; self.handle = handle
    }

    /// An editor now shows its entry in this scene.
    func register(_ editor: EntryEditorViewController) { coordinator.register(editor, in: self) }
    /// An editor closed.
    func unregister(_ editor: EntryEditorViewController) { coordinator.unregister(editor) }
    /// This scene disconnected; its editors no longer hold their entries.
    func disconnect() { coordinator.disconnect(self) }

    /// Selecting `id` here: if another scene edits it, brings that scene forward and returns true.
    func activateOtherScene(editing id: UUID) -> Bool {
        guard let holder = coordinator.scene(editing: id), holder !== self else { return false }
        holder.handle.activate()
        return true
    }

    /// `id` was deleted from this scene; see `EntryEditorCoordinator.entryDeleted(_:)`.
    func entryDeleted(_ id: UUID) { coordinator.entryDeleted(id) }
}
