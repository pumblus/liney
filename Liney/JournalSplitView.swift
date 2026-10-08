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

    /// The editor open in this window's timeline flow, outside any modal: above the timeline
    /// when collapsed, in the secondary column otherwise.
    var openEditor: EntryEditorViewController? {
        (timelineNavigation.viewControllers + entryNavigation.viewControllers)
            .lazy.compactMap { $0 as? EntryEditorViewController }.first
    }

    /// Opens an existing entry: pushed above the timeline in one stack, otherwise in the secondary column.
    func showEntry(_ editor: EntryEditorViewController) {
        if isCollapsed {
            timelineNavigation.pushViewController(editor, animated: true)
        } else {
            entryNavigation.setViewControllers([editor], animated: false)
            show(.secondary)
        }
    }

    /// Opens a new entry: pushed above the timeline in one stack, otherwise presented modally.
    func showNewEntry(_ editor: EntryEditorViewController) {
        if isCollapsed {
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

    private static func markMoving(_ controllers: some Sequence<UIViewController>) {
        for case let editor as EntryEditorViewController in controllers { editor.isMovingBetweenColumns = true }
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
        .primary
    }

    /// Moves the open editor, as the same instance, above the timeline so Back leads to it.
    func splitViewControllerDidCollapse(_ svc: UISplitViewController) {
        let entry = entryNavigation.viewControllers.filter { $0 is EntryEditorViewController }
        guard !entry.isEmpty else { return }
        Self.markMoving(entry)
        entryNavigation.setViewControllers([Self.noEntrySelected()], animated: false)
        timelineNavigation.setViewControllers(timelineNavigation.viewControllers + entry, animated: false)
    }

    /// Moves an editor pushed while collapsed, as the same instance, to the secondary column.
    func splitViewControllerDidExpand(_ svc: UISplitViewController) {
        let stack = timelineNavigation.viewControllers
        guard let index = stack.firstIndex(where: { $0 is EntryEditorViewController }),
              let editor = stack[index] as? EntryEditorViewController else { return }
        Self.markMoving(stack[index...])
        timelineNavigation.setViewControllers(Array(stack[..<index]), animated: false)
        entryNavigation.setViewControllers(Array(stack[index...]), animated: false)
        timeline.selectRow(for: editor.entry.id)
    }
}
