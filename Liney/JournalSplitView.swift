import UIKit

/// The scene root on every device: the timeline stack in the primary column and the open
/// entry, or "No Entry Selected", in the secondary. The available width decides the shape;
/// routing reads the current shape at the moment of each action.
final class JournalSplitViewController: UISplitViewController {
    let timeline: TimelineViewController
    private let timelineNavigation: UINavigationController
    private let entryNavigation = UINavigationController()

    init(timeline: TimelineViewController) {
        self.timeline = timeline
        timelineNavigation = UINavigationController(rootViewController: timeline)
        timelineNavigation.navigationBar.prefersLargeTitles = true
        super.init(style: .doubleColumn)
        entryNavigation.setViewControllers([Self.noEntrySelected()], animated: false)
        setViewController(timelineNavigation, for: .primary)
        setViewController(entryNavigation, for: .secondary)
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The entry to reopen after relaunch, opened when the window first appears and its width decides the shape.
    var restoredEntryID: UUID?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let id = restoredEntryID else { return }
        restoredEntryID = nil
        timeline.restoreEntry(id)
    }

    /// The editor open in this window's timeline flow, outside any modal: above the timeline
    /// when collapsed, in the secondary column otherwise.
    var openEditor: EntryEditorViewController? {
        (timelineNavigation.viewControllers + entryNavigation.viewControllers)
            .lazy.compactMap { $0 as? EntryEditorViewController }.first
    }

    /// What this window reopens after relaunch: its open entry, but never a new entry's draft.
    var restoration: WindowRestoration? {
        openEditor.flatMap { $0.isNew ? nil : .selectedEntry($0.entry.id) }
    }

    /// The current hierarchy shape: true while the entry column is in this window beside the
    /// timeline, false while the timeline stack is the one stack. A resize changes it, so routing
    /// asks at the moment of each action.
    var showsEntryColumn: Bool { entryNavigation.parent === self }

    /// Opens an existing entry: in the secondary column beside the timeline, otherwise pushed above it.
    func showEntry(_ editor: EntryEditorViewController, animated: Bool = true) {
        if showsEntryColumn {
            entryNavigation.setViewControllers([editor], animated: false)
            show(.secondary)
        } else {
            timelineNavigation.pushViewController(editor, animated: animated)
        }
    }

    /// Opens a new entry: presented modally beside the timeline, otherwise pushed above it.
    func showNewEntry(_ editor: EntryEditorViewController) {
        if !showsEntryColumn {
            timelineNavigation.pushViewController(editor, animated: true)
        } else {
            let navigation = UINavigationController(rootViewController: editor)
            navigation.isModalInPresentation = true
            present(navigation, animated: true)
        }
    }

    /// Closes an editor wherever it is now: popped back to the timeline, or replaced by "No Entry Selected".
    func closeEntry(_ editor: EntryEditorViewController) {
        if let index = timelineNavigation.viewControllers.firstIndex(of: editor), index > 0 {
            timelineNavigation.popToViewController(timelineNavigation.viewControllers[index - 1], animated: true)
        } else if entryNavigation.viewControllers.contains(editor) {
            entryNavigation.setViewControllers([Self.noEntrySelected()], animated: false)
            timeline.selectRow(for: nil)
        }
    }

    /// What expanding moves to the secondary column: the first editor pushed while collapsed and anything above it.
    private var pushedEntry: ArraySlice<UIViewController> {
        let stack = timelineNavigation.viewControllers
        return stack.firstIndex { $0 is EntryEditorViewController }.map { stack[$0...] } ?? []
    }

    /// Runs before the move, while the editors are still on screen with their focus and caret.
    private static func beginMove(_ controllers: some Sequence<UIViewController>) {
        for case let editor as EntryEditorViewController in controllers { editor.beginColumnMove() }
    }

    private static func noEntrySelected() -> MessageController {
        MessageController(title: String(localized: "No Entry Selected"),
                          message: String(localized: "Choose an entry from the timeline once entries exist."))
    }
}

extension JournalSplitViewController: UISplitViewControllerDelegate {
    /// One stack always starts from the timeline; an open editor is moved above it, never the placeholder.
    func splitViewController(_ svc: UISplitViewController,
                             topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
        Self.beginMove(entryNavigation.viewControllers)
        return .primary
    }

    /// Moves the open editor, as the same instance, above the timeline so Back leads to it.
    func splitViewControllerDidCollapse(_ svc: UISplitViewController) {
        let entry = entryNavigation.viewControllers.filter { $0 is EntryEditorViewController }
        guard !entry.isEmpty else { return }
        entryNavigation.setViewControllers([Self.noEntrySelected()], animated: false)
        timelineNavigation.setViewControllers(timelineNavigation.viewControllers + entry, animated: false)
    }

    func splitViewController(_ svc: UISplitViewController,
                             displayModeForExpandingToProposedDisplayMode proposedDisplayMode: UISplitViewController.DisplayMode) -> UISplitViewController.DisplayMode {
        Self.beginMove(pushedEntry)
        return proposedDisplayMode
    }

    /// Moves an editor pushed while collapsed, as the same instance, to the secondary column.
    func splitViewControllerDidExpand(_ svc: UISplitViewController) {
        let entry = pushedEntry
        guard let editor = entry.first as? EntryEditorViewController else { return }
        timelineNavigation.setViewControllers(Array(timelineNavigation.viewControllers[..<entry.startIndex]), animated: false)
        entryNavigation.setViewControllers(Array(entry), animated: false)
        timeline.selectRow(for: editor.entry.id)
    }
}
