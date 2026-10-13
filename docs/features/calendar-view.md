# Calendar View

This document owns the Calendar View: the List / Calendar switch, the month grid, the photo that represents each day, the day list, and the Go to Month picker.

- Scope: [SCOPE.md](../../SCOPE.md)
- Domain Terms: [GLOSSARY.md](../../GLOSSARY.md)
- Code Mapping: `TimelineView.swift`, `TimelineRepository.swift` (see [architecture.md](../agents/architecture.md))

## 1. Stories & Acceptance Criteria

- **Story 79**: Switch the timeline column between List and Calendar with a segmented control in the navigation bar title. Each window remembers its last mode across launches.
- **Story 80**: Show the journal as vertically scrolling months, from the month of the earliest entry to the current month, opening at the current month. No future months.
- **Story 81**: Show each day that has entries with one representative photo; show days without photos as the date number only.
- **Story 82**: Leave days without entries not tappable, including future days of the current month; emphasize today.
- **Story 83**: Tapping a day pushes a day list of that day's entries in standard timeline rows.
- **Story 84**: Return to the calendar when the day list becomes empty.
- **Story 85**: Keep the calendar current while entries are written, edited, deleted, or imported.
- **Story 86**: Jump to a year and month from Go to Month, opened by tapping a Month Header and confirmed with Done.
- **Story 87**: Give every day cell a VoiceOver label with its date, entry count, and whether it has photos.

## 2. Implementation Decisions

### Placement & Mode
- The List / Calendar `UISegmentedControl` is the `titleView` of the timeline's navigation bar. Its segments are the `list.bullet` and `calendar` symbols, read by VoiceOver as "List" / "列表" and "Calendar" / "日历", so the control fits the narrowest sidebar in every language.
- The navigation bar is the same in both modes: the List / Calendar control, New Entry, and More. Calendar mode adds no bar button.
- Calendar mode keeps the large title "Journal". It collapses while the calendar is scrolled away from its top and never covers a Month Header.
- Calendar mode hides the search bar. Text search is available only in List mode.
- The mode is stored per window through the existing window state restoration. A new window starts in List.
- The Calendar View replaces the timeline in the same column. On iPad, in Split View, and on iPhone Duo it stays in the primary column; entries still open in the secondary column. There is no separate wide layout.
- New Entry in Calendar mode creates an entry at the current date and time, the same as in List mode.

### Month Grid
- Months scroll vertically and continuously. The range runs from the month of the earliest Entry Date to the current month. With no entries, the range is the current month only.
- The first weekday follows `Calendar.current.firstWeekday`. Month and weekday names follow the system locale.
- All-day Entries count toward their day like any other entry, with no special mark.
- Multiple entries on one day show no count badge.

### Representative Photo
- Walk the day's entries in timeline order: timed entries from latest to earliest, then All-day Entries. Use the first photo of the first entry that has any photo.
- Entries without photos are skipped.
- If the photo file cannot be loaded, the cell shows the date number only.

### Day Cell States
- **Has entries**: tappable; shows the representative photo or the date number.
- **No entries**: date number only; not tappable.
- **Today**: date number tinted with Liney Aqua.
- **Future days of the current month**: dimmed date number; not tappable. A future day with entries shows and opens like any other day with entries.
- Tapping an empty day does not create an entry.

### Day List
- Pushed in the same column. The title is the full localized date with weekday (for example "Monday, October 12, 2026" / "2026年10月12日 星期一").
- Rows are standard timeline rows in timeline order and keep their row actions: Open in New Window, row drag, and swipe to delete.
- When the last entry leaves the day (deleted, or its Entry Date moved to another day), the day list pops back to the calendar.

### Go to Month
- Each Month Header is a button: the month name (for example "October 2026" / "2026年10月") followed by a chevron (⌄) in Liney Aqua. Tapping it opens Go to Month at that month.
- In a regular-width window, Go to Month is a popover anchored to the tapped Month Header. In a compact-width window (iPhone, narrow iPad Split View, the iPhone Duo outer display) it is a short sheet without a grabber.
- Go to Month has a navigation bar with **This Month** (leading), the title "Go to Month" / 「前往月份」, and the system **Done** checkmark (trailing), above the year and month wheels.
- On iOS 17.4 and later the wheels are the system `UIDatePicker` in year-and-month mode. Its range runs from the first calendar month to the current month; the system dims months outside the range and springs back from them. On iOS 17.0–17.3 the wheels are Liney's own two-column picker over the same range.
- The wheels start at the tapped month. Months without entries can be chosen.
- **Done** scrolls the calendar to the chosen month and closes Go to Month. **This Month** scrolls to the current month and closes it. Tapping outside or swiping the sheet down closes it without moving the calendar.
- Go to Month picks a month only, not a day.
- Copy: "Go to Month" / 「前往月份」, "This Month" / 「本月」; Done uses the system checkmark.

### Updates & Privacy
- The calendar derives its days from the same `TimelineRepository` data as the timeline and refreshes when the timeline does, including during Day One Import.
- Thumbnails are journal content: App Lock and the snapshot privacy shield cover the Calendar View like the timeline.

### Accessibility
- A day with entries reads like "October 12, 3 entries, with photos". An empty day reads like "October 12, no entries" and is not activatable.
- A Month Header reads as a button named after its month, with a hint that it changes the month shown, and keeps the header trait so the VoiceOver rotor still moves month by month.

## 3. Out of Scope

Mood or Plans on the calendar, a year view, choosing a day in Go to Month, text search in Calendar mode, and creating an entry from a calendar day.
