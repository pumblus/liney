# Liney Roadmap

This document collects directions for future releases. It is a reference, not a scope approval.

- **Scope**: [SCOPE.md](SCOPE.md)
- **Domain Terms**: [GLOSSARY.md](GLOSSARY.md)

Before work on any item starts, the item gets its own design review, and any product surface it adds needs an explicit user-approved scope update in `SCOPE.md` and its feature documents. Each item lists the invariants, non-goals, and stories it touches; those conflicts are resolved in that review, not here.

**Stages**: **Next** is the nearest candidate work. **Later** is planned but waits on Next. **Exploring** is an open idea whose shape or fit is not settled.

## 1. Browsing & Recall

### Calendar View — In scope
- **Scope**: Approved; behavior in [docs/features/calendar-view.md](docs/features/calendar-view.md). It moves to top-level navigation when Plans ships (see §5).

### Timeline Row Redesign — Next
- **What**: Denser timeline rows: a leading column with weekday and day number, a three-line text preview, one metadata line (time · place), and one large trailing thumbnail.
- **Constraint**: Keep system navigation and system components; no custom dark header.
- **Scope touches**: Timeline row layout (#13–#18); Apple Native invariant must hold.
- **Open**: Row layout under large Dynamic Type sizes; rows without photos; iPad and iPhone Duo widths.

### Entry Info Footer — Next
- **What**: A quiet line at the end of an entry showing its time, date, and place.
- **Scope touches**: Editor layout; uses existing Entry Info only.
- **Open**: Whether the footer also shows in the editor while typing or only when reading; tap behavior.

### Weather — Exploring
- **What**: Show the weather for an entry beside its time and place.
- **Directions**: (a) keep weather data from Day One Import, which is currently skipped, and store it locally; (b) fetch weather for new entries with WeatherKit.
- **Scope touches**: Direction (b) conflicts with the Local-Only & Private invariant (no remote services). Direction (a) changes Day One Import (#47–#53).
- **Open**: Whether to change scope at all; decided in the item's design review.

## 2. Writing & Content

### Mood — Next
- **What**: Pick one mood per entry from a set of five custom-drawn faces (happy, calm, sad, angry, tired).
- **Export**: Mood is written to Markdown Export front matter.
- **Scope touches**: Content Model (new entry field); Markdown Export (#54–#56).
- **Open**: Where the picker sits in the editor; whether the Calendar View can show mood instead of a thumbnail; whether a mood can be cleared.

### Reflection — Next
- **What**: A dated note added under an existing entry, written later to record how the writer sees that memory now. The original entry text is not changed.
- **Rules**: Each Reflection carries its own date. Reflections can be edited or deleted; their edit history is not kept. Search covers Reflections. Markdown Export appends them after the entry.
- **Edit marking**: When the original entry text is changed later, the entry shows an "Edited on" date. No full version history or diff.
- **Scope touches**: Content Model; Search (#19–#20); Markdown Export (#54–#56).
- **Open**: The threshold after which an edit counts as "later"; Reflection layout in the timeline row.

### Voice Block — Later
- **What**: A recorded voice clip as a new block type, usable in any entry and in Time Capsules.
- **Scope touches**: Non-goal "No audio"; Content Model (new block type); Markdown Export (audio files).
- **Open**: Recording UI, maximum length, file format, microphone permission copy.

### Video — Exploring
- **What**: Recorded or library video as a block.
- **Scope touches**: Non-goals "No video" and "No in-app camera"; storage size.
- **Open**: Whether video belongs in Liney at all.

## 3. Time Capsule — Later

- **What**: An entry sealed until an opening date chosen by the writer. A letter to one's future self is a Time Capsule.
- **Seal**: Time is the only lock. There is no separate password, because Liney keeps data only on the device and has no recovery path; a forgotten password would lose the content forever. Changing the device clock opens a capsule early; this is accepted, because the seal is a ritual, not a security feature. App Lock protects an opened capsule like any entry.
- **While sealed**: The timeline shows a locked row with its opening date. Content cannot be viewed or edited. There is no "open early" action. The capsule can be deleted.
- **On opening day**: An optional local notification.
- **Export**: Sealed capsules are included in Markdown Export, because export is the only backup and losing content is worse than an early peek. Export already requires fresh authentication when App Lock is on.
- **Content**: Text first; voice when the Voice Block ships.
- **Scope touches**: Content Model (sealed state, opening date); timeline rows; Markdown Export; the notification conflicts with the non-goal "No reminders".
- **Open**: Whether the timeline places a capsule at its writing date or its opening date; minimum and maximum seal durations; the opening moment's presentation.

## 4. Personalization — Exploring

### Stickers & Paper Themes
- **What**: Stickers as a new block type that flows in order with Text Blocks and Photo Groups, plus a few paper themes for the entry background. Liney ships a built-in sticker library; users can import their own.
- **Not**: A free-form canvas with stickers placed, rotated, or layered anywhere on the page.
- **Art**: Shares one visual style with the Mood faces.
- **Scope touches**: Content Model; non-goal "No rich text styles"; Apple Native invariant (Liney Aqua stays an accent; themes must not become full-screen color).
- **Open**: Imported sticker formats; how paper themes behave in dark mode; export representation.

## 5. Plans — Exploring

- **What**: A separate section for goals and to-dos, kept apart from the journal. Plans can be checked off and can carry an optional date. Plans never send reminders.
- **Navigation**: When Plans ships, top-level navigation becomes Calendar / Journal / Plans (tab bar on iPhone, sidebar on iPad). Selecting a day in the calendar shows that day's entries and dated Plans together; undated Plans appear only in the Plans section.
- **Scope touches**: Single Journal invariant; non-goal "No reminders" (Plans stay reminder-free); width-adaptive navigation (#62–#63); Markdown Export.
- **Open**: Whether Plans are included in Markdown Export; recurring Plans; what happens to past-dated unfinished Plans.

## 6. Draft Terms

These terms move into [GLOSSARY.md](GLOSSARY.md) when their feature enters scope.

**Time Capsule**:
An entry sealed until an opening date, unreadable and uneditable before that date.
_Avoid_: Sealed diary, locked entry (App Lock is a different concept)

**Reflection**:
A dated note added later under an existing entry, without changing the entry's text.
_Avoid_: Comment, timeline (timeline means the entry list)

**Mood**:
One face chosen from a fixed custom set to describe the feeling of an entry.

**Plan**:
A goal or to-do in the Plans section, with an optional date and no reminder.
_Avoid_: Schedule, event, reminder

**Sticker**:
A decorative image placed as its own block in an entry.
