import SwiftData
import Testing
import UIKit
@testable import Liney

/// Go to Month, opened by tapping a Month Header in the Calendar View.
extension CalendarViewTests {
    func monthTitle(_ date: Date) -> String { date.formatted(.dateTime.month(.wide).year()) }
    func monthStart(_ date: Date) -> Date { calendar.dateInterval(of: .month, for: date)!.start }

    /// The Month Header button of `month`, scrolled into view.
    func monthHeader(of month: Date, in calendarView: CalendarViewController, window: UIWindow) async throws -> UIButton {
        calendarView.scroll(toMonth: monthStart(month))
        try await waitForLayout(window)
        return try #require(descendants(calendarView.collectionView, as: UIButton.self).first { $0.accessibilityLabel == monthTitle(month) })
    }

    /// Taps `month`'s Month Header and returns Go to Month once it shows.
    func openGoToMonth(from month: Date, in timeline: TimelineViewController, window: UIWindow) async throws -> GoToMonthViewController {
        let calendarView = try #require(timeline.calendarView)
        try await monthHeader(of: month, in: calendarView, window: window).sendActions(for: .primaryActionTriggered)
        try await waitForLayout(window)
        let navigation = try #require(timeline.presentedViewController as? UINavigationController)
        return try #require(navigation.viewControllers.first as? GoToMonthViewController)
    }

    /// Waits until Go to Month over `timeline` has closed.
    func waitForDismissal(of timeline: TimelineViewController, window: UIWindow) async throws {
        try await waitUntil { timeline.presentedViewController == nil }
        try await waitForLayout(window)
    }

    /// Turns the system year and month wheels to `month` as a writer would.
    func turn(_ goToMonth: GoToMonthViewController, to month: Date) throws {
        let wheels = try #require(goToMonth.datePicker)
        wheels.date = month
        wheels.sendActions(for: .valueChanged)
    }

    /// Turns Liney's own year and month wheels to `month` as a writer would.
    func turnOwnWheels(_ goToMonth: GoToMonthViewController, to month: Date) throws {
        let picker = try #require(goToMonth.picker)
        let year = month.formatted(.dateTime.year())
        let yearRow = try #require((0..<picker.numberOfRows(inComponent: 0)).first { goToMonth.title(forRow: $0, inComponent: 0) == year })
        picker.selectRow(yearRow, inComponent: 0, animated: false)
        picker.delegate?.pickerView?(picker, didSelectRow: yearRow, inComponent: 0)
        let name = calendar.standaloneMonthSymbols[calendar.component(.month, from: month) - 1]
        let monthRow = try #require((0..<picker.numberOfRows(inComponent: 1)).first { goToMonth.title(forRow: $0, inComponent: 1) == name })
        picker.selectRow(monthRow, inComponent: 1, animated: false)
        picker.delegate?.pickerView?(picker, didSelectRow: monthRow, inComponent: 1)
    }

    /// Taps the Done checkmark.
    func tapGoToMonthDone(in goToMonth: GoToMonthViewController) throws {
        let done = try #require(goToMonth.navigationItem.rightBarButtonItem)
        try #require(done.primaryAction).performWithSender(done, target: nil)
    }

    /// Whether day 1 of `month` is on screen in the calendar.
    func showsFirstDay(of month: Date, in calendarView: CalendarViewController) throws -> Bool {
        let indexPath = try #require(calendarView.indexPath(for: monthStart(month)))
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

    @Test func monthHeaderReadsAsAButtonAndKeepsTheHeaderTrait() async throws {
        let (_, calendarView, window, earliest) = try await mountLongCalendar()
        let header = try await monthHeader(of: earliest, in: calendarView, window: window)
        #expect(header.accessibilityHint == String(localized: "Changes the month shown in the calendar."))
        #expect(header.accessibilityTraits.contains(.button))
        // The VoiceOver rotor still moves month by month.
        #expect(header.accessibilityTraits.contains(.header))
        await unmount(window)
    }

    @available(iOS 17.4, *)
    @Test func wheelsStartAtTheTappedMonthAndCoverTheCalendarRange() async throws {
        let (timeline, _, window, earliest) = try await mountLongCalendar()
        let tapped = calendar.date(byAdding: .month, value: 3, to: earliest)!
        let goToMonth = try await openGoToMonth(from: tapped, in: timeline, window: window)
        #expect(goToMonth.navigationItem.title == String(localized: "Go to Month"))
        let wheels = try #require(goToMonth.datePicker)
        #expect(wheels.datePickerMode == .yearAndMonth)
        #expect(monthStart(wheels.date) == monthStart(tapped))
        #expect(wheels.minimumDate == monthStart(earliest))
        // The range ends in the current month; later months are dimmed by the system.
        #expect(try monthStart(#require(wheels.maximumDate)) == monthStart(.now))
        await unmount(window)
    }

    @available(iOS 17.4, *)
    @Test func doneMovesToTheChosenMonthAndThisMonthMovesBack() async throws {
        let (timeline, calendarView, window, earliest) = try await mountLongCalendar()
        let chosen = calendar.date(byAdding: .month, value: 2, to: earliest)!
        var goToMonth = try await openGoToMonth(from: .now, in: timeline, window: window)
        try turn(goToMonth, to: chosen)
        try tapGoToMonthDone(in: goToMonth)
        try await waitForDismissal(of: timeline, window: window)
        #expect(try showsFirstDay(of: chosen, in: calendarView))

        goToMonth = try await openGoToMonth(from: earliest, in: timeline, window: window)
        try tapBarButton(String(localized: "This Month"), in: goToMonth)
        try await waitForDismissal(of: timeline, window: window)
        #expect(try showsFirstDay(of: .now, in: calendarView))
        await unmount(window)
    }

    @available(iOS 17.4, *)
    @Test func dismissingOutsideLeavesTheCalendarWhereItWas() async throws {
        let (timeline, calendarView, window, earliest) = try await mountLongCalendar()
        let goToMonth = try await openGoToMonth(from: .now, in: timeline, window: window)
        let offset = calendarView.collectionView.contentOffset
        try turn(goToMonth, to: earliest)
        // A tap outside or a swipe down dismisses through the presentation controller.
        try #require(goToMonth.navigationController).dismiss(animated: false)
        try await waitForDismissal(of: timeline, window: window)
        #expect(timeline.presentedViewController == nil)
        #expect(calendarView.collectionView.contentOffset == offset)
        await unmount(window)
    }

    @Test func goToMonthIsAPopoverOnTheTappedHeaderInRegularWidth() async throws {
        let (timeline, calendarView, window, earliest) = try await mountLongCalendar()
        let goToMonth = try await openGoToMonth(from: earliest, in: timeline, window: window)
        let navigation = try #require(goToMonth.navigationController)
        #expect(navigation.modalPresentationStyle == .popover)
        let header = try await monthHeader(of: earliest, in: calendarView, window: window)
        #expect(navigation.popoverPresentationController?.sourceItem === header)
        await unmount(window)
    }

    @Test func goToMonthIsAShortSheetWithoutAGrabberInCompactWidth() async throws {
        let (timeline, _, window, _) = try await mountLongCalendar(sizeClass: .compact, width: 390)
        let goToMonth = try await openGoToMonth(from: .now, in: timeline, window: window)
        let navigation = try #require(goToMonth.navigationController)
        let sheet = try #require(navigation.sheetPresentationController)
        #expect(navigation.modalPresentationStyle != .popover)
        #expect(!sheet.prefersGrabberVisible)
        #expect(navigation.view.frame.height < window.bounds.height / 2)
        await unmount(window)
    }

    /// Before iOS 17.4, which has no system year and month wheels, Liney's own wheels cover the same range.
    @Test func ownWheelsCoverTheCalendarRangeAndStartAtTheTappedMonth() throws {
        let earliest = calendar.date(byAdding: .month, value: -14, to: .now)!
        let months = (0..<months(since: earliest)).map { calendar.date(byAdding: .month, value: $0, to: monthStart(earliest))! }
        var chosen: Date?
        let goToMonth = GoToMonthViewController(months: months, selected: months[3], usesSystemWheels: false) { chosen = $0 }
        goToMonth.loadViewIfNeeded()
        #expect(goToMonth.datePicker == nil)
        let picker = try #require(goToMonth.picker)
        let years = (0..<picker.numberOfRows(inComponent: 0)).map { goToMonth.title(forRow: $0, inComponent: 0) }
        #expect(years.first == earliest.formatted(.dateTime.year()))
        #expect(years.last == Date.now.formatted(.dateTime.year()))
        #expect(goToMonth.title(forRow: picker.selectedRow(inComponent: 1), inComponent: 1)
                == calendar.standaloneMonthSymbols[calendar.component(.month, from: months[3]) - 1])
        // The current year ends at the current month.
        try turnOwnWheels(goToMonth, to: .now)
        #expect(goToMonth.title(forRow: picker.numberOfRows(inComponent: 1) - 1, inComponent: 1)
                == calendar.standaloneMonthSymbols[calendar.component(.month, from: .now) - 1])
        try turnOwnWheels(goToMonth, to: months[1])
        try tapGoToMonthDone(in: goToMonth)
        #expect(chosen == months[1])
    }
}
