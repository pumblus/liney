import SwiftData
import Testing
import UIKit
@testable import Liney

/// Go to Month, driven from the Calendar View's leading bar button.
extension CalendarViewTests {
    func monthTitle(_ date: Date) -> String { date.formatted(.dateTime.month(.wide).year()) }

    /// The leading bar button that shows the month in view.
    func goToMonthButton(in timeline: TimelineViewController) throws -> UIButton {
        let item = try #require(timeline.navigationItem.leftBarButtonItems?.first)
        return try #require(item.customView as? UIButton)
    }

    /// Taps the Go to Month button and returns the popover once it shows.
    func openGoToMonth(in timeline: TimelineViewController, window: UIWindow) async throws -> GoToMonthViewController {
        try goToMonthButton(in: timeline).sendActions(for: .primaryActionTriggered)
        try await waitForLayout(window)
        let navigation = try #require(timeline.presentedViewController as? UINavigationController)
        return try #require(navigation.viewControllers.first as? GoToMonthViewController)
    }

    /// Waits until the popover over `timeline` has closed.
    func waitForDismissal(of timeline: TimelineViewController, window: UIWindow) async throws {
        for _ in 0..<100 where timeline.presentedViewController != nil { try await Task.sleep(for: .milliseconds(20)) }
        try await waitForLayout(window)
    }

    /// Turns the year and month wheels to `month` as a writer would.
    func turn(_ goToMonth: GoToMonthViewController, to month: Date) throws {
        let picker = goToMonth.picker
        let year = month.formatted(.dateTime.year())
        let yearRow = try #require((0..<picker.numberOfRows(inComponent: 0)).first { goToMonth.title(forRow: $0, inComponent: 0) == year })
        picker.selectRow(yearRow, inComponent: 0, animated: false)
        picker.delegate?.pickerView?(picker, didSelectRow: yearRow, inComponent: 0)
        let name = calendar.standaloneMonthSymbols[calendar.component(.month, from: month) - 1]
        let monthRow = try #require((0..<picker.numberOfRows(inComponent: 1)).first { goToMonth.title(forRow: $0, inComponent: 1) == name })
        picker.selectRow(monthRow, inComponent: 1, animated: false)
        picker.delegate?.pickerView?(picker, didSelectRow: monthRow, inComponent: 1)
    }

    /// Whether day 1 of `month` is on screen in the calendar.
    func showsFirstDay(of month: Date, in calendarView: CalendarViewController) throws -> Bool {
        let indexPath = try #require(calendarView.indexPath(for: calendar.dateInterval(of: .month, for: month)!.start))
        return calendarView.collectionView.indexPathsForVisibleItems.contains(indexPath)
    }

    /// A journal whose earliest entry is 14 months ago, mounted and switched to Calendar.
    func mountLongCalendar(sizeClass: UIUserInterfaceSizeClass = .regular, width: CGFloat = 1100)
        async throws -> (timeline: TimelineViewController, calendarView: CalendarViewController, window: UIWindow, earliest: Date) {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let earliest = calendar.date(byAdding: .month, value: -14, to: .now)!
        context.insert(JournalEntry(title: "Fixture", entryDate: earliest))
        try context.save()
        let (root, window) = try await mountJournal(container, days: 1, sizeClass: sizeClass, width: width)
        let calendarView = try await showCalendar(in: root.timeline, months: months(since: earliest), window: window)
        return (root.timeline, calendarView, window, earliest)
    }

    @Test func goToMonthButtonReadsTheMonthInViewOnlyInCalendar() async throws {
        let (timeline, _, window, _) = try await mountLongCalendar()
        defer { window.isHidden = true }
        let button = try goToMonthButton(in: timeline)
        #expect(button.accessibilityLabel == monthTitle(.now))
        #expect(button.accessibilityHint == String(localized: "Changes the month shown in the calendar."))

        try select(String(localized: "List"), in: timeline)
        #expect(timeline.navigationItem.leftBarButtonItems?.isEmpty != false)
    }

    @Test func wheelsStartAtTheMonthInViewAndCoverTheCalendarRange() async throws {
        let (timeline, _, window, earliest) = try await mountLongCalendar()
        let goToMonth = try await openGoToMonth(in: timeline, window: window)
        let picker = goToMonth.picker
        let currentMonth = calendar.component(.month, from: .now)
        let years = (0..<picker.numberOfRows(inComponent: 0)).map { goToMonth.title(forRow: $0, inComponent: 0) }
        #expect(years.first == earliest.formatted(.dateTime.year()))
        #expect(years.last == Date.now.formatted(.dateTime.year()))
        // Starts at the month in view, the current month; the current year ends at the current month.
        #expect(picker.selectedRow(inComponent: 0) == years.count - 1)
        #expect(goToMonth.title(forRow: picker.selectedRow(inComponent: 1), inComponent: 1)
                == calendar.standaloneMonthSymbols[currentMonth - 1])
        #expect(goToMonth.title(forRow: picker.numberOfRows(inComponent: 1) - 1, inComponent: 1)
                == calendar.standaloneMonthSymbols[currentMonth - 1])
        // The earliest year starts at the earliest entry's month, which has entries; others are selectable too.
        try turn(goToMonth, to: earliest)
        #expect(goToMonth.title(forRow: 0, inComponent: 1) == calendar.standaloneMonthSymbols[calendar.component(.month, from: earliest) - 1])
        await unmount(window)
    }

    @Test func doneMovesToTheChosenMonthAndThisMonthMovesBack() async throws {
        let (timeline, calendarView, window, earliest) = try await mountLongCalendar()
        let chosen = calendar.date(byAdding: .month, value: 2, to: earliest)!
        var goToMonth = try await openGoToMonth(in: timeline, window: window)
        try turn(goToMonth, to: chosen)
        try tapBarButton(String(localized: "Done"), in: goToMonth)
        try await waitForDismissal(of: timeline, window: window)
        #expect(timeline.presentedViewController == nil)
        #expect(try showsFirstDay(of: chosen, in: calendarView))
        #expect(try goToMonthButton(in: timeline).accessibilityLabel == monthTitle(chosen))

        goToMonth = try await openGoToMonth(in: timeline, window: window)
        #expect(goToMonth.title(forRow: goToMonth.picker.selectedRow(inComponent: 1), inComponent: 1)
                == calendar.standaloneMonthSymbols[calendar.component(.month, from: chosen) - 1])
        try tapBarButton(String(localized: "This Month"), in: goToMonth)
        try await waitForDismissal(of: timeline, window: window)
        #expect(timeline.presentedViewController == nil)
        #expect(try showsFirstDay(of: .now, in: calendarView))
        #expect(try goToMonthButton(in: timeline).accessibilityLabel == monthTitle(.now))
        await unmount(window)
    }

    @Test func dismissingOutsideLeavesTheCalendarWhereItWas() async throws {
        let (timeline, calendarView, window, earliest) = try await mountLongCalendar()
        let offset = calendarView.collectionView.contentOffset
        let goToMonth = try await openGoToMonth(in: timeline, window: window)
        try turn(goToMonth, to: earliest)
        // A tap outside the popover dismisses it through its presentation controller.
        let presentation = try #require(goToMonth.navigationController?.presentationController)
        #expect(presentation.delegate?.presentationControllerShouldDismiss?(presentation) ?? true)
        goToMonth.navigationController?.dismiss(animated: false)
        presentation.delegate?.presentationControllerDidDismiss?(presentation)
        try await waitForLayout(window)
        #expect(timeline.presentedViewController == nil)
        #expect(calendarView.collectionView.contentOffset == offset)
        #expect(try goToMonthButton(in: timeline).accessibilityLabel == monthTitle(.now))
        await unmount(window)
    }

    @Test func goToMonthStaysAPopoverInCompactWidth() async throws {
        let (timeline, _, window, _) = try await mountLongCalendar(sizeClass: .compact, width: 390)
        let goToMonth = try await openGoToMonth(in: timeline, window: window)
        let navigation = try #require(goToMonth.navigationController)
        let popover = try #require(navigation.popoverPresentationController)
        #expect(popover.sourceItem === timeline.navigationItem.leftBarButtonItems?.first)
        #expect(popover.delegate?.adaptivePresentationStyle?(for: popover, traitCollection: timeline.traitCollection) == UIModalPresentationStyle.none)
        #expect(navigation.view.frame.width < window.bounds.width)
        await unmount(window)
    }
}
