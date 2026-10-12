import SwiftData
import Testing
import UIKit
@testable import Liney

/// The timeline's rows and row actions limited to one day, pushed in the timeline column.
@Suite(.serialized)
@MainActor
struct EntryListTests {
    let container: ModelContainer
    let day: Date
    let evening: JournalEntry
    let morning: JournalEntry
    let allDay: JournalEntry
    let coordinator = EntryEditorCoordinator()

    init() throws {
        container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let calendar = Calendar.current
        day = try #require(calendar.date(from: DateComponents(year: 2023, month: 11, day: 15)))
        evening = JournalEntry(title: "Synthetic evening", entryDate: day.addingTimeInterval(18 * 3600))
        morning = JournalEntry(title: "Synthetic morning", entryDate: day.addingTimeInterval(9 * 3600))
        allDay = JournalEntry(title: "Synthetic all-day", entryDate: day.addingTimeInterval(12 * 3600), isAllDay: true)
        let otherDay = JournalEntry(title: "Synthetic other day", entryDate: day.addingTimeInterval(-12 * 3600))
        for entry in [allDay, morning, evening, otherDay] { context.insert(entry) }
        try context.save()
    }

    /// A full window with `day`'s list pushed above the timeline, its rows loaded.
    func mountDayList() async throws -> (root: JournalSplitViewController, list: EntryListViewController, window: UIWindow) {
        let (root, window) = try await mountJournal(container, days: 2, editors: coordinator.connectScene(FakeScene()))
        let list = root.timeline.dayList(for: day)
        try #require(root.timeline.navigationController).pushViewController(list, animated: false)
        try await waitForRows(1, in: list)
        try await waitForLayout(window)
        return (root, list, window)
    }

    func titles(in list: EntryListViewController) -> [String?] {
        (0..<list.tableView.numberOfRows(inSection: 0)).map { row in
            list.tableView.cellForRow(at: IndexPath(row: row, section: 0))
                .flatMap { descendants($0.contentView, as: UILabel.self).first?.text }
        }
    }

    @Test func aDayListShowsOnlyThatDaysEntriesInTimelineOrder() async throws {
        let (_, list, window) = try await mountDayList()
        #expect(list.tableView.numberOfSections == 1)
        #expect(titles(in: list) == ["Synthetic evening", "Synthetic morning", "Synthetic all-day"])
        #expect(list.navigationItem.searchController == nil)
        await unmount(window)
    }

    @Test func tappingARowOpensTheEntryInTheSecondaryColumnAndSelectsIt() async throws {
        let (root, list, window) = try await mountDayList()
        list.tableView(list.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))
        try await waitForLayout(window)
        let secondary = try #require(root.viewController(for: .secondary) as? UINavigationController)
        let editor = try #require(secondary.topViewController as? EntryEditorViewController)
        #expect(editor.entry.id == morning.id)
        #expect(root.timeline.navigationController?.topViewController === list)
        await unmount(window)
    }

    @Test func rowsOfferOpenInNewWindowAndDragOutAnEntryWindowActivity() async throws {
        let (_, list, window) = try await mountDayList()
        let row = IndexPath(row: 0, section: 0)
        let actions = try #require(list.rowMenu(at: row))
        #expect(actions.children.first is UIWindowScene.ActivationAction)
        let items = list.tableView(list.tableView, itemsForBeginning: FakeDragSession(), at: row)
        #expect(items.count == 1)
        #expect(items.first?.itemProvider.canLoadObject(ofClass: NSUserActivity.self) == true)
        await unmount(window)
    }

    @Test func swipeToDeleteConfirmsThenRemovesOnlyThatRow() async throws {
        let (_, list, window) = try await mountDayList()
        let swipe = try #require(list.tableView(list.tableView,
            trailingSwipeActionsConfigurationForRowAt: IndexPath(row: 0, section: 0)))
        let action = try #require(swipe.actions.first)
        action.handler(action, list.tableView) { _ in }
        let confirmation = try await waitForAlert(from: list)
        try await perform(String(localized: "Delete Entry"), in: confirmation)
        for _ in 0..<100 where list.tableView.numberOfRows(inSection: 0) != 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(titles(in: list) == ["Synthetic morning", "Synthetic all-day"])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<JournalEntry>()) == 3)
        await unmount(window)
    }
}
