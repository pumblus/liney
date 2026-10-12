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
- **Story 86**: Jump to a year and month from a Go to Month popover, confirmed with Done.
- **Story 87**: Give every day cell a VoiceOver label with its date, entry count, and whether it has photos.

## 2. Implementation Decisions

### Placement & Mode
- The List / Calendar `UISegmentedControl` is the `titleView` of the timeline's navigation bar. The More and New Entry bar buttons stay in both modes.
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
- In Calendar mode, the leading bar button shows the month currently in view (for example "October 2026 ⌄" / "2026年10月 ⌄").
- Tapping it shows a popover anchored to the button. The popover stays a popover on iPhone too (no sheet adaptation).
- The popover has a top bar with **This Month** (leading) and **Done** (trailing, bold), above a two-column `UIPickerView` for year and month.
- The picker starts at the month in view. Its range matches the calendar range; in the current year the month column ends at the current month. Months without entries can be chosen.
- **Done** scrolls the calendar to the chosen month and closes the popover. **This Month** scrolls to the current month and closes the popover. Tapping outside closes the popover without moving the calendar.
- Go to Month picks a month only, not a day.
- Copy: "Done" / "完成", "This Month" / "本月".

### Updates & Privacy
- The calendar derives its days from the same `TimelineRepository` data as the timeline and refreshes when the timeline does, including during Day One Import.
- Thumbnails are journal content: App Lock and the snapshot privacy shield cover the Calendar View like the timeline.

### Accessibility
- A day with entries reads like "October 12, 3 entries, with photos". An empty day reads like "October 12, no entries" and is not activatable.
- The Go to Month button reads as the month in view with a hint that it changes the month.

## 3. Out of Scope

Mood or Plans on the calendar, a year view, choosing a day in Go to Month, text search in Calendar mode, and creating an entry from a calendar day.
