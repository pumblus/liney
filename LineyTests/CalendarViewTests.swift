import SwiftData
import Testing
import UIKit
@testable import Liney

/// The month calendar the timeline repository answers, with a fixed calendar and current date.
@Suite
struct MonthCalendarQueryTests {
    let calendar: Calendar

    init() {
        // All-day Entries are stored at the start of their day in the current time zone.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = Locale(identifier: "en_US")
        self.calendar = calendar
    }

    func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }

    func query(_ entries: [JournalEntry], now: Date, firstWeekday: Int = 1) async throws -> MonthCalendar {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        entries.forEach { context.insert($0) }
        try context.save()
        let repository = TimelineRepository(container: container)
        try await repository.reload()
        var calendar = calendar
        calendar.firstWeekday = firstWeekday
        return try await repository.monthCalendar(calendar: calendar, now: now)
    }

    @Test func monthsRunFromEarliestEntryAcrossYearBoundaryToCurrentMonth() async throws {
        let result = try await query([
            JournalEntry(title: "Later", entryDate: try date(2026, 1, 5)),
            JournalEntry(title: "Earliest", entryDate: try date(2025, 11, 20))
        ], now: try date(2026, 2, 10))
        #expect(result.months.map(\.start) == [
            try date(2025, 11, 1, hour: 0), try date(2025, 12, 1, hour: 0),
            try date(2026, 1, 1, hour: 0), try date(2026, 2, 1, hour: 0)
        ])
        #expect(result.months.map(\.days.count) == [30, 31, 31, 28])
    }

    @Test func emptyJournalShowsOnlyCurrentMonth() async throws {
        let result = try await query([], now: try date(2026, 10, 12))
        #expect(result.months.map(\.start) == [try date(2026, 10, 1, hour: 0)])
        #expect(result.months[0].days.map(\.number) == Array(1...31))
    }

    @Test func dayStatesListEntriesInTimelineOrder() async throws {
        let morning = JournalEntry(title: "Morning", entryDate: try date(2026, 7, 3, hour: 8))
        let evening = JournalEntry(title: "Evening", entryDate: try date(2026, 7, 3, hour: 20))
        let allDay = JournalEntry(title: "All Day", entryDate: try date(2026, 7, 3), isAllDay: true)
        let today = JournalEntry(title: "Today", entryDate: try date(2026, 7, 15, hour: 9))
        let result = try await query([allDay, morning, today, evening], now: try date(2026, 7, 15, hour: 13))
        let days = try #require(result.months.last).days

        #expect(days[2].state == .hasEntries)
        #expect(days[2].entryIDs == [evening.id, morning.id, allDay.id])
        #expect(days[2].entryCount == 3)
        #expect(!days[2].isToday)
        #expect(days[3].state == .noEntries)
        #expect(days[3].entryIDs.isEmpty)
        #expect(days[14].isToday)
        #expect(days[14].state == .hasEntries)
        #expect(days[15].state == .future)
        #expect(days[30].state == .future)
        #expect(days.filter(\.isToday).count == 1)
        #expect(days.prefix(14).allSatisfy { $0.state != .future })
    }

    @Test func futureDayWithEntriesInCurrentMonthOpensLikeAnyOtherDay() async throws {
        let ahead = JournalEntry(title: "Ahead", entryDate: try date(2026, 7, 20, hour: 9))
        let nextMonth = JournalEntry(title: "Next Month", entryDate: try date(2026, 8, 2, hour: 9))
        let result = try await query([ahead, nextMonth], now: try date(2026, 7, 15, hour: 13))

        #expect(result.months.map(\.start) == [try date(2026, 7, 1, hour: 0)])
        let days = result.months[0].days
        #expect(days[19].state == .hasEntries)
        #expect(days[19].isTappable)
        #expect(days[19].entryIDs == [ahead.id])
        #expect(days[20].state == .future)
        #expect(!days[20].isTappable)
    }

    @Test func representativePhotoIsFirstPhotoOfFirstEntryWithPhotosInTimelineOrder() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        func entry(_ title: String, _ date: Date, isAllDay: Bool = false, photos: [String] = []) {
            let entry = JournalEntry(title: title, entryDate: date, isAllDay: isAllDay)
            context.insert(entry)
            if !photos.isEmpty { _ = entry.insertPhotoGroup(fileNames: photos, in: context) }
        }
        // July 3: the latest timed entry has no photos, so the earlier timed entry's first photo wins over All-day.
        entry("Evening text", try date(2026, 7, 3, hour: 20))
        entry("Afternoon", try date(2026, 7, 3, hour: 15), photos: ["afternoon-1.jpg", "afternoon-2.jpg"])
        entry("Morning", try date(2026, 7, 3, hour: 8), photos: ["morning.jpg"])
        entry("All day", try date(2026, 7, 3), isAllDay: true, photos: ["all-day.jpg"])
        // July 4: only the All-day Entry has photos.
        entry("Timed text", try date(2026, 7, 4, hour: 9))
        entry("All day", try date(2026, 7, 4), isAllDay: true, photos: ["all-day-only.jpg"])
        // July 5: no photos at all.
        entry("Text only", try date(2026, 7, 5, hour: 9))
        try context.save()
        let repository = TimelineRepository(container: container)
        try await repository.reload()
        let days = try #require(try await repository.monthCalendar(calendar: calendar, now: try date(2026, 7, 15)).months.last).days

        #expect(days[2].photoFileName == "afternoon-1.jpg")
        #expect(days[3].photoFileName == "all-day-only.jpg")
        #expect(days[4].photoFileName == nil)
        #expect(days[5].photoFileName == nil)
    }

    @Test func emptyTodayIsNotFuture() async throws {
        let result = try await query([], now: try date(2026, 7, 15, hour: 23))
        let today = try #require(result.months.last?.days[14])
        #expect(today.isToday)
        #expect(today.state == .noEntries)
    }

    @Test(arguments: [(1, 3), (2, 2)])
    func weeksStartOnTheCalendarsFirstWeekday(firstWeekday: Int, leadingEmptyDays: Int) async throws {
        // July 1, 2026 is a Wednesday.
        let result = try await query([], now: try date(2026, 7, 15), firstWeekday: firstWeekday)
        #expect(result.months[0].leadingEmptyDays == leadingEmptyDays)
    }
}

/// The Calendar View mounted in a full window and driven like a writer would.
@Suite(.serialized)
@MainActor
struct CalendarViewTests {
    let calendar = Calendar.current

    func modeControl(of timeline: TimelineViewController) throws -> UISegmentedControl {
        try #require(timeline.navigationItem.titleView as? UISegmentedControl)
    }

    func select(_ title: String, in timeline: TimelineViewController) throws {
        let control = try modeControl(of: timeline)
        let index = try #require((0..<control.numberOfSegments).first { control.titleForSegment(at: $0) == title })
        control.selectedSegmentIndex = index
        control.sendActions(for: .valueChanged)
    }

    /// The number of months from the month of `earliest` to the current month.
    func months(since earliest: Date) -> Int {
        let start = { calendar.dateInterval(of: .month, for: $0)!.start }
        return calendar.dateComponents([.month], from: start(earliest), to: start(.now)).month! + 1
    }

    /// Switches `timeline` to Calendar and waits until its grid lists `months` months.
    func showCalendar(in timeline: TimelineViewController, months: Int, window: UIWindow) async throws -> CalendarViewController {
        try select(String(localized: "Calendar"), in: timeline)
        let calendarView = try #require(timeline.calendarView)
        try await waitUntil { calendarView.collectionView.numberOfSections == months }
        try #require(calendarView.collectionView.numberOfSections == months)
        try await waitForLayout(window)
        return calendarView
    }

    /// The cell showing `date`, scrolled into view, and whether tapping it is allowed.
    func day(_ date: Date, in calendarView: CalendarViewController) throws -> (cell: UICollectionViewCell, tappable: Bool) {
        let collectionView = calendarView.collectionView!
        let indexPath = try #require(calendarView.indexPath(for: calendar.startOfDay(for: date)))
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
        let cell = try #require(collectionView.cellForItem(at: indexPath))
        let tappable = collectionView.delegate?.collectionView?(collectionView, shouldSelectItemAt: indexPath) ?? true
        return (cell, tappable)
    }

    @Test func switchingModesSwapsSearchForCalendarAndKeepsBarButtons() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(JournalEntry(title: "Fixture"))
        try context.save()
        let (root, window) = try await mountJournal(container, days: 1)
        defer { window.isHidden = true }
        let timeline = root.timeline
        #expect(try modeControl(of: timeline).selectedSegmentIndex == 0)
        #expect(timeline.navigationItem.searchController != nil)

        let calendarView = try await showCalendar(in: timeline, months: 1, window: window)
        #expect(timeline.navigationItem.searchController == nil)
        #expect(calendarView.view.window != nil && !calendarView.view.isHidden)
        // Touches reach the calendar, not the rows beneath it.
        let center = calendarView.view.convert(CGPoint(x: calendarView.view.bounds.midX, y: 200), to: window)
        #expect(window.hitTest(center, with: nil)?.isDescendant(of: calendarView.view) == true)
        let labels = (timeline.navigationItem.rightBarButtonItems ?? []).map(\.accessibilityLabel)
        #expect(labels.contains(String(localized: "New Entry")) && labels.contains(String(localized: "More")))

        try select(String(localized: "List"), in: timeline)
        try await waitForRows(1, in: timeline)
        #expect(timeline.navigationItem.searchController != nil)
        #expect(timeline.calendarView?.view.isHidden != false)
    }

    @Test func emptyJournalShowsCurrentMonth() async throws {
        let (root, window) = try await mountJournal(try makeInMemoryContainer(), days: 0)
        defer { window.isHidden = true }
        let calendarView = try await showCalendar(in: root.timeline, months: 1, window: window)
        #expect(root.timeline.contentUnavailableConfiguration == nil)
        let today = try day(.now, in: calendarView)
        #expect(!today.tappable)
        #expect(today.cell.accessibilityValue == String(localized: "No entries"))
    }

    @Test func onlyPastDaysWithEntriesAreTappableAndVoiceOverReadsThem() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let past = calendar.date(byAdding: .day, value: -40, to: .now)!
        context.insert(JournalEntry(title: "Fixture one", entryDate: past))
        context.insert(JournalEntry(title: "Fixture two", entryDate: past, isAllDay: true))
        try context.save()
        let (root, window) = try await mountJournal(container, days: 1)
        defer { window.isHidden = true }
        let calendarView = try await showCalendar(in: root.timeline, months: months(since: past), window: window)

        let withEntries = try day(past, in: calendarView)
        #expect(withEntries.tappable)
        #expect(withEntries.cell.accessibilityLabel == past.formatted(.dateTime.month(.wide).day()))
        #expect(withEntries.cell.accessibilityValue == String(localized: "\(2) entries"))
        #expect(withEntries.cell.accessibilityTraits.contains(.button))

        let emptyPast = calendar.date(byAdding: .day, value: -39, to: .now)!
        let empty = try day(emptyPast, in: calendarView)
        #expect(!empty.tappable)
        #expect(empty.cell.accessibilityLabel == emptyPast.formatted(.dateTime.month(.wide).day()))
        #expect(empty.cell.accessibilityValue == String(localized: "No entries"))
        #expect(!empty.cell.accessibilityTraits.contains(.button))

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now)!
        if calendar.isDate(tomorrow, equalTo: .now, toGranularity: .month) {
            #expect(try !day(tomorrow, in: calendarView).tappable)
        } else {
            // On the last day of a month the calendar ends today.
            #expect(calendarView.indexPath(for: calendar.startOfDay(for: tomorrow)) == nil)
        }
    }

    /// The photo `cell` shows, waiting for it to load; nil when the cell shows its date number only.
    func shownPhoto(in cell: UICollectionViewCell) async throws -> UIImage? {
        let photo = try #require(descendants(cell, as: StoredPhotoView.self).first)
        try await waitUntil { photo.isHidden || photo.image != nil }
        return photo.isHidden ? nil : photo.image
    }

    @Test func daysShowTheirRepresentativePhotoOrTheirDateNumber() async throws {
        let (storage, directory) = makeTemporaryPhotoStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try storage.saveJPEG(from: makeJPEGData())
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let photoDay = calendar.date(byAdding: .day, value: -40, to: .now)!
        let missingDay = calendar.date(byAdding: .day, value: -39, to: .now)!
        let textDay = calendar.date(byAdding: .day, value: -38, to: .now)!
        let withPhoto = JournalEntry(title: "Fixture photo", entryDate: photoDay)
        context.insert(withPhoto)
        _ = withPhoto.insertPhotoGroup(fileNames: [stored.fileName], in: context)
        context.insert(JournalEntry(title: "Fixture text", entryDate: photoDay, isAllDay: true))
        let missing = JournalEntry(title: "Fixture missing", entryDate: missingDay)
        context.insert(missing)
        _ = missing.insertPhotoGroup(fileNames: ["synthetic-missing.jpg"], in: context)
        context.insert(JournalEntry(title: "Fixture text only", entryDate: textDay))
        try context.save()
        let (root, window) = try await mountJournal(container, days: 3, storage: storage)
        defer { window.isHidden = true }
        let calendarView = try await showCalendar(in: root.timeline, months: months(since: photoDay), window: window)

        let photo = try day(photoDay, in: calendarView).cell
        #expect(try await shownPhoto(in: photo) != nil)
        #expect(photo.accessibilityValue == String(localized: "\(2) entries, with photos"))

        let unloadable = try day(missingDay, in: calendarView).cell
        #expect(try await shownPhoto(in: unloadable) == nil)
        #expect(unloadable.accessibilityValue == String(localized: "\(1) entries, with photos"))

        let text = try day(textDay, in: calendarView).cell
        #expect(try await shownPhoto(in: text) == nil)
        #expect(text.accessibilityValue == String(localized: "\(1) entries"))

        // When the day's cell is reconfigured, the loaded photo stays rather than flashing empty.
        let added = JournalEntry(title: "Fixture added", entryDate: photoDay, isAllDay: true)
        context.insert(added)
        try context.save()
        NotificationCenter.default.post(name: .journalDidChange, object: added.id)
        let updatedValue = String(localized: "\(3) entries, with photos")
        try await waitUntil { try day(photoDay, in: calendarView).cell.accessibilityValue == updatedValue }
        let reloaded = try day(photoDay, in: calendarView).cell
        #expect(reloaded.accessibilityValue == updatedValue)
        let reloadedPhoto = try #require(descendants(reloaded, as: StoredPhotoView.self).first)
        #expect(!reloadedPhoto.isHidden && reloadedPhoto.image != nil)
    }

    @Test func calendarUpdatesAfterJournalChange() async throws {
        let container = try makeInMemoryContainer()
        let (root, window) = try await mountJournal(container, days: 0)
        defer { window.isHidden = true }
        let calendarView = try await showCalendar(in: root.timeline, months: 1, window: window)
        #expect(try !day(.now, in: calendarView).tappable)

        let context = ModelContext(container)
        let entry = JournalEntry(title: "Fixture written today")
        context.insert(entry)
        try context.save()
        NotificationCenter.default.post(name: .journalDidChange, object: entry.id)
        try await waitUntil { try day(.now, in: calendarView).tappable }
        #expect(try day(.now, in: calendarView).tappable)
        #expect(try day(.now, in: calendarView).cell.accessibilityValue == String(localized: "\(1) entries"))
    }

    /// Taps `date` in the calendar and waits for the day list it pushes to list its rows.
    func openDayList(_ date: Date, in root: JournalSplitViewController, window: UIWindow) async throws -> EntryListViewController {
        let calendarView = try #require(root.timeline.calendarView)
        let indexPath = try #require(calendarView.indexPath(for: calendar.startOfDay(for: date)))
        calendarView.collectionView(calendarView.collectionView, didSelectItemAt: indexPath)
        let list = try #require(root.timeline.navigationController?.topViewController as? EntryListViewController)
        try #require(list !== root.timeline)
        try await waitForRows(1, in: list)
        try await waitForLayout(window)
        return list
    }

    /// Waits until the timeline column shows the Calendar View again.
    func waitForCalendar(in root: JournalSplitViewController) async throws {
        let navigation = try #require(root.timeline.navigationController)
        try await waitUntil { navigation.topViewController === root.timeline }
        #expect(navigation.viewControllers.count == 1)
    }

    /// A journal with two entries on one past day, mounted in a full window showing the calendar.
    func mountDay(sizeClass: UIUserInterfaceSizeClass = .regular, width: CGFloat = 1100)
        async throws -> (root: JournalSplitViewController, window: UIWindow, container: ModelContainer, day: Date, entries: [JournalEntry]) {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let day = calendar.date(byAdding: .day, value: -10, to: calendar.startOfDay(for: .now))!
        let morning = JournalEntry(title: "Fixture morning", entryDate: day.addingTimeInterval(9 * 3600))
        let evening = JournalEntry(title: "Fixture evening", entryDate: day.addingTimeInterval(18 * 3600))
        [morning, evening].forEach { context.insert($0) }
        try context.save()
        let (root, window) = try await mountJournal(container, days: 1, sizeClass: sizeClass, width: width)
        _ = try await showCalendar(in: root.timeline, months: months(since: day), window: window)
        return (root, window, container, day, [evening, morning])
    }

    @Test func tappingADayPushesItsListTitledWithTheFullDate() async throws {
        let (root, window, _, day, entries) = try await mountDay()
        let list = try await openDayList(day, in: root, window: window)
        #expect(list.title == day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
        #expect(list.tableView.numberOfRows(inSection: 0) == 2)
        let first = list.tableView.cellForRow(at: IndexPath(row: 0, section: 0))
        #expect(first.flatMap { descendants($0.contentView, as: UILabel.self).first?.text } == entries[0].title)
        await unmount(window)
    }

    /// Moves `entry`'s Entry Date by `days` days and saves, as the editor's date picker does.
    func redate(_ entry: JournalEntry, byDays days: Int, in container: ModelContainer) throws {
        let context = ModelContext(container)
        let stored = try #require(try context.entry(id: entry.id))
        stored.entryDate = calendar.date(byAdding: .day, value: days, to: stored.entryDate)!
        try context.save()
        NotificationCenter.default.post(name: .journalDidChange, object: entry.id)
    }

    @Test func deletingTheDaysLastEntryReturnsToTheCalendar() async throws {
        let (root, window, _, day, entries) = try await mountDay()
        let list = try await openDayList(day, in: root, window: window)
        list.deleteEntry(id: entries[0].id)
        try await waitUntil { list.tableView.numberOfRows(inSection: 0) == 1 }
        #expect(root.timeline.navigationController?.topViewController === list)
        list.deleteEntry(id: entries[1].id)
        try await waitForCalendar(in: root)
        await unmount(window)
    }

    @Test func movingTheDaysLastEntryToAnotherDayReturnsToTheCalendar() async throws {
        let (root, window, container, day, entries) = try await mountDay()
        let list = try await openDayList(day, in: root, window: window)
        try redate(entries[0], byDays: -1, in: container)
        try await waitUntil { list.tableView.numberOfRows(inSection: 0) == 1 }
        #expect(root.timeline.navigationController?.topViewController === list)
        try redate(entries[1], byDays: 1, in: container)
        try await waitForCalendar(in: root)
        await unmount(window)
    }

    @Test func inOneStackMovingTheOpenEntryAwayLeavesItsEditorAboveTheCalendar() async throws {
        let (root, window, container, day, entries) = try await mountDay(sizeClass: .compact, width: 400)
        let list = try await openDayList(day, in: root, window: window)
        list.deleteEntry(id: entries[0].id)
        try await waitUntil { list.tableView.numberOfRows(inSection: 0) == 1 }
        list.tableView(list.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        try await waitForLayout(window)
        let navigation = try #require(root.timeline.navigationController)
        let editor = try #require(navigation.topViewController as? EntryEditorViewController)
        try redate(entries[1], byDays: -1, in: container)
        try await waitUntil { !navigation.viewControllers.contains(list) }
        // Back from the editor leads to the calendar; the emptied day list is gone.
        #expect(navigation.viewControllers.count == 2)
        #expect(navigation.viewControllers.first === root.timeline)
        #expect(navigation.topViewController === editor)
        await unmount(window)
    }

    @Test func closingAnEntryOpenedFromTheDayListClearsItsSelectedRow() async throws {
        let (root, window, _, day, entries) = try await mountDay()
        let list = try await openDayList(day, in: root, window: window)
        list.tableView.selectRow(at: IndexPath(row: 1, section: 0), animated: false, scrollPosition: .none)
        list.tableView(list.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))
        try await waitForLayout(window)
        let secondary = try #require(root.viewController(for: .secondary) as? UINavigationController)
        let editor = try #require(secondary.topViewController as? EntryEditorViewController)
        #expect(editor.entry.id == entries[1].id)
        #expect(list.tableView.indexPathForSelectedRow == IndexPath(row: 1, section: 0))
        try tapDone(in: editor)
        try await waitForLayout(window)
        #expect(list.tableView.indexPathForSelectedRow == nil)
        #expect(root.timeline.navigationController?.topViewController === list)
        await unmount(window)
    }

    @Test func newEntryInCalendarOpensAnEditorAtTheCurrentTime() async throws {
        let (root, window) = try await mountJournal(try makeInMemoryContainer(), days: 0)
        defer { window.isHidden = true }
        _ = try await showCalendar(in: root.timeline, months: 1, window: window)
        try tapNewEntry(in: root.timeline)
        try await waitForLayout(window)
        // Beside the timeline, a new entry opens in a modal stack.
        let navigation = try #require(root.presentedViewController as? UINavigationController)
        let editor = try #require(navigation.viewControllers.first as? EntryEditorViewController)
        #expect(editor.isNew)
        #expect(abs(editor.entry.entryDate.timeIntervalSinceNow) < 60)
        await unmount(window)
    }
}
