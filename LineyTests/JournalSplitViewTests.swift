import SwiftData
import Testing
import UIKit
@testable import Liney

/// The scene root mounted in a window; width changes through horizontal size class overrides.
@Suite(.serialized)
@MainActor
struct JournalSplitViewTests {
    let container: ModelContainer
    let first: JournalEntry
    let second: JournalEntry

    init() throws {
        container = try makeInMemoryContainer()
        let context = ModelContext(container)
        first = JournalEntry(title: "Synthetic first", entryDate: Date(timeIntervalSince1970: 1_700_100_000))
        second = JournalEntry(title: "Synthetic second", entryDate: Date(timeIntervalSince1970: 1_700_000_000))
        context.insert(first); context.insert(second)
        try context.save()
    }

    /// A mounted root and its timeline, with rows loaded.
    @MainActor struct Mounted {
        let root: JournalSplitViewController
        let timeline: TimelineViewController
        let window: UIWindow

        var primary: UINavigationController? { root.viewController(for: .primary) as? UINavigationController }
        var secondary: UINavigationController? { root.viewController(for: .secondary) as? UINavigationController }
        /// What a person sees: the one stack's top when collapsed, otherwise each shown column's top.
        var visible: [UIViewController] {
            if root.isCollapsed { return primary?.topViewController.map { [$0] } ?? [] }
            let sidebar = root.displayMode == .secondaryOnly ? nil : primary?.topViewController
            return [sidebar, secondary?.topViewController].compactMap { $0 }
        }
        var visibleEditor: EntryEditorViewController? { visible.lazy.compactMap { $0 as? EntryEditorViewController }.first }
        var showsNoEntrySelected: Bool {
            visible.contains { $0.title == String(localized: "No Entry Selected") }
        }

        func resize(to sizeClass: UIUserInterfaceSizeClass, width: CGFloat? = nil) async throws {
            if let width { window.frame.size.width = width }
            root.traitOverrides.horizontalSizeClass = sizeClass
            try await settle()
        }
        func select(day: Int) async throws {
            timeline.tableView(timeline.tableView, didSelectRowAt: IndexPath(row: 0, section: day))
            try await settle()
        }
        func settle() async throws {
            root.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    /// Mounts the root in a window `width` points wide; the system picks the display mode from it.
    func mount(_ sizeClass: UIUserInterfaceSizeClass, width: CGFloat = 1100, days: Int = 2) async throws -> Mounted {
        let timeline = TimelineViewController(container: container, appLock: AppLockModel(authenticator: DenyingAuthenticator()))
        let root = JournalSplitViewController(timeline: timeline)
        root.traitOverrides.horizontalSizeClass = sizeClass
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        window.rootViewController = root
        window.makeKeyAndVisible()
        for _ in 0..<100 {
            if timeline.tableView.numberOfSections == days { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(timeline.tableView.numberOfSections == days)
        let mounted = Mounted(root: root, timeline: timeline, window: window)
        try await mounted.settle()
        return mounted
    }

    func unmount(_ mounted: Mounted) async {
        if let presented = mounted.root.presentedViewController {
            await withCheckedContinuation { continuation in
                presented.dismiss(animated: false) { continuation.resume() }
            }
        }
        mounted.window.isHidden = true
    }

    @Test func narrowShowsOneStackAndTappingARowPushesTheEditor() async throws {
        let mounted = try await mount(.compact)
        #expect(mounted.root.isCollapsed)
        #expect(mounted.visible.map { $0 === mounted.timeline } == [true])
        try await mounted.select(day: 0)
        let editor = try #require(mounted.visibleEditor)
        #expect(editor.entry.id == first.id)
        #expect(mounted.primary?.viewControllers.first === mounted.timeline)
        await unmount(mounted)
    }

    @Test func wideShowsTheTimelineBesideTheOpenEntry() async throws {
        let mounted = try await mount(.regular)
        #expect(!mounted.root.isCollapsed)
        #expect(mounted.visible.first === mounted.timeline)
        #expect(mounted.showsNoEntrySelected)
        try await mounted.select(day: 1)
        let editor = try #require(mounted.secondary?.topViewController as? EntryEditorViewController)
        #expect(editor.entry.id == second.id)
        #expect(mounted.visible.first === mounted.timeline)
        #expect(!mounted.showsNoEntrySelected)
        await unmount(mounted)
    }

    @Test func collapsingKeepsTheOpenEditorAboveTheTimeline() async throws {
        let mounted = try await mount(.regular)
        try await mounted.select(day: 0)
        let editor = try #require(mounted.visibleEditor)
        try await mounted.resize(to: .compact)
        #expect(mounted.root.isCollapsed)
        #expect(mounted.visible.map { $0 === editor } == [true])
        // Back leads to the timeline.
        #expect(mounted.primary?.viewControllers.map { $0 === mounted.timeline || $0 === editor } == [true, true])
        #expect(mounted.primary?.viewControllers.first === mounted.timeline)
        await unmount(mounted)
    }

    @Test func collapsingWithNothingOpenShowsTheTimeline() async throws {
        let mounted = try await mount(.regular)
        try await mounted.resize(to: .compact)
        #expect(mounted.visible.map { $0 === mounted.timeline } == [true])
        #expect(mounted.primary?.viewControllers.count == 1)
        await unmount(mounted)
    }

    @Test func expandingMovesThePushedEditorToTheSecondaryColumnWithItsRowSelected() async throws {
        let mounted = try await mount(.compact)
        try await mounted.select(day: 1)
        let editor = try #require(mounted.visibleEditor)
        try await mounted.resize(to: .regular)
        #expect(!mounted.root.isCollapsed)
        #expect(mounted.secondary?.viewControllers.map { $0 === editor } == [true])
        #expect(mounted.primary?.viewControllers.map { $0 === mounted.timeline } == [true])
        #expect(mounted.timeline.tableView.indexPathForSelectedRow == IndexPath(row: 0, section: 1))
        await unmount(mounted)
    }

    @Test func expandingWithNothingOpenShowsNoEntrySelected() async throws {
        let mounted = try await mount(.compact)
        try await mounted.resize(to: .regular)
        #expect(mounted.visible.first === mounted.timeline)
        #expect(mounted.showsNoEntrySelected)
        await unmount(mounted)
    }

    @Test func aNewEntryWrittenWideStaysPresentedAcrossACollapse() async throws {
        let mounted = try await mount(.regular)
        mounted.timeline.createEntry()
        try await mounted.settle()
        let presented = try #require(mounted.root.presentedViewController as? UINavigationController)
        let editor = try #require(presented.topViewController as? EntryEditorViewController)
        #expect(editor.isNew)
        try await mounted.resize(to: .compact)
        #expect(mounted.root.presentedViewController === presented)
        #expect(presented.topViewController === editor)
        #expect(mounted.visible.map { $0 === mounted.timeline } == [true])
        await unmount(mounted)
    }

    @Test func aNewEntryPushedNarrowMovesToTheSecondaryColumnOnExpand() async throws {
        let mounted = try await mount(.compact)
        mounted.timeline.createEntry()
        try await mounted.settle()
        #expect(mounted.root.presentedViewController == nil)
        let editor = try #require(mounted.visibleEditor)
        #expect(editor.isNew)
        try await mounted.resize(to: .regular)
        #expect(mounted.secondary?.viewControllers.map { $0 === editor } == [true])
        #expect(mounted.primary?.viewControllers.map { $0 === mounted.timeline } == [true])
        await unmount(mounted)
    }

    // Open, new, and close follow the hierarchy as it is after a resize.

    @Test func doneAfterExpandingReturnsTheSecondaryColumnToNoEntrySelected() async throws {
        let mounted = try await mount(.compact)
        try await mounted.select(day: 0)
        let editor = try #require(mounted.visibleEditor)
        try await mounted.resize(to: .regular)
        editor.finish()
        try await mounted.settle()
        #expect(mounted.showsNoEntrySelected)
        #expect(mounted.primary?.viewControllers.map { $0 === mounted.timeline } == [true])
        #expect(mounted.timeline.tableView.indexPathForSelectedRow == nil)
        try await mounted.select(day: 1)
        #expect((mounted.secondary?.topViewController as? EntryEditorViewController)?.entry.id == second.id)
        await unmount(mounted)
    }

    @Test func doneAfterCollapsingReturnsToTheTimeline() async throws {
        let mounted = try await mount(.regular)
        try await mounted.select(day: 0)
        let editor = try #require(mounted.visibleEditor)
        try await mounted.resize(to: .compact)
        editor.finish()
        try await mounted.settle()
        #expect(mounted.visible.map { $0 === mounted.timeline } == [true])
        try await mounted.resize(to: .regular)
        #expect(mounted.showsNoEntrySelected)
        await unmount(mounted)
    }

    @Test func aNewEntryMovedOnExpandIsSavedByDone() async throws {
        let mounted = try await mount(.compact)
        mounted.timeline.createEntry()
        try await mounted.settle()
        let editor = try #require(mounted.visibleEditor)
        try await mounted.resize(to: .regular)
        let input = try #require(descendants(editor.view, as: BlockTextView.self).first)
        input.text = "Written after expanding"
        input.delegate?.textViewDidChange?(input)
        editor.finish()
        try await mounted.settle()
        #expect(mounted.showsNoEntrySelected)
        let saved = try ModelContext(container).fetch(FetchDescriptor<JournalEntry>())
        #expect(saved.count == 3)
        #expect(saved.contains { $0.plainTextBody == "Written after expanding" })
        await unmount(mounted)
    }

    @Test func openingAfterAResizeFollowsTheNewWidth() async throws {
        let mounted = try await mount(.regular)
        try await mounted.resize(to: .compact)
        try await mounted.select(day: 0)
        #expect(mounted.visibleEditor?.entry.id == first.id)
        #expect(mounted.primary?.viewControllers.count == 2)
        mounted.timeline.navigationController?.popViewController(animated: false)
        try await mounted.settle()
        try await mounted.resize(to: .regular)
        try await mounted.select(day: 1)
        #expect((mounted.secondary?.topViewController as? EntryEditorViewController)?.entry.id == second.id)
        mounted.timeline.createEntry()
        try await mounted.settle()
        #expect(mounted.root.presentedViewController != nil)
        await unmount(mounted)
    }

    @Test(arguments: [UIUserInterfaceSizeClass.regular, .compact])
    func screensPresentedFromTheEditorStayPresentedAcrossResizes(start: UIUserInterfaceSizeClass) async throws {
        let mounted = try await mount(start)
        try await mounted.select(day: 0)
        let editor = try #require(mounted.visibleEditor)
        let entryDate = UINavigationController(rootViewController: EntryDateViewController(entry: editor.entry) { })
        editor.present(entryDate, animated: false)
        try await mounted.settle()
        let alert = UIAlertController(title: "Fixture", message: nil, preferredStyle: .alert)
        entryDate.present(alert, animated: false)
        try await mounted.settle()
        for sizeClass in [start == .regular ? UIUserInterfaceSizeClass.compact : .regular, start] {
            try await mounted.resize(to: sizeClass)
            #expect(mounted.visibleEditor === editor)
            #expect(editor.presentedViewController === entryDate)
            #expect(entryDate.presentedViewController === alert)
        }
        await withCheckedContinuation { continuation in
            alert.dismiss(animated: false) { continuation.resume() }
        }
        await unmount(mounted)
    }

    @Test func aBlankNewEntryMovedOnExpandIsDiscardedWhenAnotherEntryOpens() async throws {
        let mounted = try await mount(.compact)
        mounted.timeline.createEntry()
        try await mounted.settle()
        try await mounted.resize(to: .regular)
        // The resize saved nothing, so the blank draft is not listed.
        #expect(mounted.timeline.tableView.numberOfSections == 2)
        try await mounted.select(day: 1)
        #expect((mounted.secondary?.topViewController as? EntryEditorViewController)?.entry.id == second.id)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<JournalEntry>()) == 2)
        await unmount(mounted)
    }

    // A resize keeps the person's place in the open editor and never saves or discards.

    /// An entry open at `start`: existing entries are selected from the timeline, new ones created.
    func openEditor(new: Bool, at start: UIUserInterfaceSizeClass) async throws -> (Mounted, EntryEditorViewController) {
        let mounted = try await mount(start)
        if new { mounted.timeline.createEntry(); try await mounted.settle() } else { try await mounted.select(day: 0) }
        return (mounted, try #require(mounted.visibleEditor))
    }

    @Test(arguments: [(false, UIUserInterfaceSizeClass.regular), (false, .compact), (true, .compact)])
    func unsavedTextCaretAndKeyboardSurviveCollapseAndExpandWithoutSaving(new: Bool, start: UIUserInterfaceSizeClass) async throws {
        let (mounted, editor) = try await openEditor(new: new, at: start)
        let input = try #require(descendants(editor.view, as: BlockTextView.self).first)
        #expect(input.becomeFirstResponder())
        // Text the debounced save has not reached yet.
        input.text = "Synthetic unsaved text"
        input.selectedRange = NSRange(location: 9, length: 0)
        for sizeClass in [start == .regular ? UIUserInterfaceSizeClass.compact : .regular, start] {
            try await mounted.resize(to: sizeClass)
            #expect(mounted.visibleEditor === editor)
            #expect(descendants(editor.view, as: BlockTextView.self).first === input)
            #expect(input.text == "Synthetic unsaved text")
            #expect(input.isFirstResponder)
            #expect(input.selectedRange == NSRange(location: 9, length: 0))
        }
        let stored = try ModelContext(container).fetch(FetchDescriptor<JournalEntry>())
        #expect(stored.count == 2)
        #expect(!stored.contains { $0.plainTextBody.contains("Synthetic unsaved text") })
        await unmount(mounted)
    }

    /// Collapse to a narrow window, rotate it, then expand: the text rewraps at every width.
    @Test(arguments: [true, false])
    func theFocusedLineOrElseTheTopVisibleBlockStaysInViewAcrossResizes(focused: Bool) async throws {
        let context = ModelContext(container)
        let long = JournalEntry(title: "Synthetic long", entryDate: Date(timeIntervalSince1970: 1_699_000_000))
        context.insert(long)
        for index in 0..<30 {
            let words = String(repeating: "Synthetic words rewrap at every width. ", count: 8)
            let block = EntryBlock(sortIndex: index, text: "Paragraph \(index). " + words, entry: long)
            long.blocks.append(block); context.insert(block)
        }
        try context.save()
        let mounted = try await mount(.regular, days: 3)
        try await mounted.select(day: 2)
        let editor = try #require(mounted.visibleEditor)
        let scroll = try #require(descendants(editor.view, as: UIScrollView.self).first { !($0 is UITextView) })
        let blocks = descendants(editor.view, as: BlockTextView.self)
        func frame(of view: UIView) -> CGRect { view.convert(view.bounds, to: scroll) }
        var visible: CGRect { scroll.bounds.inset(by: scroll.adjustedContentInset) }
        var topVisibleBlock: BlockTextView? {
            blocks.sorted { frame(of: $0).minY < frame(of: $1).minY }.first { frame(of: $0).maxY > visible.minY }
        }
        let input = blocks[20]
        func caret() throws -> CGRect {
            input.convert(input.caretRect(for: try #require(input.selectedTextRange).end), to: scroll)
        }
        if focused {
            #expect(input.becomeFirstResponder())
            input.selectedRange = NSRange(location: 150, length: 0)
            scroll.layoutIfNeeded()
            scroll.contentOffset.y = try caret().midY - scroll.bounds.height / 2
        } else {
            scroll.contentOffset.y = frame(of: blocks[15]).minY - scroll.adjustedContentInset.top
        }
        try await mounted.settle()
        for (sizeClass, width) in [(UIUserInterfaceSizeClass.compact, 400.0), (.compact, 800), (.regular, 1100)] {
            try await mounted.resize(to: sizeClass, width: width)
            if focused {
                #expect(input.isFirstResponder)
                #expect(visible.contains(try caret()), "caret at \(width) pt")
            } else {
                #expect(topVisibleBlock === blocks[15], "top block at \(width) pt")
            }
        }
        await unmount(mounted)
    }

    @Test func aNarrowWideWindowShowsTheSidebarAsAnOverlayThatHidesAfterASelection() async throws {
        let mounted = try await mount(.regular, width: 700)
        mounted.root.show(.primary)
        try await mounted.settle()
        #expect(mounted.root.displayMode == .oneOverSecondary)
        try await mounted.select(day: 0)
        #expect(mounted.root.displayMode == .secondaryOnly)
        #expect(mounted.visible.map { ($0 as? EntryEditorViewController)?.entry.id } == [first.id])
        await unmount(mounted)
    }

    @Test func aWideWindowShowsTheTimelineBesideTheEntry() async throws {
        let mounted = try await mount(.regular, width: 1100)
        #expect(mounted.root.displayMode == .oneBesideSecondary)
        try await mounted.select(day: 0)
        #expect(mounted.root.displayMode == .oneBesideSecondary)
        #expect(mounted.visible.first === mounted.timeline)
        await unmount(mounted)
    }
}
